import CleanTrashCore
import Foundation
import Testing

@Suite("Lyrics & Notch Productivity")
struct LyricsAndNotchTests {
    @Test("LRCParser parses standard, millisecond, and multi-timestamp lines")
    func parseLRC() {
        let raw = """
        [ar:M83]
        [ti:Midnight City]
        [00:12.50] Waiting in a car
        [00:18.250] Waiting for a ride in the dark
        [00:25.00][01:10.00] The night city grows
        [00:30.00]
        [00:31.00]
        """
        let lines = LRCParser.parse(raw)
        #expect(lines.count == 5)
        #expect(lines[0].text == "Waiting in a car")
        #expect(abs(lines[0].time - 12.5) < 0.001)
        #expect(abs(lines[1].time - 18.25) < 0.001)
        #expect(lines[2].text == "The night city grows")
        #expect(abs(lines[2].time - 25.0) < 0.001)
        #expect(lines[3].text == "♪")
        #expect(lines[4].text == "The night city grows")
        #expect(abs(lines[4].time - 70.0) < 0.001)
    }

    @Test("LyricsDocument locates active line using binary search with lead offset")
    func activeLineLookup() {
        let doc = LyricsDocument(
            trackKey: "test",
            syncedLines: [
                LyricLine(id: 0, time: 10, text: "First"),
                LyricLine(id: 1, time: 20, text: "Second"),
                LyricLine(id: 2, time: 30, text: "Third")
            ]
        )
        #expect(doc.activeLineIndex(at: 5.0, leadOffset: 0.25) == nil)
        #expect(doc.activeLineIndex(at: 9.8, leadOffset: 0.25) == 0)
        #expect(doc.activeLineIndex(at: 19.5, leadOffset: 0.25) == 0)
        #expect(doc.activeLineIndex(at: 20.0, leadOffset: 0.25) == 1)
        #expect(doc.activeLineIndex(at: 45.0, leadOffset: 0.25) == 2)
    }

    @Test("Track title & artist sanitization strips remaster and feature noise")
    func cleanMetadata() {
        #expect(LRCParser.cleanTrackTitle("Dreams - 2004 Remaster") == "Dreams")
        #expect(LRCParser.cleanTrackTitle("Blinding Lights (feat. Rosalía)") == "Blinding Lights")
        #expect(LRCParser.cleanTrackTitle("Bohemian Rhapsody (Remastered 2011)") == "Bohemian Rhapsody")
        #expect(LRCParser.primaryArtist("Daft Punk, Pharrell Williams") == "Daft Punk")
        #expect(LRCParser.primaryArtist("The Weeknd & Ariana Grande") == "The Weeknd")
    }

    @Test("CleanTrashSettings migrates older JSON payloads without new glass/media keys")
    func settingsMigration() throws {
        let legacyJSON = """
        {
          "notchEnabled": true,
          "notchStyle": "notch",
          "notchTrigger": "hover",
          "showLiveNotchEars": true
        }
        """
        let decoded = try JSONDecoder().decode(CleanTrashSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.notchSurface == .glass)
        #expect(decoded.showMusicInNotchEars == true)
        #expect(decoded.showLyricsInNotchEar == true)
        #expect(decoded.clipboardHistoryEnabled == true)
        #expect(decoded.autoOpenShelfOnDrag == true)
        #expect(decoded.homeWidgets == NotchWidgetID.defaultLayout)
        #expect(NotchSurfaceMode.obsidian.next == .glass)
        #expect(NotchSurfaceMode.glass.next == .clearGlass)
        #expect(NotchSurfaceMode.clearGlass.next == .obsidian)
    }

    @Test("DevlyTools handles Base64, JSON, SHA256, JWT, URL, and UUID transforms")
    func devlyTransforms() {
        let b64 = DevlyTools.encode("Hello, CleanTrash!", mode: .base64)
        #expect(b64 == "SGVsbG8sIENsZWFuVHJhc2gh")
        #expect(DevlyTools.decode(b64, mode: .base64) == "Hello, CleanTrash!")

        let pretty = DevlyTools.encode("{\"b\":2,\"a\":1}", mode: .json)
        #expect(pretty.contains("\"a\" : 1"))
        let mini = DevlyTools.decode(pretty, mode: .json)
        #expect(mini == "{\"a\":1,\"b\":2}")

        let hash = DevlyTools.encode("abc", mode: .sha256)
        #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // Valid JWT with payload {"sub":"42"}
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiI0MiJ9.sig"
        #expect(DevlyTools.decode(jwt, mode: .jwt).contains("\"sub\" : \"42\""))

        let uuid = DevlyTools.encode("", mode: .uuid)
        #expect(uuid.count == 36)
    }
}
