import AppKit

// MARK: - Settings Window Controller

class SettingsWindowController: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate {
    private var window: NSWindow?
    private var repoList: [(num: Int, path: String, label: String?, title: String?)] = []
    private var pollIntervalStepper: NSStepper!
    private var pollIntervalLabel: NSTextField!
    private var staleTimeoutStepper: NSStepper!
    private var staleTimeoutLabel: NSTextField!
    private var branchCacheStepper: NSStepper!
    private var branchCacheLabel: NSTextField!
    private var fontScaleStepper: NSStepper!
    private var fontScaleLabel: NSTextField!
    private var launchAtLoginCheckbox: NSButton!
    private var minimalViewCheckbox: NSButton!
    private var autoStartClaudeCheckbox: NSButton!
    private var tableView: NSTableView!
    private var hookStatusLabel: NSTextField!
    private var installHooksButton: NSButton!
    private var isFirstTime = false
    // Color settings — indexed: 0=idle, 1=working, 2=alert, 3=running
    private var colorWells: [NSColorWell] = []
    private var hexFields: [NSTextField] = []

    var onSave: ((AppConfig) -> Void)?

    func showWindow(firstTime: Bool = false) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        isFirstTime = firstTime

        // Load current config into editable list
        repoList = appConfig.repos.map { (num: $0.num, path: $0.path, label: $0.label, title: $0.title) }

        colorWells = []
        hexFields = []

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 848),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = firstTime ? "Welcome to Claude Sidebar" : "Claude Sidebar Settings"
        win.center()
        win.isReleasedWhenClosed = false

        if firstTime {
            win.delegate = self
        }

        let contentView = NSView(frame: win.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        win.contentView = contentView

        var yOffset: CGFloat = 808

        // === Session detection notice — shown only on first install ===
        let noticeKey = "com.claudesidebar.sessionWarningShown"
        if !UserDefaults.standard.bool(forKey: noticeKey) {
            UserDefaults.standard.set(true, forKey: noticeKey)
            yOffset -= 56
            let noticeBg = NSView()
            noticeBg.wantsLayer = true
            noticeBg.layer?.backgroundColor = NSColor(red: 1.0, green: 0.85, blue: 0.35, alpha: 0.12).cgColor
            noticeBg.layer?.cornerRadius = 6
            noticeBg.layer?.borderColor = NSColor(red: 1.0, green: 0.75, blue: 0.2, alpha: 0.4).cgColor
            noticeBg.layer?.borderWidth = 1
            noticeBg.frame = NSRect(x: 16, y: yOffset, width: 448, height: 50)
            contentView.addSubview(noticeBg)

            let noticeText = NSTextField(wrappingLabelWithString: "⚠︎  Sidebar may not detect already-running sessions correctly. Restart your Claude session so the sidebar can identify the correct window and tab.")
            noticeText.font = .systemFont(ofSize: 11)
            noticeText.textColor = NSColor(red: 0.7, green: 0.5, blue: 0.0, alpha: 1)
            noticeText.frame = NSRect(x: 10, y: 6, width: 428, height: 38)
            noticeBg.addSubview(noticeText)
        }

        // === First-time banner ===
        if firstTime {
            yOffset -= 30
            let bannerText = repoList.isEmpty
                ? "No repositories detected. Add repositories manually below."
                : "We detected \(repoList.count) repositor\(repoList.count == 1 ? "y" : "ies"). Review and save to start."
            let banner = makeLabel(bannerText)
            banner.textColor = .secondaryLabelColor
            banner.frame = NSRect(x: 20, y: yOffset, width: 440, height: 20)
            contentView.addSubview(banner)
        }

        // === Section A: Repositories ===
        yOffset -= 30
        let repoHeader = makeLabel("Repositories", bold: true)
        repoHeader.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(repoHeader)

        yOffset -= 160
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: yOffset, width: 440, height: 150))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true

        let numCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("num"))
        numCol.title = "#"
        numCol.width = 30
        numCol.isEditable = false
        tableView.addTableColumn(numCol)

        let labelCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
        labelCol.title = "Badge"
        labelCol.width = 46
        labelCol.isEditable = false
        tableView.addTableColumn(labelCol)

        let titleCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleCol.title = "Title"
        titleCol.width = 100
        titleCol.isEditable = false
        tableView.addTableColumn(titleCol)

        let pathCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathCol.title = "Path"
        pathCol.width = 184
        pathCol.isEditable = false
        tableView.addTableColumn(pathCol)

        let removeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("remove"))
        removeCol.title = ""
        removeCol.width = 40
        removeCol.isEditable = false
        tableView.addTableColumn(removeCol)

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        yOffset -= 32
        let addButton = NSButton(title: "Add Repository...", target: self, action: #selector(addRepo))
        addButton.bezelStyle = .rounded
        addButton.frame = NSRect(x: 20, y: yOffset, width: 150, height: 24)
        contentView.addSubview(addButton)

        let detectButton = NSButton(title: "Auto-Detect", target: self, action: #selector(autoDetectRepos))
        detectButton.bezelStyle = .rounded
        detectButton.frame = NSRect(x: 180, y: yOffset, width: 120, height: 24)
        contentView.addSubview(detectButton)

        // === Section B: Settings ===
        yOffset -= 40
        let settingsHeader = makeLabel("Settings", bold: true)
        settingsHeader.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(settingsHeader)

        // Poll interval
        yOffset -= 28
        let pollLabel = makeLabel("Poll interval (seconds):")
        pollLabel.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(pollLabel)

        pollIntervalStepper = NSStepper()
        pollIntervalStepper.minValue = 1
        pollIntervalStepper.maxValue = 10
        pollIntervalStepper.increment = 1
        pollIntervalStepper.doubleValue = appConfig.pollInterval ?? 3.0
        pollIntervalStepper.target = self
        pollIntervalStepper.action = #selector(stepperChanged)
        pollIntervalStepper.frame = NSRect(x: 380, y: yOffset, width: 20, height: 20)
        contentView.addSubview(pollIntervalStepper)

        pollIntervalLabel = makeLabel("\(Int(pollIntervalStepper.doubleValue))")
        pollIntervalLabel.frame = NSRect(x: 350, y: yOffset, width: 30, height: 20)
        pollIntervalLabel.alignment = .right
        contentView.addSubview(pollIntervalLabel)

        // Stale timeout
        yOffset -= 28
        let staleLabel = makeLabel("Stale timeout (minutes):")
        staleLabel.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(staleLabel)

        staleTimeoutStepper = NSStepper()
        staleTimeoutStepper.minValue = 5
        staleTimeoutStepper.maxValue = 60
        staleTimeoutStepper.increment = 5
        staleTimeoutStepper.doubleValue = (appConfig.staleTimeout ?? 1800) / 60.0
        staleTimeoutStepper.target = self
        staleTimeoutStepper.action = #selector(stepperChanged)
        staleTimeoutStepper.frame = NSRect(x: 380, y: yOffset, width: 20, height: 20)
        contentView.addSubview(staleTimeoutStepper)

        staleTimeoutLabel = makeLabel("\(Int(staleTimeoutStepper.doubleValue))")
        staleTimeoutLabel.frame = NSRect(x: 350, y: yOffset, width: 30, height: 20)
        staleTimeoutLabel.alignment = .right
        contentView.addSubview(staleTimeoutLabel)

        // Branch cache TTL
        yOffset -= 28
        let cacheLabel = makeLabel("Branch cache TTL (seconds):")
        cacheLabel.frame = NSRect(x: 20, y: yOffset, width: 220, height: 20)
        contentView.addSubview(cacheLabel)

        branchCacheStepper = NSStepper()
        branchCacheStepper.minValue = 5
        branchCacheStepper.maxValue = 30
        branchCacheStepper.increment = 5
        branchCacheStepper.doubleValue = appConfig.branchCacheTTL ?? 10.0
        branchCacheStepper.target = self
        branchCacheStepper.action = #selector(stepperChanged)
        branchCacheStepper.frame = NSRect(x: 380, y: yOffset, width: 20, height: 20)
        contentView.addSubview(branchCacheStepper)

        branchCacheLabel = makeLabel("\(Int(branchCacheStepper.doubleValue))")
        branchCacheLabel.frame = NSRect(x: 350, y: yOffset, width: 30, height: 20)
        branchCacheLabel.alignment = .right
        contentView.addSubview(branchCacheLabel)

        // Font scale
        yOffset -= 28
        let fontScaleDescLabel = makeLabel("Font size:")
        fontScaleDescLabel.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(fontScaleDescLabel)

        fontScaleStepper = NSStepper()
        fontScaleStepper.minValue = 0.8
        fontScaleStepper.maxValue = 1.5
        fontScaleStepper.increment = 0.1
        fontScaleStepper.doubleValue = appConfig.fontScale ?? 1.0
        fontScaleStepper.target = self
        fontScaleStepper.action = #selector(stepperChanged)
        fontScaleStepper.frame = NSRect(x: 380, y: yOffset, width: 20, height: 20)
        contentView.addSubview(fontScaleStepper)

        fontScaleLabel = makeLabel("\(Int(fontScaleStepper.doubleValue * 100))%")
        fontScaleLabel.frame = NSRect(x: 340, y: yOffset, width: 40, height: 20)
        fontScaleLabel.alignment = .right
        contentView.addSubview(fontScaleLabel)

        // Launch at login
        yOffset -= 30
        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
        launchAtLoginCheckbox.state = (appConfig.launchAtLogin ?? false) ? .on : .off
        launchAtLoginCheckbox.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(launchAtLoginCheckbox)

        // Minimal view
        yOffset -= 24
        minimalViewCheckbox = NSButton(checkboxWithTitle: "Minimal view (badges only, no expand)", target: nil, action: nil)
        minimalViewCheckbox.state = (appConfig.minimalView ?? false) ? .on : .off
        minimalViewCheckbox.frame = NSRect(x: 20, y: yOffset, width: 300, height: 20)
        contentView.addSubview(minimalViewCheckbox)

        // Auto-start Claude
        yOffset -= 24
        autoStartClaudeCheckbox = NSButton(checkboxWithTitle: "Auto-start Claude in new windows", target: nil, action: nil)
        autoStartClaudeCheckbox.state = (appConfig.autoStartClaude ?? false) ? .on : .off
        autoStartClaudeCheckbox.frame = NSRect(x: 20, y: yOffset, width: 300, height: 20)
        contentView.addSubview(autoStartClaudeCheckbox)

        // === Section C: Status Colors ===
        yOffset -= 40
        let colorHeader = makeLabel("Status Colors", bold: true)
        colorHeader.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(colorHeader)

        let colorDefs: [(label: String, color: NSColor)] = [
            ("Idle",    Theme.green),
            ("Working", Theme.blue),
            ("Alert",   Theme.red),
        ]
        for (idx, def) in colorDefs.enumerated() {
            yOffset -= 28
            let lbl = makeLabel("\(def.label):")
            lbl.frame = NSRect(x: 20, y: yOffset, width: 110, height: 22)
            contentView.addSubview(lbl)

            let well = NSColorWell()
            well.color = def.color
            well.frame = NSRect(x: 140, y: yOffset, width: 44, height: 22)
            well.target = self
            well.action = #selector(colorWellChanged(_:))
            well.tag = idx
            contentView.addSubview(well)
            colorWells.append(well)

            let hexField = NSTextField(string: def.color.hexString)
            hexField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            hexField.frame = NSRect(x: 194, y: yOffset, width: 90, height: 22)
            hexField.placeholderString = "#rrggbb"
            hexField.isEditable = true
            hexField.isSelectable = true   // allows copy/paste
            hexField.delegate = self
            hexField.tag = 100 + idx
            contentView.addSubview(hexField)
            hexFields.append(hexField)
        }

        // === Section D: Claude Hooks ===
        yOffset -= 40
        let hookHeader = makeLabel("Claude Hooks", bold: true)
        hookHeader.frame = NSRect(x: 20, y: yOffset, width: 200, height: 20)
        contentView.addSubview(hookHeader)

        yOffset -= 28
        hookStatusLabel = makeLabel("")
        hookStatusLabel.frame = NSRect(x: 20, y: yOffset, width: 300, height: 20)
        contentView.addSubview(hookStatusLabel)

        installHooksButton = NSButton(title: "Install Hooks", target: self, action: #selector(installHooksTapped))
        installHooksButton.bezelStyle = .rounded
        installHooksButton.frame = NSRect(x: 340, y: yOffset - 2, width: 120, height: 24)
        contentView.addSubview(installHooksButton)

        updateHookStatus()

        // === Bottom bar ===
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 380, y: 12, width: 80, height: 28)
        contentView.addSubview(saveButton)

        let cancelTitle = firstTime ? "Quit" : "Cancel"
        let cancelButton = NSButton(title: cancelTitle, target: self, action: #selector(cancelSettings))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 290, y: 12, width: 80, height: 28)
        contentView.addSubview(cancelButton)

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeLabel(_ text: String, bold: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 12)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }

    private func updateHookStatus() {
        if HookInstaller.checkHooksInstalled() {
            hookStatusLabel.stringValue = "\u{2705} Hooks installed"
        } else {
            hookStatusLabel.stringValue = "\u{26A0}\u{FE0F} Hooks not configured"
        }
        installHooksButton.title = "Copy Install Prompt"
        installHooksButton.isEnabled = true
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return repoList.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < repoList.count else { return nil }
        let repo = repoList[row]
        let id = tableColumn?.identifier.rawValue ?? ""

        if id == "num" {
            let cell = NSTextField(labelWithString: "\(repo.num)")
            cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.alignment = .center
            return cell
        } else if id == "label" {
            let cell = NSTextField(string: repo.label ?? "")
            cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.alignment = .center
            cell.placeholderString = "\(repo.num)"
            cell.isBezeled = true
            cell.bezelStyle = .roundedBezel
            cell.isEditable = true
            cell.isSelectable = true
            cell.delegate = self
            cell.tag = row          // tags 0..N = label rows
            return cell
        } else if id == "title" {
            let cell = NSTextField(string: repo.title ?? "")
            cell.font = .systemFont(ofSize: 12)
            cell.placeholderString = "Custom name"
            cell.isBezeled = true
            cell.bezelStyle = .roundedBezel
            cell.isEditable = true
            cell.isSelectable = true
            cell.delegate = self
            cell.tag = 200 + row    // tags 200..2N = title rows
            return cell
        } else if id == "path" {
            let cell = NSTextField(labelWithString: repo.path)
            cell.font = .systemFont(ofSize: 12)
            cell.lineBreakMode = .byTruncatingMiddle
            return cell
        } else if id == "remove" {
            let btn = NSButton(title: "\u{2715}", target: self, action: #selector(removeRepo(_:)))
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.font = .systemFont(ofSize: 12)
            btn.tag = row
            return btn
        }
        return nil
    }

    // MARK: - NSTextFieldDelegate (label editing)

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField else { return }
        let row = textField.tag

        // Tags 100–102: hex color fields
        if row >= 100 && row < 103 {
            let idx = row - 100
            if let color = NSColor(hexString: textField.stringValue), idx < colorWells.count {
                colorWells[idx].color = color
            }
            return
        }

        // Tags 200+: title fields
        if row >= 200 {
            let repoRow = row - 200
            guard repoRow < repoList.count else { return }
            let text = textField.stringValue
            repoList[repoRow].title = text.isEmpty ? nil : text
            return
        }

        guard row < repoList.count else { return }

        var text = textField.stringValue
        // Allow up to 2 grapheme clusters (single emoji = 1 cluster, flag = 1 cluster)
        let clusters = Array(text)
        if clusters.count > 2 {
            text = String(clusters.prefix(2))
            textField.stringValue = text
        }
        repoList[row].label = text.isEmpty ? nil : text
    }

    // MARK: - Actions

    @objc private func addRepo() {
        if repoList.count >= 8 {
            let alert = NSAlert()
            alert.messageText = "Maximum 8 repositories"
            alert.informativeText = "You can have at most 8 repositories configured."
            alert.runModal()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"
        panel.message = "Select a repository directory (must contain 'sdmain' in name)"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.path
        let folderName = url.lastPathComponent
        guard folderName.contains("sdmain") else {
            let alert = NSAlert()
            alert.messageText = "Invalid Repository"
            alert.informativeText = "The selected directory must contain 'sdmain' in its name."
            alert.runModal()
            return
        }

        // Auto-assign next available number
        let usedNums = Set(repoList.map { $0.num })
        var nextNum = 1
        while usedNums.contains(nextNum) { nextNum += 1 }

        // Use ~ shorthand if under home directory
        let home = NSHomeDirectory()
        let displayPath = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path

        repoList.append((num: nextNum, path: displayPath, label: nil, title: nil))
        repoList.sort { $0.num < $1.num }
        tableView.reloadData()
    }

    @objc private func autoDetectRepos() {
        let detected = AppConfig.detectRepos()
        if detected.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No Repositories Found"
            alert.informativeText = "Could not find any sdmain* directories with .git under your home directory (up to 5 levels deep)."
            alert.runModal()
            return
        }

        // Merge with existing: skip duplicate paths
        let existingPaths = Set(repoList.map { $0.path })
        var added = 0
        for repo in detected {
            if !existingPaths.contains(repo.path) {
                repoList.append((num: 0, path: repo.path, label: repo.label, title: repo.title))
                added += 1
            }
        }

        // Re-number sequentially
        repoList.sort { $0.path < $1.path }
        for i in 0..<repoList.count {
            repoList[i].num = i + 1
        }

        tableView.reloadData()

        if added == 0 {
            let alert = NSAlert()
            alert.messageText = "No New Repositories"
            alert.informativeText = "All detected repositories are already in the list."
            alert.runModal()
        }
    }

    @objc private func removeRepo(_ sender: NSButton) {
        let row = sender.tag
        guard row < repoList.count else { return }
        if repoList.count <= 1 && !isFirstTime {
            let alert = NSAlert()
            alert.messageText = "Cannot Remove"
            alert.informativeText = "At least one repository is required."
            alert.runModal()
            return
        }
        repoList.remove(at: row)
        // Re-number sequentially
        for i in 0..<repoList.count {
            repoList[i].num = i + 1
        }
        tableView.reloadData()
    }

    @objc private func colorWellChanged(_ sender: NSColorWell) {
        let idx = sender.tag
        guard idx < hexFields.count else { return }
        hexFields[idx].stringValue = sender.color.hexString
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        if sender === pollIntervalStepper {
            pollIntervalLabel.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === staleTimeoutStepper {
            staleTimeoutLabel.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === branchCacheStepper {
            branchCacheLabel.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === fontScaleStepper {
            fontScaleLabel.stringValue = "\(Int(sender.doubleValue * 100))%"
        }
    }

    @objc private func installHooksTapped() {
        let prompt = HookInstaller.generateInstallPrompt()

        let missing = HookInstaller.missingEvents()
        let statusText = missing.isEmpty
            ? "All hooks are already installed."
            : "Missing hooks for: \(missing.joined(separator: ", "))"

        let alert = NSAlert()
        alert.messageText = "Copy Hook Install Prompt"
        alert.informativeText = "\(statusText)\n\nClick \"Copy to Clipboard\" to get a prompt you can paste into any Claude Code session. Claude will safely merge the hooks into your existing ~/.claude/settings.json."
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            hookStatusLabel.stringValue = "\u{1F4CB} Prompt copied \u{2014} paste into Claude Code"
        }
    }

    @objc private func saveSettings() {
        // Force any in-progress text field edits to commit before reading values
        window?.makeFirstResponder(nil)
        let newConfig = AppConfig(
            repos: repoList.map { RepoConfig(num: $0.num, path: $0.path, label: $0.label, title: $0.title) },
            pollInterval: pollIntervalStepper.doubleValue,
            branchCacheTTL: branchCacheStepper.doubleValue,
            staleTimeout: staleTimeoutStepper.doubleValue * 60,
            launchAtLogin: launchAtLoginCheckbox.state == .on,
            fontScale: fontScaleStepper.doubleValue,
            minimalView: minimalViewCheckbox.state == .on,
            autoStartClaude: autoStartClaudeCheckbox.state == .on,
            colorIdle:    colorWells.count > 0 ? colorWells[0].color.hexString : nil,
            colorWorking: colorWells.count > 1 ? colorWells[1].color.hexString : nil,
            colorAlert:   colorWells.count > 2 ? colorWells[2].color.hexString : nil,
            colorRunning: nil
        )
        newConfig.save()
        isFirstTime = false
        onSave?(newConfig)
        window?.close()
    }

    @objc private func cancelSettings() {
        if isFirstTime {
            NSApp.terminate(nil)
        } else {
            window?.close()
        }
    }
}

// MARK: - NSWindowDelegate (first-time mode: closing = quit)

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if isFirstTime {
            NSApp.terminate(nil)
        }
    }
}
