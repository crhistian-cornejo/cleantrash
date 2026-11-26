import AppKit
import CleanTrashCore
import Foundation
import IOKit.pwr_mgt
import Observation
import SwiftUI

// MARK: - Quick Notes (Droppy Multi-Note List)

struct QuickNoteItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var body: String
    var updatedAt: Date
}

// MARK: - Weather Snapshot (Droppy Weather Widget)

struct HourlyWeatherPoint: Identifiable, Equatable, Sendable {
    let id: Int
    let hourLabel: String
    let tempC: Int
    let symbol: String
}

struct WeatherSnapshot: Equatable, Sendable {
    let city: String
    let tempC: Int
    let condition: String
    let symbol: String
    let highC: Int
    let lowC: Int
    let hourly: [HourlyWeatherPoint]
    let updatedAt: Date
}

// MARK: - File Shelf (Droppy-style Drop Tray)

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    let path: String
    let name: String
    let sizeBytes: UInt64
    let isDirectory: Bool
    let addedAt: Date

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

// MARK: - Clipboard Manager

enum ClipboardEntryKind: String, Codable, Equatable {
    case text
    case url
    case color
    case image
}

struct ClipboardEntry: Identifiable, Equatable {
    let id: UUID
    let kind: ClipboardEntryKind
    let previewText: String
    let fullText: String?
    let hexColor: String?
    let imageData: Data?
    let imageDimensions: String?
    let timestamp: Date
    var isPinned: Bool
}

// MARK: - Focus / Pomodoro Timer

struct FocusPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let minutes: Int
    let symbol: String

    static let defaults: [FocusPreset] = [
        FocusPreset(id: "focus", label: "Focus", minutes: 25, symbol: "brain.head.profile"),
        FocusPreset(id: "sprint", label: "Sprint", minutes: 15, symbol: "bolt.fill"),
        FocusPreset(id: "break", label: "Pausa", minutes: 5, symbol: "cup.and.saucer.fill"),
        FocusPreset(id: "long", label: "Profundo", minutes: 45, symbol: "flame.fill")
    ]
}

/// Droppy-inspired productivity engine for the Dynamic Notch:
/// File Shelf (drag-in / drag-out / zip / AirDrop), Clipboard History (text, URLs, colors, images),
/// and a Focus / Pomodoro timer.
@MainActor
@Observable
final class ProductivityHub {
    // Shelf
    private(set) var shelfItems: [ShelfItem] = []
    var isDragOverNotch = false

    // Clipboard
    private(set) var clipboardEntries: [ClipboardEntry] = []
    var clipboardEnabled = true
    private(set) var lastCopiedEntryID: UUID?

    // Focus Timer
    private(set) var timerLabel: String = "Focus"
    private(set) var timerTotalSeconds: Int = 25 * 60
    private(set) var timerRemainingSeconds: Int = 25 * 60
    private(set) var isTimerRunning = false
    var onTimerFinished: ((String) -> Void)?

    // Quick Notes (multi-note list, auto-saved — Droppy Notes style)
    var quickNotes: [QuickNoteItem] = []
    var selectedNoteID: UUID?

    // Stay Awake (native IOKit display sleep assertion — Droppy Stay Awake)
    private(set) var isStayAwakeEnabled = false
    private(set) var stayAwakeSince: Date?
    @ObservationIgnored private var sleepAssertionID: IOPMAssertionID = 0

    // Live Weather (free Open-Meteo + IP geolocation, zero API key)
    private(set) var weather: WeatherSnapshot?
    private(set) var isLoadingWeather = false

    // Multi-device Batteries (Mac + Bluetooth AirPods/Mouse/Keyboard)
    private(set) var bluetoothBatteries: [DeviceBatteryInfo] = []

    // Calendar Events (EventKit)
    private(set) var calendarEvents: [CalendarEventItem] = []
    private(set) var calendarAuthorized = false
    @ObservationIgnored private let calendarReader = CalendarReader()

    // Master System Audio (CoreAudio)
    private(set) var masterVolume: Int = 50
    private(set) var isMasterMuted: Bool = false
    private(set) var audioOutputName: String = "Altavoces"

    // Detachable Floating Mini-Player, On-Device Quick Translate, Full-Screen StandBy & Breather Wellness Engine
    @ObservationIgnored let floatingPlayer = FloatingPlayerWindowController()
    @ObservationIgnored let quickTranslate = QuickTranslateWindowController()
    @ObservationIgnored let standBy = AmbientStandByController()
    let breather = BreatherEngine()

    // Low-battery accessory alert callback (fires once per accessory <= 20%)
    var onAccessoryLowBattery: ((DeviceBatteryInfo) -> Void)?
    @ObservationIgnored private var alertedLowBatteryIDs: Set<String> = []

    // OCR completion callbacks (for Notch toast)
    var onOCRCompleted: ((Int) -> Void)?
    var onOCRPermissionNeeded: (() -> Void)?

    @ObservationIgnored private var clipboardTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var weatherTask: Task<Void, Never>?
    @ObservationIgnored private var accessoriesTask: Task<Void, Never>?
    @ObservationIgnored private var lastBatteryRead = Date.distantPast
    @ObservationIgnored private var lastWeatherFetch = Date.distantPast

    /// Home widgets currently in the notch; data for hidden widgets isn't fetched.
    @ObservationIgnored var activeWidgets: Set<NotchWidgetID> = []
    /// The Notch section of the main window shows every widget.
    @ObservationIgnored var isHubVisible = false {
        didSet { if isHubVisible && !oldValue { refreshVisibleData() } }
    }

    private func wants(_ widget: NotchWidgetID) -> Bool {
        isHubVisible || activeWidgets.contains(widget)
    }
    @ObservationIgnored private var lastPasteboardChangeCount: Int = NSPasteboard.general.changeCount
    @ObservationIgnored private let shelfStorageURL: URL
    @ObservationIgnored private let notesStorageURL: URL

    private static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword"
    ]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.shelfStorageURL = support.appendingPathComponent("CleanTrash/shelf.json")
        self.notesStorageURL = support.appendingPathComponent("CleanTrash/notes.json")
        loadNotes()
        loadShelf()
        refreshAudioState()
        refreshCalendar()
    }

    func start() {
        startClipboardMonitor()
        startWeatherLoop()
        startAccessoriesLoop()
        breather.start()
    }

    func stop() {
        clipboardTask?.cancel()
        timerTask?.cancel()
        weatherTask?.cancel()
        accessoriesTask?.cancel()
        breather.stop()
        if isStayAwakeEnabled {
            setStayAwake(false)
        }
    }

    // MARK: - Multi-Notes (Droppy Notes)

    private func loadNotes() {
        if let data = try? Data(contentsOf: notesStorageURL),
           let decoded = try? JSONDecoder().decode([QuickNoteItem].self, from: data),
           !decoded.isEmpty {
            quickNotes = decoded
            return
        }
        // Seed one clean starter note
        quickNotes = [
            QuickNoteItem(id: UUID(), title: "Nota rápida", body: "", updatedAt: .now)
        ]
    }

    private func saveNotes() {
        try? FileManager.default.createDirectory(at: notesStorageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(quickNotes) {
            try? data.write(to: notesStorageURL, options: .atomic)
        }
    }

    func createNote() -> QuickNoteItem {
        let item = QuickNoteItem(id: UUID(), title: "Nueva nota", body: "", updatedAt: .now)
        withAnimation(Mono.betweenSpring) {
            quickNotes.insert(item, at: 0)
            selectedNoteID = item.id
        }
        saveNotes()
        return item
    }

    func updateNote(id: UUID, body: String) {
        guard let idx = quickNotes.firstIndex(where: { $0.id == id }) else { return }
        quickNotes[idx].body = body
        let firstLine = body.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        quickNotes[idx].title = firstLine.isEmpty ? "Nota rápida" : String(firstLine.prefix(36))
        quickNotes[idx].updatedAt = .now
        saveNotes()
    }

    func deleteNote(id: UUID) {
        withAnimation(Mono.betweenSpring) {
            quickNotes.removeAll { $0.id == id }
            if selectedNoteID == id { selectedNoteID = nil }
        }
        saveNotes()
    }

    // MARK: - Accessories Batteries, Calendar, System Audio & Vision OCR

    private func startAccessoriesLoop() {
        accessoriesTask?.cancel()
        accessoriesTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                if !SystemActivity.isIdle {
                    // `system_profiler` is slow: every 30 s while batteries are on screen, otherwise
                    // every 5 min just to catch a low accessory battery.
                    let batteryInterval: TimeInterval = self.wants(.batteries) ? 30 : 300
                    if Date.now.timeIntervalSince(self.lastBatteryRead) >= batteryInterval {
                        await self.readBatteries()
                    }
                    if self.wants(.audio) { self.refreshAudioState() }
                    if self.wants(.calendar) { self.refreshCalendar() }
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func readBatteries() async {
        lastBatteryRead = .now
        let devices = await Task.detached(priority: .utility) {
            BluetoothBatteryReader.readConnectedAccessories()
        }.value
        bluetoothBatteries = devices
        for dev in devices {
            if dev.percent <= 20 && !dev.isCharging {
                if !alertedLowBatteryIDs.contains(dev.id) {
                    alertedLowBatteryIDs.insert(dev.id)
                    onAccessoryLowBattery?(dev)
                }
            } else if dev.percent >= 30 || dev.isCharging {
                alertedLowBatteryIDs.remove(dev.id)
            }
        }
    }

    /// Catches up on data for widgets that just became visible.
    func refreshVisibleData() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.wants(.batteries), Date.now.timeIntervalSince(self.lastBatteryRead) > 30 { await self.readBatteries() }
            if self.wants(.audio) { self.refreshAudioState() }
            if self.wants(.calendar) { self.refreshCalendar() }
            if self.wants(.weather), Date.now.timeIntervalSince(self.lastWeatherFetch) > 20 * 60 {
                self.lastWeatherFetch = .now
                await self.refreshWeather()
            }
        }
    }

    func refreshAudioState() {
        masterVolume = SystemAudioController.masterVolumePercent()
        isMasterMuted = SystemAudioController.isMuted()
        audioOutputName = SystemAudioController.outputDeviceName()
    }

    func setMasterVolume(_ percent: Int) {
        let clamped = min(100, max(0, percent))
        masterVolume = clamped
        if isMasterMuted && clamped > 0 {
            isMasterMuted = false
            SystemAudioController.setMuted(false)
        }
        SystemAudioController.setMasterVolumePercent(clamped)
    }

    func toggleMasterMute() {
        isMasterMuted.toggle()
        SystemAudioController.setMuted(isMasterMuted)
        AppKitHaptics.tap()
    }

    func refreshCalendar() {
        calendarAuthorized = calendarReader.isAuthorized
        if calendarAuthorized {
            calendarEvents = calendarReader.fetchTodayEvents()
        }
    }

    func requestCalendarAccess() async {
        let granted = await calendarReader.requestAccess()
        calendarAuthorized = granted
        if granted {
            calendarEvents = calendarReader.fetchTodayEvents()
        }
    }

    func captureScreenText() async {
        // If macOS Screen Recording isn't granted yet, check if the user already has a screenshot
        // on the clipboard (⌘⇧⌃4) so Vision OCR works immediately with ZERO extra permissions!
        if !VisionTextCapture.hasScreenRecordingPermission,
           let clipData = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff),
           let text = await VisionTextCapture.recognizeText(in: clipData) {
            writeTextToClipboard(text)
            onOCRCompleted?(text.count)
            return
        }

        switch await VisionTextCapture.captureScreenArea() {
        case .captured(let text):
            writeTextToClipboard(text)
            onOCRCompleted?(text.count)
        case .permissionRequired:
            onOCRPermissionNeeded?()
        case .cancelledOrEmpty:
            break
        }
    }

    func ocrClipboardImage() async -> Bool {
        guard let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff),
              let text = await VisionTextCapture.recognizeText(in: data) else {
            return false
        }
        writeTextToClipboard(text)
        onOCRCompleted?(text.count)
        return true
    }

    func ocrImageItem(_ item: ShelfItem) async {
        guard let text = await VisionTextCapture.recognizeText(in: item.url) else { return }
        writeTextToClipboard(text)
        onOCRCompleted?(text.count)
    }

    private func writeTextToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastPasteboardChangeCount = pb.changeCount
        captureCurrentPasteboard()
        AppKitHaptics.confirm()
    }

    func toggleStayAwake() {
        setStayAwake(!isStayAwakeEnabled)
        AppKitHaptics.confirm()
    }

    func setStayAwake(_ enabled: Bool) {
        if enabled {
            guard !isStayAwakeEnabled else { return }
            var id: IOPMAssertionID = 0
            let reason = "CleanTrash Stay Awake active" as CFString
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &id
            )
            if result == kIOReturnSuccess {
                sleepAssertionID = id
                isStayAwakeEnabled = true
                stayAwakeSince = .now
            }
        } else {
            if sleepAssertionID != 0 {
                IOPMAssertionRelease(sleepAssertionID)
                sleepAssertionID = 0
            }
            isStayAwakeEnabled = false
            stayAwakeSince = nil
        }
    }

    // MARK: - Live Weather (Open-Meteo + IP geolocation, zero API key)

    private func startWeatherLoop() {
        weatherTask?.cancel()
        weatherTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                if !SystemActivity.isIdle, self.wants(.weather),
                   Date.now.timeIntervalSince(self.lastWeatherFetch) > 20 * 60 {
                    self.lastWeatherFetch = .now
                    await self.refreshWeather()
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refreshWeather() async {
        guard !isLoadingWeather else { return }
        isLoadingWeather = true
        defer { isLoadingWeather = false }

        let fetched = await Task.detached(priority: .utility) {
            await Self.fetchWeatherSnapshot()
        }.value
        if let fetched {
            withAnimation(Mono.betweenSpring) {
                self.weather = fetched
            }
        }
    }

    private nonisolated static func fetchWeatherSnapshot() async -> WeatherSnapshot? {
        struct GeoReply: Decodable {
            let city: String?
            let latitude: Double?
            let longitude: Double?
        }
        struct OpenMeteoReply: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let weather_code: Int
            }
            struct Daily: Decodable {
                let temperature_2m_max: [Double]
                let temperature_2m_min: [Double]
            }
            struct Hourly: Decodable {
                let time: [String]
                let temperature_2m: [Double]
                let weather_code: [Int]
            }
            let current: Current
            let daily: Daily
            let hourly: Hourly
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)

        guard let geoURL = URL(string: "https://ipwho.is/"),
              let (geoData, _) = try? await session.data(from: geoURL),
              let geo = try? JSONDecoder().decode(GeoReply.self, from: geoData),
              let lat = geo.latitude,
              let lon = geo.longitude else {
            return nil
        }

        let city = (geo.city?.isEmpty == false ? geo.city! : "Tu ubicación")
        let meteoString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&hourly=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=2"
        guard let meteoURL = URL(string: meteoString),
              let (meteoData, _) = try? await session.data(from: meteoURL),
              let meteo = try? JSONDecoder().decode(OpenMeteoReply.self, from: meteoData) else {
            return nil
        }

        let cur = meteo.current
        let high = Int((meteo.daily.temperature_2m_max.first ?? cur.temperature_2m).rounded())
        let low = Int((meteo.daily.temperature_2m_min.first ?? cur.temperature_2m).rounded())
        let (cond, sym) = describeWMO(cur.weather_code)

        // Pick the next 4 upcoming hours starting from current local hour.
        let currentHour = Calendar.current.component(.hour, from: .now)
        var points: [HourlyWeatherPoint] = []
        let startIdx = min(max(0, currentHour + 1), max(0, meteo.hourly.time.count - 4))
        for offset in 0..<4 {
            let idx = startIdx + offset
            guard idx < meteo.hourly.time.count,
                  idx < meteo.hourly.temperature_2m.count,
                  idx < meteo.hourly.weather_code.count else { break }
            let rawTime = meteo.hourly.time[idx]
            let hourPart = rawTime.split(separator: "T").last?.prefix(2).description ?? "\(idx % 24)"
            let (_, hSym) = describeWMO(meteo.hourly.weather_code[idx])
            points.append(HourlyWeatherPoint(
                id: offset,
                hourLabel: hourPart,
                tempC: Int(meteo.hourly.temperature_2m[idx].rounded()),
                symbol: hSym
            ))
        }

        return WeatherSnapshot(
            city: city,
            tempC: Int(cur.temperature_2m.rounded()),
            condition: cond,
            symbol: sym,
            highC: high,
            lowC: low,
            hourly: points,
            updatedAt: .now
        )
    }

    private nonisolated static func describeWMO(_ code: Int) -> (String, String) {
        switch code {
        case 0: return ("Despejado", "sun.max.fill")
        case 1, 2: return ("Parcial", "cloud.sun.fill")
        case 3: return ("Nublado", "cloud.fill")
        case 45, 48: return ("Niebla", "cloud.fog.fill")
        case 51...57: return ("Llovizna", "cloud.drizzle.fill")
        case 61...67, 80...82: return ("Lluvia", "cloud.rain.fill")
        case 71...77, 85, 86: return ("Nieve", "cloud.snow.fill")
        case 95...99: return ("Tormenta", "cloud.bolt.rain.fill")
        default: return ("Claro", "sun.max.fill")
        }
    }

    /// Droppy Transform: converts a staged image file to PNG or JPEG right next to it and adds it to the shelf.
    func convertImageItem(_ item: ShelfItem, toPNG: Bool) {
        guard let image = NSImage(contentsOf: item.url),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return }
        let ext = toPNG ? "png" : "jpg"
        let data = toPNG
            ? rep.representation(using: .png, properties: [:])
            : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
        guard let data else { return }
        let stem = item.url.deletingPathExtension().lastPathComponent
        var dest = item.url.deletingLastPathComponent().appendingPathComponent("\(stem)-converted.\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = item.url.deletingLastPathComponent().appendingPathComponent("\(stem)-\(Self.timestampStamp()).\(ext)")
        }
        if (try? data.write(to: dest, options: .atomic)) != nil {
            addFiles([dest])
        }
    }

    // MARK: - File Shelf Operations

    func addFiles(_ urls: [URL]) {
        let fm = FileManager.default
        var added = 0
        for url in urls {
            guard url.isFileURL else { continue }
            let path = url.standardizedFileURL.path
            guard fm.fileExists(atPath: path) else { continue }
            if shelfItems.contains(where: { $0.path == path }) { continue }

            var isDir: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDir)
            let size = Self.quickSize(of: url, isDirectory: isDir.boolValue)
            let item = ShelfItem(
                id: UUID(),
                path: path,
                name: url.lastPathComponent,
                sizeBytes: size,
                isDirectory: isDir.boolValue,
                addedAt: .now
            )
            withAnimation(Mono.betweenSpring) {
                shelfItems.insert(item, at: 0)
            }
            added += 1
        }
        if added > 0 {
            if shelfItems.count > 24 {
                shelfItems = Array(shelfItems.prefix(24))
            }
            saveShelf()
            AppKitHaptics.confirm()
        }
    }

    func removeShelfItem(_ item: ShelfItem) {
        withAnimation(Mono.betweenSpring) {
            shelfItems.removeAll { $0.id == item.id }
        }
        saveShelf()
        AppKitHaptics.tap()
    }

    func clearShelf() {
        withAnimation(Mono.betweenSpring) {
            shelfItems.removeAll()
        }
        saveShelf()
        AppKitHaptics.tap()
    }

    func revealInFinder(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copyPath(_ item: ShelfItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.path, forType: .string)
        lastPasteboardChangeCount = pb.changeCount
        AppKitHaptics.tap()
    }

    /// Compresses the shelf items into a single `.zip` next to the first item (or Desktop) and stages it.
    func zipShelfItems(_ items: [ShelfItem]) async -> URL? {
        let valid = items.filter(\.exists)
        guard !valid.isEmpty else { return nil }

        let baseDir = valid.first!.url.deletingLastPathComponent()
        let stem = valid.count == 1
            ? valid[0].url.deletingPathExtension().lastPathComponent
            : "Bandeja-\(Self.timestampStamp())"
        var dest = baseDir.appendingPathComponent("\(stem).zip")
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = baseDir.appendingPathComponent("\(stem)-\(Self.timestampStamp()).zip")
        }

        let paths = valid.map(\.path)
        let destPath = dest.path
        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            if paths.count == 1 {
                process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", paths[0], destPath]
            } else {
                // Stage copies in a temp dir so ditto packs multiple files cleanly.
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ct-zip-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDir) }
                for p in paths {
                    let src = URL(fileURLWithPath: p)
                    let dst = tempDir.appendingPathComponent(src.lastPathComponent)
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
                process.arguments = ["-c", "-k", "--sequesterRsrc", tempDir.path, destPath]
            }
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value

        guard ok else { return nil }
        addFiles([dest])
        return dest
    }

    func shareShelfItems(_ items: [ShelfItem], from view: NSView? = nil) {
        let urls = items.filter(\.exists).map(\.url)
        guard !urls.isEmpty else { return }
        if let pickerView = view ?? NSApp.keyWindow?.contentView {
            let picker = NSSharingServicePicker(items: urls)
            picker.show(relativeTo: CGRect(x: pickerView.bounds.midX, y: pickerView.bounds.midY, width: 1, height: 1),
                        of: pickerView,
                        preferredEdge: .minY)
        } else if let airdrop = NSSharingService(named: .sendViaAirDrop) {
            airdrop.perform(withItems: urls)
        }
    }

    private func loadShelf() {
        guard let data = try? Data(contentsOf: shelfStorageURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        shelfItems = decoded.filter(\.exists)
    }

    private func saveShelf() {
        try? FileManager.default.createDirectory(at: shelfStorageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(shelfItems) {
            try? data.write(to: shelfStorageURL, options: .atomic)
        }
    }

    private static func quickSize(of url: URL, isDirectory: Bool) -> UInt64 {
        if !isDirectory {
            return UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? UInt64) ?? 0
    }

    private static func timestampStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f.string(from: .now)
    }

    // MARK: - Clipboard Monitor

    private func startClipboardMonitor() {
        clipboardTask?.cancel()
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        // Seed current pasteboard item once if present.
        captureCurrentPasteboard()

        clipboardTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard let self, self.clipboardEnabled, !SystemActivity.isIdle else { continue }
                let count = NSPasteboard.general.changeCount
                if count != self.lastPasteboardChangeCount {
                    self.lastPasteboardChangeCount = count
                    self.captureCurrentPasteboard()
                }
            }
        }
    }

    private func captureCurrentPasteboard() {
        let pb = NSPasteboard.general
        let rawTypes = Set((pb.types ?? []).map(\.rawValue))
        // Never store passwords or transient secrets from 1Password / Keychain.
        if !rawTypes.isDisjoint(with: Self.concealedTypes) { return }

        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            // Avoid duplicates at top
            if let existingIdx = clipboardEntries.firstIndex(where: { $0.fullText == text }) {
                var item = clipboardEntries.remove(at: existingIdx)
                item = ClipboardEntry(
                    id: item.id, kind: item.kind, previewText: item.previewText,
                    fullText: item.fullText, hexColor: item.hexColor, imageData: nil,
                    imageDimensions: nil, timestamp: .now, isPinned: item.isPinned
                )
                clipboardEntries.insert(item, at: 0)
                return
            }

            let kind: ClipboardEntryKind
            var hex: String?
            if let detectedHex = Self.detectHexColor(text) {
                kind = .color
                hex = detectedHex
            } else if Self.isLikelyURL(text) {
                kind = .url
            } else {
                kind = .text
            }

            let preview = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            let entry = ClipboardEntry(
                id: UUID(),
                kind: kind,
                previewText: String(preview.prefix(160)),
                fullText: String(text.prefix(16_000)),
                hexColor: hex,
                imageData: nil,
                imageDimensions: nil,
                timestamp: .now,
                isPinned: false
            )
            insertClipboard(entry)
            return
        }

        // Capture copied screenshots / images (capped at 6 MB PNG thumbnail)
        if let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]),
           png.count <= 6_000_000 {
            let dims = "\(rep.pixelsWide)×\(rep.pixelsHigh)"
            if let first = clipboardEntries.first, first.kind == .image, first.imageData?.count == png.count {
                return
            }
            let entry = ClipboardEntry(
                id: UUID(),
                kind: .image,
                previewText: "Imagen · \(dims)",
                fullText: nil,
                hexColor: nil,
                imageData: png,
                imageDimensions: dims,
                timestamp: .now,
                isPinned: false
            )
            insertClipboard(entry)
        }
    }

    private func insertClipboard(_ entry: ClipboardEntry) {
        withAnimation(Mono.betweenSpring) {
            clipboardEntries.insert(entry, at: 0)
            trimClipboard()
        }
    }

    private func trimClipboard() {
        let pinned = clipboardEntries.filter(\.isPinned)
        let unpinned = clipboardEntries.filter { !$0.isPinned }
        if unpinned.count > 35 {
            clipboardEntries = pinned + Array(unpinned.prefix(35))
        }
    }

    func copyBack(_ entry: ClipboardEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let text = entry.fullText {
            pb.setString(text, forType: .string)
        } else if let data = entry.imageData, let img = NSImage(data: data) {
            pb.writeObjects([img])
        }
        lastPasteboardChangeCount = pb.changeCount
        AppKitHaptics.tap()
        withAnimation(Mono.fast) { lastCopiedEntryID = entry.id }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            if self?.lastCopiedEntryID == entry.id {
                withAnimation(Mono.fast) { self?.lastCopiedEntryID = nil }
            }
        }
    }

    func togglePin(_ entry: ClipboardEntry) {
        guard let idx = clipboardEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        withAnimation(Mono.betweenSpring) {
            clipboardEntries[idx].isPinned.toggle()
        }
        AppKitHaptics.tap()
    }

    func removeClipboard(_ entry: ClipboardEntry) {
        withAnimation(Mono.betweenSpring) {
            clipboardEntries.removeAll { $0.id == entry.id }
        }
    }

    func clearUnpinnedClipboard() {
        withAnimation(Mono.betweenSpring) {
            clipboardEntries.removeAll { !$0.isPinned }
        }
        AppKitHaptics.tap()
    }

    var sortedClipboardEntries: [ClipboardEntry] {
        let pinned = clipboardEntries.filter(\.isPinned)
        let regular = clipboardEntries.filter { !$0.isPinned }
        return pinned + regular
    }

    static func detectHexColor(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 7 || trimmed.count == 4, trimmed.hasPrefix("#") else { return nil }
        let hexPart = trimmed.dropFirst()
        guard hexPart.allSatisfy({ $0.isHexDigit }) else { return nil }
        if hexPart.count == 3 {
            let expanded = hexPart.map { "\($0)\($0)" }.joined()
            return "#\(expanded.uppercased())"
        }
        return trimmed.uppercased()
    }

    private static func isLikelyURL(_ text: String) -> Bool {
        guard !text.contains("\n"), !text.contains(" "),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return url.host != nil
    }

    // MARK: - Focus / Pomodoro Timer

    var timerProgress: Double {
        guard timerTotalSeconds > 0 else { return 0 }
        return 1.0 - (Double(timerRemainingSeconds) / Double(timerTotalSeconds))
    }

    var timerFormatted: String {
        let mins = timerRemainingSeconds / 60
        let secs = timerRemainingSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var hasActiveTimer: Bool {
        isTimerRunning || (timerRemainingSeconds > 0 && timerRemainingSeconds < timerTotalSeconds)
    }

    func startPreset(_ preset: FocusPreset) {
        timerLabel = preset.label
        timerTotalSeconds = preset.minutes * 60
        timerRemainingSeconds = preset.minutes * 60
        startTimerLoop()
        AppKitHaptics.confirm()
    }

    func toggleTimer() {
        if isTimerRunning {
            pauseTimer()
        } else {
            if timerRemainingSeconds <= 0 {
                timerRemainingSeconds = timerTotalSeconds
            }
            startTimerLoop()
        }
        AppKitHaptics.tap()
    }

    func pauseTimer() {
        isTimerRunning = false
        timerTask?.cancel()
    }

    func resetTimer() {
        pauseTimer()
        timerRemainingSeconds = timerTotalSeconds
        AppKitHaptics.tap()
    }

    func adjustTimer(byMinutes delta: Int) {
        let next = min(120 * 60, max(60, timerRemainingSeconds + delta * 60))
        timerRemainingSeconds = next
        if next > timerTotalSeconds || !isTimerRunning {
            timerTotalSeconds = max(timerTotalSeconds, next)
        }
        AppKitHaptics.tap()
    }

    private func startTimerLoop() {
        timerTask?.cancel()
        isTimerRunning = true
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isTimerRunning else { break }
                if self.timerRemainingSeconds > 1 {
                    self.timerRemainingSeconds -= 1
                } else {
                    self.timerRemainingSeconds = 0
                    self.isTimerRunning = false
                    NSSound(named: "Glass")?.play()
                    AppKitHaptics.confirm()
                    self.onTimerFinished?(self.timerLabel)
                    break
                }
            }
        }
    }
}
