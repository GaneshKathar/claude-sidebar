import AppKit
import Foundation

// MARK: - Terminal Capabilities

struct TerminalCapabilities: OptionSet {
    let rawValue: UInt
    static let nativeEnumeration    = TerminalCapabilities(rawValue: 1 << 0)
    static let nativeFocus          = TerminalCapabilities(rawValue: 1 << 1)
    static let nativeCreateTab      = TerminalCapabilities(rawValue: 1 << 2)
    static let nativeCreateWindow   = TerminalCapabilities(rawValue: 1 << 3)
    static let nativeOpenWithCWD    = TerminalCapabilities(rawValue: 1 << 4)
    static let nativeCWDFromSession = TerminalCapabilities(rawValue: 1 << 5)
}

// MARK: - Terminal Info

struct TerminalInfo {
    let identifier: String       // "iterm2", "ghostty", "cmux"
    let displayName: String      // "iTerm2", "Ghostty", "cmux"
    let scriptName: String       // AppleScript name: "iTerm2", "Visual Studio Code"
    let bundleIdentifier: String?
    let keywords: [String]       // process name keywords for detection
}

// MARK: - Terminal Adapter Protocol

protocol TerminalAdapter: AnyObject {
    var info: TerminalInfo { get }
    var capabilities: TerminalCapabilities { get }

    func isAvailable() -> Bool
    func claimsSession(tty: String, focus: TerminalFocus?, processAncestry: [String]) -> Bool

    // Scanning
    func enumerateSessions(hookStates: HookStates, psInfo: PSScanResult) -> [TerminalWindow]

    // Focus
    func focusSession(windowId: Int, sessionId: String, focus: TerminalFocus?) -> Bool

    // Creation (only iTerm2 implements these natively)
    func createTab(windowId: Int) -> Bool
    func createWindow() -> Bool
    func openWithCWD(path: String, command: String?) -> Bool

    // CWD
    func parseCWD(sessionName: String) -> String?

    // Setup
    var setupInstructions: String? { get }
    func isPluginConfigured() -> Bool
}

// MARK: - Default Implementations

extension TerminalAdapter {
    func enumerateSessions(hookStates: HookStates, psInfo: PSScanResult) -> [TerminalWindow] { [] }
    func focusSession(windowId: Int, sessionId: String, focus: TerminalFocus?) -> Bool { false }
    func createTab(windowId: Int) -> Bool { false }
    func createWindow() -> Bool { false }
    func openWithCWD(path: String, command: String?) -> Bool { false }
    func parseCWD(sessionName: String) -> String? { nil }
    var setupInstructions: String? { nil }
    func isPluginConfigured() -> Bool { true }
}
