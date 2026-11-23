import Darwin
import Foundation

/// Result of emptying the Trash, reported honestly: what was really removed, what is still there and why.
public struct TrashEmptyResult: Sendable, Equatable {
    public var removedCount = 0
    public var remainingCount = 0
    public var freedBytes: UInt64 = 0
    public var errors: [String] = []
    /// `~/.Trash` could not be listed (no Full Disk Access), so CleanTrash had to rely on Finder.
    public var accessDenied = false
    public var usedFinder = false
    public var finderError: String?

    public init() {}

    public var isComplete: Bool { remainingCount == 0 && finderError == nil }
}

/// Snapshot of what is currently sitting in the Trash.
public struct TrashContents: Sendable, Equatable {
    public var itemCount = 0
    public var totalBytes: UInt64 = 0
    public var readable = true

    public init() {}
}

/// Empties every Trash the user owns (`~/.Trash` and `/Volumes/*/.Trashes/<uid>`):
/// 1. Deletes each entry directly, unlocking read-only folders and `uchg` flags first (fast, no prompts).
/// 2. Anything still left (root-owned items, missing Full Disk Access) goes through Finder's own
///    `empty trash`, which handles locked and privileged items and asks for a password itself.
/// 3. Re-checks the folders so the reported freed bytes and leftovers are real, not assumed.
public struct TrashEmptier: Sendable {
    public let trashFolders: [String]
    public let allowFinderFallback: Bool

    public init(trashFolders: [String] = TrashEmptier.defaultTrashFolders(), allowFinderFallback: Bool = true) {
        self.trashFolders = trashFolders
        self.allowFinderFallback = allowFinderFallback
    }

    public static func defaultTrashFolders() -> [String] {
        let fm = FileManager.default
        var folders = [fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path]
        let uid = getuid()
        if let volumes = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            for volume in volumes {
                let candidate = "/Volumes/\(volume)/.Trashes/\(uid)"
                var st = stat()
                if lstat(candidate, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                    folders.append(candidate)
                }
            }
        }
        return folders
    }

    /// Measures the Trash without modifying it.
    public func contents() async -> TrashContents {
        await Task.detached(priority: .utility) { [trashFolders] in
            var result = TrashContents()
            for folder in trashFolders {
                guard let entries = Self.listEntries(folder) else {
                    if folder == trashFolders.first { result.readable = false }
                    continue
                }
                result.itemCount += entries.count
                for entry in entries {
                    result.totalBytes += SafeCleaner.allocatedSize(of: URL(fileURLWithPath: entry))
                }
            }
            return result
        }.value
    }

    public func empty() async -> TrashEmptyResult {
        await Task.detached(priority: .userInitiated) { [trashFolders, allowFinderFallback] in
            var result = TrashEmptyResult()
            var sizes: [String: UInt64] = [:]
            var pending: [String] = []

            // 1. Direct removal with permission repair.
            for folder in trashFolders {
                guard let entries = Self.listEntries(folder) else {
                    if folder == trashFolders.first { result.accessDenied = true }
                    continue
                }
                for entry in entries {
                    let size = SafeCleaner.allocatedSize(of: URL(fileURLWithPath: entry))
                    sizes[entry] = size
                    if Self.forceRemove(entry) {
                        result.removedCount += 1
                        result.freedBytes += size
                    } else {
                        pending.append(entry)
                    }
                }
            }

            // 2. Finder fallback for what we could not touch (or could not even see).
            if allowFinderFallback, !pending.isEmpty || result.accessDenied {
                let statsBefore = Self.availableBytes()
                result.usedFinder = true
                result.finderError = Self.finderEmptyTrash()

                var stillThere: [String] = []
                for entry in pending {
                    if SafeCleaner.entryExists(entry) {
                        stillThere.append(entry)
                    } else {
                        result.removedCount += 1
                        result.freedBytes += sizes[entry] ?? 0
                    }
                }
                pending = stillThere

                // Without Full Disk Access we cannot size items up front: use the volume delta instead.
                if result.accessDenied, let before = statsBefore, let after = Self.availableBytes(), after > before {
                    result.freedBytes += after - before
                }
            }

            // 3. Honest leftovers.
            result.remainingCount = pending.count
            result.errors = pending.prefix(5).map { SafeCleaner.describeFailure(at: $0) }
            if result.accessDenied, result.finderError != nil {
                result.errors.insert("Sin Acceso total al disco no se puede leer la Papelera", at: 0)
            }
            return result
        }.value
    }

    // MARK: - Helpers

    /// Returns nil when the folder cannot be listed (TCC / permissions), [] when it is empty.
    static func listEntries(_ folder: String) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            return SafeCleaner.entryExists(folder) ? nil : []
        }
        return names
            .filter { $0 != ".DS_Store" && $0 != ".localized" }
            .map { "\(folder)/\($0)" }
    }

    static func forceRemove(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if (try? FileManager.default.removeItem(at: url)) != nil, !SafeCleaner.entryExists(path) {
            return true
        }
        SafeCleaner.unlockTree(at: path)
        if (try? FileManager.default.removeItem(at: url)) != nil {
            return !SafeCleaner.entryExists(path)
        }
        return !SafeCleaner.entryExists(path)
    }

    static func availableBytes() -> UInt64? {
        var fs = statfs()
        guard statfs(NSHomeDirectory(), &fs) == 0 else { return nil }
        return UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
    }

    /// Asks Finder to empty the Trash. Returns nil on success or a readable error.
    static func finderEmptyTrash() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus != 0 else { return nil }
        let message = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if message.contains("-1743") {
            return "Permite a CleanTrash controlar Finder en Ajustes › Privacidad › Automatización"
        }
        if message.contains("-128") {
            return "Cancelado"
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Finder no pudo vaciar la Papelera"
            : message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
