import Charts
import CleanTrashCore
import SwiftUI

struct OverviewView: View {
    @Bindable var appState: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var confirmSmartClean = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerHero
                bentoTelemetryGrid
                if !appState.telemetry.externalVolumes.isEmpty {
                    externalVolumesStrip
                }
                liveChartStrip
                actionableInsightsRow
            }
            .padding(20)
        }
    }

    // MARK: - Smart Care Hero

    private var headerHero: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(appState.telemetry.memory.pressure == .normal ? Mono.healthy : Mono.caution)
                            .frame(width: 7, height: 7)
                        Text(appState.telemetry.memory.pressure == .normal ? "Mac en buen estado" : "Memoria con carga alta")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(appState.telemetry.memory.pressure == .normal ? Mono.healthy : Mono.caution)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill((appState.telemetry.memory.pressure == .normal ? Mono.healthy : Mono.caution).opacity(0.14)))

                    MonoTag(text: "\(appState.telemetry.gpu.modelName) · \(appState.telemetry.coreCount) núcleos")
                }

                Text(appState.totalSmartReclaimableBytes > 0
                     ? "\(ByteFormat.compact(appState.totalSmartReclaimableBytes)) listos para liberar"
                     : "Tu Mac está limpio y ligero")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Mono.ink(scheme))
                    .contentTransition(.numericText())

                Text("Proyectos \(ByteFormat.compact(appState.reclaimableDevBytes)) · Sistema \(ByteFormat.compact(appState.reclaimableJunkBytes)) · Papelera \(ByteFormat.compact(appState.trashContents.totalBytes)) · \(appState.unusedApps.count) apps sin usar")
                    .font(.system(size: 12))
                    .foregroundStyle(Mono.muted(scheme))
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    Task { await appState.runSmartScan() }
                } label: {
                    Label(
                        appState.isScanningDev || appState.isScanningJunk ? "Analizando…" : "Analizar",
                        systemImage: "magnifyingglass"
                    )
                }
                .buttonStyle(MonoGhostButtonStyle())
                .disabled(appState.isScanningDev || appState.isScanningJunk)

                Button {
                    confirmSmartClean = true
                } label: {
                    Label(
                        appState.isCleaning ? (appState.cleaningLabel ?? "Limpiando…") : "Limpiar \(ByteFormat.compact(appState.totalSmartReclaimableBytes))",
                        systemImage: "sparkles"
                    )
                }
                .buttonStyle(MonoPrimaryButtonStyle())
                .disabled(appState.totalSmartReclaimableBytes == 0 || appState.isCleaning)
                .confirmationDialog(
                    "¿Limpiar \(ByteFormat.compact(appState.totalSmartReclaimableBytes))?",
                    isPresented: $confirmSmartClean,
                    titleVisibility: .visible
                ) {
                    Button("Limpiar ahora", role: .destructive) {
                        Task { await appState.runSmartClean() }
                    }
                    Button("Revisar primero") { appState.selectedSection = .systemJunk }
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text(smartCleanMessage)
                }
            }
        }
        .padding(18)
        .monoCard(radius: 16, glass: true)
    }

    private var smartCleanMessage: String {
        let dev = appState.devArtifacts.filter { $0.selected && !$0.isActiveBuild }.count
        let junk = appState.junkItems.filter(\.selected).count
        let destination = appState.settings.useTrashByDefault
            ? "Se moverán a la Papelera."
            : "Se borrarán definitivamente (se regeneran solos al compilar o usar las apps)."
        return "\(dev) artefactos de proyectos y \(junk) elementos del sistema. \(destination)"
    }

    // MARK: - 6-Tile Monochrome Bento Grid (Disk, RAM, GPU, CPU, Network, Battery)

    private var bentoTelemetryGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        return LazyVGrid(columns: cols, spacing: 14) {
            // 1. Storage
            bentoCard(
                icon: "internaldrive",
                label: appState.telemetry.disk.volumeName.uppercased(),
                primaryValue: ByteFormat.compact(appState.telemetry.disk.availableBytes),
                subtitle: "libres de \(ByteFormat.compact(appState.telemetry.disk.totalBytes)) · purgable \(ByteFormat.compact(appState.telemetry.disk.purgeableBytes))",
                progress: appState.telemetry.disk.usedPercent / 100.0,
                ctaTitle: "Ver mapa"
            ) {
                appState.selectedSection = .diskMap
                if appState.diskRoot == nil {
                    Task { await appState.mapDisk() }
                }
            }

            // 2. RAM + Optimize
            bentoCard(
                icon: "memorychip",
                label: "MEMORIA · \(appState.telemetry.memory.pressure.label.uppercased())",
                primaryValue: "\(Int(appState.telemetry.memory.usedPercent))%",
                subtitle: "\(ByteFormat.memory(appState.telemetry.memory.usedBytes)) / \(ByteFormat.memory(appState.telemetry.memory.totalBytes)) · Caché \(ByteFormat.memory(appState.telemetry.memory.cachedFilesBytes))",
                progress: appState.telemetry.memory.usedPercent / 100.0,
                ctaTitle: appState.isOptimizingRAM ? "Optimizando…" : "Optimizar RAM",
                ctaDisabled: appState.isOptimizingRAM
            ) {
                Task { await appState.optimizeRAM() }
            }

            // 3. GPU + Trim
            bentoCard(
                icon: "cpu.fill",
                label: "GPU · \(appState.telemetry.gpu.modelName.uppercased())",
                primaryValue: "\(Int(appState.telemetry.gpu.deviceUtilizationPercent))%",
                subtitle: "Render \(Int(appState.telemetry.gpu.rendererUtilizationPercent))% · En uso \(ByteFormat.memory(appState.telemetry.gpu.inUseMemoryBytes))",
                progress: appState.telemetry.gpu.deviceUtilizationPercent / 100.0,
                ctaTitle: "Limpiar caché",
                ctaDisabled: appState.isCleaning
            ) {
                Task { await appState.trimGPUCaches() }
            }

            // 4. CPU
            bentoCard(
                icon: "cpu",
                label: "CPU · \(appState.telemetry.thermalState.uppercased())",
                primaryValue: "\(Int(appState.telemetry.cpuTotalPercent))%",
                subtitle: "Usuario \(Int(appState.telemetry.cpuUserPercent))% · Sistema \(Int(appState.telemetry.cpuSystemPercent))% · \(appState.telemetry.coreCount) núcleos",
                progress: appState.telemetry.cpuTotalPercent / 100.0,
                ctaTitle: "Procesos"
            ) {
                appState.selectedSection = .performance
            }

            // 5. Network
            bentoCard(
                icon: "wifi",
                label: "RED",
                primaryValue: ByteFormat.speed(appState.telemetry.network.bytesInPerSec),
                subtitle: "Bajada ↓ · subida ↑ \(ByteFormat.speed(appState.telemetry.network.bytesOutPerSec))",
                progress: min(1.0, appState.telemetry.network.bytesInPerSec / 50_000_000.0),
                ctaTitle: "Vaciar DNS"
            ) {
                Task { await appState.flushDNS() }
            }

            // 6. Battery
            let bat = appState.telemetry.battery
            bentoCard(
                icon: bat.isCharging ? "battery.100.bolt" : "battery.100",
                label: "BATERÍA",
                primaryValue: bat.present ? "\(Int(bat.percent))%" : "Corriente",
                subtitle: batterySubtitle(bat),
                progress: bat.present ? bat.percent / 100.0 : 1.0,
                ctaTitle: "Detalles"
            ) {
                appState.selectedSection = .performance
            }
        }
    }

    private func batterySubtitle(_ bat: BatterySnapshot) -> String {
        guard bat.present else { return "Mac de escritorio · sin batería" }
        var parts: [String] = []
        if let mins = bat.minutesRemaining {
            parts.append(bat.isCharging ? "llena en \(mins / 60)h \(mins % 60)m" : "\(mins / 60)h \(mins % 60)m restantes")
        } else {
            parts.append(bat.isCharging ? "Cargando" : (bat.isPluggedIn ? "Conectada" : "Con batería"))
        }
        if let health = bat.healthPercent {
            parts.append("Salud \(Int(health))%")
        }
        if let cycles = bat.cycleCount {
            parts.append("\(cycles) ciclos")
        }
        return parts.joined(separator: " · ")
    }

    private func bentoCard(
        icon: String,
        label: String,
        primaryValue: String,
        subtitle: String,
        progress: Double,
        ctaTitle: String,
        ctaDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(label, systemImage: icon)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Mono.muted(scheme))
                    .lineLimit(1)
                Spacer()
            }

            HStack(alignment: .center, spacing: 8) {
                Text(primaryValue)
                    .font(.system(size: 23, weight: .bold, design: .monospaced))
                    .foregroundStyle(Mono.ink(scheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                Spacer(minLength: 4)
                Button(ctaTitle, action: action)
                    .buttonStyle(MonoGhostButtonStyle())
                    .disabled(ctaDisabled)
            }

            MonoProgressBar(value: progress, height: 4.5)

            Spacer(minLength: 0)

            Text(subtitle)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Mono.muted(scheme))
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 122, maxHeight: 122, alignment: .topLeading)
        .monoCard(radius: 14)
    }

    // MARK: - External Drives Strip

    private var externalVolumesStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DISCOS EXTERNOS (\(appState.telemetry.externalVolumes.count))")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Mono.muted(scheme))

            HStack(spacing: 12) {
                ForEach(appState.telemetry.externalVolumes) { vol in
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Mono.ink(scheme))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vol.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Mono.ink(scheme))
                            Text("\(ByteFormat.compact(vol.availableBytes)) libres de \(ByteFormat.compact(vol.totalBytes))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Mono.muted(scheme))
                        }
                        Spacer()
                        Button("Ver mapa") {
                            appState.selectedSection = .diskMap
                            Task { await appState.mapDisk(at: vol.path) }
                        }
                        .buttonStyle(MonoGhostButtonStyle())

                        if vol.isEjectable {
                            Button {
                                appState.ejectVolume(vol)
                            } label: {
                                Image(systemName: "eject.fill")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(MonoGhostButtonStyle())
                            .help("Expulsar \(vol.name) de forma segura")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .monoCard(radius: 12)
                }
            }
        }
    }

    // MARK: - Live Real-Time Sparkline Charts (Swift Charts)

    private var liveChartStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("EN VIVO · ÚLTIMOS 90 s")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Mono.muted(scheme))
                Spacer()
                HStack(spacing: 14) {
                    legendDot("CPU", opacity: 0.95)
                    legendDot("RAM", opacity: 0.55)
                    legendDot("GPU", opacity: 0.30)
                }
            }

            Chart {
                ForEach(appState.history) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("CPU", point.cpu),
                        series: .value("Metric", "CPU")
                    )
                    .foregroundStyle(Mono.ink(scheme).opacity(0.95))
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("RAM", point.memory),
                        series: .value("Metric", "RAM")
                    )
                    .foregroundStyle(Mono.ink(scheme).opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("GPU", point.gpu),
                        series: .value("Metric", "GPU")
                    )
                    .foregroundStyle(Mono.ink(scheme).opacity(0.14))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { val in
                    AxisGridLine().foregroundStyle(Mono.hairline(scheme))
                    AxisValueLabel {
                        if let intVal = val.as(Int.self) {
                            Text("\(intVal)%")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Mono.muted(scheme))
                        }
                    }
                }
            }
            .frame(height: 128)
        }
        .padding(18)
        .monoCard(radius: 14)
    }

    private func legendDot(_ title: String, opacity: Double) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Mono.ink(scheme).opacity(opacity))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Mono.muted(scheme))
        }
    }

    // MARK: - Bottom Actionable Row (Dev Bloat + Unused Software)

    private var actionableInsightsRow: some View {
        HStack(alignment: .top, spacing: 14) {
            // Top Dev Targets
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("PROYECTOS MÁS PESADOS")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Mono.muted(scheme))
                    Spacer()
                    Button("Ver todo") { appState.selectedSection = .devRadar }
                        .buttonStyle(MonoGhostButtonStyle())
                }

                if appState.devArtifacts.isEmpty {
                    Text("No hay compilaciones pesadas de Rust, Node o Swift.")
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.muted(scheme))
                        .padding(.vertical, 12)
                } else {
                    ForEach(appState.devArtifacts.prefix(4)) { item in
                        HStack {
                            Image(systemName: item.ecosystem.symbolName)
                                .font(.system(size: 12))
                                .foregroundStyle(Mono.muted(scheme))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(item.projectName) · \(item.artifactKind)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Mono.ink(scheme))
                                    .lineLimit(1)
                                Text(item.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Mono.muted(scheme))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if item.isActiveBuild {
                                MonoTag(text: "EN USO", inverted: true)
                            }
                            Text(ByteFormat.compact(item.sizeBytes))
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(Mono.ink(scheme))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 232, alignment: .topLeading)
            .monoCard(radius: 14)

            // Unused Software Prompt
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("APPS SIN USAR")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Mono.muted(scheme))
                    Spacer()
                    Button("Revisar") { appState.selectedSection = .appsAudit }
                        .buttonStyle(MonoGhostButtonStyle())
                }

                if appState.unusedApps.isEmpty {
                    Text("Ninguna app lleva más de \(appState.settings.unusedAppThresholdDays) días sin usarse.")
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.muted(scheme))
                        .padding(.vertical, 12)
                } else {
                    ForEach(appState.unusedApps.prefix(4)) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.appPath))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Mono.ink(scheme))
                                Text(ByteFormat.relativeAge(app.lastUsedDate))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Mono.muted(scheme))
                            }
                            Spacer()
                            Text(ByteFormat.compact(app.totalSizeBytes))
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(Mono.ink(scheme))
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 232, alignment: .topLeading)
            .monoCard(radius: 14)
        }
    }
}
