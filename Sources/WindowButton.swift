import AppKit


// MARK: - Gradient View (left→right color wash, used as header background)
private class GradientView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    var startAlpha: CGFloat = 0.18 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let gradient = NSGradient(
            starting: color.withAlphaComponent(startAlpha),
            ending: .clear
        ) else { return }
        gradient.draw(in: bounds, angle: 0)
    }
}

// MARK: - Window Button (collapsed + expanded)

class WindowButton: NSView {
    var windowInfo: TerminalWindow
    var isExpanded: Bool = false { didSet { if oldValue != isExpanded { rebuildUI() } } }
    var isMinimalMode: Bool = false
    var onToggle: (() -> Void)?
    var onFocusTab: ((TerminalTab) -> Void)?
    var onFocusHighPriorityTab: (() -> Void)?
    var onOpenNewWindow: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var lastRenderFingerprint: String = ""

    init(windowInfo: TerminalWindow) {
        self.windowInfo = windowInfo
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        rebuildUI()
    }

    required init?(coder: NSCoder) { nil }

    private func makeFingerprint() -> String {
        let tabsKey = windowInfo.tabs.map { t in
            let proc = t.processInfo.map { "\($0.pid):\($0.exitCode.map(String.init) ?? "r"):\($0.durationString)" } ?? ""
            return "\(t.tty):\(t.state.rawValue):\(proc):\(t.cwd ?? ""):\(t.gitBranch ?? ""):\(t.appName ?? "")"
        }.joined(separator: "|")
        return "\(windowInfo.windowId):\(windowInfo.isPlaceholder):\(windowInfo.windowName):\(windowInfo.displayPath ?? ""):\(windowInfo.displayLabel):\(isExpanded):\(isMinimalMode):\(tabsKey)"
    }

    func update(windowInfo: TerminalWindow) {
        self.windowInfo = windowInfo
        let fp = makeFingerprint()
        guard fp != lastRenderFingerprint else { return }
        lastRenderFingerprint = fp
        rebuildUI()
    }

    private func rebuildUI() {
        lastRenderFingerprint = makeFingerprint()
        subviews.forEach { $0.removeFromSuperview() }

        if windowInfo.isPlaceholder {
            if isExpanded && !isMinimalMode {
                buildPlaceholderExpanded()
            } else {
                buildPlaceholderCollapsed()
            }
        } else if isMinimalMode {
            buildMinimal()
        } else if isExpanded {
            buildExpanded()
        } else {
            buildCollapsed()
        }
    }

    // MARK: - Placeholder Collapsed (dim badge, no bar, no tab count)

    private func buildPlaceholderCollapsed() {
        // Reset any box styling from expanded mode
        layer?.cornerRadius = 0; layer?.borderWidth = 0
        layer?.borderColor = nil; layer?.backgroundColor = nil; layer?.masksToBounds = false

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 10
        badge.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        badge.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.03).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)

        let numLabel = NSTextField(labelWithString: windowInfo.displayLabel)
        numLabel.font = Theme.monoFont(ofSize: 15, weight: .bold)
        numLabel.textColor = NSColor(white: 1.0, alpha: 0.2)
        numLabel.alignment = .center
        numLabel.isBezeled = false
        numLabel.drawsBackground = false
        numLabel.isEditable = false
        numLabel.isSelectable = false
        numLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(numLabel)

        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.widthAnchor.constraint(equalToConstant: 44),
            badge.heightAnchor.constraint(equalToConstant: 40),
            numLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            numLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: 6),  // git-exact
        ])
    }

    // MARK: - Placeholder Expanded — delegate to buildExpanded (handles isPlaceholder check)

    private func buildPlaceholderExpanded() {
        buildExpanded()
    }

    // MARK: - Minimal / Collapsed Mode (shared fused bar + badge layout)

    private func buildMinimal() { buildFusedBarBadge() }
    private func buildCollapsed() { buildFusedBarBadge() }

    /// Shared builder for both minimal and collapsed modes (identical layout).
    private func buildFusedBarBadge() {
        layer?.cornerRadius = 0; layer?.borderWidth = 0
        layer?.borderColor = nil; layer?.backgroundColor = nil; layer?.masksToBounds = false

        let fused = NSView()
        fused.wantsLayer = true
        fused.layer?.cornerRadius = 10
        fused.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        fused.layer?.masksToBounds = true
        fused.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fused)

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.clear.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        fused.addSubview(bar)

        let activeTabs = windowInfo.activeTabs
        if !activeTabs.isEmpty {
            let segStack = NSStackView()
            segStack.orientation = .vertical
            segStack.spacing = 1
            segStack.distribution = .fillEqually
            segStack.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(segStack)

            for tab in activeTabs {
                let seg = NSView()
                seg.wantsLayer = true
                seg.layer?.backgroundColor = tab.segmentColor.cgColor
                segStack.addArrangedSubview(seg)
            }

            NSLayoutConstraint.activate([
                segStack.topAnchor.constraint(equalTo: bar.topAnchor),
                segStack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                segStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                segStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            ])
        }

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = windowInfo.state.badgeBackground.cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        fused.addSubview(badge)

        let numLabel = NSTextField(labelWithString: windowInfo.displayLabel)
        numLabel.font = Theme.monoFont(ofSize: 15, weight: .bold)
        numLabel.textColor = windowInfo.state.badgeTextColor
        numLabel.alignment = .center
        numLabel.isBezeled = false
        numLabel.drawsBackground = false
        numLabel.isEditable = false
        numLabel.isSelectable = false
        numLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(numLabel)

        if windowInfo.state == .alert {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0
            anim.toValue = 0.5
            anim.duration = 1.5
            anim.autoreverses = true
            anim.repeatCount = .infinity
            badge.layer?.add(anim, forKey: "alertPulse")
        }

        let tabCount = windowInfo.tabs.count
        let tabCountLabel = NSTextField(labelWithString: tabCount == 1 ? "1 tab" : "\(tabCount) tabs")
        tabCountLabel.font = Theme.font(ofSize: 8)
        tabCountLabel.textColor = Theme.textDim
        tabCountLabel.alignment = .center
        tabCountLabel.isBezeled = false
        tabCountLabel.drawsBackground = false
        tabCountLabel.isEditable = false
        tabCountLabel.isSelectable = false
        tabCountLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabCountLabel)

        NSLayoutConstraint.activate([
            fused.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            fused.centerXAnchor.constraint(equalTo: centerXAnchor),
            fused.widthAnchor.constraint(equalToConstant: Layout.badgeSize),
            fused.heightAnchor.constraint(equalToConstant: Layout.badgeHeight),

            bar.leadingAnchor.constraint(equalTo: fused.leadingAnchor),
            bar.topAnchor.constraint(equalTo: fused.topAnchor),
            bar.bottomAnchor.constraint(equalTo: fused.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 4),

            badge.leadingAnchor.constraint(equalTo: bar.trailingAnchor),
            badge.trailingAnchor.constraint(equalTo: fused.trailingAnchor),
            badge.topAnchor.constraint(equalTo: fused.topAnchor),
            badge.bottomAnchor.constraint(equalTo: fused.bottomAnchor),

            numLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            numLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            tabCountLabel.topAnchor.constraint(equalTo: fused.bottomAnchor, constant: 2),
            tabCountLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            bottomAnchor.constraint(equalTo: tabCountLabel.bottomAnchor, constant: 2),
        ])
    }

    // MARK: - Expanded Mode: Box card with gradient bar + header + tabs

    private func buildExpanded() {
        // Box styling on self
        wantsLayer = true
        layer?.cornerRadius = Layout.boxCornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.07).cgColor
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.018).cgColor
        layer?.masksToBounds = true

        let state = windowInfo.state

        // ── Header gradient background (full-height left→right wash) ──
        let headerGradient = GradientView()
        headerGradient.color = state.accentColor
        headerGradient.startAlpha = state == .inactive ? 0.10 : 0.18
        headerGradient.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerGradient)

        // ── Box header (sits on top of gradient) ──
        let headerContainer = NSView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerContainer)

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 8
        badge.layer?.backgroundColor = state.badgeBackground.cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(badge)

        let badgeNum = NSTextField(labelWithString: windowInfo.displayLabel)
        badgeNum.font = Theme.monoFont(ofSize: 11.5, weight: .semibold)
        badgeNum.textColor = state.badgeTextColor
        badgeNum.alignment = .center
        badgeNum.isBezeled = false
        badgeNum.drawsBackground = false
        badgeNum.isEditable = false
        badgeNum.isSelectable = false
        badgeNum.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeNum)

        let infoStack = NSStackView()
        infoStack.orientation = .vertical
        infoStack.spacing = 4
        infoStack.alignment = .leading
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(infoStack)

        let nameLabel = NSTextField(labelWithString: windowInfo.windowName)
        nameLabel.font = Theme.font(ofSize: 11.5, weight: .semibold)
        nameLabel.textColor = NSColor(white: 1.0, alpha: windowInfo.isPlaceholder ? 0.28 : 0.7)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        infoStack.addArrangedSubview(nameLabel)

        let pathText = windowInfo.isPlaceholder ? "No active session" : (windowInfo.displayPath ?? "")
        if !pathText.isEmpty {
            let pathLabel = NSTextField(labelWithString: pathText)
            pathLabel.font = windowInfo.isPlaceholder
                ? Theme.font(ofSize: 9)
                : Theme.monoFont(ofSize: 9)
            pathLabel.textColor = NSColor(white: 1.0, alpha: windowInfo.isPlaceholder ? 0.22 : 0.28)
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.maximumNumberOfLines = 1
            pathLabel.isBezeled = false
            pathLabel.drawsBackground = false
            pathLabel.isEditable = false
            pathLabel.isSelectable = false
            infoStack.addArrangedSubview(pathLabel)
        }

        // ── Divider + tabs (only if not placeholder) ──
        var lastAnchor: NSLayoutYAxisAnchor = headerContainer.bottomAnchor

        if !windowInfo.isPlaceholder && !windowInfo.tabs.isEmpty {
            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.055).cgColor
            divider.translatesAutoresizingMaskIntoConstraints = false
            addSubview(divider)

            NSLayoutConstraint.activate([
                divider.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
                divider.leadingAnchor.constraint(equalTo: leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: trailingAnchor),
                divider.heightAnchor.constraint(equalToConstant: 1),
            ])
            lastAnchor = divider.bottomAnchor

            for (idx, tab) in windowInfo.tabs.enumerated() {
                let isLast = idx == windowInfo.tabs.count - 1
                let card = TabCard(tab: tab, appName: tab.appName, isLastTab: isLast)
                card.translatesAutoresizingMaskIntoConstraints = false
                card.onFocus = { [weak self] in self?.onFocusTab?(tab) }
                addSubview(card)

                NSLayoutConstraint.activate([
                    card.topAnchor.constraint(equalTo: lastAnchor),
                    card.leadingAnchor.constraint(equalTo: leadingAnchor),
                    card.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
                lastAnchor = card.bottomAnchor

                if !isLast {
                    let sep = NSView()
                    sep.wantsLayer = true
                    sep.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
                    sep.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(sep)
                    NSLayoutConstraint.activate([
                        sep.topAnchor.constraint(equalTo: lastAnchor),
                        sep.leadingAnchor.constraint(equalTo: leadingAnchor),
                        sep.trailingAnchor.constraint(equalTo: trailingAnchor),
                        sep.heightAnchor.constraint(equalToConstant: 1),
                    ])
                    lastAnchor = sep.bottomAnchor
                }
            }
        }

        // ── Constraints ──
        NSLayoutConstraint.activate([
            // header gradient — same frame as headerContainer (background layer)
            headerGradient.topAnchor.constraint(equalTo: topAnchor),
            headerGradient.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerGradient.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerGradient.heightAnchor.constraint(equalToConstant: 52),

            // header container — on top of gradient
            headerContainer.topAnchor.constraint(equalTo: topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),

            // badge
            badge.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 12),
            badge.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),

            // badge label centered
            badgeNum.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeNum.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            // info stack
            infoStack.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            infoStack.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -12),
            infoStack.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            // header height via padding
            badge.topAnchor.constraint(greaterThanOrEqualTo: headerContainer.topAnchor, constant: 12),
            badge.bottomAnchor.constraint(lessThanOrEqualTo: headerContainer.bottomAnchor, constant: -12),
            headerContainer.heightAnchor.constraint(equalToConstant: 52),

            // bottom pin
            bottomAnchor.constraint(equalTo: lastAnchor),
        ])
    }

    // Colors now use SessionState extensions: .accentColor, .badgeBackground, .badgeTextColor
    // Tab segment colors use TerminalTab.segmentColor extension

    // MARK: - Mouse

    override func draw(_ dirtyRect: NSRect) { }

    override func updateTrackingAreas() {
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        trackingArea = ta
        addTrackingArea(ta)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true; needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        // Force full redraw to clear hover paint
        setNeedsDisplay(bounds)
        displayIfNeeded()
    }

    override func rightMouseDown(with event: NSEvent) {
        dumpDebugInfo()
    }

    override func mouseDown(with event: NSEvent) {
        if windowInfo.isPlaceholder {
            onOpenNewWindow?()
            return
        } else if isMinimalMode {
            onFocusHighPriorityTab?()
        } else {
            onToggle?()
        }
    }

    private func dumpDebugInfo(event: String = "manual") {
        var lines: [String] = []
        lines.append("=== WindowButton Debug [\(event)] ===")
        lines.append("windowName=\(windowInfo.windowName) label=\(windowInfo.displayLabel)")
        lines.append("isExpanded=\(isExpanded) isMinimalMode=\(isMinimalMode) isHovered=\(isHovered)")
        lines.append("state=\(windowInfo.state) tabs=\(windowInfo.tabs.count)")
        lines.append("")
        lines.append("Self layer:")
        dumpLayer(of: self, indent: "  ", into: &lines)
        lines.append("")
        lines.append("View hierarchy:")
        dumpViewTree(self, indent: "", into: &lines)

        let output = lines.joined(separator: "\n") + "\n"
        let path = "/tmp/claude-sidebar/windowbutton-debug.log"
        if let data = output.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let fh = FileHandle(forWritingAtPath: path) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
        NSLog("[WindowButton] Debug written to %@", path)
    }

    private func dumpLayer(of view: NSView, indent: String, into lines: inout [String]) {
        guard let l = view.layer else { lines.append("\(indent)(no layer)"); return }
        let bg = l.backgroundColor.map { NSColor(cgColor: $0)?.hexString ?? "?" } ?? "nil"
        let border = l.borderColor.map { NSColor(cgColor: $0)?.hexString ?? "?" } ?? "nil"
        let shadow = l.shadowOpacity > 0 ? "opacity=\(l.shadowOpacity) color=\(l.shadowColor.map { NSColor(cgColor: $0)?.hexString ?? "?" } ?? "nil") radius=\(l.shadowRadius)" : "none"
        lines.append("\(indent)bg=\(bg) border=\(border) bw=\(l.borderWidth) cr=\(l.cornerRadius) opacity=\(l.opacity) shadow=\(shadow) masksToBounds=\(l.masksToBounds)")
    }

    private func dumpViewTree(_ view: NSView, indent: String, into lines: inout [String]) {
        let cls = String(describing: type(of: view))
        let frame = "(\(Int(view.frame.origin.x)),\(Int(view.frame.origin.y)) \(Int(view.frame.width))x\(Int(view.frame.height)))"
        var desc = "\(indent)\(cls) \(frame)"
        if let tf = view as? NSTextField { desc += " text=\"\(tf.stringValue)\" color=\(tf.textColor?.hexString ?? "?")"}
        lines.append(desc)
        dumpLayer(of: view, indent: indent + "  ", into: &lines)
        for sub in view.subviews {
            dumpViewTree(sub, indent: indent + "  ", into: &lines)
        }
    }
}
