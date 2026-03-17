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
    var windowInfo: ITermWindowInfo
    var isExpanded: Bool = false { didSet { if oldValue != isExpanded { rebuildUI() } } }
    var isMinimalMode: Bool = false
    var onToggle: (() -> Void)?
    var onFocusTab: ((ITermTabInfo) -> Void)?
    var onFocusHighPriorityTab: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var lastRenderFingerprint: String = ""

    init(windowInfo: ITermWindowInfo) {
        self.windowInfo = windowInfo
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        rebuildUI()
    }

    required init?(coder: NSCoder) { nil }

    private func makeFingerprint() -> String {
        let tabsKey = windowInfo.tabs.map { t in
            let proc = t.processInfo.map { "\($0.pid):\($0.exitCode.map(String.init) ?? "r")" } ?? ""
            return "\(t.tty):\(t.state.rawValue):\(proc):\(t.cwd ?? ""):\(t.gitBranch ?? ""):\(t.appName ?? "")"
        }.joined(separator: "|")
        return "\(windowInfo.windowId):\(windowInfo.isPlaceholder):\(windowInfo.windowName):\(windowInfo.displayPath ?? ""):\(windowInfo.displayLabel):\(isExpanded):\(isMinimalMode):\(tabsKey)"
    }

    func update(windowInfo: ITermWindowInfo) {
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

    // MARK: - Minimal Mode (fused bar + badge + tab count)

    private func buildMinimal() {
        layer?.cornerRadius = 0; layer?.borderWidth = 0
        layer?.borderColor = nil; layer?.backgroundColor = nil; layer?.masksToBounds = false

        // Fused bar+badge: same structure as collapsed but minimal layout
        let fused = NSView()
        fused.wantsLayer = true
        fused.layer?.cornerRadius = 10
        fused.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        fused.layer?.masksToBounds = true
        fused.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fused)

        // Left segmented bar (4px wide) showing per-tab status
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
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
                seg.layer?.backgroundColor = tabSegmentColor(tab).cgColor
                segStack.addArrangedSubview(seg)
            }

            NSLayoutConstraint.activate([
                segStack.topAnchor.constraint(equalTo: bar.topAnchor),
                segStack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                segStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                segStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            ])
        }

        // Badge (fills rest of fused)
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = badgeBackground(windowInfo.state).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        fused.addSubview(badge)

        let numLabel = NSTextField(labelWithString: windowInfo.displayLabel)
        numLabel.font = Theme.monoFont(ofSize: 15, weight: .bold)
        numLabel.textColor = badgeTextColor(windowInfo.state)
        numLabel.alignment = .center
        numLabel.isBezeled = false
        numLabel.drawsBackground = false
        numLabel.isEditable = false
        numLabel.isSelectable = false
        numLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(numLabel)

        // Alert pulse
        if windowInfo.state == .alert {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0
            anim.toValue = 0.5
            anim.duration = 1.5
            anim.autoreverses = true
            anim.repeatCount = .infinity
            badge.layer?.add(anim, forKey: "alertPulse")
        }

        // Tab count label
        let tabCount = windowInfo.tabs.count
        let countText = tabCount == 1 ? "1 tab" : "\(tabCount) tabs"
        let countLabel = NSTextField(labelWithString: countText)
        countLabel.font = Theme.font(ofSize: 8)
        countLabel.textColor = Theme.textDim
        countLabel.alignment = .center
        countLabel.isBezeled = false
        countLabel.drawsBackground = false
        countLabel.isEditable = false
        countLabel.isSelectable = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            // Fused: centered horizontally, pinned to top
            fused.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            fused.centerXAnchor.constraint(equalTo: centerXAnchor),
            fused.widthAnchor.constraint(equalToConstant: 44),
            fused.heightAnchor.constraint(equalToConstant: 40),

            // Bar: left 4px
            bar.leadingAnchor.constraint(equalTo: fused.leadingAnchor),
            bar.topAnchor.constraint(equalTo: fused.topAnchor),
            bar.bottomAnchor.constraint(equalTo: fused.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 4),

            // Badge: fills right of bar
            badge.leadingAnchor.constraint(equalTo: bar.trailingAnchor),
            badge.trailingAnchor.constraint(equalTo: fused.trailingAnchor),
            badge.topAnchor.constraint(equalTo: fused.topAnchor),
            badge.bottomAnchor.constraint(equalTo: fused.bottomAnchor),

            // Number centered in badge
            numLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            numLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            // Count label: below fused
            countLabel.topAnchor.constraint(equalTo: fused.bottomAnchor, constant: 2),
            countLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            // Total height
            bottomAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 4),
        ])
    }

    // MARK: - Collapsed Mode: Fused bar + badge + tab count

    private func buildCollapsed() {
        layer?.cornerRadius = 0; layer?.borderWidth = 0
        layer?.borderColor = nil; layer?.backgroundColor = nil; layer?.masksToBounds = false

        // Fused bar+badge: 44x40, flat-left rounded-right, overflow hidden
        let fused = NSView()
        fused.wantsLayer = true
        fused.layer?.cornerRadius = 10
        fused.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        fused.layer?.masksToBounds = true
        fused.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fused)

        // Left segmented bar (4px wide)
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
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
                seg.layer?.backgroundColor = tabSegmentColor(tab).cgColor
                segStack.addArrangedSubview(seg)
            }

            NSLayoutConstraint.activate([
                segStack.topAnchor.constraint(equalTo: bar.topAnchor),
                segStack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                segStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                segStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            ])
        }

        // Badge (fills rest of fused)
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = badgeBackground(windowInfo.state).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        fused.addSubview(badge)

        let numLabel = NSTextField(labelWithString: "\(windowInfo.displayLabel)")
        numLabel.font = Theme.monoFont(ofSize: 15, weight: .bold)
        numLabel.textColor = badgeTextColor(windowInfo.state)
        numLabel.alignment = .center
        numLabel.isBezeled = false
        numLabel.drawsBackground = false
        numLabel.isEditable = false
        numLabel.isSelectable = false
        numLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(numLabel)

        // Alert pulse
        if windowInfo.state == .alert {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0
            anim.toValue = 0.5
            anim.duration = 1.5
            anim.autoreverses = true
            anim.repeatCount = .infinity
            badge.layer?.add(anim, forKey: "alertPulse")
        }

        // Tab count label
        let tabCount = windowInfo.tabs.count
        let countText = tabCount == 1 ? "1 tab" : "\(tabCount) tabs"
        let countLabel = NSTextField(labelWithString: countText)
        countLabel.font = Theme.font(ofSize: 8)
        countLabel.textColor = Theme.textDim
        countLabel.alignment = .center
        countLabel.isBezeled = false
        countLabel.drawsBackground = false
        countLabel.isEditable = false
        countLabel.isSelectable = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            // Fused: centered horizontally, pinned to top
            fused.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            fused.centerXAnchor.constraint(equalTo: centerXAnchor),
            fused.widthAnchor.constraint(equalToConstant: 44),
            fused.heightAnchor.constraint(equalToConstant: 40),

            // Bar: left 4px
            bar.leadingAnchor.constraint(equalTo: fused.leadingAnchor),
            bar.topAnchor.constraint(equalTo: fused.topAnchor),
            bar.bottomAnchor.constraint(equalTo: fused.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 4),

            // Badge: fills right of bar
            badge.leadingAnchor.constraint(equalTo: bar.trailingAnchor),
            badge.trailingAnchor.constraint(equalTo: fused.trailingAnchor),
            badge.topAnchor.constraint(equalTo: fused.topAnchor),
            badge.bottomAnchor.constraint(equalTo: fused.bottomAnchor),

            // Number centered in badge
            numLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            numLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            // Count label: below fused
            countLabel.topAnchor.constraint(equalTo: fused.bottomAnchor, constant: 2),
            countLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            // Total height
            bottomAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 4),
        ])
    }

    // MARK: - Expanded Mode: Box card with gradient bar + header + tabs

    private func buildExpanded() {
        // Box styling on self
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.07).cgColor
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.018).cgColor
        layer?.masksToBounds = true

        let state = windowInfo.state

        // ── Header gradient background (full-height left→right wash) ──
        let headerGradient = GradientView()
        headerGradient.color = stateAccentColor(state)
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
        badge.layer?.backgroundColor = badgeBackground(state).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(badge)

        let badgeNum = NSTextField(labelWithString: windowInfo.displayLabel)
        badgeNum.font = Theme.monoFont(ofSize: 11.5, weight: .semibold)
        badgeNum.textColor = badgeTextColor(state)
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

    // MARK: - Colors

    private func stateAccentColor(_ state: SessionState) -> NSColor {
        switch state {
        case .working: return Theme.blue
        case .alert:   return Theme.red
        case .idle:    return Theme.green
        case .inactive: return NSColor(hexString: "#7B8FA1")!  // steel — no session
        }
    }

    // Synced with expanded palette (Theme.*)
    private func tabSegmentColor(_ tab: ITermTabInfo) -> NSColor {
        if tab.hasClaude {
            switch tab.claudeState {
            case .working: return Theme.blue
            case .alert:   return Theme.red
            case .idle:    return Theme.green
            case .inactive: return Theme.green
            }
        }
        if let proc = tab.processInfo {
            switch proc.state {
            case .running: return Theme.yellow
            case .success: return Theme.green
            case .error:   return Theme.red
            }
        }
        return NSColor(white: 1.0, alpha: 0.1)
    }

    private func badgeBackground(_ state: SessionState) -> NSColor {
        switch state {
        case .working: return Theme.blue.withAlphaComponent(0.16)
        case .alert:   return Theme.red.withAlphaComponent(0.16)
        case .idle:    return Theme.green.withAlphaComponent(0.14)
        case .inactive: return NSColor(white: 1.0, alpha: 0.04)
        }
    }

    private func badgeTextColor(_ state: SessionState) -> NSColor {
        switch state {
        case .working: return Theme.blue
        case .alert:   return Theme.red
        case .idle:    return Theme.green
        case .inactive: return NSColor(white: 1.0, alpha: 0.45)
        }
    }

    // MARK: - Mouse

    override func draw(_ dirtyRect: NSRect) {
        if isHovered && !isExpanded {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
    }

    override func updateTrackingAreas() {
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        trackingArea = ta
        addTrackingArea(ta)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        if windowInfo.isPlaceholder {
            return  // placeholder slots are display-only — no terminal to open
        } else if isMinimalMode {
            onFocusHighPriorityTab?()
        } else {
            onToggle?()
        }
    }
}
