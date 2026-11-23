import Darwin
import Foundation

/// Scans macOS system & application junk categories grounded in our REA inspection of
/// CleanMyMac's `SystemJunkScanning.framework` and `TrashJunkScanning.framework`:
/// - `~/Library/Caches` & Darwin User Caches (`confstr(_CS_DARWIN_USER_CACHE_DIR)`)
/// - Sandboxed Container Caches (`~/Library/Containers/*/Data/Library/Caches`)
/// - Electron/Chromium App Caches (`Cache`, `Cache_Data`, `Code Cache`, `GPUCache`, `Service Worker/CacheStorage`)
/// - User Logs & Diagnostic Reports (`~/Library/Logs`, `~/Library/Logs/DiagnosticReports`)
/// - Xcode & Simulator Junk (`DerivedData`, `iOS DeviceSupport`, `CoreSimulator/Caches`)
/// - Broken Preferences (corrupted `.plist` files failing `PropertyListSerialization`)
/// - Broken LaunchAgents (plists in `~/Library/LaunchAgents` whose executable no longer exists)
/// - User Trash (`~/.Trash`)
/// - Old Installers (`.dmg`, `.pkg` in `~/Downloads` older than 14 days)
public struct SystemJunkScanner: Sendable {
    public init() {}

    public func scan() async -> [JunkItem] {
        await Task.detached(priority: .userInitiated) {
            var results: [JunkItem] = []
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser.path

            // 1. User Caches (~/Library/Caches)
            results.append(contentsOf: Self.scanDirectoryChildren(
                at: "\(home)/Library/Caches",
                category: .userCaches,
                reason: "Application cache",
                minBytes: 1_000_000,
                skipNames: ["CloudKit", "com.apple.nsurlsessiond", "com.apple.bird", "com.apple.HomeKit"]
            ))

            // 2. Darwin User Cache Dir (confstr _CS_DARWIN_USER_CACHE_DIR)
            if let darwinCache = Self.darwinUserCacheDir() {
                results.append(contentsOf: Self.scanDirectoryChildren(
                    at: darwinCache,
                    category: .userCaches,
                    reason: "Darwin temporary user cache",
                    minBytes: 2_000_000,
                    skipNames: ["com.apple.iconservices", "com.apple.metal"]
                ))
            }

            // 3. Sandboxed Container Caches
            let containersRoot = "\(home)/Library/Containers"
            if let containers = try? fm.contentsOfDirectory(atPath: containersRoot) {
                for bundle in containers {
                    let cacheDir = "\(containersRoot)/\(bundle)/Data/Library/Caches"
                    guard fm.fileExists(atPath: cacheDir) else { continue }
                    let size = SafeCleaner.allocatedSize(of: URL(fileURLWithPath: cacheDir))
                    if size >= 2_000_000 {
                        results.append(JunkItem(
                            name: "\(bundle) Cache",
                            path: cacheDir,
                            category: .containerCaches,
                            sizeBytes: size,
                            reason: "Sandboxed app container cache"
                        ))
                    }
                }
            }

            // 4. Electron & Browser Engine Caches inside ~/Library/Application Support
            let appSupportRoot = "\(home)/Library/Application Support"
            let electronSubdirs = ["Cache", "Cache_Data", "Code Cache", "GPUCache", "DawnCache", "DawnWebGPUCache", "GraphiteDawnCache", "GrShaderCache", "Crashpad/completed"]
            if let apps = try? fm.contentsOfDirectory(atPath: appSupportRoot) {
                for app in apps {
                    for sub in electronSubdirs {
                        let candidate = "\(appSupportRoot)/\(app)/\(sub)"
                        guard fm.fileExists(atPath: candidate) else { continue }
                        let size = SafeCleaner.allocatedSize(of: URL(fileURLWithPath: candidate))
                        if size >= 2_000_000 {
                            results.append(JunkItem(
                                name: "\(app) — \(sub)",
                                path: candidate,
                                category: .electronCaches,
                                sizeBytes: size,
                                reason: "Chromium / Electron runtime cache"
                            ))
                        }
                    }
                }
            }

            // 5. Logs & Crash Reports
            results.append(contentsOf: Self.scanDirectoryChildren(
                at: "\(home)/Library/Logs",
                category: .logs,
                reason: "Application log files",
                minBytes: 500_000,
                skipNames: []
            ))

            // 6. Xcode & Simulators
            let xcodeTargets: [(String, String, String)] = [
                ("Xcode DerivedData", "\(home)/Library/Developer/Xcode/DerivedData", "Compiled Xcode intermediates"),
                ("Xcode DeviceSupport", "\(home)/Library/Developer/Xcode/iOS DeviceSupport", "Old iOS debug symbols"),
                ("CoreSimulator Caches", "\(home)/Library/Developer/CoreSimulator/Caches", "Simulator runtime caches"),
                ("Xcode Previews Cache", "\(home)/Library/Developer/Xcode/UserData/Previews", "SwiftUI Previews cache")
            ]
            for (name, path, reason) in xcodeTargets {
                guard fm.fileExists(atPath: path) else { continue }
                let size = SafeCleaner.allocatedSize(of: URL(fileURLWithPath: path))
                if size >= 5_000_000 {
                    results.append(JunkItem(
                        name: name,
                        path: path,
                        category: .xcodeAndSimulators,
                        sizeBytes: size,
                        reason: reason
                    ))
                }
            }

            // 7. Broken Preferences (corrupted plists in ~/Library/Preferences)
            results.append(contentsOf: Self.scanBrokenPreferences(at: "\(home)/Library/Preferences"))

            // 8. Broken LaunchAgents (plists pointing to nonexistent binaries)
            results.append(contentsOf: Self.scanBrokenLaunchAgents(at: "\(home)/Library/LaunchAgents"))

            // 9. User Trash (~/.Trash)
            results.append(contentsOf: Self.scanDirectoryChildren(
                at: "\(home)/.Trash",
                category: .trash,
                reason: "Item sitting in Trash",
                minBytes: 1,
                skipNames: [".DS_Store"]
            ))

            // 10. Old Installers (.dmg / .pkg in ~/Downloads older than 14 days)
            results.append(contentsOf: Self.scanOldInstallers(at: "\(home)/Downloads", olderThanDays: 14))

            return results.sorted { $0.sizeBytes > $1.sizeBytes }
        }.value
    }

    private static func scanDirectoryChildren(
        at rootPath: String,
        category: JunkCategory,
        reason: String,
        minBytes: UInt64,
        skipNames: Set<String>
    ) -> [JunkItem] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath)
        guard let children = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return [] }

        var items: [JunkItem] = []
        for child in children {
            let name = child.lastPathComponent
            if skipNames.contains(name) { continue }
            if PathSafety.isProtectedPath(child.path) { continue }
            let size = SafeCleaner.allocatedSize(of: child)
            guard size >= minBytes else { continue }
            let mtime = (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            items.append(JunkItem(
                name: name,
                path: child.path,
                category: category,
                sizeBytes: size,
                reason: reason,
                lastModified: mtime
            ))
        }
        return items
    }

    public static func scanBrokenPreferences(at prefsPath: String) -> [JunkItem] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: prefsPath)
        guard let files = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) else { return [] }

        var broken: [JunkItem] = []
        for file in files where file.pathExtension == "plist" {
            guard let vals = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  vals.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: file) else { continue }
            if data.isEmpty {
                broken.append(JunkItem(
                    name: file.lastPathComponent,
                    path: file.path,
                    category: .brokenConfigs,
                    sizeBytes: UInt64(vals.fileSize ?? 0),
                    reason: "Empty corrupted preference plist",
                    lastModified: vals.contentModificationDate ?? .distantPast
                ))
                continue
            }
            do {
                _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            } catch {
                broken.append(JunkItem(
                    name: file.lastPathComponent,
                    path: file.path,
                    category: .brokenConfigs,
                    sizeBytes: UInt64(max(data.count, vals.fileSize ?? 0)),
                    reason: "Malformed preference plist",
                    lastModified: vals.contentModificationDate ?? .distantPast
                ))
            }
        }
        return broken
    }

    public static func scanBrokenLaunchAgents(at agentsPath: String) -> [JunkItem] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: agentsPath)
        guard let files = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) else { return [] }

        var broken: [JunkItem] = []
        for file in files where file.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: file),
                  let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                continue
            }

            let executable: String?
            if let prog = dict["Program"] as? String {
                executable = prog
            } else if let args = dict["ProgramArguments"] as? [String], let first = args.first {
                executable = first
            } else {
                executable = nil
            }

            if let executable, executable.hasPrefix("/"), !fm.fileExists(atPath: executable) {
                let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                broken.append(JunkItem(
                    name: file.lastPathComponent,
                    path: file.path,
                    category: .brokenConfigs,
                    sizeBytes: UInt64(vals?.fileSize ?? data.count),
                    reason: "LaunchAgent target missing: \(URL(fileURLWithPath: executable).lastPathComponent)",
                    lastModified: vals?.contentModificationDate ?? .distantPast
                ))
            }
        }
        return broken
    }

    private static func scanOldInstallers(at downloadsPath: String, olderThanDays: Int) -> [JunkItem] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: downloadsPath)
        guard let files = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: []
        ) else { return [] }

        let cutoff = Date.now.addingTimeInterval(-Double(olderThanDays) * 86_400)
        var items: [JunkItem] = []

        for file in files {
            let ext = file.pathExtension.lowercased()
            guard ext == "dmg" || ext == "pkg" || ext == "iso" else { continue }
            guard let vals = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  vals.isRegularFile == true else { continue }
            let mtime = vals.contentModificationDate ?? .distantPast
            guard mtime < cutoff else { continue }
            let size = SafeCleaner.allocatedSize(of: file)
            guard size > 0 else { continue }

            items.append(JunkItem(
                name: file.lastPathComponent,
                path: file.path,
                category: .installers,
                sizeBytes: size,
                reason: "Installer untouched for \(Int(Date.now.timeIntervalSince(mtime) / 86_400))d",
                lastModified: mtime,
                selected: false // Let user confirm installers explicitly
            ))
        }
        return items
    }

    private static func darwinUserCacheDir() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        guard len > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
