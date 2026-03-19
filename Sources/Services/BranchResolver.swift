import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "BranchResolver")

// MARK: - Branch Resolver (extracted from ITermScanner)

class BranchResolver {
    private var cache: [String: (String, Date)] = [:]    // cwd path -> (branch, time)
    private static let maxCacheSize = Layout.maxCacheSize
    private static let maxBranchWalkDepth = 50

    /// Resolve git branch for a CWD path, with caching.
    func resolveBranch(cwd: String, cacheTTL: TimeInterval = 10.0) -> String? {
        if let cached = cache[cwd], Date().timeIntervalSince(cached.1) < cacheTTL {
            return cached.0
        }
        if let branch = getBranch(cwd: cwd) {
            cache[cwd] = (branch, Date())
            return branch
        }
        return nil
    }

    func getBranch(cwd: String) -> String? {
        var path = cwd
        let fm = FileManager.default
        var depth = 0
        while path != "/" && depth < Self.maxBranchWalkDepth {
            depth += 1
            if fm.fileExists(atPath: path + "/.git") {
                let pipe = Pipe()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", path, "branch", "--show-current"]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    os_log("git branch failed for %{public}@: %{public}@", log: logger, type: .error, path, error.localizedDescription)
                    return nil
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            path = (path as NSString).deletingLastPathComponent
        }
        return nil
    }

    func trimCache() {
        if cache.count > Self.maxCacheSize {
            let sorted = cache.sorted { $0.value.1 < $1.value.1 }
            let toRemove = sorted.prefix(cache.count - Self.maxCacheSize / 2)
            for (key, _) in toRemove { cache.removeValue(forKey: key) }
        }
    }
}
