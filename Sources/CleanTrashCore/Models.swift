import Foundation

// MARK: - System Telemetry

public enum MemoryPressureLevel: Int, Sendable, Codable, Equatable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Alta"
        case .critical: return "Crítica"
        }
    }
}

public struct MemorySnapshot: Sendable, Equatable {
    public var totalBytes: UInt64
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var cachedFilesBytes: UInt64
    public var purgeableBytes: UInt64
    public var freeBytes: UInt64
    public var swapUsedBytes: UInt64
    public var swapTotalBytes: UInt64
    public var pressure: MemoryPressureLevel

    public init(
        totalBytes: UInt64 = 0,
        appBytes: UInt64 = 0,
        wiredBytes: UInt64 = 0,
        compressedBytes: UInt64 = 0,
        cachedFilesBytes: UInt64 = 0,
        purgeableBytes: UInt64 = 0,
        freeBytes: UInt64 = 0,
        swapUsedBytes: UInt64 = 0,
        swapTotalBytes: UInt64 = 0,
        pressure: MemoryPressureLevel = .normal
    ) {
        self.totalBytes = totalBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFilesBytes = cachedFilesBytes
        self.purgeableBytes = purgeableBytes
        self.freeBytes = freeBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressure = pressure
    }

    /// Activity Monitor definition: App (internal - purgeable) + Wired + Compressed.
    public var usedBytes: UInt64 {
        min(totalBytes, appBytes + wiredBytes + compressedBytes)
    }

    public var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return min(100, Double(usedBytes) / Double(totalBytes) * 100.0)
    }

    public var availableBytes: UInt64 {
        totalBytes > usedBytes ? totalBytes - usedBytes : 0
    }
}

public struct GPUSnapshot: Sendable, Equatable {
    public var modelName: String
    public var deviceUtilizationPercent: Double
    public var rendererUtilizationPercent: Double
    public var tilerUtilizationPercent: Double
    public var inUseMemoryBytes: UInt64
    public var allocatedMemoryBytes: UInt64

    public init(
        modelName: String = "Apple GPU",
        deviceUtilizationPercent: Double = 0,
        rendererUtilizationPercent: Double = 0,
        tilerUtilizationPercent: Double = 0,
        inUseMemoryBytes: UInt64 = 0,
        allocatedMemoryBytes: UInt64 = 0
    ) {
        self.modelName = modelName
        self.deviceUtilizationPercent = deviceUtilizationPercent
        self.rendererUtilizationPercent = rendererUtilizationPercent
        self.tilerUtilizationPercent = tilerUtilizationPercent
        self.inUseMemoryBytes = inUseMemoryBytes
        self.allocatedMemoryBytes = allocatedMemoryBytes
    }
}

public struct DiskSnapshot: Sendable, Equatable {
    public var volumeName: String
    public var totalBytes: UInt64
    public var availableBytes: UInt64
    public var opportunisticAvailableBytes: UInt64

    public init(
        volumeName: String = "Macintosh HD",
        totalBytes: UInt64 = 0,
        availableBytes: UInt64 = 0,
        opportunisticAvailableBytes: UInt64 = 0
    ) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.opportunisticAvailableBytes = opportunisticAvailableBytes
    }

    public var usedBytes: UInt64 {
        totalBytes > availableBytes ? totalBytes - availableBytes : 0
    }

    public var purgeableBytes: UInt64 {
        opportunisticAvailableBytes > availableBytes ? opportunisticAvailableBytes - availableBytes : 0
    }

    public var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return min(100, Double(usedBytes) / Double(totalBytes) * 100.0)
    }
}

public struct BatterySnapshot: Sendable, Equatable {
    public var present: Bool
    public var percent: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    public var healthPercent: Double?

    public init(
        present: Bool = false,
        percent: Double = 0,
        isCharging: Bool = false,
        isPluggedIn: Bool = false,
        minutesRemaining: Int? = nil,
        cycleCount: Int? = nil,
        healthPercent: Double? = nil
    ) {
        self.present = present
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.minutesRemaining = minutesRemaining
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
    }
}

public struct NetworkSnapshot: Sendable, Equatable {
    public var bytesInPerSec: Double
    public var bytesOutPerSec: Double

    public init(bytesInPerSec: Double = 0, bytesOutPerSec: Double = 0) {
        self.bytesInPerSec = bytesInPerSec
        self.bytesOutPerSec = bytesOutPerSec
    }
}

public struct ProcessSample: Identifiable, Sendable, Equatable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var bundleIdentifier: String?
    public var memoryBytes: UInt64
    public var cpuPercent: Double
    public var isUserApp: Bool
    /// Owned by the logged-in user and not part of the core macOS UI → safe to force-quit.
    public var isKillable: Bool
    /// Belongs to an iOS/watchOS Simulator runtime (CoreSimulator).
    public var isSimulator: Bool
    public var appPath: String?

    public init(
        pid: Int32,
        name: String,
        bundleIdentifier: String? = nil,
        memoryBytes: UInt64,
        cpuPercent: Double = 0,
        isUserApp: Bool = false,
        isKillable: Bool = false,
        isSimulator: Bool = false,
        appPath: String? = nil
    ) {
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.isUserApp = isUserApp
        self.isKillable = isKillable
        self.isSimulator = isSimulator
        self.appPath = appPath
    }
}

/// Aggregate footprint of every process that belongs to a booted Simulator.
public struct SimulatorLoad: Sendable, Equatable {
    public var processCount: Int = 0
    public var cpuPercent: Double = 0
    public var memoryBytes: UInt64 = 0

    public init(processCount: Int = 0, cpuPercent: Double = 0, memoryBytes: UInt64 = 0) {
        self.processCount = processCount
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

public struct SimulatorDevice: Identifiable, Sendable, Equatable {
    public var id: String { udid }
    public var udid: String
    public var name: String
    public var runtime: String

    public init(udid: String, name: String, runtime: String) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
    }
}

public struct ExternalVolumeInfo: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var totalBytes: UInt64
    public var availableBytes: UInt64
    public var isEjectable: Bool

    public init(name: String, path: String, totalBytes: UInt64, availableBytes: UInt64, isEjectable: Bool) {
        self.name = name
        self.path = path
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isEjectable = isEjectable
    }

    public var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        let used = totalBytes > availableBytes ? totalBytes - availableBytes : 0
        return min(100, Double(used) / Double(totalBytes) * 100.0)
    }
}

public struct SystemTelemetry: Sendable, Equatable {
    public var timestamp: Date
    public var cpuTotalPercent: Double
    public var cpuUserPercent: Double
    public var cpuSystemPercent: Double
    public var coreCount: Int
    public var thermalState: String
    public var memory: MemorySnapshot
    public var gpu: GPUSnapshot
    public var disk: DiskSnapshot
    public var battery: BatterySnapshot
    public var network: NetworkSnapshot
    public var externalVolumes: [ExternalVolumeInfo]
    public var topMemoryProcesses: [ProcessSample]
    public var topCPUProcesses: [ProcessSample] = []
    public var simulatorLoad = SimulatorLoad()
    public var processCount: Int = 0
    /// 1-minute load average (runnable threads). Above ~2× core count the Mac feels sluggish.
    public var loadAverage: Double = 0

    public init(
        timestamp: Date = .now,
        cpuTotalPercent: Double = 0,
        cpuUserPercent: Double = 0,
        cpuSystemPercent: Double = 0,
        coreCount: Int = ProcessInfo.processInfo.processorCount,
        thermalState: String = "Normal",
        memory: MemorySnapshot = .init(),
        gpu: GPUSnapshot = .init(),
        disk: DiskSnapshot = .init(),
        battery: BatterySnapshot = .init(),
        network: NetworkSnapshot = .init(),
        externalVolumes: [ExternalVolumeInfo] = [],
        topMemoryProcesses: [ProcessSample] = []
    ) {
        self.timestamp = timestamp
        self.cpuTotalPercent = cpuTotalPercent
        self.cpuUserPercent = cpuUserPercent
        self.cpuSystemPercent = cpuSystemPercent
        self.coreCount = coreCount
        self.thermalState = thermalState
        self.memory = memory
        self.gpu = gpu
        self.disk = disk
        self.battery = battery
        self.network = network
        self.externalVolumes = externalVolumes
        self.topMemoryProcesses = topMemoryProcesses
    }
}

public struct TelemetryPoint: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let cpu: Double
    public let memory: Double
    public let gpu: Double
    public let netDownKB: Double
    public let netUpKB: Double

    public init(timestamp: Date, cpu: Double, memory: Double, gpu: Double, netDownKB: Double, netUpKB: Double) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.netDownKB = netDownKB
        self.netUpKB = netUpKB
    }
}

// MARK: - Dev Artifacts

public enum DevEcosystem: String, CaseIterable, Sendable, Codable, Identifiable {
    case rust = "Rust / Cargo"
    case node = "Node / Bun / JS"
    case swift = "Swift / Xcode"
    case python = "Python"
    case jvmGo = "JVM / Go"
    case aiModels = "AI Tools & Models"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .rust: return "gearshape.2"
        case .node: return "cube.box"
        case .swift: return "swift"
        case .python: return "terminal"
        case .jvmGo: return "shippingbox"
        case .aiModels: return "cpu"
        }
    }
}

public struct DevArtifact: Identifiable, Sendable, Equatable {
    public let id: String
    public let projectName: String
    public let artifactKind: String
    public let ecosystem: DevEcosystem
    public let path: String
    public let sizeBytes: UInt64
    public let lastModified: Date
    public let isActiveBuild: Bool
    public let isGlobalCache: Bool
    public var selected: Bool

    public init(
        projectName: String,
        artifactKind: String,
        ecosystem: DevEcosystem,
        path: String,
        sizeBytes: UInt64,
        lastModified: Date,
        isActiveBuild: Bool,
        isGlobalCache: Bool = false,
        selected: Bool? = nil
    ) {
        self.id = path
        self.projectName = projectName
        self.artifactKind = artifactKind
        self.ecosystem = ecosystem
        self.path = path
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
        self.isActiveBuild = isActiveBuild
        self.isGlobalCache = isGlobalCache
        self.selected = selected ?? (!isActiveBuild)
    }

    public var ageDays: Int {
        max(0, Int(Date.now.timeIntervalSince(lastModified) / 86_400))
    }
}

// MARK: - System Junk

public enum JunkCategory: String, CaseIterable, Sendable, Identifiable {
    case userCaches = "User Caches"
    case containerCaches = "App Container Caches"
    case electronCaches = "Electron & GPU Caches"
    case logs = "Logs & Crash Reports"
    case xcodeAndSimulators = "Xcode & Simulators"
    case brokenConfigs = "Broken Plists & Agents"
    case trash = "Trash Bins"
    case installers = "Old Installers (.dmg/.pkg)"

    public var id: String { rawValue }

    /// Spanish UI label (rawValue stays stable as the identifier).
    public var title: String {
        switch self {
        case .userCaches: return "Cachés de usuario"
        case .containerCaches: return "Cachés de apps"
        case .electronCaches: return "Cachés Electron y GPU"
        case .logs: return "Registros y fallos"
        case .xcodeAndSimulators: return "Xcode y simuladores"
        case .brokenConfigs: return "Plists y agentes rotos"
        case .trash: return "Papelera"
        case .installers: return "Instaladores viejos"
        }
    }

    public var symbolName: String {
        switch self {
        case .userCaches: return "internaldrive"
        case .containerCaches: return "square.stack.3d.up"
        case .electronCaches: return "sparkles.rectangle.stack"
        case .logs: return "doc.text"
        case .xcodeAndSimulators: return "hammer"
        case .brokenConfigs: return "exclamationmark.triangle"
        case .trash: return "trash"
        case .installers: return "opticaldiscdrive"
        }
    }
}

public struct JunkItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let category: JunkCategory
    public let sizeBytes: UInt64
    public let reason: String
    public let lastModified: Date
    public var selected: Bool

    public init(
        name: String,
        path: String,
        category: JunkCategory,
        sizeBytes: UInt64,
        reason: String,
        lastModified: Date = .now,
        selected: Bool = true
    ) {
        self.id = path
        self.name = name
        self.path = path
        self.category = category
        self.sizeBytes = sizeBytes
        self.reason = reason
        self.lastModified = lastModified
        self.selected = selected
    }
}

// MARK: - Disk Space Map

public enum DiskCategory: String, CaseIterable, Sendable, Identifiable {
    case devBuilds = "Dev Builds"
    case applications = "Applications"
    case cachesAndLogs = "Caches & Logs"
    case media = "Media"
    case documents = "Documents"
    case archives = "Archives & Images"
    case library = "Library Data"
    case other = "Other"

    public var id: String { rawValue }
}

public struct DiskNode: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let sizeBytes: UInt64
    public let fileCount: Int
    public let category: DiskCategory
    public let isCleanableCandidate: Bool
    public let cleanableHint: String?
    public let children: [DiskNode]

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        sizeBytes: UInt64,
        fileCount: Int,
        category: DiskCategory,
        isCleanableCandidate: Bool = false,
        cleanableHint: String? = nil,
        children: [DiskNode] = []
    ) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.category = category
        self.isCleanableCandidate = isCleanableCandidate
        self.cleanableHint = cleanableHint
        self.children = children
    }
}

// MARK: - Apps & Unused Audit

public enum AppArtifactKind: String, Sendable, Codable {
    case bundle = "Application"
    case applicationSupport = "Application Support"
    case caches = "Caches"
    case container = "Container"
    case groupContainer = "Group Container"
    case preferences = "Preferences"
    case savedState = "Saved State"
    case logs = "Logs"
    case webData = "WebKit / HTTP / Cookies"
    case launchAgent = "Launch Agent"
}

public struct AppRelatedFile: Identifiable, Sendable, Equatable {
    public let id: String
    public let path: String
    public let kind: AppArtifactKind
    public let sizeBytes: UInt64
    public var selected: Bool

    public init(path: String, kind: AppArtifactKind, sizeBytes: UInt64, selected: Bool = true) {
        self.id = path
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.selected = selected
    }
}

public enum AppKeepDecision: String, Sendable, Codable {
    case keep
    case snoozed
}

public struct AppDecisionRecord: Sendable, Codable, Equatable {
    public var bundleID: String
    public var decision: AppKeepDecision
    public var decidedAt: Date
    public var snoozeUntil: Date?

    public init(bundleID: String, decision: AppKeepDecision, decidedAt: Date = .now, snoozeUntil: Date? = nil) {
        self.bundleID = bundleID
        self.decision = decision
        self.decidedAt = decidedAt
        self.snoozeUntil = snoozeUntil
    }
}

public struct InstalledAppInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let version: String
    public let appPath: String
    public let bundleSizeBytes: UInt64
    public let relatedFiles: [AppRelatedFile]
    public let lastUsedDate: Date?
    public let isRunning: Bool
    public let isAppleSystemApp: Bool
    public var decision: AppDecisionRecord?

    public init(
        name: String,
        bundleID: String,
        version: String,
        appPath: String,
        bundleSizeBytes: UInt64,
        relatedFiles: [AppRelatedFile],
        lastUsedDate: Date?,
        isRunning: Bool,
        isAppleSystemApp: Bool,
        decision: AppDecisionRecord? = nil
    ) {
        self.id = appPath
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.appPath = appPath
        self.bundleSizeBytes = bundleSizeBytes
        self.relatedFiles = relatedFiles
        self.lastUsedDate = lastUsedDate
        self.isRunning = isRunning
        self.isAppleSystemApp = isAppleSystemApp
        self.decision = decision
    }

    public var totalSizeBytes: UInt64 {
        bundleSizeBytes + relatedFiles.reduce(0) { $0 + $1.sizeBytes }
    }

    public var daysSinceLastUsed: Int? {
        guard let lastUsedDate else { return nil }
        return max(0, Int(Date.now.timeIntervalSince(lastUsedDate) / 86_400))
    }

    public func isUnused(thresholdDays: Int) -> Bool {
        if isRunning || isAppleSystemApp { return false }
        if let decision {
            if decision.decision == .keep { return false }
            if decision.decision == .snoozed, let until = decision.snoozeUntil, until > .now {
                return false
            }
        }
        guard let days = daysSinceLastUsed else {
            return true // Never launched or Spotlight has no open record
        }
        return days >= thresholdDays
    }
}

public struct OrphanLeftover: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let location: String
    public let sizeBytes: UInt64
    public var selected: Bool

    public init(name: String, path: String, location: String, sizeBytes: UInt64, selected: Bool = true) {
        self.id = path
        self.name = name
        self.path = path
        self.location = location
        self.sizeBytes = sizeBytes
        self.selected = selected
    }
}

// MARK: - Notices & Settings

public enum NotchNoticeKind: String, Sendable, Equatable {
    case devBloat
    case highMemory
    case unusedApp
    case cleaned
    case warning
    case failed
    case heavyCPU
}

public struct NotchNotice: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: NotchNoticeKind
    public let title: String
    public let subtitle: String
    public let primaryActionTitle: String?
    public let targetPath: String?
    public let targetBundleID: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: NotchNoticeKind,
        title: String,
        subtitle: String,
        primaryActionTitle: String? = nil,
        targetPath: String? = nil,
        targetBundleID: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.primaryActionTitle = primaryActionTitle
        self.targetPath = targetPath
        self.targetBundleID = targetBundleID
        self.createdAt = createdAt
    }
}

public enum NotchStyleMode: String, CaseIterable, Sendable, Codable {
    case notch
    case island
}

public enum NotchSurfaceMode: String, CaseIterable, Sendable, Codable {
    case obsidian
    case glass
    case clearGlass

    public var label: String {
        switch self {
        case .obsidian: return "Negro"
        case .glass: return "Dynamic Glass"
        case .clearGlass: return "Liquid Glass"
        }
    }

    public var symbol: String {
        switch self {
        case .obsidian: return "moon.fill"
        case .glass: return "drop.halffull"
        case .clearGlass: return "drop.fill"
        }
    }

    public var isGlass: Bool { self != .obsidian }

    public var next: NotchSurfaceMode {
        switch self {
        case .obsidian: return .glass
        case .glass: return .clearGlass
        case .clearGlass: return .obsidian
        }
    }
}

/// Modular widgets the user can enable, remove, and drag-reorder on the Home notch shelf.
public enum NotchWidgetID: String, CaseIterable, Sendable, Codable, Identifiable {
    case nowPlaying
    case systemStats
    case agents
    case pomodoro
    case weather
    case batteries
    case calendar
    case devly
    case clipboard
    case audio
    case notes
    case stayAwake
    case translate
    case breather

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nowPlaying: return "Música"
        case .systemStats: return "Sistema"
        case .agents: return "Agentes"
        case .pomodoro: return "Pomodoro"
        case .weather: return "Clima"
        case .batteries: return "Baterías"
        case .calendar: return "Agenda"
        case .devly: return "Devly"
        case .clipboard: return "Portapapeles"
        case .audio: return "Audio"
        case .notes: return "Notas"
        case .stayAwake: return "Despierto"
        case .translate: return "Traducir"
        case .breather: return "Breather"
        }
    }

    public var symbol: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .systemStats: return "gauge.with.dots.needle.67percent"
        case .agents: return "sparkles"
        case .pomodoro: return "timer"
        case .weather: return "sun.max.fill"
        case .batteries: return "battery.75percent"
        case .calendar: return "calendar"
        case .devly: return "chevron.left.forwardslash.chevron.right"
        case .clipboard: return "doc.on.clipboard.fill"
        case .audio: return "speaker.wave.2.fill"
        case .notes: return "note.text"
        case .stayAwake: return "cup.and.saucer.fill"
        case .translate: return "translate"
        case .breather: return "leaf.fill"
        }
    }

    /// Preferred horizontal slot weight on the Home widget bar.
    public var preferredWidth: CGFloat {
        switch self {
        case .nowPlaying: return 260
        case .systemStats: return 238
        case .agents: return 220
        case .pomodoro: return 174
        case .weather: return 172
        case .batteries: return 252
        case .calendar: return 240
        case .devly: return 245
        case .clipboard: return 255
        case .audio: return 200
        case .notes: return 205
        case .stayAwake: return 146
        case .translate: return 248
        case .breather: return 270
        }
    }

    public static let defaultLayout: [NotchWidgetID] = [.nowPlaying, .systemStats, .agents]
}

public enum NotchOpenTrigger: String, CaseIterable, Sendable, Codable {
    case hover
    case click
}

/// What the menu bar item shows next to its icon.
public enum MenuBarDisplay: String, CaseIterable, Sendable, Codable {
    case iconOnly, memory, cpu, all

    public var label: String {
        switch self {
        case .iconOnly: return "Solo ícono"
        case .memory: return "Memoria"
        case .cpu: return "CPU"
        case .all: return "Todo"
        }
    }
}

public struct CleanTrashSettings: Sendable, Codable, Equatable {
    public var watchedDevFolders: [String]
    public var devAlertThresholdGB: Double
    public var devStaleDays: Int
    public var unusedAppThresholdDays: Int
    public var useTrashByDefault: Bool
    public var permanentDeleteDevBuilds: Bool
    public var notchEnabled: Bool
    public var notchStyle: NotchStyleMode
    public var notchSurface: NotchSurfaceMode
    public var notchTrigger: NotchOpenTrigger
    public var showLiveNotchEars: Bool
    public var showMusicInNotchEars: Bool
    public var showLyricsInNotchEar: Bool
    public var clipboardHistoryEnabled: Bool
    public var autoOpenShelfOnDrag: Bool
    public var homeWidgets: [NotchWidgetID]
    public var autoNotifyDevArtifacts: Bool
    public var autoNotifyHighMemory: Bool
    public var autoOptimizeCriticalRAM: Bool
    public var autoCleanStaleDevEnabled: Bool
    public var autoCleanMinFreeGB: Double
    public var autoAskUnusedApps: Bool
    public var sidebarCollapsed: Bool
    public var monochromeAppearance: String // "dark", "light", "system"
    public var agentMascotEnabled: Bool
    public var breatherEnabled: Bool
    /// Volume / brightness changes appear in the notch (and replace the macOS overlay when Accessibility is on).
    public var systemHUDInNotch: Bool
    public var menuBarDisplay: MenuBarDisplay

    public init(
        watchedDevFolders: [String] = CleanTrashSettings.defaultDevFolders(),
        devAlertThresholdGB: Double = 2.0,
        devStaleDays: Int = 7,
        unusedAppThresholdDays: Int = 45,
        useTrashByDefault: Bool = false,
        permanentDeleteDevBuilds: Bool = true,
        notchEnabled: Bool = true,
        notchStyle: NotchStyleMode = .notch,
        notchSurface: NotchSurfaceMode = .glass,
        notchTrigger: NotchOpenTrigger = .hover,
        showLiveNotchEars: Bool = true,
        showMusicInNotchEars: Bool = true,
        showLyricsInNotchEar: Bool = true,
        clipboardHistoryEnabled: Bool = true,
        autoOpenShelfOnDrag: Bool = true,
        homeWidgets: [NotchWidgetID] = NotchWidgetID.defaultLayout,
        autoNotifyDevArtifacts: Bool = true,
        autoNotifyHighMemory: Bool = true,
        autoOptimizeCriticalRAM: Bool = false,
        autoCleanStaleDevEnabled: Bool = false,
        autoCleanMinFreeGB: Double = 30.0,
        autoAskUnusedApps: Bool = true,
        sidebarCollapsed: Bool = false,
        monochromeAppearance: String = "dark",
        agentMascotEnabled: Bool = false,
        breatherEnabled: Bool = true,
        systemHUDInNotch: Bool = true,
        menuBarDisplay: MenuBarDisplay = .memory
    ) {
        self.watchedDevFolders = watchedDevFolders
        self.devAlertThresholdGB = devAlertThresholdGB
        self.devStaleDays = devStaleDays
        self.unusedAppThresholdDays = unusedAppThresholdDays
        self.useTrashByDefault = useTrashByDefault
        self.permanentDeleteDevBuilds = permanentDeleteDevBuilds
        self.notchEnabled = notchEnabled
        self.notchStyle = notchStyle
        self.notchSurface = notchSurface
        self.notchTrigger = notchTrigger
        self.showLiveNotchEars = showLiveNotchEars
        self.showMusicInNotchEars = showMusicInNotchEars
        self.showLyricsInNotchEar = showLyricsInNotchEar
        self.clipboardHistoryEnabled = clipboardHistoryEnabled
        self.autoOpenShelfOnDrag = autoOpenShelfOnDrag
        self.homeWidgets = homeWidgets
        self.autoNotifyDevArtifacts = autoNotifyDevArtifacts
        self.autoNotifyHighMemory = autoNotifyHighMemory
        self.autoOptimizeCriticalRAM = autoOptimizeCriticalRAM
        self.autoCleanStaleDevEnabled = autoCleanStaleDevEnabled
        self.autoCleanMinFreeGB = autoCleanMinFreeGB
        self.autoAskUnusedApps = autoAskUnusedApps
        self.sidebarCollapsed = sidebarCollapsed
        self.monochromeAppearance = monochromeAppearance
        self.agentMascotEnabled = agentMascotEnabled
        self.breatherEnabled = breatherEnabled
        self.systemHUDInNotch = systemHUDInNotch
        self.menuBarDisplay = menuBarDisplay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CleanTrashSettings()
        self.watchedDevFolders = (try? c.decodeIfPresent([String].self, forKey: .watchedDevFolders)) ?? d.watchedDevFolders
        self.devAlertThresholdGB = (try? c.decodeIfPresent(Double.self, forKey: .devAlertThresholdGB)) ?? d.devAlertThresholdGB
        self.devStaleDays = (try? c.decodeIfPresent(Int.self, forKey: .devStaleDays)) ?? d.devStaleDays
        self.unusedAppThresholdDays = (try? c.decodeIfPresent(Int.self, forKey: .unusedAppThresholdDays)) ?? d.unusedAppThresholdDays
        self.useTrashByDefault = (try? c.decodeIfPresent(Bool.self, forKey: .useTrashByDefault)) ?? d.useTrashByDefault
        self.permanentDeleteDevBuilds = (try? c.decodeIfPresent(Bool.self, forKey: .permanentDeleteDevBuilds)) ?? d.permanentDeleteDevBuilds
        self.notchEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notchEnabled)) ?? d.notchEnabled
        self.notchStyle = (try? c.decodeIfPresent(NotchStyleMode.self, forKey: .notchStyle)) ?? d.notchStyle
        self.notchSurface = (try? c.decodeIfPresent(NotchSurfaceMode.self, forKey: .notchSurface)) ?? d.notchSurface
        self.notchTrigger = (try? c.decodeIfPresent(NotchOpenTrigger.self, forKey: .notchTrigger)) ?? d.notchTrigger
        self.showLiveNotchEars = (try? c.decodeIfPresent(Bool.self, forKey: .showLiveNotchEars)) ?? d.showLiveNotchEars
        self.showMusicInNotchEars = (try? c.decodeIfPresent(Bool.self, forKey: .showMusicInNotchEars)) ?? d.showMusicInNotchEars
        self.showLyricsInNotchEar = (try? c.decodeIfPresent(Bool.self, forKey: .showLyricsInNotchEar)) ?? d.showLyricsInNotchEar
        self.clipboardHistoryEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .clipboardHistoryEnabled)) ?? d.clipboardHistoryEnabled
        self.autoOpenShelfOnDrag = (try? c.decodeIfPresent(Bool.self, forKey: .autoOpenShelfOnDrag)) ?? d.autoOpenShelfOnDrag
        let decodedWidgets = (try? c.decodeIfPresent([NotchWidgetID].self, forKey: .homeWidgets)) ?? d.homeWidgets
        self.homeWidgets = decodedWidgets.isEmpty ? d.homeWidgets : decodedWidgets
        self.autoNotifyDevArtifacts = (try? c.decodeIfPresent(Bool.self, forKey: .autoNotifyDevArtifacts)) ?? d.autoNotifyDevArtifacts
        self.autoNotifyHighMemory = (try? c.decodeIfPresent(Bool.self, forKey: .autoNotifyHighMemory)) ?? d.autoNotifyHighMemory
        self.autoOptimizeCriticalRAM = (try? c.decodeIfPresent(Bool.self, forKey: .autoOptimizeCriticalRAM)) ?? d.autoOptimizeCriticalRAM
        self.autoCleanStaleDevEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .autoCleanStaleDevEnabled)) ?? d.autoCleanStaleDevEnabled
        self.autoCleanMinFreeGB = (try? c.decodeIfPresent(Double.self, forKey: .autoCleanMinFreeGB)) ?? d.autoCleanMinFreeGB
        self.autoAskUnusedApps = (try? c.decodeIfPresent(Bool.self, forKey: .autoAskUnusedApps)) ?? d.autoAskUnusedApps
        self.sidebarCollapsed = (try? c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed)) ?? d.sidebarCollapsed
        self.monochromeAppearance = (try? c.decodeIfPresent(String.self, forKey: .monochromeAppearance)) ?? d.monochromeAppearance
        self.agentMascotEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .agentMascotEnabled)) ?? d.agentMascotEnabled
        self.breatherEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .breatherEnabled)) ?? d.breatherEnabled
        self.systemHUDInNotch = (try? c.decodeIfPresent(Bool.self, forKey: .systemHUDInNotch)) ?? d.systemHUDInNotch
        self.menuBarDisplay = (try? c.decodeIfPresent(MenuBarDisplay.self, forKey: .menuBarDisplay)) ?? d.menuBarDisplay
    }

    public static func defaultDevFolders() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Developer",
            "\(home)/Projects",
            "\(home)/Code",
            "\(home)/.t3/projects",
            "\(home)/workspace"
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }
}

public struct CleanupSummary: Sendable, Equatable {
    public var removedCount: Int
    public var failedCount: Int
    public var reclaimedBytes: UInt64
    public var errors: [String]

    public init(removedCount: Int = 0, failedCount: Int = 0, reclaimedBytes: UInt64 = 0, errors: [String] = []) {
        self.removedCount = removedCount
        self.failedCount = failedCount
        self.reclaimedBytes = reclaimedBytes
        self.errors = errors
    }

    public mutating func merge(_ other: CleanupSummary) {
        removedCount += other.removedCount
        failedCount += other.failedCount
        reclaimedBytes += other.reclaimedBytes
        errors += other.errors
    }
}

public struct RAMOptimizationResult: Sendable, Equatable {
    public var beforeUsedBytes: UInt64
    public var afterUsedBytes: UInt64
    public var reclaimedBytes: UInt64
    public var durationSeconds: Double

    public init(beforeUsedBytes: UInt64, afterUsedBytes: UInt64, reclaimedBytes: UInt64, durationSeconds: Double) {
        self.beforeUsedBytes = beforeUsedBytes
        self.afterUsedBytes = afterUsedBytes
        self.reclaimedBytes = reclaimedBytes
        self.durationSeconds = durationSeconds
    }
}
