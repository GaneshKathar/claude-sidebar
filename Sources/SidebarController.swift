import AppKit
import Carbon
import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "SidebarController")

// MARK: - Flipped View (content starts from top)

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Sidebar Controller (Window-Centric)

class SidebarController {
    private enum DockSide { case left, right }

    private let window: NSPanel
    private let contentView: FlippedView
    private let scrollView: NSScrollView
    private let docView: FlippedView
    private let windowStack: NSStackView
    private let scanner = ITermScanner()
    private let processMonitor = ProcessMonitor()

    private var windowButtons: [Int: WindowButton] = [:]
    private var windows: [ITermWindowInfo] = []
    private var expandedWindows: Set<Int> = []
    private let settingsController = SettingsWindowController()

    // CWD-based grouping for non-repo slots (stable across scans)
    private var cwdGroupWindowIds: [String: Int] = [:]   // groupKey -> stable windowId
    private var cwdGroupLabels: [String: String] = [:]   // groupKey -> display label
    private var cwdGroupNextId = -20001
    private var cwdGroupNextLabel = 1

    // Timers
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var processTickTimer: Timer?   // 1s tick for running process durations
    private var darwinObserverRegistered = false
    private var lastITermWindowCount = -1
    private var windowWatchTimer: Timer?

    // Observer tokens for proper cleanup
    private var wsActivateObserver: NSObjectProtocol?
    private var wsDeactivateObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?
    private var windowMoveObserver: NSObjectProtocol?

    // Keyboard shortcuts (Carbon hotkeys — no Accessibility permission needed)
    private var hotkeyRefs: [EventHotKeyRef?] = []

    // Dock side
    private var dockSide: DockSide = .right
    private var snapWorkItem: DispatchWorkItem?

    // Drag state
    private var isDragging = false
    private var userY: CGFloat?          // set whenever the user drags; nil = use default (center)

    // Width state
    private let collapsedWidth: CGFloat = 62
    private let expandedWidth: CGFloat = 300
    private var isSidebarExpanded = false
    private var isAnimating = false
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?

    // Header/Footer views
    private let headerView = FlippedView()
    private let footerView = FlippedView()
    private let logoView = NSView()
    private let titleLabel = NSTextField(labelWithString: "Claude Manager")

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 62, height: 500),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true

        // Main content view — flipped so y=0 is at top
        contentView = FlippedView()
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 16
        contentView.layer?.backgroundColor = Theme.bg.cgColor
        contentView.layer?.borderColor = Theme.border.cgColor
        contentView.layer?.borderWidth = 1
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        // --- Scroll view (frame-based, resized manually) ---
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        contentView.addSubview(scrollView)

        docView = FlippedView()
        scrollView.documentView = docView

        windowStack = NSStackView()
        windowStack.orientation = .vertical
        windowStack.spacing = 12
        windowStack.alignment = .leading
        windowStack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(windowStack)

        NSLayoutConstraint.activate([
            windowStack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 12),
            windowStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 12),
            windowStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -12),
            windowStack.bottomAnchor.constraint(lessThanOrEqualTo: docView.bottomAnchor, constant: -12),
        ])

        // --- Header ---
        setupHeader()
        contentView.addSubview(headerView)

        // --- Footer ---
        setupFooter()
        contentView.addSubview(footerView)

        positionWindow()
        layoutSubviews()
        setupHoverTracking()
        setupKeyboardShortcuts()
        setupScreenChangeObserver()
        setupWindowMoveObserver()
    }

    deinit {
        snapWorkItem?.cancel()
        // Invalidate all timers
        fastTimer?.invalidate()
        slowTimer?.invalidate()
        windowWatchTimer?.invalidate()

        // Remove event monitors
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        for ref in hotkeyRefs {
            if let ref = ref { UnregisterEventHotKey(ref) }
        }

        // Remove Darwin notification observer
        if darwinObserverRegistered {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterRemoveObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName("com.claudesidebar.update" as CFString),
                nil
            )
        }

        // Remove NSWorkspace observers
        let ws = NSWorkspace.shared.notificationCenter
        if let obs = wsActivateObserver { ws.removeObserver(obs) }
        if let obs = wsDeactivateObserver { ws.removeObserver(obs) }

        // Remove screen change observer
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }

        // Remove window move observer
        if let obs = windowMoveObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Layout (frame-based, called on resize)

    private func layoutSubviews() {
        let w = contentView.bounds.width
        let h = contentView.bounds.height
        let headerH: CGFloat = 48
        let footerH: CGFloat = isSidebarExpanded ? 44 : 0

        headerView.frame = NSRect(x: 0, y: 0, width: w, height: headerH)

        // Center logo in collapsed, left-align in expanded
        if isSidebarExpanded {
            logoView.frame = NSRect(x: 17, y: 10, width: 28, height: 28)
        } else {
            logoView.frame = NSRect(x: (w - 28) / 2, y: 10, width: 28, height: 28)
        }

        let scrollTop = headerH + 4
        let scrollH = h - scrollTop - footerH
        scrollView.frame = NSRect(x: 0, y: scrollTop, width: w, height: max(scrollH, 0))

        footerView.frame = NSRect(x: 0, y: h - footerH, width: w, height: footerH)
        footerView.isHidden = !isSidebarExpanded

        // Document view width must match scroll view clip bounds
        let clipW = scrollView.contentView.bounds.width
        docView.frame = NSRect(x: 0, y: 0, width: clipW, height: max(docView.frame.height, scrollH))

        // After stack layout, resize docView to fit content
        windowStack.layoutSubtreeIfNeeded()
        let contentHeight = windowStack.fittingSize.height + 24  // 12px top + 12px bottom margins
        docView.frame = NSRect(x: 0, y: 0, width: clipW, height: max(contentHeight, scrollH))
    }

    // MARK: - Header

    private func setupHeader() {
        headerView.wantsLayer = true

        logoView.wantsLayer = true
        logoView.layer?.cornerRadius = 6
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor(red: 99/255, green: 102/255, blue: 241/255, alpha: 1).cgColor,
            NSColor(red: 139/255, green: 92/255, blue: 246/255, alpha: 1).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        gradient.cornerRadius = 6
        logoView.layer?.addSublayer(gradient)
        logoView.frame = NSRect(x: 17, y: 10, width: 28, height: 28)
        headerView.addSubview(logoView)

        let logoText = NSTextField(labelWithString: "C")
        logoText.font = Theme.font(ofSize: 13, weight: .semibold)
        logoText.textColor = .white
        logoText.alignment = .center
        logoText.isBezeled = false
        logoText.drawsBackground = false
        logoText.isEditable = false
        logoText.isSelectable = false
        logoText.frame = NSRect(x: 0, y: 3, width: 28, height: 22)
        logoView.addSubview(logoText)

        titleLabel.font = Theme.font(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor(white: 1.0, alpha: 0.8)
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.alphaValue = 0
        titleLabel.frame = NSRect(x: 55, y: 14, width: 200, height: 20)
        headerView.addSubview(titleLabel)

        let headerBorder = NSView()
        headerBorder.wantsLayer = true
        headerBorder.layer?.backgroundColor = Theme.border.cgColor
        headerBorder.frame = NSRect(x: 0, y: 47, width: 300, height: 1)
        headerBorder.autoresizingMask = [.width]
        headerView.addSubview(headerBorder)
    }

    // MARK: - Footer

    private func setupFooter() {
        footerView.wantsLayer = true
        footerView.isHidden = true

        let footerBorder = NSView()
        footerBorder.wantsLayer = true
        footerBorder.layer?.backgroundColor = Theme.border.cgColor
        footerBorder.frame = NSRect(x: 0, y: 0, width: 300, height: 1)
        footerBorder.autoresizingMask = [.width]
        footerView.addSubview(footerBorder)

        let settingsBtn = makeFooterButton(title: "\u{2699} Settings")
        settingsBtn.frame = NSRect(x: 8, y: 6, width: 130, height: 32)
        settingsBtn.target = self
        settingsBtn.action = #selector(settingsTapped)
        footerView.addSubview(settingsBtn)
    }

    private func makeFooterButton(title: String) -> NSButton {
        let btn = NSButton(title: title, target: nil, action: nil)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 6
        btn.layer?.borderColor = Theme.border.cgColor
        btn.layer?.borderWidth = 1
        btn.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
        btn.font = Theme.font(ofSize: 11)
        btn.contentTintColor = NSColor(white: 1.0, alpha: 0.4)
        return btn
    }

    @objc private func settingsTapped() {
        settingsController.onSave = { [weak self] newConfig in
            appConfig = newConfig
            self?.reload()
        }
        settingsController.showWindow()
    }

    // MARK: - Position

    /// Returns the screen whose frame contains the window's center, or falls back to NSScreen.main.
    private func screenForWindow() -> NSScreen? {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
    }

    /// Clamps a Y origin so the window stays within the visible frame.
    private func clampY(_ y: CGFloat, height: CGFloat, in sf: NSRect) -> CGFloat {
        min(max(y, sf.minY), sf.maxY - height)
    }

    private func collapsedContentHeight() -> CGFloat {
        let headerH: CGFloat = 48
        let padding: CGFloat = 28  // 4(scrollOffset) + 12(stackTop) + 12(stackBottom)
        windowStack.layoutSubtreeIfNeeded()
        let stackH = windowStack.fittingSize.height
        let minHeight: CGFloat = 80
        return max(headerH + stackH + padding, minHeight)
    }

    private func resizeCollapsedToFitContent() {
        guard let screen = screenForWindow() else { return }
        let sf = screen.visibleFrame
        let targetH = collapsedContentHeight()
        let frame = window.frame
        // Only resize if height changed meaningfully
        guard abs(frame.height - targetH) > 2 else { return }
        let baseY = userY ?? (sf.midY - targetH / 2)
        let newY = clampY(baseY, height: targetH, in: sf)
        let newFrame = NSRect(x: frame.origin.x, y: newY, width: frame.width, height: targetH)
        window.setFrame(newFrame, display: true)
        layoutSubviews()
    }

    private func positionWindow() {
        guard let screen = screenForWindow() else { return }
        let sf = screen.visibleFrame
        let currentWidth = isSidebarExpanded ? expandedWidth : collapsedWidth
        let h = isSidebarExpanded ? sf.height * 0.7 : collapsedContentHeight()
        let x: CGFloat
        switch dockSide {
        case .right: x = sf.maxX - currentWidth
        case .left:  x = sf.minX
        }
        let baseY = userY ?? (sf.midY - h / 2)
        let y = clampY(baseY, height: h, in: sf)
        window.setFrame(NSRect(x: x, y: y, width: currentWidth, height: h), display: true)
    }

    // MARK: - Screen Change Handling

    private func setupScreenChangeObserver() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
    }

    private func handleScreenChange() {
        guard let screen = screenForWindow() else {
            positionWindow()  // fallback: no screen found
            return
        }
        let sf = screen.visibleFrame
        var frame = window.frame

        // If window is off-screen, reposition to default
        if !sf.intersects(frame) {
            positionWindow()
            return
        }

        // Re-snap to dock edge
        switch dockSide {
        case .right: frame.origin.x = sf.maxX - frame.width
        case .left:  frame.origin.x = sf.minX
        }
        frame.origin.y = clampY(frame.origin.y, height: frame.height, in: sf)
        window.setFrame(frame, display: true)
    }

    // MARK: - Drag-to-Snap

    private func setupWindowMoveObserver() {
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowMoved()
        }
    }

    private func handleWindowMoved() {
        guard !isAnimating else { return }
        isDragging = true
        userY = window.frame.origin.y
        // Debounce: schedule snap check after a brief delay (user may still be dragging)
        snapWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.snapAfterDrag()
        }
        snapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func snapAfterDrag() {
        guard !isAnimating else { return }
        guard let screen = screenForWindow() else { return }
        let sf = screen.visibleFrame
        let frame = window.frame

        // Nearest edge wins (distance from window edge to screen edge)
        let distToLeft = frame.minX - sf.minX
        let distToRight = sf.maxX - frame.maxX

        dockSide = distToLeft <= distToRight ? .left : .right

        let targetX: CGFloat
        switch dockSide {
        case .right: targetX = sf.maxX - frame.width
        case .left:  targetX = sf.minX
        }

        let clampedY = clampY(frame.origin.y, height: frame.height, in: sf)
        let snappedFrame = NSRect(x: targetX, y: clampedY,
                                  width: frame.width, height: frame.height)

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(snappedFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.isAnimating = false
            self?.isDragging = false
        })
    }

    // MARK: - Hover Expand/Collapse

    private func setupHoverTracking() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) { [weak self] event in
            self?.checkMousePosition()
            return event
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.checkMousePosition()
        }
    }

    private func checkMousePosition() {
        guard !isAnimating, !isDragging else { return }
        // Minimal mode: never expand on hover
        if appConfig.minimalView == true { return }

        let mouse = NSEvent.mouseLocation
        let frame = window.frame

        // Expand hit zone a few pixels beyond the window edges for easier targeting
        let hitZone = NSRect(x: frame.origin.x - 4, y: frame.origin.y - 4,
                             width: frame.width + 8, height: frame.height + 8)

        // Don't expand when hovering the header (logo area) — keep it free for dragging
        let headerH: CGFloat = 48
        let inHeader = mouse.y >= frame.origin.y + frame.height - headerH
            && mouse.x >= frame.origin.x && mouse.x <= frame.maxX

        if hitZone.contains(mouse) && !isSidebarExpanded && !inHeader {
            expandSidebar()
        } else if !hitZone.contains(mouse) && isSidebarExpanded {
            collapseSidebar()
        }
    }

    private func expandSidebar() {
        guard !isSidebarExpanded, !isAnimating else { return }
        isSidebarExpanded = true
        isAnimating = true

        let frame = window.frame
        guard let screen = screenForWindow() else { isAnimating = false; return }
        let sf = screen.visibleFrame
        let expandedHeight = sf.height * 0.7

        let newX: CGFloat
        switch dockSide {
        case .right: newX = frame.maxX - expandedWidth
        case .left:  newX = frame.origin.x
        }
        // Preserve user's Y position instead of always centering
        let baseY = userY ?? (sf.midY - expandedHeight / 2)
        let newY = clampY(baseY, height: expandedHeight, in: sf)
        let newFrame = NSRect(x: newX, y: newY, width: expandedWidth, height: expandedHeight)

        // Switch buttons to expanded BEFORE animation so layout is ready
        for (_, btn) in windowButtons {
            btn.isExpanded = true
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
            titleLabel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.isAnimating = false
            self.footerView.isHidden = false
            self.layoutSubviews()
        })
    }

    private func collapseSidebar() {
        guard isSidebarExpanded, !isAnimating else { return }
        isSidebarExpanded = false
        isAnimating = true

        footerView.isHidden = true

        // Switch buttons to collapsed BEFORE measuring so fittingSize is correct
        for (_, btn) in windowButtons {
            btn.isExpanded = false
        }
        windowStack.layoutSubtreeIfNeeded()

        let frame = window.frame
        let collapsedHeight = collapsedContentHeight()

        let newX: CGFloat
        switch dockSide {
        case .right: newX = frame.maxX - collapsedWidth
        case .left:  newX = frame.origin.x
        }
        guard let screen = screenForWindow() else { isAnimating = false; return }
        let sf = screen.visibleFrame
        // Preserve user's Y position instead of always centering
        let baseY = userY ?? (sf.midY - collapsedHeight / 2)
        let newY = clampY(baseY, height: collapsedHeight, in: sf)
        let newFrame = NSRect(x: newX, y: newY, width: collapsedWidth, height: collapsedHeight)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
            titleLabel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.isAnimating = false
            self.layoutSubviews()
        })
    }

    // MARK: - Keyboard Shortcuts (Option+Shift+Number via CGEvent tap)

    private func setupKeyboardShortcuts() {
        // Install Carbon event handler for hotkey events
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, refcon) -> OSStatus in
                guard let refcon = refcon else { return OSStatus(eventNotHandledErr) }
                let sidebar = Unmanaged<SidebarController>.fromOpaque(refcon).takeUnretainedValue()

                var hotkeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)

                let repoNum = Int(hotkeyID.id)
                DispatchQueue.main.async {
                    if repoNum == 100 {
                        sidebar.toggleSidebarViaHotkey()
                    } else {
                        sidebar.focusHighPriorityTab(forRepoNum: repoNum)
                    }
                }
                return noErr
            },
            1, &eventType, refcon, nil
        )

        // Carbon key codes for 1-9 (top row)
        let keyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]  // 1,2,3,4,5,6,7,8,9
        let modifiers: UInt32 = UInt32(optionKey | shiftKey)  // Option+Shift

        for (index, keyCode) in keyCodes.enumerated() {
            let repoNum = index + 1
            var hotkeyID = EventHotKeyID(signature: OSType(0x434C5349), id: UInt32(repoNum))  // "CLSI"
            var hotkeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(keyCode, modifiers, hotkeyID,
                                             GetApplicationEventTarget(), 0, &hotkeyRef)
            if status == noErr {
                hotkeyRefs.append(hotkeyRef)
            } else {
                hotkeyRefs.append(nil)
            }
        }

        // Register Opt+Shift+0 as sidebar toggle (key code 29 = "0", ID 100)
        var toggleHotkeyID = EventHotKeyID(signature: OSType(0x434C5349), id: UInt32(100))
        var toggleHotkeyRef: EventHotKeyRef?
        let toggleStatus = RegisterEventHotKey(29, modifiers, toggleHotkeyID,
                                               GetApplicationEventTarget(), 0, &toggleHotkeyRef)
        if toggleStatus == noErr {
            hotkeyRefs.append(toggleHotkeyRef)
        } else {
            hotkeyRefs.append(nil)
        }

        let registered = hotkeyRefs.compactMap({ $0 }).count
        try? "Registered \(registered)/10 hotkeys\n".write(toFile: "/tmp/claude-sidebar-hotkey.log", atomically: true, encoding: .utf8)
    }

    private func toggleSidebarViaHotkey() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.orderFront(nil)
        }
    }

    private func focusHighPriorityTab(forRepoNum repoNum: Int) {
        // Hotkey N maps to slot N-1 (1-indexed: repos first, then non-repo windows)
        let slots = buildSlots()
        let slotIndex = repoNum - 1
        guard slotIndex >= 0, slotIndex < slots.count else {
            os_log("Hotkey: no slot for position %d", log: logger, type: .info, repoNum)
            return
        }
        let win = slots[slotIndex]

        // Placeholder — open a new iTerm window for the repo
        if win.isPlaceholder {
            if let repoNum = win.matchedRepoNum,
               let repo = appConfig.repos.first(where: { $0.num == repoNum }) {
                scanner.openWindowWithCWD(path: repo.expandedPath)
            }
            return
        }

        // Focus the highest-priority tab (same logic as minimal mode click)
        let tab = win.tabs.max(by: { $0.state < $1.state }) ?? win.tabs.first
        if let tab = tab {
            scanner.focusSession(windowId: tab.windowId, sessionId: tab.sessionId)
        }
    }

    // MARK: - Start / Reload

    func start() {
        startDarwinObserver()

        // Run full scan + process scan before showing the window so it
        // appears already populated rather than flashing empty then filling in.
        fullPollInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let initialWindows = self.scanner.scan()

            // Also run the fast (process/CWD/branch) scan while we're on background
            let ttys = initialWindows.flatMap { $0.tabs.map { $0.tty } }
            let scanResult = ttys.isEmpty ? ProcessMonitor.ScanResult() : self.processMonitor.discoverProcesses(ttys: ttys)
            let cwds = self.processMonitor.detectCWDs(shellPIDs: scanResult.shellPIDs)
            var branches: [String: String] = [:]
            for (tty, cwd) in cwds {
                if let branch = self.scanner.getBranch(cwd: cwd) { branches[tty] = branch }
            }

            DispatchQueue.main.async {
                // Apply full scan (sets fullPollInFlight = false via defer)
                self.applyFullPollResults(initialWindows)

                // Overlay process/CWD/branch data from fast scan
                for wi in 0..<self.windows.count {
                    for ti in 0..<self.windows[wi].tabs.count {
                        let tty = self.windows[wi].tabs[ti].tty
                        if let cwd = cwds[tty] { self.windows[wi].tabs[ti].cwd = cwd }
                        if let branch = branches[tty] { self.windows[wi].tabs[ti].gitBranch = branch }
                        if scanResult.claudeTTYs.contains(tty) {
                            self.windows[wi].tabs[ti].hasClaude = true
                        }
                    }
                }
                self.updateUI()

                // Now show the window — fully populated
                self.window.orderFront(nil)
                self.startTimers()
            }
        }
    }

    func reload() {
        windowButtons.values.forEach { $0.removeFromSuperview() }
        windowButtons.removeAll()
        expandedWindows.removeAll()
        startTimers()
        startDarwinObserver()
        if appConfig.minimalView == true && isSidebarExpanded {
            collapseSidebar()
        }
        fullPoll()
    }

    // MARK: - Three-Tier Polling

    private func startTimers() {
        fastTimer?.invalidate()
        slowTimer?.invalidate()
        windowWatchTimer?.invalidate()

        fastTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.fastPoll()
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: appConfig.pollInterval ?? 30.0, repeats: true) { [weak self] _ in
            self?.fullPoll()
        }
        windowWatchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkTerminalWindowCounts()
        }
    }

    private func checkTerminalWindowCounts() {
        let count = terminalWindowCount()
        if count != lastITermWindowCount {
            lastITermWindowCount = count
            fullPoll()
        }
    }

    // Count on-screen windows belonging to any supported terminal emulator.
    // Uses CGWindowListCopyWindowInfo (~0.5ms) — safe to call on main thread every 1s.
    private func terminalWindowCount() -> Int {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return 0 }

        return windowList.filter { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String else { return false }
            return ITermScanner.isKnownTerminal(owner.lowercased())
        }.count
    }

    private func startDarwinObserver() {
        guard !darwinObserverRegistered else { return }
        darwinObserverRegistered = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let sidebar = Unmanaged<SidebarController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { sidebar.instantUpdate() }
            },
            "com.claudesidebar.update" as CFString,
            nil,
            .deliverImmediately
        )

        let ws = NSWorkspace.shared.notificationCenter

        // Remove previous observers if any (prevents duplication)
        if let obs = wsActivateObserver { ws.removeObserver(obs) }
        if let obs = wsDeactivateObserver { ws.removeObserver(obs) }

        wsActivateObserver = ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  ITermScanner.isKnownTerminal((app.localizedName ?? "").lowercased()) else { return }
            self?.fullPoll()
        }
        wsDeactivateObserver = ws.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  ITermScanner.isKnownTerminal((app.localizedName ?? "").lowercased()) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.fullPoll() }
        }
    }

    // MARK: - Poll Methods

    private func instantUpdate() {
        if fullPollInFlight {
            pendingInstantUpdate = true
            return
        }
        let hookStates = scanner.readHookStates()
        for wi in 0..<windows.count {
            for ti in 0..<windows[wi].tabs.count {
                let tty = windows[wi].tabs[ti].tty
                let hasClaude = windows[wi].tabs[ti].hasClaude || hookStates.byTTY[tty] != nil
                windows[wi].tabs[ti].hasClaude = hasClaude
                if hasClaude {
                    if let ttyState = hookStates.byTTY[tty] {
                        windows[wi].tabs[ti].claudeState = SessionState.fromString(ttyState)
                    } else {
                        windows[wi].tabs[ti].claudeState = .idle
                    }
                }
            }
        }
        updateUI()
    }

    private func fastPoll() {
        let ttys = windows.flatMap { $0.tabs.map { $0.tty } }
        guard !ttys.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let scanResult = self.processMonitor.discoverProcesses(ttys: ttys)

            // Batch CWD detection from shell PIDs
            let cwds = self.processMonitor.detectCWDs(shellPIDs: scanResult.shellPIDs)

            // Batch branch detection from CWDs
            var branches: [String: String] = [:]
            for (tty, cwd) in cwds {
                if let branch = self.scanner.getBranch(cwd: cwd) {
                    branches[tty] = branch
                }
            }

            DispatchQueue.main.async {
                // Apply updates to current windows (may have changed since snapshot)
                for wi in 0..<self.windows.count {
                    for ti in 0..<self.windows[wi].tabs.count {
                        let tty = self.windows[wi].tabs[ti].tty

                        // Update Claude detection from process scan
                        if scanResult.claudeTTYs.contains(tty) {
                            self.windows[wi].tabs[ti].hasClaude = true
                            if self.windows[wi].tabs[ti].claudeState == .inactive {
                                self.windows[wi].tabs[ti].claudeState = .idle
                            }
                            // Watch this Claude PID — kqueue fires instantly when killed/crashed
                            if let claudePID = scanResult.claudePIDs[tty],
                               !self.watchedClaudePIDs.contains(claudePID) {
                                self.watchedClaudePIDs.insert(claudePID)
                                self.processMonitor.watchPID(claudePID, tty: tty) { [weak self] _ in
                                    self?.handleClaudeExit(tty: tty, pid: claudePID)
                                }
                            }
                        } else if self.windows[wi].tabs[ti].hasClaude {
                            // Claude gone from ps — clear immediately regardless of state
                            self.windows[wi].tabs[ti].hasClaude = false
                            self.windows[wi].tabs[ti].claudeState = .inactive
                        }

                        // Update CWD from shell process
                        if let cwd = cwds[tty] {
                            self.windows[wi].tabs[ti].cwd = cwd
                        }

                        // Update branch
                        if let branch = branches[tty] {
                            self.windows[wi].tabs[ti].gitBranch = branch
                        }

                        // Update non-Claude process info
                        if let proc = scanResult.processes[tty] {
                            if self.windows[wi].tabs[ti].processInfo == nil ||
                               self.windows[wi].tabs[ti].processInfo?.pid != proc.pid {
                                self.windows[wi].tabs[ti].processInfo = proc
                                self.processMonitor.watchPID(Int32(proc.pid), tty: tty) { [weak self] exitCode in
                                    self?.handleProcessExit(tty: tty, exitCode: exitCode)
                                }
                            }
                        } else if self.windows[wi].tabs[ti].processInfo?.pid == -1 {
                            // fastPoll found no foreground process but fullPoll left a synthetic pid=-1.
                            // Clear it so stale synthetic entries don't keep the tab showing "working".
                            self.windows[wi].tabs[ti].processInfo = nil
                        }
                    }
                }
                self.updateUI()
            }
        }
    }

    private var watchedClaudePIDs: Set<Int32> = []
    private var fullPollInFlight = false
    private var pendingInstantUpdate = false
    private func fullPoll() {
        guard !fullPollInFlight else { return }
        fullPollInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let newWindows = self.scanner.scan()
            DispatchQueue.main.async { self.applyFullPollResults(newWindows) }
        }
    }

    private func applyFullPollResults(_ newWindows: [ITermWindowInfo]) {
        defer {
            fullPollInFlight = false
            if pendingInstantUpdate {
                pendingInstantUpdate = false
                instantUpdate()
            }
        }

        if !newWindows.isEmpty {
            var merged = newWindows
            for wi in 0..<merged.count {
                for ti in 0..<merged[wi].tabs.count {
                    let tty = merged[wi].tabs[ti].tty
                    if let oldWindow = windows.first(where: { $0.windowId == merged[wi].windowId }),
                       let oldTab = oldWindow.tabs.first(where: { $0.tty == tty }) {
                        // Process info priority: real pid (from fastPoll) > synthetic pid=-1 (from fullPoll) > nil.
                        // fastPoll has kqueue watchers on real pids — never let fullPoll's
                        // synthetic overwrite a running real process.
                        if let old = oldTab.processInfo, old.pid > 0, old.exitCode == nil,
                           (merged[wi].tabs[ti].processInfo?.pid ?? -1) <= 0 {
                            merged[wi].tabs[ti].processInfo = old
                        }
                        if merged[wi].tabs[ti].cwd == nil, let oldCwd = oldTab.cwd {
                            merged[wi].tabs[ti].cwd = oldCwd
                        }
                        if merged[wi].tabs[ti].gitBranch == nil, let oldBranch = oldTab.gitBranch {
                            merged[wi].tabs[ti].gitBranch = oldBranch
                        }
                        // Preserve Claude detection from ps scan
                        if oldTab.hasClaude && !merged[wi].tabs[ti].hasClaude {
                            merged[wi].tabs[ti].hasClaude = true
                            merged[wi].tabs[ti].claudeState = oldTab.claudeState
                        }
                    }
                }
            }
            windows = merged

            for w in windows where w.hasActiveSession {
                expandedWindows.insert(w.windowId)
            }
        }
        updateUI()
    }

    private func handleClaudeExit(tty: String, pid: Int32) {
        watchedClaudePIDs.remove(pid)
        for wi in 0..<windows.count {
            for ti in 0..<windows[wi].tabs.count {
                if windows[wi].tabs[ti].tty == tty {
                    windows[wi].tabs[ti].hasClaude = false
                    windows[wi].tabs[ti].claudeState = .inactive
                }
            }
        }
        updateUI()
    }

    private func handleProcessExit(tty: String, exitCode: Int32) {
        for wi in 0..<windows.count {
            for ti in 0..<windows[wi].tabs.count {
                if windows[wi].tabs[ti].tty == tty {
                    windows[wi].tabs[ti].processInfo?.exitCode = Int(exitCode)
                }
            }
        }
        updateUI()

        // Auto-clear completed/failed process after 3 seconds → transition back to idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            for wi in 0..<self.windows.count {
                for ti in 0..<self.windows[wi].tabs.count {
                    if self.windows[wi].tabs[ti].tty == tty,
                       self.windows[wi].tabs[ti].processInfo?.exitCode != nil {
                        self.windows[wi].tabs[ti].processInfo = nil
                    }
                }
            }
            self.updateUI()
        }
    }

    // MARK: - Process Duration Tick (1s timer, only when processes are running)

    private var currentTickInterval: TimeInterval = 0

    /// Compute optimal tick interval based on shortest-running process:
    ///   < 60 min  → 1s  (seconds visible: "1m 30s")
    ///   >= 60 min → 60s (only minutes: "1h 23m")
    private func optimalTickInterval() -> TimeInterval {
        var shortest: TimeInterval = .greatestFiniteMagnitude
        for tab in windows.flatMap({ $0.tabs }) {
            guard let proc = tab.processInfo, proc.exitCode == nil else { continue }
            shortest = min(shortest, proc.duration)
        }
        guard shortest < .greatestFiniteMagnitude else { return 0 }
        return shortest < 3600 ? 1.0 : 60.0
    }

    private func updateProcessTickTimer() {
        let interval = optimalTickInterval()

        if interval == 0 {
            // No running processes — stop timer
            processTickTimer?.invalidate()
            processTickTimer = nil
            currentTickInterval = 0
            return
        }

        // Recreate timer only if interval changed or timer doesn't exist
        if processTickTimer == nil || currentTickInterval != interval {
            processTickTimer?.invalidate()
            currentTickInterval = interval
            processTickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.tickProcessDurations()
            }
        }
    }

    private func tickProcessDurations() {
        let interval = optimalTickInterval()

        if interval == 0 {
            processTickTimer?.invalidate()
            processTickTimer = nil
            currentTickInterval = 0
            return
        }

        // Interval tier changed (e.g. process crossed 60min) — recreate timer
        if interval != currentTickInterval {
            updateProcessTickTimer()
        }

        // Nudge only buttons whose tabs have a running process —
        // the fingerprint includes durationString so only they rebuild.
        for (_, btn) in windowButtons {
            if btn.windowInfo.tabs.contains(where: { $0.processInfo != nil && $0.processInfo?.exitCode == nil }) {
                btn.update(windowInfo: btn.windowInfo)
            }
        }
    }

    // MARK: - Slot Building (repo-aggregated + CWD-grouped)

    // Walk up from cwd to find the nearest .git directory (project root)
    private func gitRoot(for cwd: String) -> String? {
        var path = cwd
        let fm = FileManager.default
        for _ in 0..<20 {
            if fm.fileExists(atPath: path + "/.git") { return path }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { break }  // reached filesystem root
            path = parent
        }
        return nil
    }

    private func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func buildSlots() -> [ITermWindowInfo] {
        var slots: [ITermWindowInfo] = []
        var claimedTTYs = Set<String>()

        // Flatten all tabs from all scanned windows.
        // Include alwaysShow tabs so all iTerm windows remain visible when showAllITermWindows is on.
        let allTabs = windows.flatMap { $0.tabs }.filter { tab in
            tab.hasClaude || tab.processInfo != nil || tab.alwaysShow
        }

        // 1. Repo slots: collect ALL tabs (from any terminal) whose CWD is under each repo path
        for repo in appConfig.repos {
            let repoPath = repo.expandedPath
            let repoTabs = allTabs.filter { tab in
                guard let cwd = tab.cwd else { return false }
                return cwd == repoPath || cwd.hasPrefix(repoPath + "/")
            }

            if repoTabs.isEmpty {
                slots.append(.placeholder(for: repo))
            } else {
                repoTabs.forEach { claimedTTYs.insert($0.tty) }
                // Re-index tabs so tabIndex is contiguous
                let indexedTabs = repoTabs.enumerated().map { idx, t -> ITermTabInfo in
                    var tab = t; tab.tabIndex = idx; return tab
                }
                // Window name: custom title if set, else last path component
                let slotName = repo.title ?? (repoPath as NSString).lastPathComponent
                slots.append(ITermWindowInfo(
                    windowId: -repo.num,
                    windowName: slotName,
                    displayLabel: repo.displayLabel,
                    displayPath: shortPath(repoPath),
                    tabs: indexedTabs,
                    matchedRepoNum: repo.num
                ))
            }
        }

        // 2. Non-repo tabs: group by git root (or exact CWD if no git root)
        let remaining = allTabs.filter { !claimedTTYs.contains($0.tty) }

        var cwdGroups: [String: [ITermTabInfo]] = [:]
        var unknownByWindow: [Int: [ITermTabInfo]] = [:]

        for tab in remaining {
            if let cwd = tab.cwd {
                let key = gitRoot(for: cwd) ?? cwd
                cwdGroups[key, default: []].append(tab)
            } else {
                unknownByWindow[tab.windowId, default: []].append(tab)
            }
        }

        // CWD groups sorted by path for stable order
        for (key, tabs) in cwdGroups.sorted(by: { $0.key < $1.key }) {
            if cwdGroupWindowIds[key] == nil {
                cwdGroupWindowIds[key] = cwdGroupNextId
                cwdGroupNextId -= 1
            }
            if cwdGroupLabels[key] == nil {
                cwdGroupLabels[key] = "\(cwdGroupNextLabel)"
                cwdGroupNextLabel += 1
            }
            let windowId = cwdGroupWindowIds[key]!
            let label = cwdGroupLabels[key]!

            let indexedTabs = tabs.sorted { $0.tabIndex < $1.tabIndex }.enumerated().map { idx, t -> ITermTabInfo in
                var tab = t; tab.tabIndex = idx; return tab
            }
            slots.append(ITermWindowInfo(
                windowId: windowId,
                windowName: (key as NSString).lastPathComponent,
                displayLabel: label,
                displayPath: shortPath(key),
                tabs: indexedTabs
            ))
            tabs.forEach { claimedTTYs.insert($0.tty) }
        }

        // Tabs with unknown CWD: fall back to original window grouping
        for (wid, tabs) in unknownByWindow.sorted(by: { $0.key < $1.key }) {
            let origWindow = windows.first(where: { $0.windowId == wid })
            let label: String
            if let orig = origWindow {
                label = orig.displayLabel
            } else {
                label = "\(cwdGroupNextLabel)"
                cwdGroupNextLabel += 1
            }
            let indexedTabs = tabs.sorted { $0.tabIndex < $1.tabIndex }.enumerated().map { idx, t -> ITermTabInfo in
                var tab = t; tab.tabIndex = idx; return tab
            }
            slots.append(ITermWindowInfo(
                windowId: wid,
                windowName: origWindow?.windowName ?? "Terminal",
                displayLabel: label,
                tabs: indexedTabs
            ))
        }

        return slots
    }

    // MARK: - UI Update

    private func updateUI() {
        let slots = buildSlots()
        let slotIds = Set(slots.map { $0.windowId })
        let isMinimal = appConfig.minimalView == true

        // Clean up removed windows and unwatch their PIDs
        for (id, btn) in windowButtons where !slotIds.contains(id) {
            if let oldWin = windows.first(where: { $0.windowId == id }) {
                for tab in oldWin.tabs {
                    if let proc = tab.processInfo, proc.exitCode == nil, proc.pid > 0 {
                        processMonitor.unwatchPID(Int32(proc.pid))
                    }
                }
            }
            btn.removeFromSuperview()
            windowButtons.removeValue(forKey: id)
        }

        for win in slots {
            if let btn = windowButtons[win.windowId] {
                btn.isMinimalMode = isMinimal
                btn.update(windowInfo: win)
                btn.isExpanded = isMinimal ? false : isSidebarExpanded
                // Repo slots reuse -repo.num for both placeholder and active states.
                // Set missing callbacks when a placeholder button gains real tabs.
                if btn.onFocusTab == nil {
                    btn.onFocusTab = { [weak self] tab in
                        self?.scanner.focusSession(windowId: tab.windowId, sessionId: tab.sessionId)
                    }
                }
                if btn.onFocusHighPriorityTab == nil {
                    btn.onFocusHighPriorityTab = { [weak self, weak btn] in
                        let tab = btn?.windowInfo.tabs.max(by: { $0.state < $1.state })
                                     ?? btn?.windowInfo.tabs.first
                        if let tab = tab {
                            self?.scanner.focusSession(windowId: tab.windowId, sessionId: tab.sessionId)
                        }
                    }
                }
            } else {
                let btn = WindowButton(windowInfo: win)
                btn.isMinimalMode = isMinimal
                btn.isExpanded = isMinimal ? false : isSidebarExpanded
                btn.onToggle = { [weak self] in
                    self?.toggleWindow(win.windowId)
                }
                btn.onFocusTab = { [weak self] tab in
                    self?.scanner.focusSession(windowId: tab.windowId, sessionId: tab.sessionId)
                }
                btn.onFocusHighPriorityTab = { [weak self, weak btn] in
                    let tab = btn?.windowInfo.tabs.max(by: { $0.state < $1.state })
                                 ?? btn?.windowInfo.tabs.first
                    if let tab = tab {
                        self?.scanner.focusSession(windowId: tab.windowId, sessionId: tab.sessionId)
                    }
                }
                if let repoNum = win.matchedRepoNum,
                   let repo = appConfig.repos.first(where: { $0.num == repoNum }) {
                    let repoPath = repo.expandedPath
                    btn.onOpenNewWindow = { [weak self] in
                        self?.scanner.openWindowWithCWD(path: repoPath)
                    }
                }
                btn.translatesAutoresizingMaskIntoConstraints = false
                windowStack.addArrangedSubview(btn)
                btn.widthAnchor.constraint(equalTo: windowStack.widthAnchor).isActive = true
                windowButtons[win.windowId] = btn
            }
        }

        // Reorder arranged subviews to match slot order
        for (index, win) in slots.enumerated() {
            if let btn = windowButtons[win.windowId] {
                windowStack.removeArrangedSubview(btn)
                windowStack.insertArrangedSubview(btn, at: index)
            }
        }

        // Start/stop 1s process duration timer based on running processes
        updateProcessTickTimer()

        // Update document view height to fit content
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.layoutSubviews()
            // When collapsed, resize window height to fit content
            if !self.isSidebarExpanded && !self.isAnimating {
                self.resizeCollapsedToFitContent()
            }
        }
    }

    private func toggleWindow(_ windowId: Int) {
        if expandedWindows.contains(windowId) {
            expandedWindows.remove(windowId)
        } else {
            expandedWindows.insert(windowId)
        }
        updateUI()
    }
}
