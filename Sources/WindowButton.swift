import AppKit

// MARK: - Window Button (collapsed + expanded)

class WindowButton: NSView {
    var windowInfo: ITermWindowInfo
    var isExpanded: Bool = false { didSet { if oldValue != isExpanded { rebuildUI() } } }
    var isMinimalMode: Bool = false
    var onToggle: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onFocusTab: ((ITermTabInfo) -> Void)?
    var onOpenRepo: (() -> Void)?
    var onFocusHighPriorityTab: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(windowInfo: ITermWindowInfo) {
        self.windowInfo = windowInfo
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        rebuildUI()
    }

    required init?(coder: NSCoder) { nil }

    func update(windowInfo: ITermWindowInfo) {
        self.windowInfo = windowInfo
        rebuildUI()
    }

    private func rebuildUI() {
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
            bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: 6),
        ])
    }

    // MARK: - Placeholder Expanded (dim badge + path + click hint)

    private func buildPlaceholderExpanded() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Header row: dim badge + path
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.03).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 28).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let badgeNum = NSTextField(labelWithString: windowInfo.displayLabel)
        badgeNum.font = Theme.monoFont(ofSize: 12, weight: .semibold)
        badgeNum.textColor = NSColor(white: 1.0, alpha: 0.2)
        badgeNum.alignment = .center
        badgeNum.isBezeled = false
        badgeNum.drawsBackground = false
        badgeNum.isEditable = false
        badgeNum.isSelectable = false
        badgeNum.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeNum)
        badgeNum.centerXAnchor.constraint(equalTo: badge.centerXAnchor).isActive = true
        badgeNum.centerYAnchor.constraint(equalTo: badge.centerYAnchor).isActive = true

        // Show shortened repo path
        let home = NSHomeDirectory()
        let pathStr = windowInfo.windowName.hasPrefix(home)
            ? "~" + windowInfo.windowName.dropFirst(home.count)
            : windowInfo.windowName
        let nameLabel = NSTextField(labelWithString: pathStr)
        nameLabel.font = Theme.font(ofSize: 12, weight: .medium)
        nameLabel.textColor = NSColor(white: 1.0, alpha: 0.3)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        header.addArrangedSubview(badge)
        header.addArrangedSubview(nameLabel)
        header.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Hint
        let hint = NSTextField(labelWithString: "Click to open")
        hint.font = Theme.font(ofSize: 10)
        hint.textColor = NSColor(white: 1.0, alpha: 0.2)
        hint.isBezeled = false
        hint.drawsBackground = false
        hint.isEditable = false
        hint.isSelectable = false

        let hintWrapper = NSView()
        hintWrapper.translatesAutoresizingMaskIntoConstraints = false
        hintWrapper.addSubview(hint)
        hint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: hintWrapper.leadingAnchor, constant: 36),
            hint.topAnchor.constraint(equalTo: hintWrapper.topAnchor),
            hint.bottomAnchor.constraint(equalTo: hintWrapper.bottomAnchor),
        ])
        stack.addArrangedSubview(hintWrapper)
        hintWrapper.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    // MARK: - Minimal Mode (fused bar + badge + tab count)

    private func buildMinimal() {
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

    // MARK: - Expanded Mode: Header + accordion tab list

    private func buildExpanded() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Header row: badge + name + meta + "+" + chevron
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.backgroundColor = badgeBackground(windowInfo.state).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 28).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let badgeNum = NSTextField(labelWithString: "\(windowInfo.displayLabel)")
        badgeNum.font = Theme.monoFont(ofSize: 12, weight: .semibold)
        badgeNum.textColor = badgeTextColor(windowInfo.state)
        badgeNum.alignment = .center
        badgeNum.isBezeled = false
        badgeNum.drawsBackground = false
        badgeNum.isEditable = false
        badgeNum.isSelectable = false
        badgeNum.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeNum)
        badgeNum.centerXAnchor.constraint(equalTo: badge.centerXAnchor).isActive = true
        badgeNum.centerYAnchor.constraint(equalTo: badge.centerYAnchor).isActive = true

        let nameLabel = NSTextField(labelWithString: windowInfo.windowName)
        nameLabel.font = Theme.font(ofSize: 12, weight: .medium)
        nameLabel.textColor = NSColor(white: 1.0, alpha: 0.8)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        header.addArrangedSubview(badge)
        header.addArrangedSubview(nameLabel)
        header.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Tab cards
        for tab in windowInfo.tabs {
            let card = TabCard(tab: tab)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.onFocus = { [weak self] in self?.onFocusTab?(tab) }

            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(card)
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
                card.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -4),
                card.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 1),
                card.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -1),
            ])

            stack.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    // MARK: - Colors

    private func tabSegmentColor(_ tab: ITermTabInfo) -> NSColor {
        if tab.hasClaude {
            switch tab.claudeState {
            case .working: return Theme.blue
            case .alert: return Theme.red
            case .idle: return Theme.green
            case .inactive: return Theme.green
            }
        }
        if let proc = tab.processInfo {
            switch proc.state {
            case .running: return Theme.yellow
            case .success: return Theme.green
            case .error: return Theme.red
            }
        }
        return NSColor(white: 1.0, alpha: 0.1)
    }

    private func badgeBackground(_ state: SessionState) -> NSColor {
        switch state {
        case .working: return NSColor(red: 96/255, green: 165/255, blue: 250/255, alpha: 0.10)
        case .alert: return NSColor(red: 248/255, green: 113/255, blue: 113/255, alpha: 0.10)
        case .idle: return NSColor(red: 74/255, green: 222/255, blue: 128/255, alpha: 0.10)
        case .inactive: return NSColor(white: 1.0, alpha: 0.05)
        }
    }

    private func badgeTextColor(_ state: SessionState) -> NSColor {
        switch state {
        case .working: return Theme.blue
        case .alert: return Theme.red
        case .idle: return Theme.green
        case .inactive: return NSColor(white: 1.0, alpha: 0.35)
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
            onOpenRepo?()
        } else if isMinimalMode {
            onFocusHighPriorityTab?()
        } else {
            onToggle?()
        }
    }
}
