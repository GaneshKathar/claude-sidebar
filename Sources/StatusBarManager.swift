import AppKit

// MARK: - Status Bar Manager

class StatusBarManager {
    private var statusItem: NSStatusItem?
    var onOpenSettings: (() -> Void)?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            if let img = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Claude Sidebar") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "CS"
            }
            button.toolTip = "Claude Sidebar"
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Claude Sidebar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
