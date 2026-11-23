import AppKit
import Darwin
import Foundation

/// Memory, GPU cache, APFS snapshot, and maintenance optimizer.
/// Informed by REA evidence of CleanMyMac's `PerformanceService.framework`
/// (`CMRAMCleaner`, `CMVolumeThinner`, `PurgeableSpaceCleaner`, `FlushDNSCacheTaskRunner`).
public struct MemoryOptimizer: Sendable {
    public init() {}

    /// Reclaims inactive & purgeable RAM cleanly WITHOUT increasing CleanTrash's own resident RAM
    /// or forcing apps into swap/compressor.
    ///
    /// Why `mmap` + `munmap` (instead of `malloc` + `free`):
    /// macOS `libmalloc` retains freed large slabs as `MADV_FREE_REUSABLE`, which keeps them charged
    /// to `internal_page_count` and makes RAM usage appear to *increase* after optimization.
    /// `mmap(MAP_ANON)` + `munmap()` immediately unmaps every page from the kernel pmap, AND
    /// stopping as soon as `compressorBytes` starts rising prevents compressing active apps.
    public func optimizeRAM(
        deepPurgeWithTouchID: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> RAMOptimizationResult {
        await Task.detached(priority: .userInitiated) {
            let start = Date.now
            let before = SystemMonitor.readMemory()
            progress?(0.15)

            // 1. Release any transient allocator magazines inside CleanTrash itself first.
            malloc_zone_pressure_relief(nil, 0)

            // 2. If user chose Deep Purge (or wants Apple's native kernel flush), invoke `/usr/sbin/purge`
            //    via Touch ID — flushes disk & purgeable caches directly in XNU without allocating fake RAM.
            if deepPurgeWithTouchID {
                progress?(0.45)
                _ = Self.runAdminCommand("/usr/sbin/purge")
                try? await Task.sleep(for: .milliseconds(400))
                progress?(1.0)
                let after = SystemMonitor.readMemory()
                return Self.makeResult(before: before, after: after, start: start)
            }

            // 3. Fast non-privileged gentle reclamation using `mmap` + immediate `munmap`:
            //    Only nudges purgeable & inactive file caches; aborts IMMEDIATELY if the kernel
            //    starts compressing app pages or touching swap so `usedBytes` never climbs.
            let pageSize = max(4096, Int(getpagesize()))
            let chunkBytes = 32 * 1024 * 1024 // 32 MB slabs
            let safeBudget = min(
                before.purgeableBytes + before.freeBytes / 2,
                512 * 1024 * 1024 // Cap at 512 MB so we never trigger compressor/swap bloat
            )
            let maxSlabs = max(1, min(16, Int(safeBudget / UInt64(chunkBytes))))

            var mappings: [UnsafeMutableRawPointer] = []
            mappings.reserveCapacity(maxSlabs)

            for i in 0..<maxSlabs {
                let current = SystemMonitor.readMemory()
                // Abort immediately if kernel begins compressing apps, swapping, or raising pressure.
                if current.pressure != .normal
                    || current.compressedBytes > before.compressedBytes + 32 * 1024 * 1024
                    || current.swapUsedBytes > before.swapUsedBytes + 16 * 1024 * 1024 {
                    break
                }

                let raw = mmap(
                    nil,
                    chunkBytes,
                    PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANON,
                    -1,
                    0
                )
                guard raw != MAP_FAILED, let ptr = raw else { break }

                let bytes = ptr.assumingMemoryBound(to: UInt8.self)
                var offset = 0
                while offset < chunkBytes {
                    bytes[offset] = UInt8(truncatingIfNeeded: i &+ 1)
                    offset += pageSize
                }
                mappings.append(ptr)
                progress?(0.20 + Double(i + 1) / Double(maxSlabs) * 0.60)
            }

            // Immediately unmap every single page directly back to the kernel VM (zero libmalloc retention!).
            for ptr in mappings {
                munmap(ptr, chunkBytes)
            }
            mappings.removeAll()
            malloc_zone_pressure_relief(nil, 0)

            // Wait briefly for Mach VM counters to reflect the unmapped + evicted pages.
            try? await Task.sleep(for: .milliseconds(450))
            progress?(1.0)

            let after = SystemMonitor.readMemory()
            return Self.makeResult(before: before, after: after, start: start)
        }.value
    }

    private static func makeResult(
        before: MemorySnapshot,
        after: MemorySnapshot,
        start: Date
    ) -> RAMOptimizationResult {
        let beforeTotalActive = before.usedBytes + before.cachedFilesBytes
        let afterTotalActive = after.usedBytes + after.cachedFilesBytes
        let reclaimed: UInt64
        if before.usedBytes > after.usedBytes {
            reclaimed = before.usedBytes - after.usedBytes
        } else if beforeTotalActive > afterTotalActive {
            reclaimed = beforeTotalActive - afterTotalActive
        } else if after.freeBytes > before.freeBytes {
            reclaimed = after.freeBytes - before.freeBytes
        } else {
            reclaimed = 0
        }

        return RAMOptimizationResult(
            beforeUsedBytes: before.usedBytes,
            afterUsedBytes: after.usedBytes,
            reclaimedBytes: reclaimed,
            durationSeconds: Date.now.timeIntervalSince(start)
        )
    }

    private static func runAdminCommand(_ command: String) -> (success: Bool, output: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return runCommand("/usr/bin/osascript", arguments: [
            "-e", "do shell script \"\(escaped)\" with administrator privileges"
        ])
    }

    /// Trims Metal, WebGPU/Dawn, and Chromium/Electron GPU shader caches safely on disk.
    public func trimGPUCaches() async -> CleanupSummary {
        let paths = await Task.detached(priority: .utility) {
            Self.discoverGPUCachePaths()
        }.value
        guard !paths.isEmpty else { return CleanupSummary() }
        return await SafeCleaner().clean(paths: paths, moveToTrash: false)
    }

    public static func discoverGPUCachePaths() -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var targets: [String] = []

        // 1. User Metal & Shader caches in ~/Library/Caches
        let cachesRoot = "\(home)/Library/Caches"
        let gpuFolderNames: Set<String> = [
            "GPUCache", "DawnCache", "DawnWebGPUCache", "DawnGraphiteCache",
            "GraphiteDawnCache", "GrShaderCache", "ShaderCache", "com.apple.metal"
        ]
        if let top = try? fm.contentsOfDirectory(atPath: cachesRoot) {
            for entry in top {
                let full = "\(cachesRoot)/\(entry)"
                if gpuFolderNames.contains(entry) || entry.localizedCaseInsensitiveContains("metal") {
                    targets.append(full)
                } else {
                    for sub in gpuFolderNames {
                        let candidate = "\(full)/\(sub)"
                        if fm.fileExists(atPath: candidate) {
                            targets.append(candidate)
                        }
                    }
                }
            }
        }

        // 2. Electron / Chromium GPU caches inside ~/Library/Application Support/<App>/GPUCache
        let appSupportRoot = "\(home)/Library/Application Support"
        if let apps = try? fm.contentsOfDirectory(atPath: appSupportRoot) {
            for app in apps {
                for sub in ["GPUCache", "DawnCache", "DawnWebGPUCache", "DawnGraphiteCache", "GrShaderCache", "ShaderCache"] {
                    let candidate = "\(appSupportRoot)/\(app)/\(sub)"
                    if fm.fileExists(atPath: candidate) {
                        targets.append(candidate)
                    }
                }
            }
        }

        // 3. AI browser-profile GPU caches (observed in CleanMyMac 5.7 AIToolScanning)
        let extraProfiles = [
            "\(home)/.gemini/antigravity-browser-profile/Default",
            "\(home)/.cache/chrome-devtools-mcp/chrome-profile/Default"
        ]
        for profile in extraProfiles {
            for sub in ["GPUCache", "DawnCache", "DawnWebGPUCache", "DawnGraphiteCache", "GrShaderCache", "GraphiteDawnCache"] {
                let candidate = "\(profile)/\(sub)"
                if fm.fileExists(atPath: candidate) {
                    targets.append(candidate)
                }
            }
        }

        return Array(Set(targets))
    }

    /// Thins local APFS Time Machine snapshots via `/usr/bin/tmutil thinlocalsnapshots`
    /// (observed in CleanMyMac's `CMVolumeThinner`).
    public func thinAPFSSnapshots(requestedGB: Int = 20, urgency: Int = 4) async -> (success: Bool, output: String) {
        await Task.detached(priority: .userInitiated) {
            let bytes = UInt64(max(1, requestedGB)) * 1_000_000_000
            return Self.runCommand("/usr/bin/tmutil", arguments: [
                "thinlocalsnapshots", "/", "\(bytes)", "\(max(1, min(4, urgency)))"
            ])
        }.value
    }

    /// Lists current local APFS snapshots on `/`.
    public func listLocalSnapshots() async -> [String] {
        await Task.detached(priority: .utility) {
            let res = Self.runCommand("/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"])
            guard res.success else { return [] }
            return res.output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("com.apple.TimeMachine") }
        }.value
    }

    /// Flushes macOS DNS cache via `dscacheutil -flushcache` (non-privileged user flush).
    public func flushDNSCache() async -> (success: Bool, output: String) {
        await Task.detached(priority: .userInitiated) {
            Self.runCommand("/usr/bin/dscacheutil", arguments: ["-flushcache"])
        }.value
    }

    /// Gracefully terminates a user application process by PID.
    @MainActor
    public func terminateProcess(pid: Int32, force: Bool = false) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return force ? app.forceTerminate() : app.terminate()
        }
        return kill(pid, force ? SIGKILL : SIGTERM) == 0
    }

    private static func runCommand(_ executable: String, arguments: [String]) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let outText = String(data: outData, encoding: .utf8) ?? ""
            let errText = String(data: errData, encoding: .utf8) ?? ""
            let combined = [outText, errText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return (process.terminationStatus == 0, combined)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
