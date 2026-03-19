import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "CWDResolver")

// MARK: - CWD Resolver (extracted from ITermScanner)

class CWDResolver {
    private var cache: [String: (String, Date)] = [:]   // tty -> (cwd, time)
    private static let maxCacheSize = Layout.maxCacheSize

    /// Resolve CWD for a TTY: hook state first, then lsof, with caching.
    func resolveCWD(tty: String, cacheTTL: TimeInterval = 10.0) -> String? {
        // Check cache first
        if let cached = cache[tty], Date().timeIntervalSince(cached.1) < cacheTTL {
            return cached.0
        }
        // Try hook state file
        if let cwd = readCWDFromHookState(tty: tty) {
            cache[tty] = (cwd, Date())
            return cwd
        }
        // Fall back to lsof
        if let cwd = detectCWD(tty: tty) {
            cache[tty] = (cwd, Date())
            return cwd
        }
        return nil
    }

    func readCWDFromHookState(tty: String) -> String? {
        let fm = FileManager.default
        let stateDir = "/tmp/claude-sidebar"
        guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else { return nil }
        var bestCWD: String? = nil
        var bestTimestamp: Double = 0
        for file in files where file.hasSuffix(".json") && !file.hasPrefix("focus") {
            let path = "\(stateDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let hookState = try? JSONDecoder().decode(HookState.self, from: data),
                  let hookTTY = hookState.tty, hookTTY == tty else { continue }
            if hookState.timestamp > bestTimestamp {
                bestTimestamp = hookState.timestamp
                bestCWD = hookState.cwd.isEmpty ? nil : hookState.cwd
            }
        }
        return bestCWD
    }

    func detectCWD(tty: String) -> String? {
        guard tty.hasPrefix("/dev/") && !tty.contains(";") && !tty.contains("$") && !tty.contains("`") else {
            os_log("Invalid TTY format: %{public}@", log: logger, type: .error, tty)
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "lsof -a -d cwd +D /dev -F n -t \(tty) 2>/dev/null | head -1 | xargs -I{} lsof -a -d cwd -p {} -F n 2>/dev/null | grep ^n/ | head -1 | cut -c2-"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            os_log("detectCWD failed for tty %{public}@: %{public}@", log: logger, type: .error, tty, error.localizedDescription)
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result?.isEmpty == true ? nil : result
    }

    func trimCache() {
        if cache.count > Self.maxCacheSize {
            let sorted = cache.sorted { $0.value.1 < $1.value.1 }
            let toRemove = sorted.prefix(cache.count - Self.maxCacheSize / 2)
            for (key, _) in toRemove { cache.removeValue(forKey: key) }
        }
    }
}
