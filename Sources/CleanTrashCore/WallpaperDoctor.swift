import Foundation

public struct WallpaperHealth: Sendable, Equatable {
    /// Desktop choices (per display / per Space) whose image file no longer exists → macOS draws black.
    public var brokenCount = 0
    public var totalImageChoices = 0
    /// Existing image used to replace the broken ones (the most recently used valid wallpaper).
    public var replacementPath: String?

    public var isBroken: Bool { brokenCount > 0 }
}

/// Detects and repairs wallpapers that render black because their image vanished.
///
/// macOS stores one wallpaper choice per display *and per Space* in
/// `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`. Images picked from a temp
/// folder (`$TMPDIR/StaticWallpaper/*_static.jpg`, which macOS purges) or later deleted from Downloads
/// leave dangling `file://` URLs, and WallpaperAgent then shows a black desktop on those Spaces.
public struct WallpaperDoctor: Sendable {
    public let indexURL: URL

    public init(indexURL: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")) {
        self.indexURL = indexURL
    }

    public func diagnose() -> WallpaperHealth {
        guard let root = loadIndex() else { return WallpaperHealth() }
        var health = WallpaperHealth()
        var newest: (Date, String)?
        Self.visitImageChoices(in: root) { config, lastUse in
            guard let path = Self.imagePath(from: config) else { return config }
            health.totalImageChoices += 1
            if FileManager.default.fileExists(atPath: path) {
                if let lastUse, newest == nil || lastUse > newest!.0 { newest = (lastUse, path) }
            } else {
                health.brokenCount += 1
            }
            return config
        }
        health.replacementPath = newest?.1
        return health
    }

    /// Points every broken choice at `replacement` (default: newest valid wallpaper), keeps a backup next
    /// to the index, and restarts WallpaperAgent so the desktops redraw. Returns how many were fixed.
    @discardableResult
    public func repair(using replacement: String? = nil, restartAgent: Bool = true) throws -> Int {
        guard var root = loadIndex() else { return 0 }
        let target = replacement ?? diagnose().replacementPath
        guard let target, FileManager.default.fileExists(atPath: target) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "No hay ninguna imagen de fondo válida para usar"])
        }
        let replacementConfig = try PropertyListSerialization.data(
            fromPropertyList: ["type": "imageFile", "url": ["relative": URL(fileURLWithPath: target).absoluteString]],
            format: .binary, options: 0
        )

        var fixed = 0
        root = Self.visitImageChoices(in: root) { config, _ in
            guard let path = Self.imagePath(from: config), !FileManager.default.fileExists(atPath: path) else { return config }
            fixed += 1
            return replacementConfig
        } as? [String: Any] ?? root
        guard fixed > 0 else { return 0 }

        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backup = indexURL.deletingLastPathComponent().appendingPathComponent("Index.plist.backup-cleantrash-\(stamp)")
        try? FileManager.default.copyItem(at: indexURL, to: backup)

        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: indexURL, options: .atomic)
        if restartAgent { Self.restartWallpaperAgent() }
        return fixed
    }

    // MARK: - Plist walking

    private func loadIndex() -> [String: Any]? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Calls `transform` for each image choice's `Configuration` blob (with the enclosing entry's
    /// `LastUse`) and rebuilds the tree with whatever it returns.
    @discardableResult
    static func visitImageChoices(in node: Any, lastUse: Date? = nil, _ transform: (Data, Date?) -> Data) -> Any {
        if var dict = node as? [String: Any] {
            let use = dict["LastUse"] as? Date ?? lastUse
            if var choices = dict["Choices"] as? [[String: Any]] {
                for i in choices.indices where (choices[i]["Provider"] as? String) == "com.apple.wallpaper.choice.image" {
                    if let config = choices[i]["Configuration"] as? Data, !config.isEmpty {
                        choices[i]["Configuration"] = transform(config, use)
                    }
                }
                dict["Choices"] = choices
            }
            for (key, value) in dict where key != "Choices" {
                dict[key] = visitImageChoices(in: value, lastUse: use, transform)
            }
            return dict
        }
        if let array = node as? [Any] {
            return array.map { visitImageChoices(in: $0, lastUse: lastUse, transform) }
        }
        return node
    }

    static func imagePath(from config: Data) -> String? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: config, format: nil)) as? [String: Any],
              let url = plist["url"] as? [String: Any],
              let relative = url["relative"] as? String,
              relative.hasPrefix("file://"),
              let fileURL = URL(string: relative) else { return nil }
        return fileURL.path
    }

    private static func restartWallpaperAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        try? process.run()
        process.waitUntilExit()
    }
}
