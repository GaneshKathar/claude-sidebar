import AppKit
import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "TerminalRegistry")

// MARK: - Terminal Registry (singleton)

class TerminalRegistry {
    static let shared = TerminalRegistry()

    // Shared services
    let detector = TerminalDetector()
    let cwdResolver = CWDResolver()
    let branchResolver = BranchResolver()

    // Registered adapters in priority order
    private(set) var adapters: [TerminalAdapter] = []

    private init() {
        // Priority order: iTerm2, cmux, VS Code, Ghostty, Kitty, then generics
        adapters = [
            ITerm2Adapter(),
            CmuxAdapter(),
            VSCodeAdapter(),
            GhosttyAdapter(),
            KittyAdapter(),
            // Generic adapters for known terminals
            GenericTerminalAdapter(info: TerminalInfo(
                identifier: "alacritty", displayName: "Alacritty", scriptName: "Alacritty",
                bundleIdentifier: "org.alacritty", keywords: ["alacritty"])),
            GenericTerminalAdapter(info: TerminalInfo(
                identifier: "warp", displayName: "Warp", scriptName: "Warp",
                bundleIdentifier: "dev.warp.Warp-Stable", keywords: ["warp"])),
            GenericTerminalAdapter(info: TerminalInfo(
                identifier: "hyper", displayName: "Hyper", scriptName: "Hyper",
                bundleIdentifier: "co.zeit.hyper", keywords: ["hyper"])),
            GenericTerminalAdapter(info: TerminalInfo(
                identifier: "tabby", displayName: "Tabby", scriptName: "Tabby",
                bundleIdentifier: nil, keywords: ["tabby"])),
            GenericTerminalAdapter(info: TerminalInfo(
                identifier: "rio", displayName: "Rio", scriptName: "Rio",
                bundleIdentifier: nil, keywords: ["rio"])),
            GenericTerminalAdapter(info: TerminalInfo(
                identifier: "cursor", displayName: "Cursor", scriptName: "Cursor",
                bundleIdentifier: "com.todesktop.230313mzl4w4u92", keywords: ["cursor"])),
            GenericTerminalAdapter(info: TerminalInfo(
                identifier: "terminal", displayName: "Terminal", scriptName: "Terminal",
                bundleIdentifier: "com.apple.Terminal", keywords: ["terminal"])),
        ]
    }

    /// Find the adapter that claims this TTY session.
    func adapterForTTY(_ tty: String, focus: TerminalFocus?, psInfo: PSScanResult) -> TerminalAdapter? {
        let ancestry = detector.processAncestry(for: tty, psInfo: psInfo)
        return adapters.first { $0.claimsSession(tty: tty, focus: focus, processAncestry: ancestry) }
    }

    /// Adapters where isAvailable() is true.
    func availableAdapters() -> [TerminalAdapter] {
        adapters.filter { $0.isAvailable() }
    }

    /// Available adapters with native enumeration.
    func enumeratingAdapters() -> [TerminalAdapter] {
        availableAdapters().filter { $0.capabilities.contains(.nativeEnumeration) }
    }

    /// Replaces ITermScanner.isKnownTerminal — used by PollingCoordinator.
    func isKnownTerminal(_ lowerName: String) -> Bool {
        TerminalDetector.isKnownTerminal(lowerName)
    }
}
