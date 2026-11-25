import AppKit
import AudioToolbox
import CleanTrashCore
import CoreAudio
import EventKit
import Foundation
import SwiftUI
import Vision

// MARK: - Multi-Device Battery Reader (Mac + AirPods / Mouse / Keyboard)

struct DeviceBatteryInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let percent: Int
    let symbol: String
    let isCharging: Bool
}

enum BluetoothBatteryReader {
    /// Reads connected Bluetooth HID & audio accessories (Magic Mouse, Keyboard, Trackpad, AirPods)
    /// directly from IOKit registry without blocking the main thread.
    static func readConnectedAccessories() -> [DeviceBatteryInfo] {
        var devices: [DeviceBatteryInfo] = []
        var seen = Set<String>()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-c", "AppleDeviceManagementHIDEventService", "-l"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let text = String(data: data, encoding: .utf8) {
                let blocks = text.components(separatedBy: "+-o ")
                for block in blocks {
                    guard let pct = extractInt(key: "\"BatteryPercent\" = ", in: block),
                          pct >= 0 && pct <= 100 else { continue }
                    let name = extractString(key: "\"Product\" = \"", in: block) ?? "Accesorio"
                    guard !seen.contains(name) else { continue }
                    seen.insert(name)
                    devices.append(DeviceBatteryInfo(
                        id: "hid:\(name)",
                        name: shortName(name),
                        percent: pct,
                        symbol: symbolForDevice(name),
                        isCharging: false
                    ))
                }
            }
        }

        // Also check AirPods / Bluetooth headsets via defaults read of Apple's Bluetooth cache if present
        let btProc = Process()
        btProc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        btProc.arguments = ["SPBluetoothDataType", "-json"]
        let btPipe = Pipe()
        btProc.standardOutput = btPipe
        btProc.standardError = Pipe()
        if (try? btProc.run()) != nil {
            let data = btPipe.fileHandleForReading.readDataToEndOfFile()
            btProc.waitUntilExit()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["SPBluetoothDataType"] as? [[String: Any]] {
                for entry in list {
                    guard let connected = entry["device_connected"] as? [[String: Any]] else { continue }
                    for devDict in connected {
                        for (devName, rawProps) in devDict {
                            guard let props = rawProps as? [String: Any] else { continue }
                            let keys = ["device_batteryLevelMain", "device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevelCase"]
                            var bestPct: Int?
                            for k in keys {
                                if let str = props[k] as? String {
                                    let digits = str.filter(\.isNumber)
                                    if let val = Int(digits) { bestPct = val; break }
                                }
                            }
                            guard let pct = bestPct, !seen.contains(devName) else { continue }
                            seen.insert(devName)
                            devices.append(DeviceBatteryInfo(
                                id: "bt:\(devName)",
                                name: shortName(devName),
                                percent: min(100, max(0, pct)),
                                symbol: symbolForDevice(devName),
                                isCharging: false
                            ))
                        }
                    }
                }
            }
        }

        // Also detect connected iPhone / iPad via USB (`ioreg` + optional `ideviceinfo`)
        let usbProc = Process()
        usbProc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        usbProc.arguments = ["SPUSBDataType", "-json"]
        let usbPipe = Pipe()
        usbProc.standardOutput = usbPipe
        usbProc.standardError = Pipe()
        if (try? usbProc.run()) != nil {
            let data = usbPipe.fileHandleForReading.readDataToEndOfFile()
            usbProc.waitUntilExit()
            if let text = String(data: data, encoding: .utf8),
               (text.contains("\"iPhone\"") || text.contains("\"iPad\"")) {
                // If libimobiledevice (`ideviceinfo`) is installed via Homebrew, read exact battery %!
                for candidateBin in ["/opt/homebrew/bin/ideviceinfo", "/usr/local/bin/ideviceinfo"] where FileManager.default.isExecutableFile(atPath: candidateBin) {
                    let infoProc = Process()
                    infoProc.executableURL = URL(fileURLWithPath: candidateBin)
                    infoProc.arguments = ["-q", "com.apple.mobile.battery"]
                    let infoPipe = Pipe()
                    infoProc.standardOutput = infoPipe
                    infoProc.standardError = Pipe()
                    if (try? infoProc.run()) != nil {
                        let out = infoPipe.fileHandleForReading.readDataToEndOfFile()
                        infoProc.waitUntilExit()
                        if let outStr = String(data: out, encoding: .utf8),
                           let pct = extractLineInt(prefix: "BatteryCurrentCapacity:", in: outStr) {
                            let isIPad = text.contains("\"iPad\"") && !text.contains("\"iPhone\"")
                            let devName = isIPad ? "iPad" : "iPhone"
                            let charging = outStr.contains("BatteryIsCharging: true")
                            if !seen.contains(devName) {
                                seen.insert(devName)
                                devices.append(DeviceBatteryInfo(
                                    id: "ios:\(devName)",
                                    name: devName,
                                    percent: min(100, max(0, pct)),
                                    symbol: isIPad ? "ipad" : "iphone",
                                    isCharging: charging
                                ))
                            }
                        }
                    }
                    break
                }
            }
        }

        return devices
    }

    private static func extractLineInt(prefix: String, in text: String) -> Int? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                let digits = trimmed.dropFirst(prefix.count).filter(\.isNumber)
                return Int(digits)
            }
        }
        return nil
    }

    private static func extractInt(key: String, in text: String) -> Int? {
        guard let r = text.range(of: key) else { return nil }
        let tail = text[r.upperBound...]
        let num = tail.prefix { $0.isNumber }
        return Int(num)
    }

    private static func extractString(key: String, in text: String) -> String? {
        guard let r = text.range(of: key) else { return nil }
        let tail = text[r.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
    }

    private static func shortName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "Apple ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func symbolForDevice(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("mouse") { return "magicmouse.fill" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left.filled" }
        if lower.contains("keyboard") || lower.contains("teclado") { return "keyboard.fill" }
        if lower.contains("beats") || lower.contains("headphone") || lower.contains("sony") || lower.contains("bose") {
            return "headphones"
        }
        return "dot.radiowaves.left.and.right"
    }
}

// MARK: - On-Device Vision OCR Text Capture (Droppy Text Capture)

enum OCRCaptureOutcome: Sendable {
    case captured(String)
    case permissionRequired
    case cancelledOrEmpty
}

enum VisionTextCapture {
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Launches macOS interactive screen region capture (`screencapture -i -x`) and runs
    /// Apple's on-device Vision OCR (`VNRecognizeTextRequest`) on the captured area.
    /// Checks `CGPreflightScreenCaptureAccess()` first so we can explain macOS's generic
    /// Screen Recording prompt cleanly (CleanTrash never records audio or sends pixels anywhere).
    static func captureScreenArea() async -> OCRCaptureOutcome {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            return .permissionRequired
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let captured = await Task.detached(priority: .userInitiated) { () -> Bool in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", tmp.path]
            do {
                try p.run()
                p.waitUntilExit()
                return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: tmp.path)
            } catch {
                return false
            }
        }.value

        guard captured else { return .cancelledOrEmpty }
        if let text = await recognizeText(in: tmp) {
            return .captured(text)
        }
        return .cancelledOrEmpty
    }

    static func recognizeText(in imageURL: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            guard let nsImage = NSImage(contentsOf: imageURL) else { return nil }
            return Self.recognizeTextSync(in: nsImage)
        }.value
    }

    /// Zero-permission Vision OCR directly from an in-memory `NSImage` (e.g. macOS ⌘⇧⌃4 clipboard screenshot).
    static func recognizeText(in imageData: Data) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            guard let nsImage = NSImage(data: imageData) else { return nil }
            return Self.recognizeTextSync(in: nsImage)
        }.value
    }

    private nonisolated static func recognizeTextSync(in nsImage: NSImage) -> String? {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["es-ES", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        } catch {
            return nil
        }
    }
}

// MARK: - Native EventKit Calendar Reader (Droppy Calendar Widget)

struct CalendarEventItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let timeRange: String
    let isAllDay: Bool
    let colorHex: UInt32
}

@MainActor
final class CalendarReader {
    private let store = EKEventStore()

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    func fetchTodayEvents() -> [CalendarEventItem] {
        guard isAuthorized else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: .now)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"

        return events.prefix(5).map { ev in
            let range = ev.isAllDay ? "Todo el día" : "\(fmt.string(from: ev.startDate)) – \(fmt.string(from: ev.endDate))"
            let hex = Self.hexColor(from: ev.calendar.cgColor)
            return CalendarEventItem(
                id: ev.eventIdentifier ?? UUID().uuidString,
                title: ev.title ?? "Evento",
                timeRange: range,
                isAllDay: ev.isAllDay,
                colorHex: hex
            )
        }
    }

    private static func hexColor(from cgColor: CGColor?) -> UInt32 {
        guard let cgColor,
              let rgb = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
            return 0x60A5FA
        }
        let r = UInt32(max(0, min(255, rgb.redComponent * 255)))
        let g = UInt32(max(0, min(255, rgb.greenComponent * 255)))
        let b = UInt32(max(0, min(255, rgb.blueComponent * 255)))
        return (r << 16) | (g << 8) | b
    }
}

// MARK: - Native CoreAudio Master Volume & Output Device Controller

enum SystemAudioController {
    static func defaultOutputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    static func outputDeviceName() -> String {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != 0 else { return "Altavoces" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
        guard status == noErr, let name = cfName?.takeRetainedValue() as String? else {
            return "Salida de audio"
        }
        return name
    }

    static func masterVolumePercent() -> Int {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != 0 else { return 50 }
        var vol: Float32 = 0.5
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &vol) == noErr {
            return Int((vol * 100).rounded())
        }
        return 50
    }

    static func setMasterVolumePercent(_ percent: Int) {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != 0 else { return }
        var vol = Float32(min(100, max(0, percent))) / 100.0
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
    }

    static func isMuted() -> Bool {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != 0 else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        return false
    }

    static func setMuted(_ mute: Bool) {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != 0 else { return }
        var value: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
    }

    /// Detects if macOS default audio input (microphone) is actively running (e.g. Zoom, Meet, FaceTime)
    /// so Breather automatically pauses break cards during calls!
    static func isMicrophoneActive() -> Bool {
        var inputID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultInAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInAddr, 0, nil, &size, &inputID) == noErr,
              inputID != 0 else {
            return false
        }
        var running: UInt32 = 0
        var runSize = UInt32(MemoryLayout<UInt32>.size)
        var runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(inputID, &runAddr, 0, nil, &runSize, &running) == noErr {
            return running != 0
        }
        return false
    }
}

// MARK: - Droppy Floating Desktop Mini-Player (Adaptive · Track Gradient · Native Draggable)

private enum FloatingPlayerSizeMode: CaseIterable {
    case mini
    case player
    case expanded

    var cardWidth: CGFloat {
        switch self {
        case .mini: return 324
        case .player: return 392
        case .expanded: return 406
        }
    }

    func cardHeight(hasSyncedLyrics: Bool, hasCurrentLyric: Bool) -> CGFloat {
        switch self {
        case .mini:
            return 68
        case .player:
            return hasCurrentLyric ? 196 : 168
        case .expanded:
            return hasSyncedLyrics ? 356 : 226
        }
    }

    func panelSize(hasSyncedLyrics: Bool, hasCurrentLyric: Bool) -> NSSize {
        NSSize(
            width: cardWidth + 36,
            height: cardHeight(hasSyncedLyrics: hasSyncedLyrics, hasCurrentLyric: hasCurrentLyric) + 36
        )
    }

    var next: FloatingPlayerSizeMode {
        switch self {
        case .mini: return .player
        case .player: return .expanded
        case .expanded: return .mini
        }
    }

    var symbol: String {
        switch self {
        case .mini: return "rectangle.expand.vertical"
        case .player: return "text.quote"
        case .expanded: return "rectangle.compress.vertical"
        }
    }

    var helpText: String {
        switch self {
        case .mini: return "Expandir a Reproductor"
        case .player: return "Expandir con Letras sincronizadas"
        case .expanded: return "Compactar a Mini"
        }
    }
}

/// Native AppKit drag layer placed behind buttons so borderless `.nonactivatingPanel` windows
/// drag smoothly from anywhere on the card background (even with SwiftUI materials/glass).
private struct FloatingPanelDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> DragSurfaceNSView {
        DragSurfaceNSView()
    }

    func updateNSView(_ nsView: DragSurfaceNSView, context: Context) {}

    final class DragSurfaceNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

@MainActor
final class FloatingPlayerWindowController {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(media: MediaPlayerController, surface: NotchSurfaceMode) {
        if let existing = panel, existing.isVisible {
            existing.orderOut(nil)
            return
        }
        show(media: media, surface: surface)
    }

    func show(media: MediaPlayerController, surface: NotchSurfaceMode) {
        if let existing = panel {
            existing.orderFrontRegardless()
            return
        }

        let hasSynced = media.lyrics?.syncedLines.isEmpty == false
        let hasLine = media.currentLyricLine != nil
        let initialSize = FloatingPlayerSizeMode.player.panelSize(hasSyncedLyrics: hasSynced, hasCurrentLyric: hasLine)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        // Never use NSWindow's rectangular shadow on rounded glass panels (draws ugly square corners).
        p.hasShadow = false
        p.isMovable = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.maxX - initialSize.width - 14, y: vf.minY + 18))
        }

        let content = FloatingMiniPlayerView(
            media: media,
            surface: surface,
            onResize: { [weak p] newSize in
                guard let p else { return }
                var frame = p.frame
                let deltaH = newSize.height - frame.height
                let deltaW = newSize.width - frame.width
                // Keep top-right edge anchored smoothly while staying inside screen visibleFrame
                frame.origin.y -= deltaH
                frame.origin.x -= deltaW * 0.5
                frame.size = newSize
                if let vf = (p.screen ?? NSScreen.main)?.visibleFrame {
                    frame.origin.x = min(max(frame.origin.x, vf.minX - 10), vf.maxX - frame.width + 10)
                    frame.origin.y = min(max(frame.origin.y, vf.minY - 10), vf.maxY - frame.height + 10)
                }
                p.setFrame(frame, display: true, animate: true)
            },
            onClose: { [weak p] in
                p?.orderOut(nil)
            }
        )
        let hosting = NSHostingView(rootView: content)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = hosting
        p.orderFrontRegardless()
        self.panel = p
    }
}

private struct FloatingMiniPlayerView: View {
    @Bindable var media: MediaPlayerController
    let surface: NotchSurfaceMode
    let onResize: (NSSize) -> Void
    let onClose: () -> Void

    @State private var mode: FloatingPlayerSizeMode = .player
    @State private var hoverScrubFraction: Double?

    private var accent: Color { media.palette.primary }
    private var secondary: Color { media.palette.secondary }
    private var hasSyncedLyrics: Bool { media.lyrics?.syncedLines.isEmpty == false }
    private var hasCurrentLyric: Bool { media.currentLyricLine != nil }

    private var cardWidth: CGFloat { mode.cardWidth }
    private var cardHeight: CGFloat {
        mode.cardHeight(hasSyncedLyrics: hasSyncedLyrics, hasCurrentLyric: hasCurrentLyric)
    }
    private var panelSize: NSSize {
        mode.panelSize(hasSyncedLyrics: hasSyncedLyrics, hasCurrentLyric: hasCurrentLyric)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        ZStack {
            // Track artwork-derived ambient gradient backdrop (smoothly adapts to every song!)
            ZStack {
                Color(hex: 0x090A0F).opacity(surface.isGlass ? 0.72 : 0.92)

                LinearGradient(
                    colors: [
                        accent.opacity(0.50),
                        secondary.opacity(0.32),
                        Color(hex: 0x08090D).opacity(0.84)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [accent.opacity(0.36), .clear],
                    center: UnitPoint(x: 0.16, y: 0.18),
                    startRadius: 8,
                    endRadius: 220
                )

                RadialGradient(
                    colors: [secondary.opacity(0.24), .clear],
                    center: UnitPoint(x: 0.88, y: 0.86),
                    startRadius: 6,
                    endRadius: 200
                )
            }
            .animation(.easeInOut(duration: 0.55), value: media.track?.id)

            // Full-card native AppKit drag surface behind interactive controls
            FloatingPanelDragSurface()

            // Foreground player layout
            VStack(spacing: 0) {
                switch mode {
                case .mini:
                    miniContent
                case .player:
                    playerContent(includeLyrics: false)
                case .expanded:
                    playerContent(includeLyrics: true)
                }
            }
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .top)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.28), accent.opacity(0.28), Color.white.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.42), radius: 16, y: 8)
        .shadow(color: accent.opacity(0.20), radius: 20, y: 4)
        .padding(18)
        .frame(width: panelSize.width, height: panelSize.height)
        .environment(\.colorScheme, .dark)
        .environment(\.notchSurface, surface)
        .onChange(of: panelSize) { _, newSize in
            onResize(newSize)
        }
    }

    // MARK: - Compact Mini Mode

    private var miniContent: some View {
        HStack(spacing: 10) {
            artworkView(size: 44, radius: 11)

            VStack(alignment: .leading, spacing: 2) {
                Text(media.track?.title ?? "Sin música")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(media.currentLyricLine ?? media.track?.artist ?? "Spotify / Música")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            Button { media.nextTrack() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            windowChromeButtons
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Player & Expanded Lyrics Modes (Zero Overlap, Zero Clipping!)

    private func playerContent(includeLyrics: Bool) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            // Top Row: Artwork + Title + [L] + Visualizer + Clean Non-Overlapping Window Controls
            HStack(alignment: .center, spacing: 11) {
                artworkView(size: 52, radius: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Button { media.openTrackInPlayer() } label: {
                        Text(media.track?.title ?? "Sin música")
                            .font(.system(size: 15.5, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()

                    Button { media.openArtistInPlayer() } label: {
                        Text(media.track?.artist ?? "Abre Spotify o Apple Music")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }

                Spacer(minLength: 4)

                AudioVisualizerBars(
                    isPlaying: media.isPlaying,
                    color: accent,
                    secondaryColor: secondary,
                    barCount: 4,
                    maxHeight: 14,
                    barWidth: 2.2
                )

                windowChromeButtons
            }

            // Scrubber Row (full horizontal padding so timestamps NEVER clip!)
            if let track = media.track {
                scrubberRow(track)
            }

            // Centered Transport Controls
            HStack(spacing: 0) {
                Button { media.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(media.isShuffling ? accent : .white.opacity(0.5))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Spacer()

                HStack(spacing: 24) {
                    Button { media.previousTrack() } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()

                    Button { media.togglePlayPause() } label: {
                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: media.isPlaying ? 0 : 1.5)
                            .frame(width: 38, height: 36)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()

                    Button { media.nextTrack() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }

                Spacer()

                HStack(spacing: 6) {
                    Button { media.toggleRepeat() } label: {
                        Image(systemName: "repeat")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(media.isRepeating ? accent : .white.opacity(0.5))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()

                    Button { media.openPlayerApp() } label: {
                        Image(systemName: "macbook")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }

            if includeLyrics {
                Divider().overlay(Color.white.opacity(0.12))
                expandedLyricsList
            } else if let line = media.currentLyricLine {
                HStack(spacing: 6) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 9))
                        .foregroundStyle(accent.opacity(0.9))
                    Text(line)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var expandedLyricsList: some View {
        Group {
            if let doc = media.lyrics, !doc.syncedLines.isEmpty {
                let activeIdx = media.activeLyricIndex
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(doc.syncedLines.enumerated()), id: \.offset) { idx, line in
                                let isActive = idx == activeIdx
                                Button { media.seek(to: line.time) } label: {
                                    Text(line.text)
                                        .font(.system(size: isActive ? 14 : 12, weight: isActive ? .bold : .medium))
                                        .foregroundStyle(isActive ? .white : .white.opacity(0.45))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                .id(idx)
                            }
                        }
                    }
                    .onChange(of: activeIdx) { _, newIdx in
                        guard let newIdx else { return }
                        withAnimation(Mono.betweenSpring) {
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
            } else {
                Text("Sin letras sincronizadas para esta canción")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var windowChromeButtons: some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(Mono.openingSpring) { mode = mode.next }
            } label: {
                Image(systemName: mode.symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.11)))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(mode.helpText)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Cerrar mini-reproductor")
        }
    }

    private func artworkView(size: CGFloat, radius: CGFloat) -> some View {
        ZStack {
            if let art = media.artwork {
                Image(nsImage: art)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.38, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
        )
    }

    private func scrubberRow(_ track: NowPlayingTrack) -> some View {
        let frac = hoverScrubFraction ?? media.progress
        let elapsed = media.isScrubbing ? media.scrubPreviewPosition : media.effectivePosition
        let remaining = max(0, track.duration - elapsed)

        return HStack(spacing: 8) {
            Text(formatTime(elapsed))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.58))
                .frame(width: 34, alignment: .leading)

            GeometryReader { geo in
                let w = max(1, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16)).frame(height: 6)
                    Capsule().fill(Color.white.opacity(0.84)).frame(width: max(6, w * frac), height: 6)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let p = min(1, max(0, v.location.x / w))
                            media.isScrubbing = true
                            media.scrubPreviewPosition = p * track.duration
                            hoverScrubFraction = p
                        }
                        .onEnded { v in
                            let p = min(1, max(0, v.location.x / w))
                            hoverScrubFraction = nil
                            media.seek(to: p * track.duration)
                        }
                )
            }
            .frame(height: 14)
            .pointingHandCursor()

            Text("-\(formatTime(remaining))")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.58))
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
