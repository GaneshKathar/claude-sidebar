import AppKit

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var sidebar: SidebarController?
    let statusBar = StatusBarManager()
    let settingsController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: "/tmp/claude-sidebar", withIntermediateDirectories: true)

        // Setup status bar icon
        statusBar.onOpenSettings = { [weak self] in
            self?.settingsController.showWindow()
        }
        statusBar.setup()

        // Setup settings save callback
        settingsController.onSave = { [weak self] newConfig in
            appConfig = newConfig
            self?.sidebar?.reload()
        }

        sidebar = SidebarController()
        sidebar?.start()
    }
}

