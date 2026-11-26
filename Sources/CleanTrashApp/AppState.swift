import AppKit
import CleanTrashCore
import Darwin
import Foundation
import Observation
import ServiceManagement
import SwiftUI

enum BannerTone: Equatable {
    case success, info, warning, error

    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: return Mono.healthy
        case .info: return Color.secondary
        case .warning: return Mono.caution
        case .error: return Mono.danger
        }
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Inicio"
    case systemJunk = "Limpieza"
    case devRadar = "Proyectos"
    case diskMap = "Mapa de disco"
    case appsAudit = "Apps"
    case performance = "Rendimiento"
    case agents = "Agentes"
    case notchHub = "Notch"
    case vault = "Bóveda"
    case settings = "Ajustes"

    var id: String { rawValue }

    /// Rows in the sidebar (Ajustes sits in the footer).
    static let sidebar: [DashboardSection] = [.overview, .systemJunk, .appsAudit, .performance, .agents, .notchHub, .vault]

    /// Tabs inside Limpieza.
    static let cleanupTabs: [DashboardSection] = [.systemJunk, .devRadar, .diskMap]

    /// The sidebar row that owns this section (cleanup tabs all live under Limpieza).
    var sidebarRow: DashboardSection {
        Self.cleanupTabs.contains(self) ? .systemJunk : self
    }

    /// Short label for a Limpieza tab.
    var tabTitle: String {
        switch self {
        case .systemJunk: return "Sistema"
        default: return rawValue
        }
    }

    var icon3D: Icon3DName {
        switch self {
        case .overview: return .smartcare
        case .systemJunk: return .trash
        case .devRadar: return .dev
        case .diskMap: return .diskmap
        case .appsAudit: return .apps
        case .performance: return .performance
        case .agents: return .dev
        case .notchHub: return .notch
        case .vault: return .vault
        case .settings: return .settings
        }
    }
}

@MainActor
@Observable
final class AppState {
    // Navigation
    var selectedSection: DashboardSection = .overview
    var settingsPane: SettingsPane = .general
    var hasFullDiskAccess: Bool = PathSafety.hasFullDiskAccess()

    // Live Telemetry
    var telemetry = SystemTelemetry()
    var history: [TelemetryPoint] = []
    var localSnapshots: [String] = []

    // Scan Datasets
    var devArtifacts: [DevArtifact] = []
    var junkItems: [JunkItem] = []
    var diskRoot: DiskNode?
    var diskScanTargetPath: String = NSHomeDirectory()
    var diskScanCurrentFolder: String = ""
    var installedApps: [InstalledAppInfo] = []
    var orphanLeftovers: [OrphanLeftover] = []

    // Loading / Operation flags
    var isScanningDev = false
    var isScanningJunk = false
    var isMappingDisk = false
    var isAuditingApps = false
    var isOptimizingRAM = false
    var ramOptimizationProgress: Double = 0
    var isCleaning = false
    var cleaningLabel: String?
    var statusBanner: String?
    var statusTone: BannerTone = .success
    var totalReclaimedSessionBytes: UInt64 = 0
    var trashContents = TrashContents()
    var bootedSimulators: [SimulatorDevice] = []
    var isShuttingDownSimulators = false
    /// PIDs we just asked to quit; hidden from lists until the next scan confirms they are gone.
    var quittingPIDs: Set<Int32> = []

    // Coding agents (Claude Code, Codex, Antigravity, T3 Code) reporting through hooks
    let agents = AgentMonitor()
    let hud = SystemHUDMonitor()
    let updater = AppUpdater()

    // Droppy-class Media (Spotify / Apple Music + Synced Lyrics), Productivity & Hardened Password Vault
    let media = MediaPlayerController()
    let productivity = ProductivityHub()
    let vault = VaultController()

    // Notch Live Notices
    var activeNotice: NotchNotice?

    /// Adds or removes a Home widget in the notch (max 4, never empty; adding a 5th drops the oldest).
    func toggleHomeWidget(_ widget: NotchWidgetID) {
        var current = settings.homeWidgets
        if let index = current.firstIndex(of: widget) {
            guard current.count > 1 else { return }
            current.remove(at: index)
        } else {
            if current.count >= 4 { current.removeFirst() }
            current.append(widget)
        }
        withAnimation(Mono.betweenSpring) { settings.homeWidgets = current }
        AppKitHaptics.tap()
    }

    // Settings
    var settings: CleanTrashSettings {
        didSet {
            saveSettings()
            if oldValue.watchedDevFolders != settings.watchedDevFolders {
                restartDevWatcher()
            }
            productivity.clipboardEnabled = settings.clipboardHistoryEnabled
            productivity.breather.enabled = settings.breatherEnabled
            productivity.activeWidgets = Set(settings.homeWidgets)
            if oldValue.homeWidgets != settings.homeWidgets { productivity.refreshVisibleData() }
            hud.isEnabled = settings.notchEnabled && settings.systemHUDInNotch
            onSettingsChanged?(settings)
        }
    }

    var onSettingsChanged: ((CleanTrashSettings) -> Void)?
    var onOpenMainWindow: (() -> Void)?
    var onOpenNotchVault: (() -> Void)?

    // Services
    private let monitor = SystemMonitor()
    private let optimizer = MemoryOptimizer()
    private let cleaner = SafeCleaner()
    private let devScanner = DevArtifactScanner()
    private let devWatcher = DevWatcher()
    private let junkScanner = SystemJunkScanner()
    private let diskMapper = DiskMapper()
    private let appAuditor = AppAuditEngine()

    private var telemetryTask: Task<Void, Never>?
    private var noticeDismissTask: Task<Void, Never>?
    private var lastMemoryAlertDate: Date = .distantPast
    private var lastDevAlertDate: Date = .distantPast
    private var lastUnusedAppAlertDate: Date = .distantPast
    private var lastAutoRAMOptimizeDate: Date = .distantPast
    private var lastCPUAlertDate: Date = .distantPast
    private var lastKnownChargingState: Bool?
    private var lastLowBatteryAlertDate: Date = .distantPast
    private var heavySince: [Int32: Date] = [:]
    private let simulatorController = SimulatorController()
    private let settingsURL: URL

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.settingsURL = support.appendingPathComponent("CleanTrash/settings.json")
        self.settings = Self.loadSettings(from: settingsURL)

        productivity.clipboardEnabled = settings.clipboardHistoryEnabled
        productivity.breather.enabled = settings.breatherEnabled
        productivity.breather.onBreakDue = { [weak self] kind in
            self?.postNotice(NotchNotice(
                kind: .cleaned,
                title: "Breather · \(kind.rawValue)",
                subtitle: kind.subtitle,
                primaryActionTitle: "Hecho",
                targetPath: "breather:\(kind.rawValue)"
            ), autoDismissAfter: 14.0)
        }
        productivity.onAccessoryLowBattery = { [weak self] dev in
            self?.postNotice(NotchNotice(
                kind: .warning,
                title: "\(dev.name) al \(dev.percent)%",
                subtitle: "Batería baja · conéctalo pronto"
            ), autoDismissAfter: 9.0)
        }
        productivity.onTimerFinished = { [weak self] label in
            self?.postNotice(NotchNotice(
                kind: .cleaned,
                title: "Sesión \(label) completada",
                subtitle: "Buen trabajo · tómate un respiro"
            ), autoDismissAfter: 8.0)
        }
        productivity.onOCRCompleted = { [weak self] charCount in
            self?.postNotice(NotchNotice(
                kind: .cleaned,
                title: "Texto capturado (OCR)",
                subtitle: "\(charCount) caracteres copiados al portapapeles"
            ), autoDismissAfter: 5.0)
        }
        productivity.onOCRPermissionNeeded = { [weak self] in
            self?.report("Para capturar texto directo de pantalla, activa Grabación de pantalla en Ajustes (solo lee el área elegida localmente, sin audio). O copia una captura (⌘⇧⌃4) y pulsa OCR sin permisos.", tone: .warning)
            self?.postNotice(NotchNotice(
                kind: .warning,
                title: "Permiso de pantalla para OCR",
                subtitle: "Actívalo en Ajustes (sin audio) o usa ⌘⇧⌃4 + OCR",
                primaryActionTitle: "Ajustes",
                targetPath: "ocr-permission"
            ), autoDismissAfter: 9.0)
        }
        vault.onStatusMessage = { [weak self] message, tone in
            self?.report(message, tone: tone)
        }
        media.start()
        SystemActivity.start()
        productivity.activeWidgets = Set(settings.homeWidgets)
        productivity.start()

        startTelemetryLoop()
        restartDevWatcher()

        // Kick off lightweight initial background scans so dashboard & notch are populated immediately.
        Task {
            await runInitialScans()
        }
    }

    // MARK: - Computed Totals

    var reclaimableDevBytes: UInt64 {
        devArtifacts.filter { $0.selected && !$0.isActiveBuild }.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalDevBytes: UInt64 {
        devArtifacts.reduce(0) { $0 + $1.sizeBytes }
    }

    var reclaimableJunkBytes: UInt64 {
        junkItems.filter(\.selected).reduce(0) { $0 + $1.sizeBytes }
    }

    var unusedApps: [InstalledAppInfo] {
        installedApps.filter { $0.isUnused(thresholdDays: settings.unusedAppThresholdDays) }
    }

    var unusedAppsBytes: UInt64 {
        unusedApps.reduce(0) { $0 + $1.totalSizeBytes }
    }

    var totalSmartReclaimableBytes: UInt64 {
        reclaimableDevBytes + reclaimableJunkBytes
    }

    /// Short label for whatever long-running work is in flight (shown in the notch and status areas).
    var activityLabel: String? {
        if isCleaning { return cleaningLabel ?? "Limpiando…" }
        if isOptimizingRAM { return "Optimizando RAM…" }
        if isMappingDisk { return "Mapeando disco…" }
        if isScanningJunk || isScanningDev || isAuditingApps { return "Analizando…" }
        return nil
    }

    // MARK: - Feedback

    func report(_ text: String, tone: BannerTone = .success) {
        withAnimation(Mono.betweenSpring) {
            statusBanner = text
            statusTone = tone
        }
    }

    /// Turns a cleanup summary into an honest banner + notch notice (success / partial / failure).
    private func reportCleanup(_ summary: CleanupSummary, title: String, emptyMessage: String = "No había nada seleccionado para limpiar") {
        let freed = ByteFormat.compact(summary.reclaimedBytes)
        let firstError = summary.errors.first ?? "permiso denegado"
        if summary.failedCount == 0 {
            guard summary.removedCount > 0 else {
                report(emptyMessage, tone: .info)
                return
            }
            AppKitHaptics.confirm()
            report("\(title) · \(freed) liberados en \(summary.removedCount) \(summary.removedCount == 1 ? "elemento" : "elementos")")
            postNotice(NotchNotice(kind: .cleaned, title: title, subtitle: "\(freed) liberados · \(summary.removedCount) \(summary.removedCount == 1 ? "elemento" : "elementos")"))
        } else if summary.removedCount > 0 {
            report("\(title) en parte · \(freed) liberados · \(summary.failedCount) sin borrar (\(firstError))", tone: .warning)
            postNotice(NotchNotice(kind: .warning, title: "\(title) en parte", subtitle: "\(freed) liberados · \(summary.failedCount) sin borrar"))
        } else {
            report("No se pudo completar: \(firstError)", tone: .error)
            postNotice(NotchNotice(kind: .failed, title: "No se pudo limpiar", subtitle: firstError))
        }
    }

    /// Returns false (and tells the user) when another destructive operation is already running.
    private func beginCleaning(_ label: String) -> Bool {
        guard !isCleaning else {
            report("Espera un momento: ya hay una limpieza en curso", tone: .info)
            return false
        }
        isCleaning = true
        cleaningLabel = label
        return true
    }

    private func endCleaning() {
        isCleaning = false
        cleaningLabel = nil
        malloc_zone_pressure_relief(nil, 0)
    }

    var preferredColorScheme: ColorScheme? {
        switch settings.monochromeAppearance {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    // MARK: - Telemetry Loop

    private func startTelemetryLoop() {
        telemetryTask?.cancel()
        telemetryTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { break }
                let includeProcs = (tick % 2 == 0)
                let snap = await Task.detached(priority: .utility) { [monitor = self.monitor] in
                    monitor.sample(includeProcesses: includeProcs)
                }.value

                if includeProcs || self.telemetry.topMemoryProcesses.isEmpty {
                    self.telemetry = snap
                } else {
                    // Process scan runs every other tick: carry the last process lists forward.
                    var merged = snap
                    merged.topMemoryProcesses = self.telemetry.topMemoryProcesses
                    merged.topCPUProcesses = self.telemetry.topCPUProcesses
                    merged.simulatorLoad = self.telemetry.simulatorLoad
                    merged.processCount = self.telemetry.processCount
                    self.telemetry = merged
                }
                if includeProcs {
                    self.checkHeavyCPU(snap)
                }
                self.checkBatteryHUD(snap.battery)

                let point = TelemetryPoint(
                    timestamp: snap.timestamp,
                    cpu: snap.cpuTotalPercent,
                    memory: snap.memory.usedPercent,
                    gpu: snap.gpu.deviceUtilizationPercent,
                    netDownKB: snap.network.bytesInPerSec / 1024.0,
                    netUpKB: snap.network.bytesOutPerSec / 1024.0
                )
                self.history.append(point)
                if self.history.count > 45 {
                    self.history.removeFirst(self.history.count - 45)
                }

                // Auto-notice or auto-optimize when RAM pressure spikes
                if snap.memory.pressure == .critical,
                   self.settings.autoOptimizeCriticalRAM,
                   Date.now.timeIntervalSince(self.lastAutoRAMOptimizeDate) > 600 {
                    self.lastAutoRAMOptimizeDate = .now
                    await self.optimizeRAM()
                } else if self.settings.autoNotifyHighMemory,
                          (snap.memory.pressure != .normal || snap.memory.usedPercent >= 88),
                          Date.now.timeIntervalSince(self.lastMemoryAlertDate) > 300 {
                    self.lastMemoryAlertDate = .now
                    self.postNotice(NotchNotice(
                        kind: .highMemory,
                        title: "Memoria al \(Int(snap.memory.usedPercent))%",
                        subtitle: "\(ByteFormat.compact(snap.memory.availableBytes)) libres · \(ByteFormat.compact(snap.memory.cachedFilesBytes)) en caché",
                        primaryActionTitle: "Optimizar"
                    ))
                }

                tick += 1
                // Nobody is looking while the Mac is locked or asleep: sample far less often.
                let idle = await MainActor.run { SystemActivity.isIdle }
                try? await Task.sleep(for: .seconds(idle ? 15 : 2))
            }
        }
    }

    // MARK: - Dev FSEvents Watcher

    func restartDevWatcher() {
        devWatcher.start(paths: settings.watchedDevFolders) { [weak self] changedPaths in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.scanDevArtifacts(triggerNoticeIfLarge: true, changedHints: changedPaths)
            }
        }
    }

    // MARK: - Scanning Operations

    func runInitialScans() async {
        // Stagger startup scans cleanly so launch stays whisper-quiet (<60 MB RAM, low CPU).
        await scanDevArtifacts(triggerNoticeIfLarge: true)
        await refreshSnapshots()
        await scanSystemJunk()
        await auditApplications()
        await checkWallpaper()
    }

    // MARK: - Wallpaper health

    /// Droppy-style battery charging & low-battery dynamic pill HUDs.
    private func checkBatteryHUD(_ battery: BatterySnapshot) {
        guard battery.present else { return }
        defer { lastKnownChargingState = battery.isPluggedIn }

        if let prev = lastKnownChargingState, !prev && battery.isPluggedIn {
            postNotice(NotchNotice(
                kind: .cleaned,
                title: "Cargando · \(Int(battery.percent))%",
                subtitle: battery.minutesRemaining.map { "Aprox. \($0) min para carga completa" } ?? "Conectado a corriente"
            ), autoDismissAfter: 4.5)
        } else if !battery.isPluggedIn,
                  battery.percent > 0 && battery.percent <= 20,
                  Date.now.timeIntervalSince(lastLowBatteryAlertDate) > 900 {
            lastLowBatteryAlertDate = .now
            postNotice(NotchNotice(
                kind: .failed,
                title: "\(Int(battery.percent))% Batería",
                subtitle: "Conecta el cargador o activa el modo bajo consumo"
            ), autoDismissAfter: 7.0)
        }
    }

    /// Desktops render black when their wallpaper image was deleted (or purged from macOS's temp folder).
    func checkWallpaper() async {
        let health = await Task.detached(priority: .utility) { WallpaperDoctor().diagnose() }.value
        guard health.isBroken, health.replacementPath != nil else { return }
        postNotice(NotchNotice(
            kind: .warning,
            title: "Fondo de pantalla en negro",
            subtitle: "\(health.brokenCount) escritorios apuntan a imágenes borradas",
            primaryActionTitle: "Reparar",
            targetPath: "wallpaper"
        ), autoDismissAfter: 20)
    }

    func repairWallpaper() async {
        do {
            let fixed = try await Task.detached(priority: .userInitiated) { try WallpaperDoctor().repair() }.value
            if fixed > 0 {
                postNotice(NotchNotice(kind: .cleaned, title: "Fondo reparado", subtitle: "\(fixed) escritorios vuelven a tener imagen"))
            }
        } catch {
            report("No se pudo reparar el fondo: \(error.localizedDescription)", tone: .error)
        }
    }

    func runSmartScan() async {
        hasFullDiskAccess = PathSafety.hasFullDiskAccess()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.scanDevArtifacts(triggerNoticeIfLarge: false) }
            group.addTask { await self.scanSystemJunk() }
            group.addTask { await self.auditApplications() }
            group.addTask { await self.refreshSnapshots() }
            group.addTask { await self.checkWallpaper() }
        }
        report(totalSmartReclaimableBytes > 0
            ? "Análisis completo · \(ByteFormat.compact(totalSmartReclaimableBytes)) listos para liberar"
            : "Análisis completo · tu Mac está limpio", tone: totalSmartReclaimableBytes > 0 ? .info : .success)
    }

    func scanDevArtifacts(triggerNoticeIfLarge: Bool = false, changedHints: [String] = []) async {
        guard !isScanningDev else { return }
        isScanningDev = true
        defer { isScanningDev = false }

        let found = await devScanner.scan(roots: settings.watchedDevFolders, includeGlobalCaches: true)
        self.devArtifacts = found

        // Optional automated stale dev cleanup when disk space drops below configured minimum
        let minFreeBytes = UInt64(settings.autoCleanMinFreeGB * 1_000_000_000)
        if settings.autoCleanStaleDevEnabled,
           telemetry.disk.availableBytes > 0,
           telemetry.disk.availableBytes < minFreeBytes {
            let staleTargets = found.filter { !$0.isActiveBuild && !$0.isGlobalCache && $0.ageDays >= settings.devStaleDays }
            if !staleTargets.isEmpty {
                let sizes = Dictionary(uniqueKeysWithValues: staleTargets.map { ($0.path, $0.sizeBytes) })
                await cleanDevPaths(staleTargets.map(\.path), sizes: sizes)
                return
            }
        }

        let thresholdBytes = UInt64(settings.devAlertThresholdGB * 1_000_000_000)
        if triggerNoticeIfLarge,
           settings.autoNotifyDevArtifacts,
           reclaimableDevBytes >= thresholdBytes,
           Date.now.timeIntervalSince(lastDevAlertDate) > 120 {
            lastDevAlertDate = .now
            let biggest = found.first(where: { !$0.isActiveBuild && !$0.isGlobalCache }) ?? found.first
            if let biggest {
                postNotice(NotchNotice(
                    kind: .devBloat,
                    title: biggest.projectName.localizedCaseInsensitiveContains(biggest.artifactKind)
                        ? biggest.projectName
                        : "\(biggest.artifactKind) en \(biggest.projectName)",
                    subtitle: "\(ByteFormat.compact(biggest.sizeBytes)) · \(ByteFormat.compact(reclaimableDevBytes)) en total",
                    primaryActionTitle: "Limpiar \(ByteFormat.compact(biggest.sizeBytes))",
                    targetPath: biggest.path
                ))
            }
        }
    }

    func scanSystemJunk() async {
        guard !isScanningJunk else { return }
        isScanningJunk = true
        defer { isScanningJunk = false }
        self.junkItems = await junkScanner.scan()
        await refreshTrashContents()
    }

    func refreshTrashContents() async {
        trashContents = await TrashEmptier().contents()
    }

    func mapDisk(at path: String? = nil) async {
        guard !isMappingDisk else { return }
        let target = path ?? diskScanTargetPath
        diskScanTargetPath = target
        isMappingDisk = true
        diskScanCurrentFolder = URL(fileURLWithPath: target).lastPathComponent
        defer {
            isMappingDisk = false
            diskScanCurrentFolder = ""
        }

        let mapped = await diskMapper.mapDirectory(at: target, maxTreeDepth: 4) { [weak self] folder, _ in
            Task { @MainActor [weak self] in
                self?.diskScanCurrentFolder = folder
            }
        }
        self.diskRoot = mapped
    }

    func auditApplications() async {
        guard !isAuditingApps else { return }
        isAuditingApps = true
        defer { isAuditingApps = false }
        let (apps, leftovers) = await appAuditor.scanApplications()
        self.installedApps = apps
        self.orphanLeftovers = leftovers

        // Gently prompt in Notch if untouched apps are found and no other notice is active
        if settings.autoAskUnusedApps,
           activeNotice == nil,
           let topUnused = unusedApps.first,
           Date.now.timeIntervalSince(lastUnusedAppAlertDate) > 21_600 {
            lastUnusedAppAlertDate = .now
            postNotice(NotchNotice(
                kind: .unusedApp,
                title: "¿Aún usas \(topUnused.name)?",
                subtitle: "Último uso \(ByteFormat.relativeAge(topUnused.lastUsedDate)) · \(ByteFormat.compact(topUnused.totalSizeBytes))",
                primaryActionTitle: "Revisar",
                targetBundleID: topUnused.bundleID
            ), autoDismissAfter: 9.0)
        }
    }

    func refreshSnapshots() async {
        self.localSnapshots = await optimizer.listLocalSnapshots()
    }

    // MARK: - Optimization & Cleaning Actions

    func refreshDiskNow() {
        malloc_zone_pressure_relief(nil, 0)
        telemetry.disk = SystemMonitor.readDisk()
        telemetry.memory = SystemMonitor.readMemory()
    }

    func refreshMemoryNow() {
        malloc_zone_pressure_relief(nil, 0)
        telemetry.memory = SystemMonitor.readMemory()
    }

    func emptyTrashNow() async {
        guard beginCleaning("Vaciando Papelera…") else { return }
        defer { endCleaning() }

        let result = await TrashEmptier().empty()
        totalReclaimedSessionBytes += result.freedBytes
        junkItems.removeAll { $0.category == .trash && !Self.pathExists($0.path) }
        await refreshTrashContents()
        refreshDiskNow()

        let freed = ByteFormat.compact(result.freedBytes)
        if result.isComplete {
            if result.removedCount == 0 && !result.usedFinder {
                report("La Papelera ya está vacía", tone: .info)
                return
            }
            AppKitHaptics.confirm()
            let detail = result.freedBytes > 0 ? "\(freed) liberados" : "Espacio liberado"
            report("Papelera vaciada · \(detail)")
            postNotice(NotchNotice(kind: .cleaned, title: "Papelera vaciada", subtitle: detail))
        } else if result.removedCount > 0 {
            let reason = result.finderError ?? result.errors.first ?? "elementos protegidos"
            report("Papelera vaciada en parte · \(freed) liberados · \(result.remainingCount) siguen ahí (\(reason))", tone: .warning)
            postNotice(NotchNotice(kind: .warning, title: "Papelera vaciada en parte", subtitle: "\(result.remainingCount) elementos siguen · \(reason)"))
        } else {
            let reason = result.finderError ?? result.errors.first ?? "macOS bloqueó el acceso"
            report("No se pudo vaciar la Papelera: \(reason)", tone: .error)
            postNotice(NotchNotice(kind: .failed, title: "No se pudo vaciar la Papelera", subtitle: reason))
        }
    }

    private static func pathExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    func resetAppDecisions() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let file = support.appendingPathComponent("CleanTrash/app-decisions.json")
        try? FileManager.default.removeItem(at: file)
        for idx in installedApps.indices {
            installedApps[idx].decision = nil
        }
        report("Decisiones de apps sin usar restablecidas", tone: .info)
    }

    func optimizeRAM(deepPurge: Bool = false) async {
        guard !isOptimizingRAM else { return }
        isOptimizingRAM = true
        ramOptimizationProgress = 0.05
        defer {
            isOptimizingRAM = false
            ramOptimizationProgress = 0
        }

        let result = await optimizer.optimizeRAM(deepPurgeWithTouchID: deepPurge) { [weak self] pct in
            Task { @MainActor [weak self] in
                self?.ramOptimizationProgress = pct
            }
        }
        refreshMemoryNow()
        AppKitHaptics.confirm()
        report(result.reclaimedBytes > 0
            ? "RAM optimizada · \(ByteFormat.memory(result.reclaimedBytes)) liberados"
            : "La memoria ya estaba equilibrada", tone: result.reclaimedBytes > 0 ? .success : .info)

        postNotice(NotchNotice(
            kind: .cleaned,
            title: deepPurge ? "Purga profunda de RAM" : "RAM optimizada",
            subtitle: result.reclaimedBytes > 0
                ? "Liberados \(ByteFormat.memory(result.reclaimedBytes)) de memoria inactiva"
                : "Sin cachés inactivas por liberar"
        ))
    }

    func trimGPUCaches() async {
        guard beginCleaning("Limpiando cachés GPU…") else { return }
        defer { endCleaning() }

        let summary = await optimizer.trimGPUCaches()
        totalReclaimedSessionBytes += summary.reclaimedBytes
        refreshDiskNow()
        reportCleanup(summary, title: "Cachés GPU limpias", emptyMessage: "Las cachés de GPU ya estaban limpias")
    }

    func thinAPFSSnapshots() async {
        let res = await optimizer.thinAPFSSnapshots(requestedGB: 25, urgency: 4)
        await refreshSnapshots()
        if res.success {
            report("Snapshots locales de APFS reducidos")
        } else {
            report(res.output.isEmpty ? "No hay snapshots locales de Time Machine que reducir" : "Snapshots: \(res.output)", tone: res.output.isEmpty ? .info : .warning)
        }
    }

    func flushDNS() async {
        let res = await optimizer.flushDNSCache()
        if res.success {
            report("Caché DNS vaciada")
        } else {
            report("No se pudo vaciar la caché DNS: \(res.output)", tone: .error)
        }
    }

    func cleanSelectedDevArtifacts() async {
        let targets = devArtifacts.filter { $0.selected && !$0.isActiveBuild }
        guard !targets.isEmpty else {
            report("No hay artefactos dev seleccionados", tone: .info)
            return
        }
        await cleanDevPaths(targets.map(\.path), sizes: Dictionary(targets.map { ($0.path, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a }))
    }

    func cleanSingleDevArtifact(_ artifact: DevArtifact) async {
        await cleanDevPaths([artifact.path], sizes: [artifact.path: artifact.sizeBytes])
    }

    private func cleanDevPaths(_ paths: [String], sizes: [String: UInt64]) async {
        guard beginCleaning("Limpiando proyectos…") else { return }
        defer { endCleaning() }
        let summary = await performDevClean(paths, sizes: sizes)
        refreshDiskNow()
        reportCleanup(summary, title: "Proyectos limpios")
    }

    private func performDevClean(_ paths: [String], sizes: [String: UInt64]) async -> CleanupSummary {
        let moveToTrash = !settings.permanentDeleteDevBuilds && settings.useTrashByDefault
        let summary = await cleaner.clean(paths: paths, moveToTrash: moveToTrash, knownSizes: sizes)
        totalReclaimedSessionBytes += summary.reclaimedBytes
        let cleanedSet = Set(paths)
        devArtifacts.removeAll { cleanedSet.contains($0.path) && !Self.pathExists($0.path) }
        return summary
    }

    func cleanSelectedJunk() async {
        let targets = junkItems.filter(\.selected)
        guard !targets.isEmpty else {
            report("No hay elementos seleccionados", tone: .info)
            return
        }
        guard beginCleaning("Limpiando basura del sistema…") else { return }
        defer { endCleaning() }
        let summary = await performJunkClean(targets)
        refreshDiskNow()
        reportCleanup(summary, title: "Limpieza completa")
    }

    private func performJunkClean(_ targets: [JunkItem]) async -> CleanupSummary {
        var total = CleanupSummary()
        let trashTargets = targets.filter { $0.category == .trash }
        let otherTargets = targets.filter { $0.category != .trash }

        if !trashTargets.isEmpty {
            let allTrashSelected = junkItems.filter { $0.category == .trash }.allSatisfy(\.selected)
            if allTrashSelected {
                // Whole Trash selected → same robust path as "Vaciar Papelera" (permission repair + Finder fallback).
                let result = await TrashEmptier().empty()
                total.removedCount += result.removedCount
                total.failedCount += result.remainingCount + (result.finderError != nil && result.remainingCount == 0 && result.accessDenied ? 1 : 0)
                total.reclaimedBytes += result.freedBytes
                total.errors += (result.finderError.map { [$0] } ?? []) + result.errors
            } else {
                // Items already in ~/.Trash must be deleted for real (moving Trash → Trash frees nothing).
                let sizes = Dictionary(trashTargets.map { ($0.path, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
                let s = await cleaner.clean(paths: trashTargets.map(\.path), moveToTrash: false, knownSizes: sizes)
                total.merge(s)
            }
        }

        if !otherTargets.isEmpty {
            let sizes = Dictionary(otherTargets.map { ($0.path, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
            let s = await cleaner.clean(paths: otherTargets.map(\.path), moveToTrash: settings.useTrashByDefault, knownSizes: sizes)
            total.merge(s)
        }

        totalReclaimedSessionBytes += total.reclaimedBytes
        let targetSet = Set(targets.map(\.path))
        junkItems.removeAll { targetSet.contains($0.path) && !Self.pathExists($0.path) }
        await refreshTrashContents()
        return total
    }

    func cleanDiskNode(_ node: DiskNode, permanent: Bool = false) async {
        guard beginCleaning("Eliminando \(node.name)…") else { return }
        let summary = await cleaner.clean(
            paths: [node.path],
            moveToTrash: !permanent && settings.useTrashByDefault,
            knownSizes: [node.path: node.sizeBytes]
        )
        totalReclaimedSessionBytes += summary.reclaimedBytes
        refreshDiskNow()
        endCleaning()
        reportCleanup(summary, title: "\(node.name) eliminado")
        await mapDisk(at: diskScanTargetPath)
    }

    /// One-click Smart Clean: selected dev artifacts + selected system junk, reported as one result.
    func runSmartClean() async {
        let devTargets = devArtifacts.filter { $0.selected && !$0.isActiveBuild }
        let junkTargets = junkItems.filter(\.selected)
        guard !devTargets.isEmpty || !junkTargets.isEmpty else {
            report("No hay nada seleccionado para limpiar", tone: .info)
            return
        }
        guard beginCleaning("Limpieza inteligente…") else { return }
        defer { endCleaning() }

        var total = CleanupSummary()
        if !devTargets.isEmpty {
            let sizes = Dictionary(devTargets.map { ($0.path, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
            total.merge(await performDevClean(devTargets.map(\.path), sizes: sizes))
        }
        if !junkTargets.isEmpty {
            total.merge(await performJunkClean(junkTargets))
        }
        refreshDiskNow()
        reportCleanup(total, title: "Limpieza inteligente")
    }

    // MARK: - App Audit Decisions & Deep Uninstaller

    func markAppDecision(_ app: InstalledAppInfo, decision: AppKeepDecision, snoozeDays: Int = 30) {
        let snoozeDate = decision == .snoozed ? Date.now.addingTimeInterval(Double(snoozeDays) * 86_400) : nil
        let record = AppDecisionRecord(bundleID: app.bundleID, decision: decision, decidedAt: .now, snoozeUntil: snoozeDate)
        appAuditor.saveDecision(record)
        if let idx = installedApps.firstIndex(where: { $0.id == app.id }) {
            installedApps[idx].decision = record
        }
    }

    func deepUninstallApp(_ app: InstalledAppInfo, selectedRelatedPaths: [String]? = nil) async {
        guard beginCleaning("Desinstalando \(app.name)…") else { return }
        defer { endCleaning() }

        let related = selectedRelatedPaths ?? app.relatedFiles.filter(\.selected).map(\.path)
        var allPaths = related
        allPaths.append(app.appPath)

        // Check whether removal will already trigger the native macOS Admin Touch ID sheet.
        // If not, ask for Touch ID directly via LocalAuthentication so every uninstall needs only 1 Touch ID tap.
        let fm = FileManager.default
        let willNeedAdmin = allPaths.contains { path in
            path.hasPrefix("/Library/") || !fm.isWritableFile(atPath: path)
        }
        if !willNeedAdmin {
            let authorized = await cleaner.authenticateWithTouchID(
                reason: "Desinstalar \(app.name) y todos sus archivos"
            )
            guard authorized else {
                report("Desinstalación de \(app.name) cancelada", tone: .info)
                return
            }
        }

        // Terminate running instance gracefully before cleaning
        if app.isRunning {
            for running in NSWorkspace.shared.runningApplications where running.bundleIdentifier == app.bundleID {
                running.terminate()
            }
            try? await Task.sleep(for: .milliseconds(400))
        }

        var sizes: [String: UInt64] = [app.appPath: app.bundleSizeBytes]
        for file in app.relatedFiles {
            sizes[file.path] = file.sizeBytes
        }

        let keywords = [app.name, app.bundleID].filter { $0.count >= 4 }
        let moveToTrash = settings.useTrashByDefault
        let summary = await cleaner.clean(
            paths: allPaths,
            moveToTrash: moveToTrash,
            knownSizes: sizes,
            allowAdminEscalation: true,
            processKillKeywords: keywords
        )
        totalReclaimedSessionBytes += summary.reclaimedBytes
        refreshDiskNow()

        let bundleRemoved = !fm.fileExists(atPath: app.appPath)
        if bundleRemoved {
            installedApps.removeAll { $0.id == app.id }
            AppKitHaptics.confirm()
            let extraCount = max(0, summary.removedCount - 1)
            let destLabel = moveToTrash ? "movida a la Papelera" : "eliminada del disco"
            report("Eliminado \(app.name)\(extraCount > 0 ? " y \(extraCount) archivos extra" : "") · \(ByteFormat.compact(summary.reclaimedBytes)) liberados")
            postNotice(NotchNotice(
                kind: .cleaned,
                title: "\(app.name) eliminada",
                subtitle: "\(ByteFormat.compact(summary.reclaimedBytes)) (\(destLabel))"
            ))
        } else {
            let reason = summary.errors.first ?? "macOS bloqueó la eliminación de \(app.name)"
            report("No se pudo eliminar \(app.name): \(reason)", tone: .error)
            postNotice(NotchNotice(
                kind: .failed,
                title: "No se pudo eliminar \(app.name)",
                subtitle: reason
            ))
        }
    }

    func cleanSelectedOrphanLeftovers() async {
        let selected = orphanLeftovers.filter(\.selected)
        guard !selected.isEmpty else { return }
        guard beginCleaning("Eliminando restos de apps…") else { return }
        defer { endCleaning() }

        let sizes = Dictionary(selected.map { ($0.path, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
        let summary = await cleaner.clean(paths: selected.map(\.path), moveToTrash: settings.useTrashByDefault, knownSizes: sizes)
        totalReclaimedSessionBytes += summary.reclaimedBytes
        let set = Set(selected.map(\.path))
        orphanLeftovers.removeAll { set.contains($0.path) && !Self.pathExists($0.path) }
        refreshDiskNow()
        reportCleanup(summary, title: "Restos de apps eliminados")
    }

    func terminateProcess(_ process: ProcessSample, force: Bool = false) {
        Task { await forceQuit([process], graceful: !force) }
    }

    // MARK: - CPU hogs & Simulators

    /// User-owned, non-critical processes burning ≥ 40 % CPU (one core ≈ 100 %). Simulators are handled as a group.
    var heavyCPUProcesses: [ProcessSample] {
        telemetry.topCPUProcesses.filter {
            $0.isKillable && !$0.isSimulator && $0.cpuPercent >= 40 && !quittingPIDs.contains($0.pid)
        }
    }

    var visibleCPUProcesses: [ProcessSample] {
        telemetry.topCPUProcesses.filter { !$0.isSimulator && !quittingPIDs.contains($0.pid) }
    }

    /// The Mac is effectively overloaded when runnable threads far exceed the core count.
    var isCPUOverloaded: Bool {
        telemetry.loadAverage > Double(telemetry.coreCount) * 2 || telemetry.cpuTotalPercent >= 90
    }

    /// One-line verdict for the "Estado del Mac" header: worst signal wins, with the reason that caused it.
    var macHealth: MacHealth {
        var issues: [(level: MacHealth.Level, reason: String, area: MacHealth.Area)] = []
        let t = telemetry
        let cores = Double(max(1, t.coreCount))

        switch t.memory.pressure {
        case .critical: issues.append((.critical, "Memoria al límite", .memory))
        case .warning: issues.append((.attention, "Memoria con presión alta", .memory))
        default: break
        }
        if t.loadAverage > cores * 6 || t.cpuTotalPercent >= 97 {
            issues.append((.critical, "CPU saturada · carga \(Int(t.loadAverage))", .cpu))
        } else if isCPUOverloaded {
            issues.append((.attention, "CPU muy ocupada · carga \(Int(t.loadAverage))", .cpu))
        }
        if t.simulatorLoad.cpuPercent >= 150 {
            issues.append((.attention, "\(Int(t.simulatorLoad.cpuPercent))% de CPU en simuladores iOS", .cpu))
        }
        let freeRatio = t.disk.totalBytes > 0 ? Double(t.disk.availableBytes) / Double(t.disk.totalBytes) : 1
        if freeRatio < 0.05 {
            issues.append((.critical, "Disco casi lleno", .disk))
        } else if freeRatio < 0.10 {
            issues.append((.attention, "Poco espacio libre", .disk))
        }
        switch t.thermalState {
        case "Crítica": issues.append((.critical, "Temperatura crítica", .cpu))
        case "Caliente": issues.append((.attention, "Mac caliente", .cpu))
        default: break
        }

        let worst = issues.map(\.level).max() ?? .good
        let top = issues.first { $0.level == worst }
        return MacHealth(level: worst, reason: top?.reason, area: top?.area, issueCount: issues.count)
    }

    /// Force-quits processes (SIGKILL / forceTerminate) and reports what really died.
    func forceQuit(_ processes: [ProcessSample], graceful: Bool = false) async {
        let targets = processes.filter(\.isKillable)
        guard !targets.isEmpty else {
            report("Esos procesos son del sistema; macOS no deja cerrarlos", tone: .info)
            return
        }
        quittingPIDs.formUnion(targets.map(\.pid))
        for process in targets {
            _ = optimizer.terminateProcess(pid: process.pid, force: !graceful)
        }
        try? await Task.sleep(for: .milliseconds(graceful ? 2500 : 700))

        let survivors = targets.filter { kill($0.pid, 0) == 0 }
        let killed = targets.count - survivors.count
        quittingPIDs.subtract(survivors.map(\.pid))
        telemetry.topCPUProcesses.removeAll { p in targets.contains { $0.pid == p.pid } && !survivors.contains { $0.pid == p.pid } }
        telemetry.topMemoryProcesses.removeAll { p in targets.contains { $0.pid == p.pid } && !survivors.contains { $0.pid == p.pid } }

        let names = targets.prefix(3).map(\.name).joined(separator: ", ")
        if survivors.isEmpty {
            AppKitHaptics.confirm()
            report(killed == 1 ? "\(names) cerrado" : "\(killed) procesos cerrados: \(names)")
            postNotice(NotchNotice(kind: .cleaned, title: killed == 1 ? "\(names) cerrado" : "\(killed) procesos cerrados", subtitle: "CPU liberada"))
        } else if killed > 0 {
            report("\(killed) cerrados · \(survivors.map(\.name).joined(separator: ", ")) siguen abiertos", tone: .warning)
        } else if graceful {
            report("\(names) no respondió; usa Forzar cierre", tone: .warning)
        } else {
            report("No se pudo cerrar \(names)", tone: .error)
        }
    }

    func quitHeavyCPUApps() async {
        let heavy = heavyCPUProcesses
        guard !heavy.isEmpty else {
            report("No hay apps tuyas usando demasiada CPU", tone: .info)
            return
        }
        await forceQuit(heavy)
    }

    func refreshSimulators() async {
        bootedSimulators = await simulatorController.bootedDevices()
    }

    func shutdownSimulators(_ devices: [SimulatorDevice]? = nil) async {
        guard !isShuttingDownSimulators else { return }
        isShuttingDownSimulators = true
        defer { isShuttingDownSimulators = false }
        let before = telemetry.simulatorLoad
        let targets = devices ?? bootedSimulators
        let error = await simulatorController.shutdown(devices == nil ? [] : targets.map(\.udid))
        await refreshSimulators()
        if let error, !bootedSimulators.isEmpty {
            report("No se pudieron apagar los simuladores: \(error)", tone: .error)
            return
        }
        AppKitHaptics.confirm()
        let count = devices?.count ?? max(targets.count, 1)
        let detail = before.processCount > 0
            ? "\(before.processCount) procesos y ~\(Int(before.cpuPercent))% de CPU liberados"
            : "CPU liberada"
        report("\(count == 1 ? "Simulador apagado" : "\(count) simuladores apagados") · \(detail)")
        postNotice(NotchNotice(kind: .cleaned, title: count == 1 ? "Simulador apagado" : "\(count) simuladores apagados", subtitle: detail))
    }

    /// Automatic heads-up (never automatic killing): simulators hogging the Mac, or one app pinned at high CPU for 30 s.
    private func checkHeavyCPU(_ snap: SystemTelemetry) {
        guard activeNotice == nil, Date.now.timeIntervalSince(lastCPUAlertDate) > 600 else { return }

        if snap.simulatorLoad.cpuPercent >= 150 {
            lastCPUAlertDate = .now
            Task { await refreshSimulators() }
            postNotice(NotchNotice(
                kind: .heavyCPU,
                title: "Simuladores usando \(Int(snap.simulatorLoad.cpuPercent))% de CPU",
                subtitle: "\(snap.simulatorLoad.processCount) procesos · \(ByteFormat.memory(snap.simulatorLoad.memoryBytes)) de RAM",
                primaryActionTitle: "Apagar",
                targetPath: "simulators"
            ), autoDismissAfter: 12)
            return
        }

        let now = Date.now
        let hogs = snap.topCPUProcesses.filter { $0.isKillable && !$0.isSimulator && $0.cpuPercent >= 90 }
        heavySince = heavySince.filter { pid, _ in hogs.contains { $0.pid == pid } }
        for hog in hogs where heavySince[hog.pid] == nil {
            heavySince[hog.pid] = now
        }
        if let sustained = hogs.first(where: { now.timeIntervalSince(heavySince[$0.pid] ?? now) >= 30 }) {
            lastCPUAlertDate = now
            postNotice(NotchNotice(
                kind: .heavyCPU,
                title: "\(sustained.name) usa \(Int(sustained.cpuPercent))% de CPU",
                subtitle: "Lleva más de 30 s así · \(ByteFormat.memory(sustained.memoryBytes)) de RAM",
                primaryActionTitle: "Forzar cierre",
                targetPath: "pid:\(sustained.pid)"
            ), autoDismissAfter: 12)
        }
    }

    // MARK: - Notch Notice Management

    func postNotice(_ notice: NotchNotice, autoDismissAfter seconds: Double = 7.0) {
        activeNotice = notice
        noticeDismissTask?.cancel()
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if self?.activeNotice?.id == notice.id {
                withAnimation(Mono.foldingSpring) {
                    self?.activeNotice = nil
                }
            }
        }
    }

    func handleNoticePrimaryAction(_ notice: NotchNotice) {
        dismissNotice()
        Task {
            switch notice.kind {
            case .devBloat:
                if let path = notice.targetPath,
                   let match = devArtifacts.first(where: { $0.path == path }) {
                    await cleanSingleDevArtifact(match)
                } else {
                    await cleanSelectedDevArtifacts()
                }
            case .highMemory:
                await optimizeRAM()
            case .heavyCPU:
                if notice.targetPath == "simulators" {
                    await refreshSimulators()
                    await shutdownSimulators()
                } else if let raw = notice.targetPath?.split(separator: ":").last, let pid = Int32(raw),
                          let process = telemetry.topCPUProcesses.first(where: { $0.pid == pid }) {
                    await forceQuit([process])
                }
            case .unusedApp:
                selectedSection = .appsAudit
                onOpenMainWindow?()
            case .warning where notice.targetPath == "wallpaper":
                await repairWallpaper()
            case .warning where notice.targetPath == "ocr-permission":
                VisionTextCapture.openScreenRecordingSettings()
            case .cleaned where notice.targetPath?.hasPrefix("breather:") == true:
                productivity.breather.completeBreak()
            case .cleaned, .warning, .failed:
                break
            }
        }
    }

    func dismissNotice() {
        noticeDismissTask?.cancel()
        withAnimation(Mono.foldingSpring) {
            activeNotice = nil
        }
    }

    func openFullDiskAccessSettings() {
        // Trigger a read probe on a TCC-protected path so macOS TCC registers CleanTrash.app in the FDA list.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        _ = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/Library/Mail")
        _ = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/Library/Safari/Bookmarks.plist"))
        _ = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.Trash")

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealAppBundleInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func ejectVolume(_ volume: ExternalVolumeInfo) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume.path))
            report("\(volume.name) expulsado")
        } catch {
            report("No se pudo expulsar \(volume.name): \(error.localizedDescription)", tone: .error)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                report("CleanTrash se abrirá al iniciar sesión")
            } else {
                try SMAppService.mainApp.unregister()
                report("Inicio automático desactivado", tone: .info)
            }
        } catch {
            report("El inicio automático requiere CleanTrash en /Applications: \(error.localizedDescription)", tone: .error)
        }
    }

    func cleanAllCleanableInDiskNode(_ parent: DiskNode) async {
        let targets = parent.children.filter { $0.isCleanableCandidate && !PathSafety.isProtectedPath($0.path) }
        guard !targets.isEmpty else { return }
        guard beginCleaning("Limpiando \(parent.name)…") else { return }

        let sizes = Dictionary(targets.map { ($0.path, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
        let summary = await cleaner.clean(
            paths: targets.map(\.path),
            moveToTrash: settings.useTrashByDefault,
            knownSizes: sizes
        )
        totalReclaimedSessionBytes += summary.reclaimedBytes
        refreshDiskNow()
        endCleaning()
        reportCleanup(summary, title: "\(parent.name) limpio")
        await mapDisk(at: diskScanTargetPath)
    }

    // MARK: - Settings Persistence

    private static func loadSettings(from url: URL) -> CleanTrashSettings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CleanTrashSettings.self, from: data) else {
            return CleanTrashSettings()
        }
        return decoded
    }

    private func saveSettings() {
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }
}
