import AppKit
import Darwin
import Foundation
import LocalAuthentication

/// Safe file removal service informed by CleanMyMac's ToolsKitObjc (`PANFileImmutabilityService` +
/// `PANFileRemoverService`): enforces strict OS path protection, authenticates with Touch ID,
/// terminates helper daemons & unloads LaunchAgents/LaunchDaemons BEFORE removing app bundles
/// (preventing third-party uninstaller popups like TeamViewerUninstaller), unlocks `UF_IMMUTABLE`
/// flags, and escalates cleanly via a single native macOS Touch ID/admin prompt when needed.
public struct SafeCleaner: Sendable {
    public init() {}

    /// Prompts native macOS Touch ID (with password fallback) before performing sensitive actions.
    public func authenticateWithTouchID(reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let context = LAContext()
            var error: NSError?
            let policy: LAPolicy = .deviceOwnerAuthentication
            guard context.canEvaluatePolicy(policy, error: &error) else {
                continuation.resume(returning: true)
                return
            }
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    public func clean(
        paths: [String],
        moveToTrash: Bool,
        knownSizes: [String: UInt64] = [:],
        allowAdminEscalation: Bool = false,
        processKillKeywords: [String] = []
    ) async -> CleanupSummary {
        await Task.detached(priority: .userInitiated) {
            var summary = CleanupSummary()
            let fm = FileManager.default
            var needsAdminPaths: [(path: String, size: UInt64)] = []

            // 1. Stop related user processes & unload user LaunchAgents BEFORE touching the .app bundle
            //    so third-party helper daemons don't trigger popups like TeamViewerUninstaller.
            for keyword in processKillKeywords where keyword.count >= 4 {
                Self.terminateMatchingUserProcesses(keyword: keyword)
            }
            for rawPath in paths where rawPath.contains("/Library/LaunchAgents/") && rawPath.hasSuffix(".plist") {
                Self.unloadLaunchAgent(at: rawPath)
            }

            // 2. If any target is a system daemon, privileged helper, or root-owned /Applications bundle,
            //    handle all privileged paths together in one single Touch ID / admin action.
            for rawPath in paths {
                let url = URL(fileURLWithPath: rawPath).standardizedFileURL
                let path = url.path

                guard !PathSafety.isProtectedPath(path) else {
                    summary.failedCount += 1
                    summary.errors.append("Ruta protegida: \(path)")
                    continue
                }

                // lstat (not fileExists) so dangling symlinks are still removed instead of silently skipped.
                guard Self.entryExists(path) else {
                    continue
                }

                let size = knownSizes[rawPath] ?? knownSizes[path] ?? Self.allocatedSize(of: url)

                // System-wide LaunchDaemons / LaunchAgents / PrivilegedHelperTools require admin unload first
                if allowAdminEscalation && (
                    path.hasPrefix("/Library/LaunchDaemons/")
                    || path.hasPrefix("/Library/LaunchAgents/")
                    || path.hasPrefix("/Library/PrivilegedHelperTools/")
                ) {
                    needsAdminPaths.append((path, size))
                    continue
                }

                Self.clearUserImmutableFlagIfNeeded(at: path)

                if Self.tryDirectDelete(url: url, moveToTrash: moveToTrash, fm: fm) {
                    summary.removedCount += 1
                    summary.reclaimedBytes += size
                    continue
                }

                // Retry after unlocking the whole tree: read-only folders (dotslash, Go module cache,
                // Bazel/Nix outputs) and uchg/uappnd flags make unlink() fail with EACCES/EPERM.
                Self.unlockTree(at: path)
                if Self.tryDirectDelete(url: url, moveToTrash: moveToTrash, fm: fm) {
                    summary.removedCount += 1
                    summary.reclaimedBytes += size
                    continue
                }

                if allowAdminEscalation {
                    needsAdminPaths.append((path, size))
                } else {
                    summary.failedCount += 1
                    summary.errors.append(Self.describeFailure(at: path))
                }
            }

            // 3. Batch all privileged items (and daemons/helpers) into ONE single Touch ID / Admin prompt.
            if !needsAdminPaths.isEmpty {
                let adminResult = Self.removeWithAdminPrompt(
                    paths: needsAdminPaths.map(\.path),
                    moveToTrash: moveToTrash,
                    processKillKeywords: processKillKeywords
                )
                for entry in needsAdminPaths {
                    if !Self.entryExists(entry.path) {
                        summary.removedCount += 1
                        summary.reclaimedBytes += entry.size
                    } else {
                        summary.failedCount += 1
                        let detail = adminResult.error ?? "Permiso denegado"
                        summary.errors.append("\(URL(fileURLWithPath: entry.path).lastPathComponent): \(detail)")
                    }
                }
            }

            return summary
        }.value
    }

    private static func tryDirectDelete(url: URL, moveToTrash: Bool, fm: FileManager) -> Bool {
        do {
            if moveToTrash {
                try fm.trashItem(at: url, resultingItemURL: nil)
            } else {
                try fm.removeItem(at: url)
            }
            return !entryExists(url.path)
        } catch {
            return false
        }
    }

    private static func terminateMatchingUserProcesses(keyword: String) {
        let lower = keyword.lowercased()
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            if app.processIdentifier == selfPID { continue }
            let name = (app.localizedName ?? "").lowercased()
            let bid = (app.bundleIdentifier ?? "").lowercased()
            if name.contains(lower) || bid.contains(lower) {
                app.forceTerminate()
            }
        }
    }

    /// Invokes a single native macOS Administrator authorization sheet (Touch ID / password)
    /// that stops background helpers/daemons first and cleanly moves all items to Trash.
    private static func removeWithAdminPrompt(
        paths: [String],
        moveToTrash: Bool,
        processKillKeywords: [String]
    ) -> (success: Bool, error: String?) {
        let safePaths = paths.filter { !PathSafety.isProtectedPath($0) }
        guard !safePaths.isEmpty else { return (false, "Ruta protegida bloqueada") }

        let trashDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        let uid = getuid()
        let shellEscape: (String) -> String = { s in
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        var commands: [String] = []

        // First bootout any system/user LaunchDaemons & LaunchAgents before deleting the app
        for path in safePaths where path.hasSuffix(".plist") && (path.contains("/LaunchDaemons/") || path.contains("/LaunchAgents/")) {
            let escaped = shellEscape(path)
            commands.append("launchctl bootout system \(escaped) 2>/dev/null || true")
            commands.append("launchctl bootout gui/\(uid) \(escaped) 2>/dev/null || true")
        }

        // Kill any lingering helper/uninstaller daemons matching this app
        for kw in processKillKeywords where kw.count >= 4 {
            let sanitized = kw.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
            if sanitized.count >= 4 {
                commands.append("pkill -9 -i -f \(shellEscape(sanitized)) 2>/dev/null || true")
            }
        }

        // Remove daemons & helpers first, then the .app bundle itself
        let ordered = safePaths.sorted { a, b in
            let aIsApp = a.hasSuffix(".app")
            let bIsApp = b.hasSuffix(".app")
            if aIsApp != bIsApp { return !aIsApp }
            return a < b
        }

        for path in ordered {
            let escapedSrc = shellEscape(path)
            let isDaemonOrHelper = path.hasPrefix("/Library/LaunchDaemons/")
                || path.hasPrefix("/Library/LaunchAgents/")
                || path.hasPrefix("/Library/PrivilegedHelperTools/")

            if moveToTrash && !isDaemonOrHelper {
                let baseName = URL(fileURLWithPath: path).lastPathComponent
                let stamp = Int(Date.now.timeIntervalSince1970)
                let dest = "\(trashDir)/\(baseName)"
                let fallbackDest = "\(trashDir)/\(baseName)-\(stamp)"
                let escapedDest = shellEscape(dest)
                let escapedFallback = shellEscape(fallbackDest)
                commands.append(
                    "chflags -R nouchg \(escapedSrc) 2>/dev/null || true; " +
                    "if [ -e \(escapedDest) ]; then mv \(escapedSrc) \(escapedFallback); else mv \(escapedSrc) \(escapedDest); fi"
                )
            } else {
                commands.append("chflags -R nouchg \(escapedSrc) 2>/dev/null || true; rm -rf \(escapedSrc)")
            }
        }

        let joined = commands.joined(separator: "; ")
        let appleScriptEscaped = joined
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(appleScriptEscaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return (true, nil)
            }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, errMsg?.isEmpty == false ? errMsg : "Autorización cancelada")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Calculates real APFS allocated bytes on disk using zero-allocation POSIX `fts_open`/`fts_read`
    /// (`st_blocks * 512`). Skips symlinks (`FTS_PHYSICAL`), never crosses volume mount boundaries
    /// (`FTS_XDEV`), and skips evicted iCloud dataless files (`SF_DATALESS`) so it never triggers downloads.
    public static func allocatedSize(of url: URL) -> UInt64 {
        let path = url.path
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else { return 0 }

        let datalessFlag: UInt32 = 0x40000000 // SF_DATALESS on macOS APFS
        if (rootStat.st_flags & datalessFlag) != 0 {
            return 0
        }

        let isDir = (rootStat.st_mode & S_IFMT) == S_IFDIR
        if !isDir {
            return UInt64(max(0, rootStat.st_blocks)) * 512
        }

        let cPath = strdup(path)
        guard let cPath else { return 0 }
        defer { free(cPath) }

        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return 0
        }
        defer { fts_close(stream) }

        var total: UInt64 = 0
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_F, let st = entry.pointee.fts_statp {
                if (st.pointee.st_flags & datalessFlag) == 0 {
                    total &+= UInt64(max(0, st.pointee.st_blocks)) * 512
                }
            }
        }
        return total
    }

    private static func clearUserImmutableFlagIfNeeded(at path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if (st.st_flags & UInt32(UF_IMMUTABLE)) != 0 {
            let updated = st.st_flags & ~UInt32(UF_IMMUTABLE)
            _ = chflags(path, updated)
        }
    }

    /// Makes every entry under `path` deletable by the current user: clears user immutable/append-only
    /// flags and adds `u+rwx` to directories the user owns. Walks with `fts` (pre-order) so a folder is
    /// unlocked *before* its children are read, which is what lets read-only (`r-x`/`---`) trees go away.
    static func unlockTree(at path: String) {
        let userFlags = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND)
        let uid = getuid()

        func unlock(_ cPath: UnsafePointer<CChar>, _ st: stat, isDir: Bool) {
            if (st.st_flags & userFlags) != 0 {
                _ = chflags(cPath, st.st_flags & ~userFlags)
            }
            if isDir, st.st_uid == uid, (st.st_mode & S_IRWXU) != S_IRWXU {
                _ = chmod(cPath, (st.st_mode & 0o7777) | S_IRWXU)
            }
        }

        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else { return }
        let rootIsDir = (rootStat.st_mode & S_IFMT) == S_IFDIR
        path.withCString { unlock($0, rootStat, isDir: rootIsDir) }
        guard rootIsDir, let cPath = strdup(path) else { return }
        defer { free(cPath) }

        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(stream) }

        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            guard let entryPath = entry.pointee.fts_path else { continue }
            switch info {
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = entry.pointee.fts_statp?.pointee else { continue }
                unlock(entryPath, st, isDir: info == FTS_D)
            case FTS_DNR:
                // Unreadable folder: unlock it and ask fts to visit it again.
                var st = stat()
                if lstat(entryPath, &st) == 0, st.st_uid == uid, (st.st_mode & S_IRWXU) != S_IRWXU {
                    unlock(entryPath, st, isDir: true)
                    var after = stat()
                    if lstat(entryPath, &after) == 0, (after.st_mode & S_IRWXU) == S_IRWXU {
                        fts_set(stream, entry, FTS_AGAIN)
                    }
                }
            default:
                continue
            }
        }
    }

    static func entryExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Human-readable reason why `path` could not be removed (ownership vs. privacy/TCC vs. generic).
    static func describeFailure(at path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        var st = stat()
        if lstat(path, &st) == 0, st.st_uid != getuid() {
            return "\(name): pertenece a otro usuario (requiere administrador)"
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if access(parent, W_OK) != 0, errno == EPERM {
            return "\(name): macOS bloqueó el acceso (activa Acceso total al disco)"
        }
        return "\(name): sin permiso para borrar"
    }

    private static func unloadLaunchAgent(at path: String) {
        let uid = getuid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(uid)", path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
