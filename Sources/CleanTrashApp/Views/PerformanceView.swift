import Charts
import CleanTrashCore
import SwiftUI

struct PerformanceView: View {
    @Bindable var appState: AppState
    @Environment(\.colorScheme) private var scheme

    private var ramSegments: [(label: String, bytes: UInt64, tint: Color)] {
        let m = appState.telemetry.memory
        return [
            ("Apps", m.appBytes, Mono.ramAccent),
            ("Fija (Sistema)", m.wiredBytes, Mono.cpuAccent),
            ("Comprimida", m.compressedBytes, Mono.junkAccent),
            ("Caché", m.cachedFilesBytes, Mono.gpuAccent.opacity(0.75)),
            ("Libre", m.freeBytes, Mono.ink(scheme).opacity(0.16))
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Icon3D(name: .performance, size: 58)
                        .padding(.trailing, 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rendimiento · RAM y GPU")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(Mono.ink(scheme))
                        Text("Libera memoria RAM, optimiza la GPU y revisa qué apps consumen más recursos.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Mono.muted(scheme))
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            Task { await appState.optimizeRAM(deepPurge: false) }
                        } label: {
                            Label(appState.isOptimizingRAM ? "Optimizando…" : "Optimizar RAM", systemImage: "memorychip")
                        }
                        .buttonStyle(MonoGhostButtonStyle())
                        .disabled(appState.isOptimizingRAM)

                        Button {
                            Task { await appState.optimizeRAM(deepPurge: true) }
                        } label: {
                            Label("Purga profunda", systemImage: "touchid")
                        }
                        .buttonStyle(MonoPrimaryButtonStyle())
                        .disabled(appState.isOptimizingRAM)
                    }
                }

                // RAM & GPU Split Panel
                HStack(alignment: .top, spacing: 14) {
                    ramPanel
                    gpuPanel
                }

                // Maintenance Row (APFS Snapshots + DNS + GPU Cache)
                HStack(spacing: 14) {
                    maintenanceCard(
                        title: "Snapshots locales APFS",
                        subtitle: "\(appState.localSnapshots.count) snapshots locales de Time Machine",
                        buttonTitle: "Reducir"
                    ) {
                        Task { await appState.thinAPFSSnapshots() }
                    }
                    maintenanceCard(
                        title: "Cachés de shaders GPU y Metal",
                        subtitle: "Metal, Dawn/WebGPU y cachés GPU de Electron",
                        buttonTitle: "Limpiar"
                    ) {
                        Task { await appState.trimGPUCaches() }
                    }
                    maintenanceCard(
                        title: "Caché DNS",
                        subtitle: "Vacía la caché de directorio y mDNS",
                        buttonTitle: "Vaciar"
                    ) {
                        Task { await appState.flushDNS() }
                    }
                }

                // Top Memory Consumers Table
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Procesos que más RAM usan")
                            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(Mono.muted(scheme))
                        Spacer()
                        Text("PID · RAM residente")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Mono.subtle(scheme))
                    }

                    ForEach(appState.telemetry.topMemoryProcesses) { proc in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Mono.ink(scheme).opacity(proc.isUserApp ? 0.9 : 0.35))
                                .frame(width: 7, height: 7)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(proc.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Mono.ink(scheme))
                                Text("PID \(proc.pid)\(proc.bundleIdentifier.map { " · \($0)" } ?? "")")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(Mono.muted(scheme))
                            }

                            Spacer()

                            Text(ByteFormat.compact(proc.memoryBytes))
                                .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(Mono.ink(scheme))
                                .frame(width: 76, alignment: .trailing)

                            if proc.isUserApp && proc.pid != ProcessInfo.processInfo.processIdentifier {
                                Button("Cerrar") {
                                    appState.terminateProcess(proc, force: false)
                                }
                                .buttonStyle(MonoGhostButtonStyle())
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Mono.ink(scheme).opacity(0.035)))
                    }
                }
                .padding(18)
                .monoCard(radius: 14)
            }
            .padding(20)
        }
    }

    private var ramPanel: some View {
        let mem = appState.telemetry.memory
        let ramTint = mem.usedPercent >= 88 ? Mono.caution : Mono.ramAccent
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Memoria unificada")
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(Mono.muted(scheme))
                Spacer()
                MonoTag(text: mem.pressure.label, inverted: mem.pressure != .normal, tint: mem.pressure == .normal ? Mono.ramAccent : Mono.caution)
            }

            HStack(alignment: .center, spacing: 14) {
                MetricRing3D(icon: .memory, percent: mem.usedPercent, tint: ramTint, size: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(mem.usedPercent))%")
                        .font(.system(size: 30, weight: .bold).monospacedDigit())
                        .foregroundStyle(Mono.ink(scheme))
                        .contentTransition(.numericText())
                    Text("\(ByteFormat.memory(mem.usedBytes)) / \(ByteFormat.memory(mem.totalBytes))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Mono.muted(scheme))
                }
            }

            if appState.isOptimizingRAM {
                MonoProgressBar(value: appState.ramOptimizationProgress, height: 6, tint: Mono.ramAccent)
            }

            // Segmented horizontal bar via Swift Charts
            Chart(Array(ramSegments.enumerated()), id: \.element.label) { _, seg in
                BarMark(
                    x: .value("Bytes", seg.bytes)
                )
                .foregroundStyle(seg.tint)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 14)
            .clipShape(Capsule())

            VStack(spacing: 6) {
                ForEach(Array(ramSegments.enumerated()), id: \.element.label) { _, seg in
                    HStack {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(seg.tint)
                            .frame(width: 9, height: 9)
                        Text(seg.label)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Mono.ink(scheme))
                        Spacer()
                        Text(ByteFormat.memory(seg.bytes))
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Mono.muted(scheme))
                    }
                }
                Divider().overlay(Mono.hairline(scheme))
                HStack {
                    Text("Swap usado")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mono.muted(scheme))
                    Spacer()
                    Text("\(ByteFormat.memory(mem.swapUsedBytes)) / \(ByteFormat.memory(mem.swapTotalBytes))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Mono.muted(scheme))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 344, maxHeight: 344, alignment: .topLeading)
        .monoCard(radius: 16, glass: true)
    }

    private var gpuPanel: some View {
        let gpu = appState.telemetry.gpu
        let gpuTint = gpu.deviceUtilizationPercent >= 90 ? Mono.caution : Mono.gpuAccent
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GPU · IOKit")
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(Mono.muted(scheme))
                Spacer()
                MonoTag(text: gpu.modelName, tint: Mono.gpuAccent)
            }

            HStack(alignment: .center, spacing: 14) {
                MetricRing3D(icon: .gpu, percent: gpu.deviceUtilizationPercent, tint: gpuTint, size: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(gpu.deviceUtilizationPercent))%")
                        .font(.system(size: 30, weight: .bold).monospacedDigit())
                        .foregroundStyle(Mono.ink(scheme))
                        .contentTransition(.numericText())
                    Text("Uso del dispositivo")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Mono.muted(scheme))
                }
            }

            VStack(spacing: 9) {
                gpuBarRow("Renderer Engine", pct: gpu.rendererUtilizationPercent, tint: Mono.gpuAccent)
                gpuBarRow("Tiler Engine", pct: gpu.tilerUtilizationPercent, tint: Mono.cpuAccent)
            }

            Divider().overlay(Mono.hairline(scheme))

            VStack(spacing: 6) {
                HStack {
                    Text("Memoria GPU en uso")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mono.ink(scheme))
                    Spacer()
                    Text(ByteFormat.compact(gpu.inUseMemoryBytes))
                        .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(Mono.ink(scheme))
                }
                HStack {
                    Text("Memoria del sistema asignada")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mono.muted(scheme))
                    Spacer()
                    Text(ByteFormat.compact(gpu.allocatedMemoryBytes))
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Mono.muted(scheme))
                }
            }

            // Mini GPU history chart
            Chart(appState.history) { point in
                AreaMark(
                    x: .value("Time", point.timestamp),
                    y: .value("GPU", point.gpu)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Mono.gpuAccent.opacity(0.32), Mono.gpuAccent.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("GPU", point.gpu)
                )
                .foregroundStyle(Mono.gpuAccent)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
                .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 54)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 344, maxHeight: 344, alignment: .topLeading)
        .monoCard(radius: 16, glass: true)
    }

    private func gpuBarRow(_ label: String, pct: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Mono.muted(scheme))
                Spacer()
                Text("\(Int(pct))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Mono.ink(scheme))
            }
            MonoProgressBar(value: pct / 100.0, height: 4.5, tint: tint)
        }
    }

    private func maintenanceCard(title: String, subtitle: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Mono.ink(scheme))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Mono.muted(scheme))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(buttonTitle, action: action)
                .buttonStyle(MonoGhostButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 114, maxHeight: 114, alignment: .topLeading)
        .monoCard(radius: 14)
    }
}
