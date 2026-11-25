import Charts
import CleanTrashCore
import SwiftUI

/// Which vital the notch is drilled into (tapping a tile on the Home / Estado tab).
enum NotchDetail: String, Equatable {
    case cpu, memory, gpu, disk

    /// Generous shelf height so every drill-down (including simulator banner + process list)
    /// renders completely without ever clipping the bottom rows.
    var extraHeight: CGFloat {
        switch self {
        case .cpu: return 156
        case .memory: return 164
        case .gpu: return 74
        case .disk: return 78
        }
    }
}

/// CleanMyMac-style drill-down inside the notch: live chart, breakdown, and the actions that fix the
/// problem (force-quit CPU hogs, shut down simulators, optimize RAM, empty trash…).
struct NotchDetailView: View {
    @Bindable var appState: AppState
    @Bindable var coordinator: NotchCoordinator
    let detail: NotchDetail

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var armedAction: String?
    @State private var armTask: Task<Void, Never>?

    private var t: SystemTelemetry { appState.telemetry }

    var body: some View {
        Group {
            if Mono.snapshotMode {
                detailContent
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    detailContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: detail) {
            if detail == .cpu { await appState.refreshSimulators() }
        }
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch detail {
            case .cpu: cpuDetail
            case .memory: memoryDetail
            case .gpu: gpuDetail
            case .disk: diskDetail
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Shared chrome

    private func header(icon: Icon3DName, title: String, value: String, valueTint: Color = .white, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(reduceMotion ? .none : Mono.betweenSpring) { coordinator.detail = nil }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
            .help("Volver")

            Icon3D(name: icon, size: 30)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(1)

            Text(value)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(valueTint)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 6)
            trailing()
        }
    }

    private func pillButton(_ title: String, key: String? = nil, destructive: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        let armed = key != nil && armedAction == key
        return Button {
            if let key { confirmOrArm(key, action: action) } else { action() }
        } label: {
            Text(armed ? "¿Seguro?" : title)
                .font(.system(size: 10.5, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(armed || destructive ? Color.white : Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(armed ? Mono.danger : (destructive ? Mono.danger.opacity(0.75) : Color.white)))
                .contentShape(Capsule())
                .contentTransition(.interpolate)
        }
        .buttonStyle(NotchButtonStyle())
        .disabled(disabled && !armed)
        .opacity(disabled && !armed ? 0.4 : 1)
    }

    private func confirmOrArm(_ key: String, action: @escaping () -> Void) {
        if armedAction == key {
            armTask?.cancel()
            armedAction = nil
            action()
            return
        }
        withAnimation(Mono.betweenSpring) { armedAction = key }
        armTask?.cancel()
        armTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(Mono.betweenSpring) { armedAction = nil }
        }
    }

    private func historyChart(_ value: KeyPath<TelemetryPoint, Double>, tint: Color = .white) -> some View {
        Chart(appState.history) { point in
            AreaMark(x: .value("t", point.timestamp), y: .value("%", min(100, point[keyPath: value])))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", point.timestamp), y: .value("%", min(100, point[keyPath: value])))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 2)
    }

    private func stat(_ label: String, _ value: String, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(1)
            Text(value)
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private func processRow(_ p: ProcessSample, metric: String, fraction: Double) -> some View {
        HStack(spacing: 8) {
            Group {
                if let path = p.appPath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high)
                } else {
                    Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
                }
            }
            .frame(width: 18, height: 18)

            Text(p.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: 46, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(fraction >= 0.8 ? Mono.danger : (fraction >= 0.4 ? Mono.caution : Color.white.opacity(0.85)))
                        .frame(width: 46 * min(1, max(0.03, fraction)), height: 4)
                }

            Text(metric)
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 52, alignment: .trailing)
                .contentTransition(.numericText())

            if p.isKillable {
                Button {
                    confirmOrArm("kill-\(p.pid)") {
                        Task { await appState.forceQuit([p]) }
                    }
                } label: {
                    Image(systemName: armedAction == "kill-\(p.pid)" ? "xmark" : "xmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(armedAction == "kill-\(p.pid)" ? Color.white : Color.white.opacity(0.7))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(armedAction == "kill-\(p.pid)" ? Mono.danger : Color.white.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                .help(armedAction == "kill-\(p.pid)" ? "Toca otra vez para forzar el cierre" : "Forzar cierre de \(p.name)")
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .frame(width: 24, height: 22)
                    .help("Proceso del sistema: macOS no permite cerrarlo")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .notchHoverRow(cornerRadius: 7)
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.45))
    }

    // MARK: - CPU

    private var cpuDetail: some View {
        let heavy = appState.heavyCPUProcesses
        let sim = t.simulatorLoad
        let showSim = sim.processCount > 0 && (sim.cpuPercent >= 5 || !appState.bootedSimulators.isEmpty)
        let rows = Array(appState.visibleCPUProcesses.prefix(showSim ? 4 : 5))
        let maxCPU = Double(max(1, t.coreCount)) * 100

        return VStack(alignment: .leading, spacing: 9) {
            header(icon: .cpu, title: "CPU", value: "\(Int(t.cpuTotalPercent))%",
                   valueTint: t.cpuTotalPercent >= 85 ? Mono.danger : .white) {
                if !heavy.isEmpty {
                    pillButton("Cerrar \(heavy.count) pesada\(heavy.count == 1 ? "" : "s")", key: "killHeavy", destructive: true) {
                        Task { await appState.quitHeavyCPUApps() }
                    }
                    .help("Fuerza el cierre de: " + heavy.map(\.name).joined(separator: ", "))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }

            historyChart(\.cpu, tint: t.cpuTotalPercent >= 85 ? Mono.danger : Mono.cpuAccent)

            HStack(spacing: 6) {
                stat("Usuario", "\(Int(t.cpuUserPercent))%")
                stat("Sistema", "\(Int(t.cpuSystemPercent))%", tint: t.cpuSystemPercent >= 50 ? Mono.caution : .white)
                stat("Carga", String(format: "%.0f", t.loadAverage), tint: appState.isCPUOverloaded ? Mono.danger : .white)
                stat("Procesos", "\(t.processCount)")
            }

            if showSim {
                simulatorBanner(sim)
            }

            sectionLabel(rows.isEmpty ? "Sin procesos activos" : "Más CPU · 100% = 1 núcleo")
            VStack(spacing: 4) {
                ForEach(rows) { p in
                    processRow(p, metric: "\(Int(p.cpuPercent))%", fraction: p.cpuPercent / min(maxCPU, 100))
                }
            }
            .animation(reduceMotion ? .none : Mono.betweenSpring, value: rows.map(\.pid))
        }
    }

    private func simulatorBanner(_ sim: SimulatorLoad) -> some View {
        let count = appState.bootedSimulators.count
        let heavy = sim.cpuPercent >= 100
        return HStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(heavy ? Mono.caution : .white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill((heavy ? Mono.caution : Color.white).opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(count > 0 ? "\(count) simulador\(count == 1 ? "" : "es") iOS encendido\(count == 1 ? "" : "s")" : "Simuladores iOS")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(Int(sim.cpuPercent))% CPU · \(sim.processCount) procesos · \(ByteFormat.memory(sim.memoryBytes))")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
                    .help(appState.bootedSimulators.map(\.name).joined(separator: ", "))
            }
            Spacer(minLength: 4)
            pillButton(appState.isShuttingDownSimulators ? "Apagando…" : "Apagar", key: "sims",
                       destructive: heavy, disabled: appState.isShuttingDownSimulators) {
                Task { await appState.shutdownSimulators() }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill((heavy ? Mono.caution : Color.white).opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder((heavy ? Mono.caution : Color.white).opacity(0.22), lineWidth: 1))
    }

    // MARK: - Memory

    private var memoryDetail: some View {
        let m = t.memory
        let total = Double(max(1, m.totalBytes))
        let segments: [(String, UInt64, Color)] = [
            ("Apps", m.appBytes, .white),
            ("Sistema", m.wiredBytes, Color.white.opacity(0.62)),
            ("Comprimida", m.compressedBytes, Mono.caution),
            ("Caché", m.cachedFilesBytes, Color.white.opacity(0.32)),
        ]
        let sim = t.simulatorLoad
        let showSim = sim.memoryBytes > 1_000_000_000
        let rows = Array(t.topMemoryProcesses.filter { !$0.isSimulator && !appState.quittingPIDs.contains($0.pid) }.prefix(showSim ? 3 : 4))
        let pressureTint: Color = m.pressure == .normal ? Mono.healthy : (m.pressure == .critical ? Mono.danger : Mono.caution)

        return VStack(alignment: .leading, spacing: 9) {
            header(icon: .memory, title: "Memoria", value: "\(Int(m.usedPercent))%", valueTint: m.usedPercent >= 88 ? Mono.caution : .white) {
                pillButton(appState.isOptimizingRAM ? "Liberando…" : "Optimizar", disabled: appState.isOptimizingRAM) {
                    Task { await appState.optimizeRAM() }
                }
            }

            historyChart(\.memory, tint: m.usedPercent >= 88 ? Mono.caution : Mono.ramAccent)

            // Composition bar
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.0) { seg in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(seg.2)
                                .frame(width: max(2, geo.size.width * Double(seg.1) / total))
                        }
                        RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                    }
                }
                .frame(height: 8)
                HStack(spacing: 10) {
                    ForEach(segments, id: \.0) { seg in
                        HStack(spacing: 4) {
                            Circle().fill(seg.2).frame(width: 6, height: 6)
                            Text("\(seg.0) \(ByteFormat.memory(seg.1))")
                                .font(.system(size: 9, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                stat("Presión", m.pressure.label, tint: pressureTint)
                stat("En uso", "\(ByteFormat.memory(m.usedBytes))")
                stat("Swap", ByteFormat.memory(m.swapUsedBytes), tint: m.swapUsedBytes > 2_000_000_000 ? Mono.caution : .white)
            }

            if showSim {
                simulatorBanner(sim)
            }

            sectionLabel("Más memoria")
            VStack(spacing: 4) {
                ForEach(rows) { p in
                    processRow(p, metric: ByteFormat.memory(p.memoryBytes), fraction: Double(p.memoryBytes) / total * 4)
                }
            }
            .animation(reduceMotion ? .none : Mono.betweenSpring, value: rows.map(\.pid))
        }
    }

    // MARK: - GPU

    private var gpuDetail: some View {
        let g = t.gpu
        let simHeavy = t.simulatorLoad.processCount > 0
        return VStack(alignment: .leading, spacing: 9) {
            header(icon: .gpu, title: "GPU · \(g.modelName)", value: "\(Int(g.deviceUtilizationPercent))%") {
                pillButton(appState.isCleaning ? "Limpiando…" : "Limpiar cachés", disabled: appState.isCleaning) {
                    Task { await appState.trimGPUCaches() }
                }
            }

            historyChart(\.gpu, tint: Mono.gpuAccent)

            HStack(spacing: 6) {
                stat("Render", "\(Int(g.rendererUtilizationPercent))%")
                stat("Tiler", "\(Int(g.tilerUtilizationPercent))%")
                stat("En uso", ByteFormat.memory(g.inUseMemoryBytes))
                stat("Asignada", ByteFormat.memory(g.allocatedMemoryBytes))
            }

            VStack(alignment: .leading, spacing: 6) {
                tipRow(icon: "sparkles", text: "Limpiar cachés borra shaders compilados de Metal, WebGPU y Electron. Se regeneran al abrir cada app.")
                if simHeavy {
                    tipRow(icon: "iphone.gen3", text: "Los simuladores iOS dibujan con la GPU (SimMetalHost). Apágalos desde el detalle de CPU si no los usas.", tint: Mono.caution)
                }
                if g.deviceUtilizationPercent >= 80 {
                    tipRow(icon: "flame", text: "GPU casi al máximo: cierra pestañas con video/3D o juegos en segundo plano.", tint: Mono.caution)
                }
            }
        }
    }

    private func tipRow(icon: String, text: String, tint: Color = .white) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    // MARK: - Disk

    private var diskDetail: some View {
        let d = t.disk
        let total = Double(max(1, d.totalBytes))
        let apps = appState.installedApps.reduce(0 as UInt64) { $0 + $1.totalSizeBytes }
        let junk = appState.totalSmartReclaimableBytes + appState.trashContents.totalBytes
        let used = d.totalBytes > d.availableBytes ? d.totalBytes - d.availableBytes : 0
        let known = apps + junk
        let other = used > known ? used - known : 0

        return VStack(alignment: .leading, spacing: 9) {
            header(icon: .disk, title: d.volumeName, value: ByteFormat.compact(d.availableBytes)) {
                pillButton("Ver mapa") {
                    coordinator.isExpanded = false
                    appState.selectedSection = .diskMap
                    appState.onOpenMainWindow?()
                    if appState.diskRoot == nil { Task { await appState.mapDisk() } }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                DotMatrixStorageBar(
                    appsFraction: Double(apps) / total,
                    cleanableFraction: Double(junk) / total,
                    systemFraction: Double(other) / total
                )
                .frame(height: 36)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))

                HStack(spacing: 12) {
                    legend(Mono.appsAccent, "Apps \(ByteFormat.compact(apps))")
                    legend(Mono.junkAccent, "Recuperable \(ByteFormat.compact(junk))")
                    legend(.white.opacity(0.65), "Sistema \(ByteFormat.compact(other))")
                    legend(.white.opacity(0.22), "Libre \(ByteFormat.compact(d.availableBytes))")
                }
            }
            .padding(.top, 2)

            sectionLabel("Lo que puedes liberar")
            VStack(spacing: 5) {
                diskRow(icon: "terminal", title: "Proyectos (build, node_modules…)", bytes: appState.reclaimableDevBytes, actionTitle: "Limpiar", key: "disk-dev") {
                    Task { await appState.cleanSelectedDevArtifacts() }
                }
                diskRow(icon: "internaldrive", title: "Cachés y registros del sistema", bytes: appState.reclaimableJunkBytes, actionTitle: "Revisar", key: nil) {
                    coordinator.isExpanded = false
                    appState.selectedSection = .systemJunk
                    appState.onOpenMainWindow?()
                }
                diskRow(icon: "trash", title: "Papelera", bytes: appState.trashContents.totalBytes, actionTitle: "Vaciar", key: "disk-trash",
                        forceEnabled: !appState.trashContents.readable) {
                    Task { await appState.emptyTrashNow() }
                }
                diskRow(icon: "app.dashed", title: "\(appState.unusedApps.count) apps sin usar", bytes: appState.unusedAppsBytes, actionTitle: "Revisar", key: nil) {
                    coordinator.isExpanded = false
                    appState.selectedSection = .appsAudit
                    appState.onOpenMainWindow?()
                }
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
        }
    }

    private func diskRow(icon: String, title: String, bytes: UInt64, actionTitle: String, key: String?,
                         forceEnabled: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            if bytes == 0 && !forceEnabled {
                Label("Limpio", systemImage: "checkmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Mono.healthy)
                    .padding(.horizontal, 6)
            } else {
                Text(bytes > 0 ? ByteFormat.compact(bytes) : "?")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                pillButton(actionTitle, key: key, disabled: appState.isCleaning, action: action)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .notchHoverRow(cornerRadius: 8)
    }
}

extension MacHealth.Area {
    var notchDetail: NotchDetail {
        switch self {
        case .memory: return .memory
        case .cpu: return .cpu
        case .disk: return .disk
        }
    }
}
