import AppKit
import AudioToolbox
import CleanTrashCore
import CoreAudio
import SwiftUI
import os

private let hudLog = Logger(subsystem: "com.cleantrash.mac", category: "hud")

/// Last key-takeover state, readable outside the app (`hud-status.txt` in Application Support).
private func writeHUDStatus(_ text: String) {
    hudLog.notice("\(text, privacy: .public)")
    let url = AgentBridgePaths.supportDirectory.appendingPathComponent("hud-status.txt")
    try? "\(Date.now.ISO8601Format()) \(text)\n".write(to: url, atomically: true, encoding: .utf8)
}

/// Volume / brightness change shown in the notch instead of (or next to) the macOS overlay.
struct SystemHUDEvent: Equatable {
    enum Kind: Equatable { case volume, brightness }

    var kind: Kind
    /// 0…1
    var value: Double
    var muted = false
    var id = UUID()

    var title: String {
        switch kind {
        case .volume: return muted ? "Silencio" : "Volumen"
        case .brightness: return "Brillo"
        }
    }

    var symbol: String {
        switch kind {
        case .volume:
            if muted || value <= 0.001 { return "speaker.slash.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return value < 0.35 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    /// Wash on the right side of the notch, fading toward the camera.
    var colors: [Color] {
        switch kind {
        case .volume: return [Mono.infoAccent, Mono.cpuAccent, Color(hex: 0xC084FC)]
        case .brightness: return [Color(hex: 0xFDE68A), Mono.caution, Color(hex: 0xF97316)]
        }
    }
}

/// Watches system volume (CoreAudio) and built-in display brightness (DisplayServices) and, when
/// Accessibility is granted, takes over the volume/brightness keys so the notch replaces the macOS overlay.
@MainActor
@Observable
final class SystemHUDMonitor {
    private(set) var current: SystemHUDEvent?
    /// The keys are routed through CleanTrash (system overlay suppressed).
    private(set) var isReplacingSystemHUD = false

    /// Mirrors the "HUD de sistema en el Notch" setting.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { installKeyTap() } else { removeKeyTap(); current = nil }
        }
    }

    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var outputDevice = AudioDeviceID(0)
    @ObservationIgnored private var volumeBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var lastVolume: Double = -1
    @ObservationIgnored private var lastMuted = false
    @ObservationIgnored private var lastBrightness: Double = -1
    @ObservationIgnored private var brightnessKeyAt = Date.distantPast
    @ObservationIgnored private var keyTap: CFMachPort?
    @ObservationIgnored private var keyTapSource: CFRunLoopSource?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var started = false

    nonisolated(unsafe) fileprivate static weak var shared: SystemHUDMonitor?

    func start() {
        guard !started else { return }
        started = true
        Self.shared = self
        watchDefaultOutputDevice()
        attachVolumeListener()
        watchBrightness()
        // Brightness keys are a hint that a brightness change came from the user, not auto-brightness.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { event in
            guard let key = MediaKey(event: event), key.isBrightness else { return }
            MainActor.assumeIsolated { SystemHUDMonitor.shared?.brightnessKeyAt = .now }
        }
        if isEnabled { installKeyTap() }
        // Accessibility is often granted later from System Settings: pick the keys up once it is.
        Task { @MainActor [weak self] in
            while let self, self.keyTap == nil {
                try? await Task.sleep(for: .seconds(5))
                self.refreshKeyTap()
            }
        }
    }

    /// Retries the key takeover (called after the user grants Accessibility).
    func refreshKeyTap() {
        guard isEnabled, keyTap == nil else { return }
        installKeyTap()
    }

    // MARK: Presenting

    private func present(_ event: SystemHUDEvent) {
        guard isEnabled else { return }
        withAnimation(Mono.betweenSpring) { current = event }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            withAnimation(Mono.foldingSpring) { self?.current = nil }
        }
    }

    // MARK: Volume

    private func watchDefaultOutputDevice() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { SystemHUDMonitor.shared?.attachVolumeListener() }
        }
        deviceBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    private func attachVolumeListener() {
        if let block = volumeBlock, outputDevice != 0 {
            for var address in Self.volumeAddresses {
                AudioObjectRemovePropertyListenerBlock(outputDevice, &address, .main, block)
            }
        }
        outputDevice = SystemAudioController.defaultOutputDeviceID()
        guard outputDevice != 0 else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { SystemHUDMonitor.shared?.volumeChanged() }
        }
        volumeBlock = block
        for var address in Self.volumeAddresses where AudioObjectHasProperty(outputDevice, &address) {
            AudioObjectAddPropertyListenerBlock(outputDevice, &address, .main, block)
        }
        lastVolume = readVolume() ?? -1
        lastMuted = SystemAudioController.isMuted()
    }

    private static var volumeAddresses: [AudioObjectPropertyAddress] {
        [
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
        ]
    }

    private func readVolume() -> Double? {
        var address = Self.volumeAddresses[0]
        guard outputDevice != 0, AudioObjectHasProperty(outputDevice, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(outputDevice, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return Double(volume)
    }

    private func setVolume(_ value: Double) -> Bool {
        var address = Self.volumeAddresses[0]
        var settable: DarwinBoolean = false
        guard outputDevice != 0, AudioObjectHasProperty(outputDevice, &address),
              AudioObjectIsPropertySettable(outputDevice, &address, &settable) == noErr, settable.boolValue else { return false }
        var volume = Float32(min(1, max(0, value)))
        return AudioObjectSetPropertyData(outputDevice, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume) == noErr
    }

    private func volumeChanged() {
        guard let volume = readVolume() else { return }
        let muted = SystemAudioController.isMuted()
        defer { lastVolume = volume; lastMuted = muted }
        guard lastVolume >= 0, abs(volume - lastVolume) > 0.001 || muted != lastMuted else { return }
        present(SystemHUDEvent(kind: .volume, value: volume, muted: muted))
    }

    // MARK: Brightness

    private func watchBrightness() {
        guard let register = DisplayServices.registerForChanges else { return }
        let display = DisplayServices.builtInDisplay
        lastBrightness = DisplayServices.brightness(display) ?? -1
        _ = register(display, nil, { _, _, _, _, info in
            let raw = (info as NSDictionary?)?["value"]
            let value = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init)
            guard let value else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { SystemHUDMonitor.shared?.brightnessChanged(value) }
            }
        })
    }

    private func brightnessChanged(_ value: Double) {
        defer { lastBrightness = value }
        guard lastBrightness >= 0 else { return }
        let delta = abs(value - lastBrightness)
        // Auto-brightness drifts in tiny steps; a key press (or an open HUD) means the user is changing it.
        let fromUser = Date.now.timeIntervalSince(brightnessKeyAt) < 0.8 || current?.kind == .brightness || delta >= 0.03
        guard delta > 0.001, fromUser else { return }
        present(SystemHUDEvent(kind: .brightness, value: value))
    }

    // MARK: Key takeover

    private func installKeyTap() {
        guard keyTap == nil else { return }
        guard AXIsProcessTrusted() else {
            writeHUDStatus("Accessibility not granted: macOS keeps its own volume/brightness overlay")
            isReplacingSystemHUD = false
            requestAccessibilityOnce()
            return
        }
        let mask = CGEventMask(1 << 14) // NSEventTypeSystemDefined
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated {
                        if let tap = SystemHUDMonitor.shared?.keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard let nsEvent = NSEvent(cgEvent: event), let key = MediaKey(event: nsEvent) else {
                    return Unmanaged.passUnretained(event)
                }
                let handled = MainActor.assumeIsolated { SystemHUDMonitor.shared?.handle(key) ?? false }
                return handled ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            writeHUDStatus("Key tap could not be created")
            isReplacingSystemHUD = false
            return
        }
        writeHUDStatus("Key tap installed: volume/brightness keys handled by the notch")
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyTap = tap
        keyTapSource = source
        isReplacingSystemHUD = true
    }

    /// macOS only lets the notch replace its own overlay with Accessibility; ask once, then the
    /// background retry picks the keys up as soon as it's granted.
    private func requestAccessibilityOnce() {
        let key = "systemHUDAccessibilityPrompted.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        hudLog.notice("Requesting Accessibility for the volume/brightness keys")
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func removeKeyTap() {
        if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = keyTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        keyTap = nil
        keyTapSource = nil
        isReplacingSystemHUD = false
    }

    /// Returns true when the key was applied here (the system overlay is then skipped).
    private func handle(_ key: MediaKey) -> Bool {
        guard isEnabled else { return false }
        // Swallow the key-up of keys we act on so the system never sees half a press.
        guard key.isDown else { return key.isVolume || (key.isBrightness && DisplayServices.canSet) }
        let fine = key.modifiers.contains(.option) && key.modifiers.contains(.shift)
        let step = fine ? 1.0 / 64 : 1.0 / 16

        switch key.code {
        case .soundUp, .soundDown:
            guard let volume = readVolume() else { return false }
            let target = Self.snap(volume + (key.code == .soundUp ? step : -step), step: step)
            if key.code == .soundUp, SystemAudioController.isMuted() { SystemAudioController.setMuted(false) }
            guard setVolume(target) else { return false }
            if target <= 0 { SystemAudioController.setMuted(true) }
            present(SystemHUDEvent(kind: .volume, value: target, muted: SystemAudioController.isMuted()))
            return true
        case .mute:
            SystemAudioController.setMuted(!SystemAudioController.isMuted())
            present(SystemHUDEvent(kind: .volume, value: readVolume() ?? 0, muted: SystemAudioController.isMuted()))
            return true
        case .brightnessUp, .brightnessDown:
            let display = DisplayServices.builtInDisplay
            guard DisplayServices.canSet, let brightness = DisplayServices.brightness(display) else { return false }
            let target = Self.snap(brightness + (key.code == .brightnessUp ? step : -step), step: step)
            guard DisplayServices.setBrightness(display, target) else { return false }
            brightnessKeyAt = .now
            present(SystemHUDEvent(kind: .brightness, value: target))
            return true
        }
    }

    private static func snap(_ value: Double, step: Double) -> Double {
        min(1, max(0, (value / step).rounded() * step))
    }
}

/// Decoded NX media key from an `NSEventTypeSystemDefined` event (subtype 8).
private struct MediaKey {
    enum Code: Int { case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7 }

    let code: Code
    let isDown: Bool
    let modifiers: NSEvent.ModifierFlags

    init?(event: NSEvent) {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return nil }
        let data = event.data1
        guard let code = Code(rawValue: (data & 0xFFFF_0000) >> 16) else { return nil }
        self.code = code
        self.isDown = ((data & 0xFF00) >> 8) == 0xA
        self.modifiers = event.modifierFlags
    }

    var isVolume: Bool { code == .soundUp || code == .soundDown || code == .mute }
    var isBrightness: Bool { code == .brightnessUp || code == .brightnessDown }
}

/// Private DisplayServices calls for the built-in panel's brightness (loaded lazily, optional).
private enum DisplayServices {
    typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias RegisterFn = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    static let getBrightness = symbol("DisplayServicesGetBrightness", as: GetFn.self)
    static let setBrightnessFn = symbol("DisplayServicesSetBrightness", as: SetFn.self)
    static let registerForChanges = symbol("DisplayServicesRegisterForBrightnessChangeNotifications", as: RegisterFn.self)

    static var canSet: Bool { setBrightnessFn != nil && getBrightness != nil }

    static var builtInDisplay: CGDirectDisplayID {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetOnlineDisplayList(16, &displays, &count)
        return displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    static func brightness(_ display: CGDirectDisplayID) -> Double? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        return getBrightness(display, &value) == 0 ? Double(value) : nil
    }

    static func setBrightness(_ display: CGDirectDisplayID, _ value: Double) -> Bool {
        guard let setBrightnessFn else { return false }
        return setBrightnessFn(display, Float(min(1, max(0, value)))) == 0
    }
}

// MARK: - Notch view

/// The closed notch while a HUD is up: icon + label on the left ear, level bar on the right ear with a
/// color wash that fades in from the right edge.
struct NotchSystemHUDView: View {
    let event: SystemHUDEvent
    let earWidth: CGFloat
    let sidePad: CGFloat
    let cameraGap: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var percent: Int { Int((event.muted ? 0 : event.value) * 100 + 0.5) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: event.symbol, variableValue: event.kind == .volume ? event.value : 1)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 20)
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
            .padding(.trailing, cameraGap)
            .frame(width: earWidth - sidePad, alignment: .leading)
            .padding(.leading, sidePad)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                levelBar
                Text("\(percent)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(percent)))
                    .frame(width: 24, alignment: .trailing)
            }
            .padding(.leading, cameraGap)
            .frame(width: earWidth - sidePad, alignment: .leading)
            .padding(.trailing, sidePad)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .trailing) { wash }
        .animation(reduceMotion ? .none : .spring(response: 0.28, dampingFraction: 0.86), value: event.value)
        .animation(reduceMotion ? .none : .spring(response: 0.28, dampingFraction: 0.86), value: event.muted)
    }

    private var levelBar: some View {
        GeometryReader { geo in
            let fraction = event.muted ? 0 : min(1, max(0, event.value))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(5, geo.size.width * fraction))
            }
        }
        .frame(height: 5)
    }

    /// Color wash behind the right ear only: strongest at the outer edge, dissolving toward the camera.
    private var wash: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: event.colors[0].opacity(0.28), location: 0.35),
                .init(color: event.colors[1].opacity(0.62), location: 0.72),
                .init(color: event.colors[2].opacity(0.85), location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: earWidth + 36)
        .blur(radius: 8)
        .allowsHitTesting(false)
    }
}
