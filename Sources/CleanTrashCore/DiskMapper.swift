import Darwin
import Foundation

/// High-speed parallel APFS disk space mapper informed by our REA inspection of
/// CleanMyMac's `SpaceLensScanning.framework`:
/// - Uses real physical APFS block size (`totalFileAllocatedSizeKey`)
/// - Skips evicted iCloud Drive files (`ubiquitousItemDownloadingStatus == .notDownloaded`)
/// - Respects mount boundaries (`isVolumeKey`) to avoid double-counting firmlinks or external drives
/// - Deduplicates hardlinks via `(st_dev, st_ino)`
/// - Tags potentially cleanable directories/files right inside the visual tree
public struct DiskMapper: Sendable {
    public init() {}

    public func mapDirectory(
        at rootPath: String,
        maxTreeDepth: Int = 4,
        onProgress: (@Sendable (String, UInt64) -> Void)? = nil
    ) async -> DiskNode {
        await Task.detached(priority: .userInitiated) {
            let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
            let seenInodes = LockedInodeSet()
            return await Self.scanNode(
                url: rootURL,
                depth: 0,
                maxTreeDepth: maxTreeDepth,
                isRoot: true,
                seenInodes: seenInodes,
                onProgress: onProgress
            )
        }.value
    }

    private static func scanNode(
        url: URL,
        depth: Int,
        maxTreeDepth: Int,
        isRoot: Bool,
        seenInodes: LockedInodeSet,
        onProgress: (@Sendable (String, UInt64) -> Void)?
    ) async -> DiskNode {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isVolumeKey,
            .isPackageKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]

        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return DiskNode(
                name: url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent,
                path: url.path,
                isDirectory: true,
                sizeBytes: 0,
                fileCount: 0,
                category: classify(path: url.path, isDirectory: true)
            )
        }

        // Parallelize top-level directory subtrees for blistering Apple Silicon throughput.
        if depth <= 1 {
            let children = await withTaskGroup(of: DiskNode?.self) { group in
                for entry in entries {
                    group.addTask {
                        await Self.processEntry(
                            entry,
                            depth: depth + 1,
                            maxTreeDepth: maxTreeDepth,
                            keys: keys,
                            seenInodes: seenInodes,
                            onProgress: onProgress
                        )
                    }
                }
                var collected: [DiskNode] = []
                for await node in group {
                    if let node, node.sizeBytes > 0 {
                        collected.append(node)
                    }
                }
                return collected.sorted { $0.sizeBytes > $1.sizeBytes }
            }

            let totalBytes = children.reduce(0) { $0 + $1.sizeBytes }
            let totalFiles = children.reduce(0) { $0 + $1.fileCount }
            let hint = cleanableHint(for: url.path, size: totalBytes)
            onProgress?(url.lastPathComponent, totalBytes)

            return DiskNode(
                name: isRoot ? (url.path == NSHomeDirectory() ? "Home" : url.lastPathComponent) : url.lastPathComponent,
                path: url.path,
                isDirectory: true,
                sizeBytes: totalBytes,
                fileCount: totalFiles,
                category: classify(path: url.path, isDirectory: true),
                isCleanableCandidate: hint != nil,
                cleanableHint: hint,
                children: Array(children.prefix(64))
            )
        } else {
            var children: [DiskNode] = []
            var totalBytes: UInt64 = 0
            var totalFiles = 0

            for entry in entries {
                if let node = await Self.processEntry(
                    entry,
                    depth: depth + 1,
                    maxTreeDepth: maxTreeDepth,
                    keys: keys,
                    seenInodes: seenInodes,
                    onProgress: nil
                ) {
                    totalBytes += node.sizeBytes
                    totalFiles += node.fileCount
                    if depth < maxTreeDepth && node.sizeBytes >= 1_000_000 {
                        children.append(node)
                    }
                }
            }

            children.sort { $0.sizeBytes > $1.sizeBytes }
            let hint = cleanableHint(for: url.path, size: totalBytes)
            return DiskNode(
                name: url.lastPathComponent,
                path: url.path,
                isDirectory: true,
                sizeBytes: totalBytes,
                fileCount: totalFiles,
                category: classify(path: url.path, isDirectory: true),
                isCleanableCandidate: hint != nil,
                cleanableHint: hint,
                children: depth < maxTreeDepth ? Array(children.prefix(40)) : []
            )
        }
    }

    private static func processEntry(
        _ entry: URL,
        depth: Int,
        maxTreeDepth: Int,
        keys: Set<URLResourceKey>,
        seenInodes: LockedInodeSet,
        onProgress: (@Sendable (String, UInt64) -> Void)?
    ) async -> DiskNode? {
        guard let values = try? entry.resourceValues(forKeys: keys) else { return nil }
        if values.isSymbolicLink == true { return nil }
        // Never cross volume/mount boundaries (prevents double-counting firmlinks or external disks).
        if values.isVolume == true { return nil }
        // Skip evicted iCloud Drive placeholders so we never trigger downloads.
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
            return nil
        }

        if values.isDirectory == true {
            // Treat `.app` bundles as atomic leaves so disk maps stay clean & fast.
            if entry.pathExtension == "app" || depth >= maxTreeDepth {
                let (bytes, files) = fastSubtreeSize(at: entry, seenInodes: seenInodes)
                guard bytes > 0 else { return nil }
                let hint = cleanableHint(for: entry.path, size: bytes)
                return DiskNode(
                    name: entry.lastPathComponent,
                    path: entry.path,
                    isDirectory: true,
                    sizeBytes: bytes,
                    fileCount: files,
                    category: classify(path: entry.path, isDirectory: true),
                    isCleanableCandidate: hint != nil,
                    cleanableHint: hint
                )
            }
            return await scanNode(
                url: entry,
                depth: depth,
                maxTreeDepth: maxTreeDepth,
                isRoot: false,
                seenInodes: seenInodes,
                onProgress: onProgress
            )
        } else {
            var st = stat()
            if lstat(entry.path, &st) == 0, st.st_nlink > 1 {
                if !seenInodes.insert(dev: st.st_dev, ino: st.st_ino) {
                    return nil
                }
            }
            let bytes = UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            guard bytes > 0 else { return nil }
            let hint = cleanableHint(for: entry.path, size: bytes)
            return DiskNode(
                name: entry.lastPathComponent,
                path: entry.path,
                isDirectory: false,
                sizeBytes: bytes,
                fileCount: 1,
                category: classify(path: entry.path, isDirectory: false),
                isCleanableCandidate: hint != nil,
                cleanableHint: hint
            )
        }
    }

    private static func fastSubtreeSize(at url: URL, seenInodes: LockedInodeSet) -> (UInt64, Int) {
        let cPath = strdup(url.path)
        guard let cPath else { return (0, 0) }
        defer { free(cPath) }

        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return (0, 0)
        }
        defer { fts_close(stream) }

        let datalessFlag: UInt32 = 0x40000000 // SF_DATALESS
        var total: UInt64 = 0
        var count = 0

        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_F, let st = entry.pointee.fts_statp {
                if (st.pointee.st_flags & datalessFlag) != 0 { continue }
                if st.pointee.st_nlink > 1 {
                    if !seenInodes.insert(dev: st.pointee.st_dev, ino: st.pointee.st_ino) {
                        continue
                    }
                }
                total &+= UInt64(max(0, st.pointee.st_blocks)) * 512
                count += 1
            }
        }
        return (total, count)
    }

    public static func classify(path: String, isDirectory: Bool) -> DiskCategory {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()

        if name == "target" || name == "node_modules" || name == ".build" || name == ".next"
            || name == "DerivedData" || name == ".cargo" || name == ".gradle" || name == ".bun"
            || name == ".npm" || path.contains("/Developer/Xcode/") {
            return .devBuilds
        }
        if ext == "app" || path.hasPrefix("/Applications") || path.contains("/Applications/") {
            return .applications
        }
        if name == "Caches" || name == "Logs" || name == "GPUCache" || name == "Code Cache"
            || path.contains("/Library/Caches") || path.contains("/Library/Logs") || path.contains("/.Trash") {
            return .cachesAndLogs
        }
        if ["dmg", "pkg", "iso", "zip", "tar", "gz", "xz", "7z", "rar"].contains(ext) {
            return .archives
        }
        if ["mp4", "mov", "mkv", "avi", "mp3", "wav", "flac", "png", "jpg", "jpeg", "heic", "webp", "raw", "psd"].contains(ext)
            || name == "Movies" || name == "Pictures" || name == "Music" {
            return .media
        }
        if path.contains("/Library/") || name == "Library" {
            return .library
        }
        if !isDirectory && ["pdf", "doc", "docx", "pages", "key", "numbers", "md", "txt", "csv", "xlsx"].contains(ext) {
            return .documents
        }
        return .other
    }

    public static func cleanableHint(for path: String, size: UInt64) -> String? {
        guard size >= 10_000_000 else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()

        if name == "target" { return "Rust Cargo build cache" }
        if name == "node_modules" { return "Reinstallable Node dependencies" }
        if name == ".build" || name == "DerivedData" { return "Swift / Xcode build intermediates" }
        if name == ".next" || name == ".turbo" || name == ".vite" { return "Frontend build cache" }
        if name == "Caches" || name == "GPUCache" || name == "Code Cache" || path.contains("/Library/Caches/") {
            return "Regenerable app cache"
        }
        if name == "Logs" || path.contains("/Library/Logs/") { return "Historical logs" }
        if path.contains("/.Trash/") { return "Trash item" }
        if ["dmg", "pkg", "iso"].contains(ext) { return "Disk image / installer" }
        return nil
    }
}

private final class LockedInodeSet: @unchecked Sendable {
    private struct Key: Hashable {
        let dev: dev_t
        let ino: ino_t
    }
    private let lock = NSLock()
    private var seen = Set<Key>()

    func insert(dev: dev_t, ino: ino_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(Key(dev: dev, ino: ino)).inserted
    }
}
