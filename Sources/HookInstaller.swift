import AppKit
import Foundation

// MARK: - Hook Installer

class HookInstaller {
    static let settingsPath = NSHomeDirectory() + "/.claude/settings.json"

    static let hookEvents = ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "PermissionRequest", "PostToolUse", "SessionEnd"]

    static func hookScriptPath() -> String {
        return AppConfig.installDir + "/hooks/sidebar-state.sh"
    }

    static func checkHooksInstalled() -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        let scriptPath = hookScriptPath()
        for event in hookEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            let found = entries.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    (h["command"] as? String) == scriptPath
                }
            }
            if !found { return false }
        }
        return true
    }

    static func generateInstallPrompt() -> String {
        let scriptPath = hookScriptPath()

        var prompt = "Add or replace the following hooks in my ~/.claude/settings.json (preserve all existing settings, but replace any existing sidebar-state.sh hook entries with these exact entries):\n\n"
        for event in hookEvents {
            prompt += "Event: \(event)\n"
            if event == "Notification" {
                prompt += "  matcher: \"permission_prompt|elicitation_dialog\"\n"
            }
            prompt += "  command: \"\(scriptPath)\"\n"
            prompt += "  async: true, timeout: 5\n\n"
        }
        prompt += "Remove any sidebar-state.sh hook entries for events not listed above."
        return prompt
    }

    static func missingEvents() -> [String] {
        var existingHooks: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hooks = json["hooks"] as? [String: Any] {
            existingHooks = hooks
        }

        let scriptPath = hookScriptPath()
        var missing: [String] = []
        for event in hookEvents {
            let entries = existingHooks[event] as? [[String: Any]] ?? []
            let found = entries.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in (h["command"] as? String) == scriptPath }
            }
            if !found { missing.append(event) }
        }
        return missing
    }
}
