import Charts
import CleanTrashCore
import SwiftUI

struct OverviewView: View {
    @Bindable var appState: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var confirmSmartClean = false

    private var disk: DiskSnapshot { appState.telemetry.disk }
    private var totalBytes: UInt64 { max(1, disk.totalBytes) }
    private var appsBytes: UInt64 { appState.installedApps.reduce(0) { $0 + $1.totalSizeBytes } }
    private var cleanableBytes: UInt64 { appState.totalSmartReclaimableBytes + appState.trashContents.totalBytes }
    private var systemOtherBytes: UInt64 {
        let known = appsBytes + cleanableBytes
        return disk.usedBytes > known ? disk.usedBytes - known : 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerHero
                bentoTelemetryGrid
                liveNotchQuickStrip
                if !appState.telemetry.externalVolumes.isEmpty {
                    externalVolumesStrip
                }
                liveChartStrip
                actionableInsightsRow
            }
            .padding(20)
        }
    }

    // MARK: - Smart Care Hero + Droppy Dot-Matrix Storage Visualizer

    var headerHero: some View {
        let health = appState.macHealth
        let tint = health.tint(for: scheme)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 24) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(scheme == .dark ? 0.22 : 0.14))
                        .frame(width: 140, height: 140)
                        .blur(radius: 36)
                    Icon3D(name: .smartcare, size: 118)
                }
                .frame(width: 138, height: 126)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 7, height: 7)
                        (Text("Estado del Mac: ") + Text(health.label).foregroundStyle(tint))
                            .font(.system(size: 12.5, weight: .semibold))
                        if let reason = health.reason {
                            Text("· \(reason)")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Mono.muted(scheme))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(Mono.ink(scheme))

                    Text("Cuidado inteligente")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(Mono.ink(scheme))

                    Text(appState.totalSmartReclaimableBytes > 0
                         ? "\(ByteFormat.compact(appState.totalSmartReclaimableBytes)) listos para liberar. Un mantenimiento rápido que prioriza lo esencial."
                         : "Tu Mac está limpio y ligero. Analiza de nuevo cuando quieras.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Mono.muted(scheme))
                        .contentTransition(.numericText())
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Proyectos \(ByteFormat.compact(appState.reclaimableDevBytes)) · Sistema \(ByteFormat.compact(appState.reclaimableJunkBytes)) · Papelera \(ByteFormat.compact(appState.trashContents.totalBytes)) · \(appState.unusedApps.count) apps sin usar")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Mono.subtle(scheme))

                    HStack(spacing: 10) {
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

                        Text("\(appState.telemetry.gpu.modelName) · \(appState.telemetry.coreCount) núcleos")
                            .font(.system(size: 11))
                            .foregroundStyle(Mono.subtle(scheme))
                            .padding(.leading, 4)
                    }
                    .padding(.top, 4)
                }

                Spacer(minLength: 0)
            }

            // Droppy-Matched 5-Row Glowing Dot-Matrix Storage Visualizer
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Text(ByteFormat.compact(disk.usedBytes))
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                            .foregroundStyle(Mono.ink(scheme))
                        Text("usados de \(ByteFormat.compact(disk.totalBytes))")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Mono.muted(scheme))
                    }
                    Spacer()
                    dotLegend("Apps", value: ByteFormat.compact(appsBytes), color: Mono.appsAccent)
                    dotLegend("Basura", value: ByteFormat.compact(cleanableBytes), color: Mono.junkAccent)
                    dotLegend("Sistema", value: ByteFormat.compact(systemOtherBytes), color: Mono.ink(scheme).opacity(0.62))
                    dotLegend("Libre", value: ByteFormat.compact(disk.availableBytes), color: Mono.ink(scheme).opacity(0.22))
                }

                DotMatrixStorageBar(
                    appsFraction: Double(appsBytes) / Double(totalBytes),
                    cleanableFraction: Double(cleanableBytes) / Double(totalBytes),
                    systemFraction: Double(systemOtherBytes) / Double(totalBytes),
                    forceDark: false
                )
                .frame(height: 36)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Mono.ink(scheme).opacity(scheme == .dark ? 0.045 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Mono.hairline(scheme), lineWidth: 0.75)
                )
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .monoCard(radius: 20, glass: true)
        .animation(Mono.betweenSpring, value: health)
    }

    private func dotLegend(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(label) \(value)")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Mono.muted(scheme))
                .lineLimit(1)
        }
    }

    private var smartCleanMessage: String {
        let dev = appState.devArtifacts.filter { $0.selected && !$0.isActiveBuild }.count
        let junk = appState.junkItems.filter(\.selected).count
        let destination = appState.settings.useTrashByDefault
            ? "Se moverán a la Papelera."
            : "Se borrarán definitivamente (se regeneran solos al compilar o usar las apps)."
        return "\(dev) artefactos de proyectos y \(junk) elementos del sistema. \(destination)"
    }

    // MARK: - 6-Tile Notch-Matched Glowing 3D Ring Bento Grid

    private var bentoTelemetryGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        let cpu = appState.telemetry.cpuTotalPercent
        let ram = appState.telemetry.memory.usedPercent
        let gpu = appState.telemetry.gpu.deviceUtilizationPercent
        let bat = appState.telemetry.battery

        return LazyVGrid(columns: cols, spacing: 14) {
            // 1. Storage
            bento3DCard(
                icon3D: .disk,
                label: disk.volumeName,
                primaryValue: ByteFormat.compact(disk.availableBytes),
                subtitle: "libres de \(ByteFormat.compact(disk.totalBytes)) · purgable \(ByteFormat.compact(disk.purgeableBytes))",
                percent: disk.usedPercent,
                tint: disk.usedPercent >= 90 ? Mono.danger : Mono.appsAccent,
                ctaTitle: "Ver mapa"
            ) {
                appState.selectedSection = .diskMap
                if appState.diskRoot == nil {
                    Task { await appState.mapDisk() }
                }
            }

            // 2. RAM + Optimize
            bento3DCard(
                icon3D: .memory,
                label: "Memoria · \(appState.telemetry.memory.pressure.label)",
                primaryValue: "\(Int(ram))%",
                subtitle: "\(ByteFormat.memory(appState.telemetry.memory.usedBytes)) / \(ByteFormat.memory(appState.telemetry.memory.totalBytes)) · Caché \(ByteFormat.memory(appState.telemetry.memory.cachedFilesBytes))",
                percent: ram,
                tint: ram >= 88 ? Mono.caution : Mono.ramAccent,
                ctaTitle: appState.isOptimizingRAM ? "Optimizando…" : "Optimizar RAM",
                ctaDisabled: appState.isOptimizingRAM
            ) {
                Task { await appState.optimizeRAM() }
            }

            // 3. GPU + Trim
            bento3DCard(
                icon3D: .gpu,
                label: "GPU · \(appState.telemetry.gpu.modelName)",
                primaryValue: "\(Int(gpu))%",
                subtitle: "Render \(Int(appState.telemetry.gpu.rendererUtilizationPercent))% · En uso \(ByteFormat.memory(appState.telemetry.gpu.inUseMemoryBytes))",
                percent: gpu,
                tint: gpu >= 90 ? Mono.caution : Mono.gpuAccent,
                ctaTitle: "Limpiar caché",
                ctaDisabled: appState.isCleaning
            ) {
                Task { await appState.trimGPUCaches() }
            }

            // 4. CPU
            bento3DCard(
                icon3D: .cpu,
                label: "CPU · \(appState.telemetry.thermalState)",
                primaryValue: "\(Int(cpu))%",
                subtitle: "Usuario \(Int(appState.telemetry.cpuUserPercent))% · Sistema \(Int(appState.telemetry.cpuSystemPercent))% · \(appState.telemetry.coreCount) núcleos",
                percent: cpu,
                tint: cpu >= 88 ? Mono.danger : Mono.cpuAccent,
                ctaTitle: "Procesos"
            ) {
                appState.selectedSection = .performance
            }

            // 5. Network
            bentoSymbolCard(
                symbol: "wifi",
                label: "Red en vivo",
                primaryValue: ByteFormat.speed(appState.telemetry.network.bytesInPerSec),
                subtitle: "Bajada ↓ · subida ↑ \(ByteFormat.speed(appState.telemetry.network.bytesOutPerSec))",
                percent: min(100, (appState.telemetry.network.bytesInPerSec / 50_000_000.0) * 100.0),
                tint: Mono.networkAccent,
                ctaTitle: "Vaciar DNS"
            ) {
                Task { await appState.flushDNS() }
            }

            // 6. Battery
            bentoSymbolCard(
                symbol: bat.isCharging ? "battery.100.bolt" : "battery.100",
                label: "Batería",
                primaryValue: bat.present ? "\(Int(bat.percent))%" : "Corriente",
                subtitle: batterySubtitle(bat),
                percent: bat.present ? bat.percent : 100,
                tint: bat.present && bat.percent <= 20 && !bat.isCharging ? Mono.danger : Mono.batteryAccent,
                ctaTitle: "Detalles"
            ) {
                appState.selectedSection = .performance
            }
        }
    }

    private func bento3DCard(
        icon3D: Icon3DName,
        label: String,
        primaryValue: String,
        subtitle: String,
        percent: Double,
        tint: Color,
        ctaTitle: String,
        ctaDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                MetricRing3D(icon: icon3D, percent: percent, tint: tint, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Mono.muted(scheme))
                        .lineLimit(1)
                    Text(primaryValue)
                        .font(.system(size: 22, weight: .bold).monospacedDigit())
                        .foregroundStyle(Mono.ink(scheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 4)
                Button(ctaTitle, action: action)
                    .buttonStyle(MonoGhostButtonStyle())
                    .disabled(ctaDisabled)
            }

            MonoProgressBar(value: percent / 100.0, height: 4.5, tint: tint)

            Text(subtitle)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Mono.muted(scheme))
                .lineLimit(1)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 124, maxHeight: 124, alignment: .topLeading)
        .monoCard(radius: 16)
    }

    private func bentoSymbolCard(
        symbol: String,
        label: String,
        primaryValue: String,
        subtitle: String,
        percent: Double,
        tint: Color,
        ctaTitle: String,
        ctaDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                MetricSymbolRing(symbol: symbol, percent: percent, tint: tint, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Mono.muted(scheme))
                        .lineLimit(1)
                    Text(primaryValue)
                        .font(.system(size: 22, weight: .bold).monospacedDigit())
                        .foregroundStyle(Mono.ink(scheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 4)
                Button(ctaTitle, action: action)
                    .buttonStyle(MonoGhostButtonStyle())
                    .disabled(ctaDisabled)
            }

            MonoProgressBar(value: percent / 100.0, height: 4.5, tint: tint)

            Text(subtitle)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Mono.muted(scheme))
                .lineLimit(1)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 124, maxHeight: 124, alignment: .topLeading)
        .monoCard(radius: 16)
    }

    // MARK: - Live Notch Quick Strip (Música · Focus / Despierto · Centro Notch)

    private var liveNotchQuickStrip: some View {
        let media = appState.media
        let hub = appState.productivity

        return HStack(spacing: 14) {
            // 1. Live Now Playing Mini-Card
            HStack(spacing: 11) {
                if let track = media.track {
                    if let art = media.artwork {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(media.palette.primary.opacity(0.3))
                            .frame(width: 40, height: 40)
                            .overlay { Image(systemName: "music.note").foregroundStyle(Mono.ink(scheme)) }
                    }
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(track.title)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Mono.ink(scheme))
                            .lineLimit(1)
                        Text(media.currentLyricLine ?? track.artist)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Mono.muted(scheme))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        Button { media.togglePlayPause() } label: {
                            Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Mono.primaryInk(scheme))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Mono.primaryFill(scheme)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()

                        Button { media.nextTrack() } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Mono.ink(scheme))
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Mono.ink(scheme).opacity(0.09)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 16))
                        .foregroundStyle(Mono.muted(scheme))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Mono.ink(scheme).opacity(0.08)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Música y Letras")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Mono.ink(scheme))
                        Text("Spotify y Apple Music en vivo")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Mono.muted(scheme))
                    }
                    Spacer()
                    Button("Abrir") { appState.selectedSection = .notchHub }
                        .buttonStyle(MonoGhostButtonStyle())
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 68)
            .monoCard(radius: 15)

            // 2. Focus + Stay Awake + Quick Actions
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "timer")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Mono.junkAccent)
                        Text("Focus · \(hub.timerFormatted)")
                            .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(Mono.ink(scheme))
                    }
                    Text("\(hub.shelfItems.count) archivos en Bandeja · \(hub.clipboardEntries.count) clips")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Mono.muted(scheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    hub.toggleStayAwake()
                } label: {
                    Image(systemName: hub.isStayAwakeEnabled ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hub.isStayAwakeEnabled ? .black : Mono.ink(scheme))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(hub.isStayAwakeEnabled ? Mono.junkAccent : Mono.ink(scheme).opacity(0.09)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(hub.isStayAwakeEnabled ? "Desactivar Mantener despierta" : "Mantener Mac despierta")

                Button {
                    Task { await hub.captureScreenText() }
                } label: {
                    Label("OCR", systemImage: "text.viewfinder")
                }
                .buttonStyle(MonoGhostButtonStyle())

                Button("Centro Notch") {
                    withAnimation(Mono.betweenSpring) {
                        appState.selectedSection = .notchHub
                    }
                }
                .buttonStyle(MonoPrimaryButtonStyle())
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 68)
            .monoCard(radius: 15)
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

    // MARK: - External Drives Strip

    private var externalVolumesStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Discos externos (\(appState.telemetry.externalVolumes.count))")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(Mono.muted(scheme))

            HStack(spacing: 12) {
                ForEach(appState.telemetry.externalVolumes) { vol in
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Mono.appsAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vol.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Mono.ink(scheme))
                            Text("\(ByteFormat.compact(vol.availableBytes)) libres de \(ByteFormat.compact(vol.totalBytes))")
                                .font(.system(size: 10).monospacedDigit())
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
                    .monoCard(radius: 14)
                }
            }
        }
    }

    // MARK: - Live Real-Time Sparkline Charts (Notch Accent Palette)

    private var liveChartStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("En vivo · últimos 90 s")
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(Mono.muted(scheme))
                Spacer()
                HStack(spacing: 14) {
                    legendDot("CPU", color: Mono.cpuAccent)
                    legendDot("RAM", color: Mono.ramAccent)
                    legendDot("GPU", color: Mono.gpuAccent)
                }
            }

            Chart {
                ForEach(appState.history) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("CPU", point.cpu),
                        series: .value("Metric", "CPU")
                    )
                    .foregroundStyle(Mono.cpuAccent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("RAM", point.memory),
                        series: .value("Metric", "RAM")
                    )
                    .foregroundStyle(Mono.ramAccent)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("GPU", point.gpu),
                        series: .value("Metric", "GPU")
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Mono.gpuAccent.opacity(0.28), Mono.gpuAccent.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("GPU", point.gpu),
                        series: .value("Metric", "GPU")
                    )
                    .foregroundStyle(Mono.gpuAccent)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
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
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(Mono.muted(scheme))
                        }
                    }
                }
            }
            .frame(height: 128)
        }
        .padding(18)
        .monoCard(radius: 16)
    }

    private func legendDot(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Mono.muted(scheme))
        }
    }

    // MARK: - Bottom Actionable Row (Dev Bloat + Unused Software)

    private var actionableInsightsRow: some View {
        HStack(alignment: .top, spacing: 14) {
            // Top Dev Targets
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Proyectos más pesados")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
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
                                .foregroundStyle(Mono.cpuAccent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(item.projectName) · \(item.artifactKind)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Mono.ink(scheme))
                                    .lineLimit(1)
                                Text(item.path)
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(Mono.muted(scheme))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if item.isActiveBuild {
                                MonoTag(text: "EN USO", inverted: true)
                            }
                            Text(ByteFormat.compact(item.sizeBytes))
                                .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(Mono.ink(scheme))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .monoCard(radius: 16)

            // Unused Software Prompt
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Apps sin usar")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
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
                                .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(Mono.ink(scheme))
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .monoCard(radius: 16)
        }
    }
}
