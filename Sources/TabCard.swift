import AppKit

// MARK: - Tab Card

class TabCard: NSView {
    var onClick: (() -> Void)?
    var onFocus: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private let borderView = NSView()

    init(tab: ITermTabInfo) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.03).cgColor

        // Left border colored by state
        borderView.wantsLayer = true
        borderView.layer?.cornerRadius = 1
        borderView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(borderView)

        if tab.hasClaude {
            borderView.layer?.backgroundColor = tab.claudeState.color.withAlphaComponent(0.4).cgColor
        } else if let proc = tab.processInfo {
            borderView.layer?.backgroundColor = proc.state.color.withAlphaComponent(0.4).cgColor
        } else {
            borderView.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.15).cgColor
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Row 1: CWD + focus button
        let row1 = NSStackView()
        row1.orientation = .horizontal
        row1.spacing = 4
        row1.alignment = .centerY

        let cwdLabel = NSTextField(labelWithString: "")
        cwdLabel.font = Theme.monoFont(ofSize: 10)
        cwdLabel.textColor = NSColor(white: 1.0, alpha: 0.45)
        cwdLabel.lineBreakMode = .byTruncatingHead
        cwdLabel.maximumNumberOfLines = 1
        cwdLabel.isBezeled = false
        cwdLabel.drawsBackground = false
        cwdLabel.isEditable = false
        cwdLabel.isSelectable = false
        if let cwd = tab.cwd {
            // Shorten home directory
            let home = NSHomeDirectory()
            cwdLabel.stringValue = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
        } else {
            // Don't show raw session name — just show "Tab N"
            cwdLabel.stringValue = "Tab \(tab.tabIndex)"
            cwdLabel.textColor = NSColor(white: 1.0, alpha: 0.3)
        }
        cwdLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cwdLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row1.addArrangedSubview(cwdLabel)

        let focusBtn = NSTextField(labelWithString: "\u{2318}")
        focusBtn.font = Theme.font(ofSize: 9)
        focusBtn.textColor = NSColor(white: 1.0, alpha: 0.15)
        focusBtn.isBezeled = false
        focusBtn.drawsBackground = false
        focusBtn.isEditable = false
        focusBtn.isSelectable = false
        focusBtn.setContentHuggingPriority(.required, for: .horizontal)
        row1.addArrangedSubview(focusBtn)

        stack.addArrangedSubview(row1)

        // Row 2: Branch (if available)
        if let branch = tab.gitBranch, !branch.isEmpty {
            let row2 = NSStackView()
            row2.orientation = .horizontal
            row2.spacing = 3
            row2.alignment = .centerY

            let branchIcon = NSTextField(labelWithString: "\u{2387}")
            branchIcon.font = Theme.font(ofSize: 10)
            branchIcon.textColor = NSColor(white: 1.0, alpha: 0.25)
            branchIcon.isBezeled = false
            branchIcon.drawsBackground = false
            branchIcon.isEditable = false
            branchIcon.isSelectable = false

            let branchName = NSTextField(labelWithString: branch)
            branchName.font = Theme.font(ofSize: 10)
            branchName.textColor = NSColor(white: 1.0, alpha: 0.4)
            branchName.lineBreakMode = .byTruncatingTail
            branchName.maximumNumberOfLines = 1
            branchName.isBezeled = false
            branchName.drawsBackground = false
            branchName.isEditable = false
            branchName.isSelectable = false

            row2.addArrangedSubview(branchIcon)
            row2.addArrangedSubview(branchName)
            stack.addArrangedSubview(row2)
        }

        // Row 3: Claude status OR process status
        if tab.hasClaude {
            let row3 = makeClaudeStatusRow(tab: tab)
            stack.addArrangedSubview(row3)
        } else if let proc = tab.processInfo {
            let row3 = makeProcessStatusRow(proc: proc)
            stack.addArrangedSubview(row3)
        }

        NSLayoutConstraint.activate([
            borderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            borderView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            borderView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            borderView.widthAnchor.constraint(equalToConstant: 2),

            stack.leadingAnchor.constraint(equalTo: borderView.trailingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        // Row width constraint
        row1.translatesAutoresizingMaskIntoConstraints = false
        row1.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    private func makeClaudeStatusRow(tab: ITermTabInfo) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = tab.claudeState.color.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        if tab.claudeState == .working {
            dot.layer?.shadowColor = Theme.blue.cgColor
            dot.layer?.shadowRadius = 3
            dot.layer?.shadowOpacity = 0.5
            dot.layer?.shadowOffset = .zero
        }

        let label = NSTextField(labelWithString: "")
        label.font = Theme.font(ofSize: 10)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false

        switch tab.claudeState {
        case .working:
            label.stringValue = "Claude working"
            label.textColor = Theme.blue
        case .alert:
            label.stringValue = "Needs permission"
            label.textColor = Theme.red
        case .idle:
            label.stringValue = "Claude idle"
            label.textColor = Theme.green
        case .inactive:
            label.stringValue = "Claude"
            label.textColor = Theme.textDim
        }

        row.addArrangedSubview(dot)
        row.addArrangedSubview(label)
        return row
    }

    private func makeProcessStatusRow(proc: ProcessInfo) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY

        switch proc.state {
        case .running:
            // Spinner (yellow dot with glow for now — real spinner needs CALayer animation)
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = Theme.yellow.cgColor
            dot.layer?.shadowColor = Theme.yellow.cgColor
            dot.layer?.shadowRadius = 3
            dot.layer?.shadowOpacity = 0.4
            dot.layer?.shadowOffset = .zero
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

            let label = NSTextField(labelWithString: "Running")
            label.font = Theme.font(ofSize: 10)
            label.textColor = Theme.yellow
            label.isBezeled = false; label.drawsBackground = false
            label.isEditable = false; label.isSelectable = false

            let name = NSTextField(labelWithString: proc.name)
            name.font = Theme.monoFont(ofSize: 10)
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
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = Theme.green.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

            let label = NSTextField(labelWithString: "Completed")
            label.font = Theme.font(ofSize: 10)
            label.textColor = Theme.green
            label.isBezeled = false; label.drawsBackground = false
            label.isEditable = false; label.isSelectable = false

            let name = NSTextField(labelWithString: proc.name)
            name.font = Theme.monoFont(ofSize: 10)
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
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = Theme.red.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

            let exitLabel = "Failed (exit \(proc.exitCode ?? 1))"
            let label = NSTextField(labelWithString: exitLabel)
            label.font = Theme.font(ofSize: 10)
            label.textColor = Theme.red
            label.isBezeled = false; label.drawsBackground = false
            label.isEditable = false; label.isSelectable = false

            let name = NSTextField(labelWithString: proc.name)
            name.font = Theme.monoFont(ofSize: 10)
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
