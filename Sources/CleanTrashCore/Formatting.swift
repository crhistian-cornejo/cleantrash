import Foundation

public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    /// Base-1000 decimal formatting (matches macOS Finder for Disk sizes).
    public static func compact(_ bytes: UInt64) -> String {
        let kb = 1_000.0
        let mb = kb * 1_000.0
        let gb = mb * 1_000.0
        let tb = gb * 1_000.0
        let value = Double(bytes)
        if value >= tb {
            return String(format: "%.2f TB", value / tb)
        } else if value >= gb {
            return String(format: "%.1f GB", value / gb)
        } else if value >= mb {
            return String(format: "%.0f MB", value / mb)
        } else if value >= kb {
            return String(format: "%.0f KB", value / kb)
        } else {
            return "\(bytes) B"
        }
    }

    /// Base-1024 binary formatting (matches macOS Activity Monitor for RAM & GPU memory: 24.0 GB instead of 25.8 GB).
    public static func memory(_ bytes: UInt64) -> String {
        let kib = 1024.0
        let mib = kib * 1024.0
        let gib = mib * 1024.0
        let value = Double(bytes)
        if value >= gib {
            let g = value / gib
            return g.truncatingRemainder(dividingBy: 1) < 0.05
                ? String(format: "%.0f GB", g)
                : String(format: "%.1f GB", g)
        } else if value >= mib {
            return String(format: "%.0f MB", value / mib)
        } else if value >= kib {
            return String(format: "%.0f KB", value / kib)
        } else {
            return "\(bytes) B"
        }
    }

    public static func speed(_ bytesPerSec: Double) -> String {
        let value = max(0, bytesPerSec)
        if value >= 1_000_000_000 {
            return String(format: "%.1f GB/s", value / 1_000_000_000)
        } else if value >= 1_000_000 {
            return String(format: "%.1f MB/s", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.0f KB/s", value / 1_000)
        } else {
            return String(format: "%.0f B/s", value)
        }
    }

    public static func relativeAge(_ date: Date?) -> String {
        guard let date else { return "Sin abrir" }
        let seconds = Date.now.timeIntervalSince(date)
        if seconds < 60 { return "Ahora" }
        if seconds < 3_600 { return "Hace \(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "Hace \(Int(seconds / 3_600)) h" }
        let days = Int(seconds / 86_400)
        if days < 30 { return "Hace \(days) d" }
        let months = days / 30
        if months < 12 { return months == 1 ? "Hace 1 mes" : "Hace \(months) meses" }
        let years = months / 12
        return years == 1 ? "Hace 1 año" : "Hace \(years) años"
    }
}

public enum PathSafety {
    /// Paths that CleanTrash will NEVER delete under any circumstance.
    private static let exactProtected: Set<String> = [
        "/",
        "/System",
        "/System/Volumes",
        "/System/Volumes/Data",
        "/Library",
        "/Applications",
        "/Users",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/private",
        "/private/etc",
        "/private/var",
        "/var",
        "/dev",
        "/Volumes",
        "/cores",
        "/opt"
    ]

    public static func isProtectedPath(_ rawPath: String) -> Bool {
        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        if standardized.isEmpty || standardized == "/" { return true }
        if exactProtected.contains(standardized) { return true }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let protectedHomeRoots: Set<String> = [
            home,
            "\(home)/Library",
            "\(home)/Library/Application Support",
            "\(home)/Library/Caches",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Preferences",
            "\(home)/Library/Logs",
            "\(home)/Library/LaunchAgents",
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Pictures",
            "\(home)/Movies",
            "\(home)/Music",
            "\(home)/Developer",
            "\(home)/.ssh",
            "\(home)/.gnupg",
            "\(home)/.aws"
        ]
        if protectedHomeRoots.contains(standardized) { return true }

        // Never touch SIP / Apple core directories or Keychains.
        let protectedPrefixes = [
            "/System/",
            "/usr/",
            "/bin/",
            "/sbin/",
            "/Library/Apple/",
            "\(home)/Library/Keychains",
            "\(home)/.ssh/"
        ]
        for prefix in protectedPrefixes where standardized.hasPrefix(prefix) {
            return true
        }
        return false
    }

    public static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // TCC-protected directories that succeed only with Full Disk Access.
        let probes = [
            "\(home)/Library/Safari/Bookmarks.plist",
            "\(home)/Library/Mail",
            "/Library/Application Support/com.apple.TCC/TCC.db"
        ]
        for probe in probes {
            if FileManager.default.isReadableFile(atPath: probe) {
                return true
            }
        }
        // Fallback: try reading directory entries of ~/Library/Mail or Safari.
        if (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/Library/Safari")) != nil {
            return true
        }
        return false
    }
}
