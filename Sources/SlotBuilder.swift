import Foundation

// MARK: - Slot Builder (extracted from SidebarController — SRP)
// Pure function: takes windows + config, returns display slots.
// No side effects, no delegates needed.

class SlotBuilder {
    // CWD-based grouping for non-repo slots (stable across scans)
    var cwdGroupWindowIds: [String: Int] = [:]   // groupKey -> stable windowId
    var cwdGroupLabels: [String: String] = [:]   // groupKey -> display label
    var cwdGroupNextId = -20001
    var cwdGroupNextLabel = 1

    func buildSlots(windows: [TerminalWindow], repos: [RepoConfig]) -> [TerminalWindow] {
        var slots: [TerminalWindow] = []
        var claimedTTYs = Set<String>()

        // Flatten all tabs from all scanned windows.
        let allTabs = windows.flatMap { $0.tabs }.filter { tab in
            tab.hasClaude || tab.processInfo != nil || tab.alwaysShow
        }

        // 1. Repo slots: collect ALL tabs (from any terminal) whose CWD is under each repo path
        for repo in repos {
            let repoPath = repo.expandedPath
            let repoTabs = allTabs.filter { tab in
                guard let cwd = tab.cwd else { return false }
                return cwd == repoPath || cwd.hasPrefix(repoPath + "/")
            }

            if repoTabs.isEmpty {
                slots.append(.placeholder(for: repo))
            } else {
                repoTabs.forEach { claimedTTYs.insert($0.tty) }
                // Sort: Claude sessions first, then non-Claude
                let sortedTabs = repoTabs.sorted { a, b in
                    if a.hasClaude != b.hasClaude { return a.hasClaude }
                    return a.state > b.state  // higher priority state first
                }
                let indexedTabs = sortedTabs.enumerated().map { idx, t -> TerminalTab in
                    var tab = t; tab.tabIndex = idx; return tab
                }
                let slotName = repo.title ?? (repoPath as NSString).lastPathComponent
                slots.append(TerminalWindow(
                    windowId: -repo.num,
                    windowName: slotName,
                    displayLabel: repo.displayLabel,
                    displayPath: shortPath(repoPath),
                    tabs: indexedTabs,
                    matchedRepoNum: repo.num
                ))
            }
        }

        // 2. Non-repo tabs: group by git root (or exact CWD if no git root)
        let remaining = allTabs.filter { !claimedTTYs.contains($0.tty) }

        var cwdGroups: [String: [TerminalTab]] = [:]
        var unknownByWindow: [Int: [TerminalTab]] = [:]

        for tab in remaining {
            if let cwd = tab.cwd {
                let key = gitRoot(for: cwd) ?? cwd
                cwdGroups[key, default: []].append(tab)
            } else {
                unknownByWindow[tab.windowId, default: []].append(tab)
            }
        }

        // CWD groups sorted by path for stable order
        for (key, tabs) in cwdGroups.sorted(by: { $0.key < $1.key }) {
            if cwdGroupWindowIds[key] == nil {
                cwdGroupWindowIds[key] = cwdGroupNextId
                cwdGroupNextId -= 1
            }
            if cwdGroupLabels[key] == nil {
                // Use abbreviated dir name instead of sequential number
                let dirName = (key as NSString).lastPathComponent
                cwdGroupLabels[key] = abbreviate(dirName)
            }
            let windowId = cwdGroupWindowIds[key]!
            let label = cwdGroupLabels[key]!

            let indexedTabs = tabs.sorted { $0.tabIndex < $1.tabIndex }.enumerated().map { idx, t -> TerminalTab in
                var tab = t; tab.tabIndex = idx; return tab
            }
            slots.append(TerminalWindow(
                windowId: windowId,
                windowName: (key as NSString).lastPathComponent,
                displayLabel: label,
                displayPath: shortPath(key),
                tabs: indexedTabs
            ))
            tabs.forEach { claimedTTYs.insert($0.tty) }
        }

        // Tabs with unknown CWD: fall back to original window grouping
        for (wid, tabs) in unknownByWindow.sorted(by: { $0.key < $1.key }) {
            let origWindow = windows.first(where: { $0.windowId == wid })
            let label: String
            if let orig = origWindow {
                label = orig.displayLabel
            } else {
                label = "\(cwdGroupNextLabel)"
                cwdGroupNextLabel += 1
            }
            let indexedTabs = tabs.sorted { $0.tabIndex < $1.tabIndex }.enumerated().map { idx, t -> TerminalTab in
                var tab = t; tab.tabIndex = idx; return tab
            }
            slots.append(TerminalWindow(
                windowId: wid,
                windowName: origWindow?.windowName ?? "Terminal",
                displayLabel: label,
                tabs: indexedTabs
            ))
        }

        return slots
    }

    // MARK: - Helpers

    /// Walk up from cwd to find the nearest .git directory (project root)
    private func gitRoot(for cwd: String) -> String? {
        var path = cwd
        let fm = FileManager.default
        for _ in 0..<20 {
            if fm.fileExists(atPath: path + "/.git") { return path }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { break }
            path = parent
        }
        return nil
    }

    /// Abbreviate a directory name: first letter of each word (max 3).
    /// "claude-sidebar" → "CS", "my-cool-project" → "MCP", "foo" → "F"
    private func abbreviate(_ name: String) -> String {
        let parts = name.components(separatedBy: CharacterSet(charactersIn: "-_."))
            .filter { !$0.isEmpty }
        let abbr = parts.prefix(3).map { String($0.prefix(1)) }.joined()
        return abbr.uppercased()
    }

    private func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
