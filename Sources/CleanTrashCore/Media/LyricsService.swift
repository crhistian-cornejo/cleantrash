import Foundation

/// A single timestamped lyric line parsed from LRC format.
public struct LyricLine: Identifiable, Sendable, Equatable, Codable {
    public let id: Int
    public let time: TimeInterval
    public let text: String

    public init(id: Int, time: TimeInterval, text: String) {
        self.id = id
        self.time = time
        self.text = text
    }
}

/// Synced and/or plain lyrics for a track.
public struct LyricsDocument: Sendable, Equatable, Codable {
    public let trackKey: String
    public let syncedLines: [LyricLine]
    public let plainLines: [String]
    public let instrumental: Bool

    public init(
        trackKey: String,
        syncedLines: [LyricLine] = [],
        plainLines: [String] = [],
        instrumental: Bool = false
    ) {
        self.trackKey = trackKey
        self.syncedLines = syncedLines
        self.plainLines = plainLines
        self.instrumental = instrumental
    }

    public var isSynced: Bool { !syncedLines.isEmpty }
    public var isEmpty: Bool { syncedLines.isEmpty && plainLines.isEmpty && !instrumental }

    /// Index into `syncedLines` for a playback position (seconds). Uses a tiny anticipation lead so
    /// the highlight feels locked to the vocal onset.
    public func activeLineIndex(at position: TimeInterval, leadOffset: TimeInterval = 0.25) -> Int? {
        guard !syncedLines.isEmpty else { return nil }
        let target = position + leadOffset
        if target < syncedLines[0].time { return nil }

        // Binary search for the last line with time <= target.
        var low = 0
        var high = syncedLines.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLines[mid].time <= target {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}

/// Pure, deterministic parser for standard LRC files (`[mm:ss.xx]`, `[mm:ss.xxx]`, multi-tags).
public enum LRCParser {
    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#
    )

    public static func parse(_ raw: String) -> [LyricLine] {
        var entries: [(time: TimeInterval, text: String)] = []
        let lines = raw.components(separatedBy: .newlines)

        for rawLine in lines {
            let nsLine = rawLine as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            let matches = timestampRegex.matches(in: rawLine, range: fullRange)
            guard !matches.isEmpty else { continue }

            // Strip all leading/inline timestamps to extract the lyric text.
            var text = timestampRegex.stringByReplacingMatches(
                in: rawLine,
                range: fullRange,
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            // Keep musical interlude markers readable instead of empty blanks.
            if text.isEmpty {
                text = "♪"
            }

            for match in matches {
                guard match.numberOfRanges >= 3 else { continue }
                let minStr = nsLine.substring(with: match.range(at: 1))
                let secStr = nsLine.substring(with: match.range(at: 2))
                guard let minutes = Double(minStr), let seconds = Double(secStr) else { continue }

                var fraction: Double = 0
                if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound {
                    let fracStr = nsLine.substring(with: match.range(at: 3))
                    if let fracVal = Double(fracStr) {
                        switch fracStr.count {
                        case 1: fraction = fracVal / 10.0
                        case 2: fraction = fracVal / 100.0
                        default: fraction = fracVal / 1000.0
                        }
                    }
                }

                let time = minutes * 60.0 + seconds + fraction
                entries.append((time, text))
            }
        }

        entries.sort { $0.time < $1.time }

        // Drop consecutive pure-interlude duplicates so timelines stay tidy.
        var result: [LyricLine] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            if entry.text == "♪", result.last?.text == "♪" { continue }
            result.append(LyricLine(id: result.count, time: entry.time, text: entry.text))
        }
        return result
    }

    /// Removes noisy suffixes like `(Remastered 2011)`, `- Radio Edit`, `[Deluxe]` to improve LRCLIB hits.
    public static func cleanTrackTitle(_ title: String) -> String {
        var s = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"\s*[\(\[](?:feat\.?|ft\.?|with|(?:\d{4}\s+)?remaster(?:ed)?|live|acoustic|radio edit|deluxe|bonus|version|mono|stereo)[^\)\]]*[\)\]]"#,
            #"\s+-\s+(?:(?:\d{4}\s+)?remaster(?:ed)?|live|radio edit|single version|album version|from\s+).*$"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: (s as NSString).length)
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func primaryArtist(_ artist: String) -> String {
        let separators = [", ", " & ", " feat. ", " ft. ", " x ", " / "]
        var current = artist
        for sep in separators {
            if let range = current.range(of: sep, options: .caseInsensitive) {
                current = String(current[..<range.lowerBound])
            }
        }
        return current.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Fetches and caches time-synced karaoke lyrics from LRCLIB (free, no API key required).
public actor LyricsService {
    public static let shared = LyricsService()

    private struct LRCLIBRecord: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private var memoryCache: [String: LyricsDocument] = [:]
    private let cacheDirectory: URL
    private let session: URLSession

    public init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.cacheDirectory = support.appendingPathComponent("CleanTrash/lyrics-cache", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpAdditionalHeaders = ["User-Agent": "CleanTrash/1.0 (macOS Notch Media Player)"]
        self.session = URLSession(configuration: config)
    }

    public static func trackKey(artist: String, title: String) -> String {
        "\(artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))::\(title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    public func fetchLyrics(
        artist: String,
        title: String,
        album: String = "",
        duration: TimeInterval = 0
    ) async -> LyricsDocument? {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        let key = Self.trackKey(artist: trimmedArtist, title: trimmedTitle)
        if let cached = memoryCache[key] {
            return cached.isEmpty ? nil : cached
        }
        if let disk = loadFromDisk(key: key) {
            memoryCache[key] = disk
            return disk.isEmpty ? nil : disk
        }

        // 1. Exact lookup on /api/get
        if let exact = await queryExact(artist: trimmedArtist, title: trimmedTitle, album: album, duration: duration),
           !exact.isEmpty {
            store(exact, key: key)
            return exact
        }

        // 2. Fallback search with cleaned title & primary artist
        let cleanTitle = LRCParser.cleanTrackTitle(trimmedTitle)
        let mainArtist = LRCParser.primaryArtist(trimmedArtist)
        if let searched = await querySearch(artist: mainArtist, title: cleanTitle, duration: duration),
           !searched.isEmpty {
            store(searched, key: key)
            return searched
        }

        // Negative-cache in memory only (not disk) so transient offline states recover next launch.
        memoryCache[key] = LyricsDocument(trackKey: key)
        return nil
    }

    private func queryExact(artist: String, title: String, album: String, duration: TimeInterval) async -> LyricsDocument? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title)
        ]
        if !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if duration > 10 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components?.queryItems = items
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let record = try JSONDecoder().decode(LRCLIBRecord.self, from: data)
            return buildDocument(key: Self.trackKey(artist: artist, title: title), from: record)
        } catch {
            return nil
        }
    }

    private func querySearch(artist: String, title: String, duration: TimeInterval) async -> LyricsDocument? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        let query = artist.isEmpty ? title : "\(artist) \(title)"
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let records = try JSONDecoder().decode([LRCLIBRecord].self, from: data)
            guard !records.isEmpty else { return nil }

            // Prefer synced lyrics and closest duration match.
            let ranked = records.sorted { lhs, rhs in
                let lSynced = !(lhs.syncedLyrics?.isEmpty ?? true)
                let rSynced = !(rhs.syncedLyrics?.isEmpty ?? true)
                if lSynced != rSynced { return lSynced }
                if duration > 10 {
                    let lDiff = abs((lhs.duration ?? duration) - duration)
                    let rDiff = abs((rhs.duration ?? duration) - duration)
                    if abs(lDiff - rDiff) > 2 { return lDiff < rDiff }
                }
                return !(lhs.plainLyrics?.isEmpty ?? true) && (rhs.plainLyrics?.isEmpty ?? true)
            }
            guard let best = ranked.first else { return nil }
            return buildDocument(key: Self.trackKey(artist: artist, title: title), from: best)
        } catch {
            return nil
        }
    }

    private func buildDocument(key: String, from record: LRCLIBRecord) -> LyricsDocument {
        let synced = record.syncedLyrics.map { LRCParser.parse($0) } ?? []
        let plain = (record.plainLyrics ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return LyricsDocument(
            trackKey: key,
            syncedLines: synced,
            plainLines: plain,
            instrumental: record.instrumental ?? false
        )
    }

    private func store(_ doc: LyricsDocument, key: String) {
        memoryCache[key] = doc
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: diskURL(for: key), options: .atomic)
        }
    }

    private func loadFromDisk(key: String) -> LyricsDocument? {
        guard let data = try? Data(contentsOf: diskURL(for: key)) else { return nil }
        return try? JSONDecoder().decode(LyricsDocument.self, from: data)
    }

    private func diskURL(for key: String) -> URL {
        let safe = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return cacheDirectory.appendingPathComponent("\(safe.prefix(96)).json")
    }
}
