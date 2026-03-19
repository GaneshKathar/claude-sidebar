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

class SidebarController: PollingDelegate, DockingDelegate {
    private let window: NSPanel
    private let contentView: FlippedView
    private let scrollView: NSScrollView
    private let docView: FlippedView
    private let windowStack: NSStackView
    let scanner = TerminalScanner()
    private let processMonitor = ProcessMonitor()
    private let pollingCoordinator: PollingCoordinator

    var windowButtons: [Int: WindowButton] = [:]
    var windows: [TerminalWindow] = []
    var expandedWindows: Set<Int> = []
    private let settingsController = SettingsWindowController()

    private let slotBuilder = SlotBuilder()

    private let dockingManager: DockingManager

    private let keyboardManager = KeyboardShortcutManager()

    // Width state
    let collapsedWidth: CGFloat = 62
    let expandedWidth: CGFloat = 300
    var isSidebarExpanded = false
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?

    // Header/Footer views
    private let headerView = FlippedView()
    private let footerView = FlippedView()
    private let logoView = NSView()
    private let titleLabel = NSTextField(labelWithString: "Claude Manager")

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 62, height: 500),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        window = panel
        dockingManager = DockingManager(window: panel)
        pollingCoordinator = PollingCoordinator(scanner: scanner, processMonitor: processMonitor)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true

        // Main content view — flipped so y=0 is at top
        contentView = FlippedView()
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = Layout.cornerRadius
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

        pollingCoordinator.delegate = self
        dockingManager.delegate = self

        dockingManager.positionWindow()
        layoutSubviews()
        setupHoverTracking()
        setupKeyboardShortcuts()
        dockingManager.setupScreenChangeObserver()
        dockingManager.setupWindowMoveObserver()
    }

    deinit {
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        // DockingManager, PollingCoordinator, KeyboardShortcutManager handle own cleanup in deinit
    }

    // MARK: - Layout (frame-based, called on resize)

    func layoutSubviews() {
        let w = contentView.bounds.width
        let h = contentView.bounds.height
        let headerH: CGFloat = 0
        let footerH: CGFloat = isSidebarExpanded ? 44 : 0

        headerView.frame = NSRect(x: 0, y: 0, width: w, height: headerH)
        headerView.isHidden = true

        let scrollTop: CGFloat = 4
        let scrollH = h - scrollTop - footerH
        scrollView.frame = NSRect(x: 0, y: scrollTop, width: w, height: max(scrollH, 0))

        footerView.frame = NSRect(x: 0, y: h - footerH, width: w, height: footerH)
        footerView.isHidden = !isSidebarExpanded

        // Footer layout: vertically center all items (footer = 44px, center = 22px)
        let fy: CGFloat = (44 - 24) / 2  // 10px for 24px items
        if isSidebarExpanded {
            logoView.frame = NSRect(x: 12, y: fy, width: 24, height: 24)
            titleLabel.frame = NSRect(x: 44, y: fy + 2, width: w - 88, height: 20)
        } else {
            logoView.frame = NSRect(x: (w - 24) / 2, y: fy, width: 24, height: 24)
        }

        if let settingsBtn = footerView.subviews.first(where: { $0.tag == 999 }) {
            settingsBtn.frame = NSRect(x: w - 36, y: (44 - 28) / 2, width: 28, height: 28)
            settingsBtn.isHidden = !isSidebarExpanded
        }

        // Document view width must match scroll view clip bounds
        let clipW = scrollView.contentView.bounds.width
        docView.frame = NSRect(x: 0, y: 0, width: clipW, height: max(docView.frame.height, scrollH))

        // After stack layout, resize docView to fit content
        windowStack.layoutSubtreeIfNeeded()
        let contentHeight = windowStack.fittingSize.height + 24  // 12px top + 12px bottom margins
        docView.frame = NSRect(x: 0, y: 0, width: clipW, height: max(contentHeight, scrollH))
    }

    // MARK: - Header (empty — content moved to footer)

    private func setupHeader() {
        headerView.wantsLayer = true
    }

    // MARK: - Footer (logo + title + settings)

    private func setupFooter() {
        footerView.wantsLayer = true
        footerView.isHidden = false

        let footerBorder = NSView()
        footerBorder.wantsLayer = true
        footerBorder.layer?.backgroundColor = Theme.border.cgColor
        footerBorder.frame = NSRect(x: 0, y: 0, width: 300, height: 1)
        footerBorder.autoresizingMask = [.width]
        footerView.addSubview(footerBorder)

        // Logo
        logoView.wantsLayer = true
        logoView.layer?.cornerRadius = 6
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor(red: 99/255, green: 102/255, blue: 241/255, alpha: 1).cgColor,
            NSColor(red: 139/255, green: 92/255, blue: 246/255, alpha: 1).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        gradient.cornerRadius = 5
        logoView.layer?.addSublayer(gradient)
        logoView.frame = NSRect(x: 10, y: 10, width: 24, height: 24)
        footerView.addSubview(logoView)

        let logoText = NSTextField(labelWithString: "C")
        logoText.font = Theme.font(ofSize: 12, weight: .bold)
        logoText.textColor = .white
        logoText.alignment = .center
        logoText.isBezeled = false
        logoText.drawsBackground = false
        logoText.isEditable = false
        logoText.isSelectable = false
        // Vertically center: use full frame and let text alignment handle it
        logoText.frame = NSRect(x: 0, y: 4, width: 24, height: 16)
        logoView.addSubview(logoText)

        // Title (shown in expanded mode)
        titleLabel.font = Theme.font(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor(white: 1.0, alpha: 0.7)
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.alphaValue = 0
        titleLabel.frame = NSRect(x: 42, y: 12, width: 160, height: 20)
        footerView.addSubview(titleLabel)

        // Settings button (small icon on the right)
        let settingsBtn = NSButton(title: "\u{2699}", target: self, action: #selector(settingsTapped))
        settingsBtn.isBordered = false
        settingsBtn.wantsLayer = true
        settingsBtn.layer?.cornerRadius = 5
        settingsBtn.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
        settingsBtn.font = Theme.font(ofSize: 14)
        settingsBtn.contentTintColor = NSColor(white: 1.0, alpha: 0.35)
        settingsBtn.frame = NSRect(x: 0, y: 8, width: 28, height: 28)  // positioned in layoutSubviews
        settingsBtn.tag = 999
        footerView.addSubview(settingsBtn)
    }

    @objc private func settingsTapped() {
        settingsController.onSave = { [weak self] newConfig in
            appConfig = newConfig
            self?.reload()
        }
        settingsController.showWindow()
    }

    // MARK: - DockingDelegate

    func collapsedContentHeight() -> CGFloat {
        let footerH: CGFloat = 0   // footer hidden in collapsed
        let padding: CGFloat = 24
        windowStack.layoutSubtreeIfNeeded()
        let stackH = windowStack.fittingSize.height
        let minHeight: CGFloat = 80
        return max(footerH + stackH + padding, minHeight)
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
        guard !dockingManager.isAnimating, !dockingManager.isDragging else { return }
        if appConfig.minimalView == true { return }

        let mouse = NSEvent.mouseLocation
        let frame = window.frame

        let hitZone = NSRect(x: frame.origin.x - 4, y: frame.origin.y - 4,
                             width: frame.width + 8, height: frame.height + 8)

        let footerH: CGFloat = 44
        let inFooter = mouse.y <= frame.origin.y + footerH
            && mouse.x >= frame.origin.x && mouse.x <= frame.maxX

        if hitZone.contains(mouse) && !isSidebarExpanded && !inFooter {
            expandSidebar()
        } else if !hitZone.contains(mouse) && isSidebarExpanded {
            collapseSidebar()
        }
    }

    private func expandSidebar() {
        guard !isSidebarExpanded, !dockingManager.isAnimating else { return }
        isSidebarExpanded = true
        dockingManager.isAnimating = true

        let frame = window.frame
        guard let screen = dockingManager.screenForWindow() else { dockingManager.isAnimating = false; return }
        let sf = screen.visibleFrame
        let expandedHeight = sf.height * 0.7

        let newX: CGFloat
        switch dockingManager.dockSide {
        case .right: newX = frame.maxX - expandedWidth
        case .left:  newX = frame.origin.x
        }
        let baseY = dockingManager.userY ?? (sf.midY - expandedHeight / 2)
        let newY = dockingManager.clampY(baseY, height: expandedHeight, in: sf)
        let newFrame = NSRect(x: newX, y: newY, width: expandedWidth, height: expandedHeight)

        for (_, btn) in windowButtons {
            btn.isExpanded = true
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Layout.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
            titleLabel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.dockingManager.isAnimating = false
            self.footerView.isHidden = false
            self.layoutSubviews()
        })
    }

    func collapseSidebar() {
        guard isSidebarExpanded, !dockingManager.isAnimating else { return }
        isSidebarExpanded = false
        dockingManager.isAnimating = true

        footerView.isHidden = true

        for (_, btn) in windowButtons {
            btn.isExpanded = false
        }
        windowStack.layoutSubtreeIfNeeded()

        let frame = window.frame
        let collapsedHeight = collapsedContentHeight()

        let newX: CGFloat
        switch dockingManager.dockSide {
        case .right: newX = frame.maxX - collapsedWidth
        case .left:  newX = frame.origin.x
        }
        guard let screen = dockingManager.screenForWindow() else { dockingManager.isAnimating = false; return }
        let sf = screen.visibleFrame
        let baseY = dockingManager.userY ?? (sf.midY - collapsedHeight / 2)
        let newY = dockingManager.clampY(baseY, height: collapsedHeight, in: sf)
        let newFrame = NSRect(x: newX, y: newY, width: collapsedWidth, height: collapsedHeight)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Layout.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
            titleLabel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.dockingManager.isAnimating = false
            self.layoutSubviews()
        })
    }

    // MARK: - Keyboard Shortcuts (delegated to KeyboardShortcutManager)

    private func setupKeyboardShortcuts() {
        keyboardManager.onToggleSidebar = { [weak self] in
            guard let self = self else { return }
            if self.window.isVisible {
                self.window.orderOut(nil)
            } else {
                self.window.orderFront(nil)
            }
        }
        keyboardManager.onFocusRepo = { [weak self] repoNum in
            self?.focusHighPriorityTab(forRepoNum: repoNum)
        }
        keyboardManager.setup()
    }

    private func focusHighPriorityTab(forRepoNum repoNum: Int) {
        let slots = buildSlots()
        let slotIndex = repoNum - 1
        guard slotIndex >= 0, slotIndex < slots.count else {
            os_log("Hotkey: no slot for position %d", log: logger, type: .info, repoNum)
            return
        }
        let win = slots[slotIndex]

        if win.isPlaceholder {
            if let repoNum = win.matchedRepoNum,
               let repo = appConfig.repos.first(where: { $0.num == repoNum }) {
                scanner.openWindowWithCWD(path: repo.expandedPath)
            }
            return
        }

        let tab = win.tabs.max(by: { $0.state < $1.state }) ?? win.tabs.first
        if let tab = tab {
            scanner.focusSession(windowId: tab.windowId, sessionId: tab.sessionId)
        }
    }

    // MARK: - Start / Reload

    func start() {
        pollingCoordinator.startDarwinObserver()

        // Run full scan + process scan before showing the window so it
        // appears already populated rather than flashing empty then filling in.
        pollingCoordinator.fullPollInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let initialWindows = self.scanner.scan()

            let ttys = initialWindows.flatMap { $0.tabs.map { $0.tty } }
            let scanResult = ttys.isEmpty ? ProcessMonitorScanResult() : self.processMonitor.discoverProcesses(ttys: ttys)
            let cwds = self.processMonitor.detectCWDs(shellPIDs: scanResult.shellPIDs)
            var branches: [String: String] = [:]
            for (tty, cwd) in cwds {
                if let branch = self.scanner.getBranch(cwd: cwd) { branches[tty] = branch }
            }

            DispatchQueue.main.async {
                self.pollingCoordinator.applyFullPollResults(initialWindows)

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

                self.window.orderFront(nil)
                self.pollingCoordinator.startTimers()
            }
        }
    }

    func reload() {
        windowButtons.values.forEach { $0.removeFromSuperview() }
        windowButtons.removeAll()
        expandedWindows.removeAll()
        pollingCoordinator.startTimers()
        pollingCoordinator.startDarwinObserver()
        if appConfig.minimalView == true && isSidebarExpanded {
            collapseSidebar()
        }
        pollingCoordinator.fullPoll()
    }

    // MARK: - Slot Building (delegated to SlotBuilder)

    private func buildSlots() -> [TerminalWindow] {
        slotBuilder.buildSlots(windows: windows, repos: appConfig.repos)
    }

    // MARK: - UI Update

    func updateUI() {
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
        pollingCoordinator.updateProcessTickTimer()

        // Update document view height to fit content
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.layoutSubviews()
            // When collapsed, resize window height to fit content
            if !self.isSidebarExpanded && !self.dockingManager.isAnimating {
                self.dockingManager.resizeCollapsedToFitContent()
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
