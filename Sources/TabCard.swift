import AppKit


// MARK: - Tab Card

class TabCard: NSView {
    var onClick: (() -> Void)?
    var onFocus: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(tab: TerminalTab, appName: String? = nil, isLastTab: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        // Transparent by default — box background shows through; hover adds subtle tint

        // ── Row 1: dot + CWD (truncate head) + app (right-aligned) ──
        let row1 = NSView()
        row1.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row1)

        // State dot (8px circle)
        let dot8 = NSView()
        dot8.wantsLayer = true
        dot8.layer?.cornerRadius = 4
        let dotColor = (!tab.hasClaude && tab.processInfo == nil) ? Theme.active : tab.state.color
        dot8.layer?.backgroundColor = dotColor.cgColor
        dot8.translatesAutoresizingMaskIntoConstraints = false
        row1.addSubview(dot8)

        // CWD label — truncate head, 10pt mono, 54% white
        let cwdLabel = NSTextField(labelWithString: "")
        cwdLabel.font = Theme.monoFont(ofSize: 10)
        cwdLabel.textColor = NSColor(white: 1.0, alpha: 0.54)
        cwdLabel.lineBreakMode = .byTruncatingHead
        cwdLabel.maximumNumberOfLines = 1
        cwdLabel.isBezeled = false
        cwdLabel.drawsBackground = false
        cwdLabel.isEditable = false
        cwdLabel.isSelectable = false
        cwdLabel.allowsExpansionToolTips = false
        cwdLabel.translatesAutoresizingMaskIntoConstraints = false
        if let cwd = tab.cwd {
            let home = NSHomeDirectory()
            cwdLabel.stringValue = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
        } else {
            cwdLabel.stringValue = "Tab \(tab.tabIndex)"
            cwdLabel.textColor = NSColor(white: 1.0, alpha: 0.3)
        }
        cwdLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cwdLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row1.addSubview(cwdLabel)

        // App label — right-aligned, 9pt, 24% white, min-width 36px
        let appLabel = NSTextField(labelWithString: appName ?? "")
        appLabel.font = Theme.font(ofSize: 9)
        appLabel.textColor = NSColor(white: 1.0, alpha: 0.24)
        appLabel.alignment = .right
        appLabel.isBezeled = false
        appLabel.drawsBackground = false
        appLabel.isEditable = false
        appLabel.isSelectable = false
        appLabel.lineBreakMode = .byTruncatingTail
        appLabel.maximumNumberOfLines = 1
        appLabel.translatesAutoresizingMaskIntoConstraints = false
        appLabel.setContentHuggingPriority(.required, for: .horizontal)
        appLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        row1.addSubview(appLabel)

        // ── Row 2: branch (indent 16px) ──
        var row2: NSView? = nil
        if let branch = tab.gitBranch, !branch.isEmpty {
            let r2 = NSView()
            r2.translatesAutoresizingMaskIntoConstraints = false
            addSubview(r2)
            row2 = r2

            let branchIcon = NSTextField(labelWithString: "\u{2387}")
            branchIcon.font = Theme.font(ofSize: 9)
            branchIcon.textColor = NSColor(white: 1.0, alpha: 0.2)
            branchIcon.isBezeled = false
            branchIcon.drawsBackground = false
            branchIcon.isEditable = false
            branchIcon.isSelectable = false
            branchIcon.translatesAutoresizingMaskIntoConstraints = false
            r2.addSubview(branchIcon)

            let branchName = NSTextField(labelWithString: branch)
            branchName.font = Theme.font(ofSize: 9)
            branchName.textColor = NSColor(white: 1.0, alpha: 0.36)
            branchName.lineBreakMode = .byTruncatingTail
            branchName.maximumNumberOfLines = 1
            branchName.isBezeled = false
            branchName.drawsBackground = false
            branchName.isEditable = false
            branchName.isSelectable = false
            branchName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            branchName.translatesAutoresizingMaskIntoConstraints = false
            r2.addSubview(branchName)

            NSLayoutConstraint.activate([
                branchIcon.leadingAnchor.constraint(equalTo: r2.leadingAnchor),
                branchIcon.centerYAnchor.constraint(equalTo: r2.centerYAnchor),
                branchName.leadingAnchor.constraint(equalTo: branchIcon.trailingAnchor, constant: 4),
                branchName.trailingAnchor.constraint(lessThanOrEqualTo: r2.trailingAnchor),
                branchName.centerYAnchor.constraint(equalTo: r2.centerYAnchor),
                r2.heightAnchor.constraint(equalToConstant: 16),
            ])
        }

        // ── Status line ──
        var statusView: NSView? = nil
        if tab.hasClaude {
            statusView = makeClaudeStatusRow(tab: tab)
        } else if let proc = tab.processInfo {
            statusView = makeProcessStatusRow(proc: proc)
        } else if tab.alwaysShow {
            statusView = makeIdleStatusRow()
        }
        if let sv = statusView {
            sv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sv)
        }

        // ── Layout constraints ──
        // Row 1: padding 8px top, 12px sides; gap 8px between dot/cwd/app
        NSLayoutConstraint.activate([
            dot8.widthAnchor.constraint(equalToConstant: 8),
            dot8.heightAnchor.constraint(equalToConstant: 8),
            dot8.leadingAnchor.constraint(equalTo: row1.leadingAnchor),
            dot8.centerYAnchor.constraint(equalTo: row1.centerYAnchor),

            cwdLabel.leadingAnchor.constraint(equalTo: dot8.trailingAnchor, constant: 8),
            cwdLabel.centerYAnchor.constraint(equalTo: row1.centerYAnchor),

            appLabel.leadingAnchor.constraint(equalTo: cwdLabel.trailingAnchor, constant: 8),
            appLabel.trailingAnchor.constraint(equalTo: row1.trailingAnchor),
            appLabel.centerYAnchor.constraint(equalTo: row1.centerYAnchor),
            appLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),

            row1.heightAnchor.constraint(equalToConstant: 16),

            row1.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row1.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row1.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        // Row 2 (branch) — indent 16px from leading, 4px below row1
        var lastBottomAnchor: NSLayoutYAxisAnchor = row1.bottomAnchor

        if let r2 = row2 {
            NSLayoutConstraint.activate([
                r2.topAnchor.constraint(equalTo: row1.bottomAnchor, constant: 4),
                r2.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16 + 12),
                r2.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
            lastBottomAnchor = r2.bottomAnchor
        }

        // Status line: 4px top, 12px sides, isLastTab ? 12px : 8px bottom, 28px left indent
        if let sv = statusView {
            let bottomPad: CGFloat = isLastTab ? 12 : 8
            NSLayoutConstraint.activate([
                sv.topAnchor.constraint(equalTo: lastBottomAnchor, constant: 4),
                sv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
                sv.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
                sv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomPad),
            ])
        } else {
            let bottomPad: CGFloat = isLastTab ? 12 : 8
            lastBottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomPad).isActive = true
        }
    }

    required init?(coder: NSCoder) { nil }

    private func makeClaudeStatusRow(tab: TerminalTab) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2
        dot.layer?.backgroundColor = tab.claudeState.color.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 4).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 4).isActive = true

        if tab.claudeState == .working {
            dot.layer?.shadowColor = Theme.working.cgColor
            dot.layer?.shadowRadius = 3
            dot.layer?.shadowOpacity = 0.5
            dot.layer?.shadowOffset = .zero
        }

        let label = NSTextField(labelWithString: "")
        label.font = Theme.font(ofSize: 9, weight: .medium)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false

        switch tab.claudeState {
        case .working:
            label.stringValue = "Claude working"
            label.textColor = Theme.working
        case .alert:
            label.stringValue = "Needs permission"
            label.textColor = Theme.alert
        case .active:
            label.stringValue = "Claude active"
            label.textColor = Theme.active
        case .idle:
            label.stringValue = "Claude idle"
            label.textColor = Theme.idle
        case .inactive:
            label.stringValue = "Claude"
            label.textColor = Theme.textDim
        }

        row.addArrangedSubview(dot)
        row.addArrangedSubview(label)
        return row
    }

    private func makeIdleStatusRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2
        dot.layer?.backgroundColor = Theme.active.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 4).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 4).isActive = true

        let label = NSTextField(labelWithString: "Idle")
        label.font = Theme.font(ofSize: 9, weight: .medium)
        label.textColor = Theme.active
        label.isBezeled = false; label.drawsBackground = false
        label.isEditable = false; label.isSelectable = false

        row.addArrangedSubview(dot)
        row.addArrangedSubview(label)
        return row
    }

    private func makeProcessStatusRow(proc: ProcessInfo) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY

        switch proc.state {
        case .running:
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 2
            dot.layer?.backgroundColor = Theme.running.cgColor
            dot.layer?.shadowColor = Theme.running.cgColor
            dot.layer?.shadowRadius = 3
            dot.layer?.shadowOpacity = 0.4
            dot.layer?.shadowOffset = .zero
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 4).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 4).isActive = true

            let label = NSTextField(labelWithString: "Running")
            label.font = Theme.font(ofSize: 9, weight: .medium)
            label.textColor = Theme.running
            label.isBezeled = false; label.drawsBackground = false
            label.isEditable = false; label.isSelectable = false

            let name = NSTextField(labelWithString: proc.name)
            name.font = Theme.monoFont(ofSize: 9)
            name.textColor = NSColor(white: 1.0, alpha: 0.3)
            name.lineBreakMode = .byTruncatingTail
            name.maximumNumberOfLines = 1
            name.isBezeled = false; name.drawsBackground = false
            name.isEditable = false; name.isSelectable = false

            let duration = NSTextField(labelWithString: proc.durationString)
            duration.font = Theme.font(ofSize: 9)
            duration.textColor = NSColor(white: 1.0, alpha: 0.25)
            duration.isBezeled = false; duration.drawsBackground = false
            duration.isEditable = false; duration.isSelectable = false
            duration.setContentHuggingPriority(.required, for: .horizontal)

            row.addArrangedSubview(dot)
            row.addArrangedSubview(label)
            row.addArrangedSubview(name)
            row.addArrangedSubview(duration)

        case .success:
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 2
            dot.layer?.backgroundColor = Theme.idle.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 4).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 4).isActive = true

            let label = NSTextField(labelWithString: "Completed")
            label.font = Theme.font(ofSize: 9, weight: .medium)
            label.textColor = Theme.idle
            label.isBezeled = false; label.drawsBackground = false
            label.isEditable = false; label.isSelectable = false

            let name = NSTextField(labelWithString: proc.name)
            name.font = Theme.monoFont(ofSize: 9)
            name.textColor = NSColor(white: 1.0, alpha: 0.3)
            name.isBezeled = false; name.drawsBackground = false
            name.isEditable = false; name.isSelectable = false

            let duration = NSTextField(labelWithString: proc.durationString)
            duration.font = Theme.font(ofSize: 9)
            duration.textColor = NSColor(white: 1.0, alpha: 0.25)
            duration.isBezeled = false; duration.drawsBackground = false
            duration.isEditable = false; duration.isSelectable = false
            duration.setContentHuggingPriority(.required, for: .horizontal)

            row.addArrangedSubview(dot)
            row.addArrangedSubview(label)
            row.addArrangedSubview(name)
            row.addArrangedSubview(duration)

        case .error:
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 2
            dot.layer?.backgroundColor = Theme.alert.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 4).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 4).isActive = true

            let exitLabel = "Failed (exit \(proc.exitCode ?? 1))"
            let label = NSTextField(labelWithString: exitLabel)
            label.font = Theme.font(ofSize: 9, weight: .medium)
            label.textColor = Theme.alert
            label.isBezeled = false; label.drawsBackground = false
            label.isEditable = false; label.isSelectable = false

            let name = NSTextField(labelWithString: proc.name)
            name.font = Theme.monoFont(ofSize: 9)
            name.textColor = NSColor(white: 1.0, alpha: 0.3)
            name.isBezeled = false; name.drawsBackground = false
            name.isEditable = false; name.isSelectable = false

            let duration = NSTextField(labelWithString: proc.durationString)
            duration.font = Theme.font(ofSize: 9)
            duration.textColor = NSColor(white: 1.0, alpha: 0.25)
            duration.isBezeled = false; duration.drawsBackground = false
            duration.isEditable = false; duration.isSelectable = false
            duration.setContentHuggingPriority(.required, for: .horizontal)

            row.addArrangedSubview(dot)
            row.addArrangedSubview(label)
            row.addArrangedSubview(name)
            row.addArrangedSubview(duration)
        }

        return row
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor(white: 1.0, alpha: 0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
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
    override func mouseDown(with event: NSEvent) { onFocus?() }
}
