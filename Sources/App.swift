import AppKit
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "App")

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var sidebar: SidebarController?
    let statusBar = StatusBarManager()
    let settingsController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install global error handlers
        NSSetUncaughtExceptionHandler { exception in
            os_log("Uncaught exception: %{public}@ — %{public}@", log: logger, type: .fault,
                   exception.name.rawValue, exception.reason ?? "no reason")
            os_log("Stack trace: %{public}@", log: logger, type: .fault,
                   exception.callStackSymbols.joined(separator: "\n"))
        }
        for sig: Int32 in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig) { sigNum in
                os_log("Fatal signal %d received", log: logger, type: .fault, sigNum)
            }
        }

        let stateDir = "/tmp/claude-sidebar"
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700  // Owner-only access
            ])
        } catch {
            os_log("Failed to create state directory: %{public}@", log: logger, type: .error, error.localizedDescription)
        }

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

        os_log("App launched successfully", log: logger, type: .info)
    }

    func applicationWillTerminate(_ notification: Notification) {
        os_log("App terminating", log: logger, type: .info)
    }
}
