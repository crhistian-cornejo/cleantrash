import CleanTrashCore
import Foundation
import Observation
import SwiftUI

enum BreatherBreakKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case eyes = "Descanso visual"
    case stretch = "Estiramiento"
    case water = "Hidratación"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .eyes: return "Ojos"
        case .stretch: return "Estirar"
        case .water: return "Agua"
        }
    }

    var subtitle: String {
        switch self {
        case .eyes: return "Regla 20-20-20 · mira a 6 m por 20 s"
        case .stretch: return "Hombros, cuello y muñecas"
        case .water: return "Un vaso de agua fresca"
        }
    }

    var dailyGoal: Int {
        switch self {
        case .eyes: return 6
        case .stretch: return 3
        case .water: return 4
        }
    }

    var tint: Color {
        switch self {
        case .eyes: return Mono.gpuAccent    // Cyan
        case .stretch: return Mono.networkAccent // Violet
        case .water: return Mono.infoAccent   // Blue
        }
    }
}

struct BreatherPersistence: Codable, Equatable {
    var dayKey: String
    var eyesDone: Int
    var stretchDone: Int
    var waterDone: Int
    var streakDays: Int
    var completedDaysOfWeek: [Int] // 1=Mon...7=Sun
}

/// Droppy-inspired Breather wellness engine (20-20-20 Eye Rest, Stretch, Water breaks)
/// with 3 concentric daily rings, streak tracking, and automatic CoreAudio call silencing.
@MainActor
@Observable
final class BreatherEngine {
    private(set) var eyesDone: Int = 0
    private(set) var stretchDone: Int = 0
    private(set) var waterDone: Int = 0
    private(set) var streakDays: Int = 1
    private(set) var completedWeekdays: Set<Int> = [] // 1=Mon ... 7=Sun

    private(set) var isPaused: Bool = false
    private(set) var isSilencedByCall: Bool = false
    private(set) var nextBreakKind: BreatherBreakKind = .eyes
    private(set) var secondsUntilNextBreak: Int = 20 * 60
    private(set) var isBreakActive: Bool = false
    private(set) var activeBreakSecondsLeft: Int = 20

    var enabled: Bool = true
    var onBreakDue: ((BreatherBreakKind) -> Void)?

    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private let storageURL: URL

    var totalDoneToday: Int { eyesDone + stretchDone + waterDone }
    var totalGoalToday: Int {
        BreatherBreakKind.eyes.dailyGoal + BreatherBreakKind.stretch.dailyGoal + BreatherBreakKind.water.dailyGoal
    }
    var minutesUntilNextBreak: Int { max(1, Int(ceil(Double(secondsUntilNextBreak) / 60.0))) }

    var eyesProgress: Double { min(1, Double(eyesDone) / Double(BreatherBreakKind.eyes.dailyGoal)) }
    var stretchProgress: Double { min(1, Double(stretchDone) / Double(BreatherBreakKind.stretch.dailyGoal)) }
    var waterProgress: Double { min(1, Double(waterDone) / Double(BreatherBreakKind.water.dailyGoal)) }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.storageURL = support.appendingPathComponent("CleanTrash/breather.json")
        load()
    }

    func start() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.enabled, !self.isPaused else { continue }
                self.tickOneSecond()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    func togglePause() {
        isPaused.toggle()
        AppKitHaptics.tap()
    }

    func startBreakNow(_ kind: BreatherBreakKind? = nil) {
        if let kind { nextBreakKind = kind }
        isBreakActive = true
        activeBreakSecondsLeft = 20
        AppKitHaptics.tap()
    }

    func completeBreak(_ kind: BreatherBreakKind? = nil) {
        let target = kind ?? nextBreakKind
        switch target {
        case .eyes: eyesDone = min(BreatherBreakKind.eyes.dailyGoal, eyesDone + 1)
        case .stretch: stretchDone = min(BreatherBreakKind.stretch.dailyGoal, stretchDone + 1)
        case .water: waterDone = min(BreatherBreakKind.water.dailyGoal, waterDone + 1)
        }
        isBreakActive = false
        activeBreakSecondsLeft = 20
        secondsUntilNextBreak = 20 * 60
        nextBreakKind = chooseNextKind()
        completedWeekdays.insert(Self.currentISOWeekday())
        save()
        AppKitHaptics.confirm()
    }

    private func tickOneSecond() {
        // Check microphone every 10 seconds to silence breaks during calls
        if secondsUntilNextBreak % 10 == 0 {
            isSilencedByCall = SystemAudioController.isMicrophoneActive()
        }

        if isBreakActive {
            if activeBreakSecondsLeft > 1 {
                activeBreakSecondsLeft -= 1
            } else {
                completeBreak()
            }
            return
        }

        if secondsUntilNextBreak > 1 {
            secondsUntilNextBreak -= 1
        } else {
            secondsUntilNextBreak = 20 * 60
            guard !isSilencedByCall else { return }
            onBreakDue?(nextBreakKind)
        }
    }

    private func chooseNextKind() -> BreatherBreakKind {
        let remaining: [(BreatherBreakKind, Double)] = [
            (.eyes, eyesProgress),
            (.stretch, stretchProgress),
            (.water, waterProgress)
        ]
        return remaining.min(by: { $0.1 < $1.1 })?.0 ?? .eyes
    }

    private func load() {
        let today = Self.todayKey()
        guard let data = try? Data(contentsOf: storageURL),
              let saved = try? JSONDecoder().decode(BreatherPersistence.self, from: data) else {
            completedWeekdays = []
            return
        }
        if saved.dayKey == today {
            eyesDone = saved.eyesDone
            stretchDone = saved.stretchDone
            waterDone = saved.waterDone
            streakDays = max(1, saved.streakDays)
            completedWeekdays = Set(saved.completedDaysOfWeek)
        } else {
            // New day: increment streak if yesterday had progress
            let hadProgress = (saved.eyesDone + saved.stretchDone + saved.waterDone) > 0
            streakDays = hadProgress ? saved.streakDays + 1 : 1
            completedWeekdays = Self.currentISOWeekday() == 1 ? [] : Set(saved.completedDaysOfWeek)
            save()
        }
    }

    private func save() {
        let payload = BreatherPersistence(
            dayKey: Self.todayKey(),
            eyesDone: eyesDone,
            stretchDone: stretchDone,
            waterDone: waterDone,
            streakDays: streakDays,
            completedDaysOfWeek: Array(completedWeekdays).sorted()
        )
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private static func todayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: .now)
    }

    static func currentISOWeekday() -> Int {
        // Calendar weekday: 1=Sun, 2=Mon...7=Sat → ISO 1=Mon...7=Sun
        let wd = Calendar.current.component(.weekday, from: .now)
        return wd == 1 ? 7 : wd - 1
    }
}

/// Droppy-exact 3 concentric daily rings (Eyes · Stretch · Water) with live center count.
struct BreatherConcentricRings: View {
    let eyesProgress: Double
    let stretchProgress: Double
    let waterProgress: Double
    let centerText: String
    var size: CGFloat = 58

    var body: some View {
        ZStack {
            // Outer: Eyes (Cyan)
            ring(progress: eyesProgress, tint: BreatherBreakKind.eyes.tint, inset: 0, width: 4.5)
            // Middle: Stretch (Violet)
            ring(progress: stretchProgress, tint: BreatherBreakKind.stretch.tint, inset: 6.5, width: 4.2)
            // Inner: Water (Blue)
            ring(progress: waterProgress, tint: BreatherBreakKind.water.tint, inset: 12.5, width: 4.0)

            Text(centerText)
                .font(.system(size: size * 0.23, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
    }

    private func ring(progress: Double, tint: Color, inset: CGFloat, width: CGFloat) -> some View {
        let clamped = min(1, max(0, progress))
        return ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: width)
                .padding(inset)
            Circle()
                .trim(from: 0, to: max(0.02, clamped))
                .stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(inset)
                .shadow(color: tint.opacity(clamped > 0 ? 0.45 : 0), radius: 3)
                .animation(Mono.betweenSpring, value: clamped)
        }
    }
}
