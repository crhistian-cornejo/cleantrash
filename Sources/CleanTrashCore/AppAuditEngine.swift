import AppKit
import CoreServices
import Foundation

/// Audits installed macOS applications, detects unused software via Spotlight `kMDItemLastUsedDate`,
/// tracks user Keep/Snooze decisions, maps all 10 associated Library artifact locations (grounded in
/// CleanMyMac's `UninstallerScanning.framework`), and discovers orphaned Library leftovers.
public struct AppAuditEngine: Sendable {
    private let decisionsURL: URL

    public init(decisionsURL: URL? = nil) {
        if let decisionsURL {
            self.decisionsURL = decisionsURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.decisionsURL = support.appendingPathComponent("CleanTrash/app-decisions.json")
        }
    }

    public func loadDecisions() -> [String: AppDecisionRecord] {
        guard let data = try? Data(contentsOf: decisionsURL),
              let records = try? JSONDecoder().decode([AppDecisionRecord].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.bundleID, $0) })
    }

    public func saveDecision(_ record: AppDecisionRecord) {
        var map = loadDecisions()
        map[record.bundleID] = record
        let list = Array(map.values)
        try? FileManager.default.createDirectory(at: decisionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: decisionsURL, options: .atomic)
        }
    }

    public func scanApplications() async -> (apps: [InstalledAppInfo], leftovers: [OrphanLeftover]) {
        let decisions = loadDecisions()
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser.path
            let searchDirs = ["/Applications", "\(home)/Applications"]

            var appURLs: [URL] = []
            for dir in searchDirs {
                guard let entries = try? fm.contentsOfDirectory(
                    at: URL(fileURLWithPath: dir),
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for entry in entries {
                    if entry.pathExtension == "app" {
                        appURLs.append(entry)
                    } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        // One level deeper for vendor subfolders like /Applications/Utilities or JetBrains
                        if let nested = try? fm.contentsOfDirectory(
                            at: entry,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        ) {
                            appURLs.append(contentsOf: nested.filter { $0.pathExtension == "app" })
                        }
                    }
                }
            }

            // Pre-index user Library directories once for fast O(1)/O(n) matching per app.
            let libraryIndex = LibraryDirectoryIndex(home: home)

            // Bounded concurrency (4 workers) prevents CPU/RAM spikes when sizing large bundles like Xcode.app
            let apps = await withTaskGroup(of: InstalledAppInfo?.self) { group in
                let maxConcurrent = 4
                var nextIdx = 0
                var collected: [InstalledAppInfo] = []

                func enqueueNext() {
                    guard nextIdx < appURLs.count else { return }
                    let appURL = appURLs[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        Self.inspectApp(
                            at: appURL,
                            runningBundleIDs: runningBundleIDs,
                            decisions: decisions,
                            libraryIndex: libraryIndex
                        )
                    }
                }

                for _ in 0..<min(maxConcurrent, appURLs.count) {
                    enqueueNext()
                }
                for await app in group {
                    if let app { collected.append(app) }
                    enqueueNext()
                }
                return collected
            }

            let installedBundleIDs = Set(apps.map { $0.bundleID.lowercased() })
            let installedNames = Set(apps.map { $0.name.lowercased() })
            let leftovers = Self.scanOrphanLeftovers(
                libraryIndex: libraryIndex,
                installedBundleIDs: installedBundleIDs,
                installedNames: installedNames
            )

            return (
                apps.sorted { $0.totalSizeBytes > $1.totalSizeBytes },
                leftovers.sorted { $0.sizeBytes > $1.sizeBytes }
            )
        }.value
    }

    private static func inspectApp(
        at url: URL,
        runningBundleIDs: Set<String>,
        decisions: [String: AppDecisionRecord],
        libraryIndex: LibraryDirectoryIndex
    ) -> InstalledAppInfo? {
        guard let bundle = Bundle(url: url) else { return nil }
        let bundleID = bundle.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "—"

        let isAppleSystem = bundleID.hasPrefix("com.apple.") || url.path.hasPrefix("/System/")
        let lastUsed = spotlightLastUsedDate(for: url)
        let bundleSize = SafeCleaner.allocatedSize(of: url)
        let related = libraryIndex.findRelatedFiles(bundleID: bundleID, appName: name)

        return InstalledAppInfo(
            name: name,
            bundleID: bundleID,
            version: version,
            appPath: url.path,
            bundleSizeBytes: bundleSize,
            relatedFiles: related,
            lastUsedDate: lastUsed,
            isRunning: runningBundleIDs.contains(bundleID),
            isAppleSystemApp: isAppleSystem,
            decision: decisions[bundleID]
        )
    }

    private static func spotlightLastUsedDate(for url: URL) -> Date? {
        guard let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        if let date = MDItemCopyAttribute(mdItem, kMDItemLastUsedDate) as? Date {
            return date
        }
        return nil
    }

    private static func scanOrphanLeftovers(
        libraryIndex: LibraryDirectoryIndex,
        installedBundleIDs: Set<String>,
        installedNames: Set<String>
    ) -> [OrphanLeftover] {
        // Only flag clear reverse-DNS bundle directories (`com.vendor.app`, `io.vendor.app`, `org.vendor.app`)
        // that do not match any installed app and are not Apple/system services.
        let safeSkipPrefixes = [
            "com.apple.", "com.macpaw.", "org.swift.", "com.cleantrash.",
            "group.com.apple.", "com.google.keystone"
        ]

        let buckets: [(String, [URL])] = [
            ("Caches", libraryIndex.caches),
            ("Containers", libraryIndex.containers),
            ("Saved State", libraryIndex.savedState),
            ("HTTPStorages", libraryIndex.httpStorages)
        ]

        var orphans: [OrphanLeftover] = []
        for (label, urls) in buckets {
            for url in urls {
                let rawName = url.lastPathComponent
                let normalized = rawName
                    .replacingOccurrences(of: ".savedState", with: "")
                    .lowercased()

                // Require reverse-DNS pattern (at least 2 dots) to avoid false positives on generic folders.
                guard normalized.split(separator: ".").count >= 3 else { continue }
                if safeSkipPrefixes.contains(where: { normalized.hasPrefix($0) }) { continue }
                if installedBundleIDs.contains(normalized) { continue }
                if installedBundleIDs.contains(where: { normalized.hasPrefix($0) || $0.hasPrefix(normalized) }) { continue }
                let lastComponent = normalized.split(separator: ".").last.map(String.init) ?? ""
                if !lastComponent.isEmpty && installedNames.contains(where: { $0.replacingOccurrences(of: " ", with: "") == lastComponent }) {
                    continue
                }

                let size = SafeCleaner.allocatedSize(of: url)
                guard size >= 5_000_000 else { continue }
                orphans.append(OrphanLeftover(
                    name: rawName,
                    path: url.path,
                    location: "~/Library/\(label)",
                    sizeBytes: size
                ))
            }
        }
        return orphans
    }
}

private struct LibraryDirectoryIndex: Sendable {
    let appSupport: [URL]
    let systemAppSupport: [URL]
    let caches: [URL]
    let containers: [URL]
    let groupContainers: [URL]
    let preferences: [URL]
    let savedState: [URL]
    let logs: [URL]
    let httpStorages: [URL]
    let webKit: [URL]
    let cookies: [URL]
    let launchAgents: [URL]
    let systemLaunchAgents: [URL]
    let systemLaunchDaemons: [URL]
    let privilegedHelpers: [URL]

    init(home: String) {
        func list(_ absPath: String) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: absPath),
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
        }
        self.appSupport = list("\(home)/Library/Application Support")
        self.systemAppSupport = list("/Library/Application Support")
        self.caches = list("\(home)/Library/Caches")
        self.containers = list("\(home)/Library/Containers")
        self.groupContainers = list("\(home)/Library/Group Containers")
        self.preferences = list("\(home)/Library/Preferences")
        self.savedState = list("\(home)/Library/Saved Application State")
        self.logs = list("\(home)/Library/Logs")
        self.httpStorages = list("\(home)/Library/HTTPStorages")
        self.webKit = list("\(home)/Library/WebKit")
        self.cookies = list("\(home)/Library/Cookies")
        self.launchAgents = list("\(home)/Library/LaunchAgents")
        self.systemLaunchAgents = list("/Library/LaunchAgents")
        self.systemLaunchDaemons = list("/Library/LaunchDaemons")
        self.privilegedHelpers = list("/Library/PrivilegedHelperTools")
    }

    func findRelatedFiles(bundleID: String, appName: String) -> [AppRelatedFile] {
        let bid = bundleID.lowercased()
        let cleanName = appName.lowercased()
        let compactName = cleanName.replacingOccurrences(of: " ", with: "")
        // e.g. "com.teamviewer.TeamViewer" -> prefix "com.teamviewer."
        let parts = bid.split(separator: ".")
        let vendorPrefix: String? = parts.count >= 2 ? "\(parts[0]).\(parts[1])." : nil
        let genericVendors: Set<String> = [
            "com.apple.", "com.microsoft.", "com.google.", "com.adobe.", "com.jetbrains.", "org.mozilla."
        ]
        let safeVendorPrefix = vendorPrefix.flatMap { genericVendors.contains($0) ? nil : $0 }

        func matches(_ url: URL, allowNameMatch: Bool, allowVendorPrefix: Bool = false) -> Bool {
            let item = url.lastPathComponent.lowercased()
            if item == bid || item == "\(bid).plist" || item == "\(bid).savedstate" || item == "\(bid).binarycookies" {
                return true
            }
            if item.hasPrefix("\(bid).") || item.contains(".\(bid)") {
                return true
            }
            if allowVendorPrefix, let vp = safeVendorPrefix, item.hasPrefix(vp) {
                return true
            }
            if allowNameMatch && cleanName.count >= 4 {
                if item == cleanName || item == compactName {
                    return true
                }
            }
            return false
        }

        var found: [AppRelatedFile] = []
        let mappings: [([URL], AppArtifactKind, Bool, Bool)] = [
            (appSupport, .applicationSupport, true, false),
            (systemAppSupport, .applicationSupport, true, false),
            (caches, .caches, true, false),
            (containers, .container, false, false),
            (groupContainers, .groupContainer, false, false),
            (preferences, .preferences, false, false),
            (savedState, .savedState, false, false),
            (logs, .logs, true, false),
            (httpStorages, .webData, false, false),
            (webKit, .webData, false, false),
            (cookies, .webData, false, false),
            (launchAgents, .launchAgent, false, true),
            (systemLaunchAgents, .launchAgent, false, true),
            (systemLaunchDaemons, .launchAgent, false, true),
            (privilegedHelpers, .launchAgent, false, true)
        ]

        var seenPaths = Set<String>()
        for (entries, kind, allowName, allowVendor) in mappings {
            for url in entries where matches(url, allowNameMatch: allowName, allowVendorPrefix: allowVendor) {
                if seenPaths.insert(url.path).inserted {
                    let size = SafeCleaner.allocatedSize(of: url)
                    found.append(AppRelatedFile(path: url.path, kind: kind, sizeBytes: size))
                }
            }
        }
        return found.sorted { $0.sizeBytes > $1.sizeBytes }
    }
}
