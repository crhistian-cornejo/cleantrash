import AppKit
import CleanTrashCore
import SwiftUI
import UniformTypeIdentifiers

private enum CleanerSubTab: String, CaseIterable, Identifiable {
    case disk = "Disco"
    case dev = "Proyectos"
    case apps = "Apps"

    var id: String { rawValue }
}

/// Droppy-inspired Dot-Matrix Storage & Smart Cleaner panel inside the Notch,
/// unifying Disk Dot-Matrix, Dev Radar (`target/`, `node_modules/`), and Unused Apps triage
/// in one clean view without extra dock menus.
struct NotchCleanerView: View {
    @Bindable var appState: AppState
    @Bindable var coordinator: NotchCoordinator

    @Environment(\.notchSurface) private var surface
    @State private var subTab: CleanerSubTab = .disk
    @State private var isAppDropTargeted = false
    @State private var armedAction: String?
    @State private var armTask: Task<Void, Never>?

    private var disk: DiskSnapshot { appState.telemetry.disk }
    private var totalBytes: UInt64 { max(1, disk.totalBytes) }
    private var usedBytes: UInt64 { disk.usedBytes }
    private var appsBytes: UInt64 { appState.installedApps.reduce(0) { $0 + $1.totalSizeBytes } }
    private var cleanableBytes: UInt64 { appState.totalSmartReclaimableBytes + appState.trashContents.totalBytes }
    private var systemOtherBytes: UInt64 {
        let known = appsBytes + cleanableBytes
        return usedBytes > known ? usedBytes - known : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Compact top switcher: Disco · Proyectos · Apps + RAM Optimize pill
            HStack(spacing: 6) {
                ForEach(CleanerSubTab.allCases) { tab in
                    let selected = subTab == tab
                    Button {
                        withAnimation(Mono.betweenSpring) { subTab = tab }
                    } label: {
                        HStack(spacing: 4) {
                            Text(tab.rawValue)
                                .font(.system(size: 10.5, weight: .semibold))
                            if let count = cleanerBadge(tab) {
                                Text(count)
                                    .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                                    .foregroundStyle(selected ? .white : .black)
                                    .padding(.horizontal, 4.5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(selected ? Color.black.opacity(0.65) : Color.white.opacity(0.85)))
                            }
                        }
                        .foregroundStyle(selected ? .black : Color.white.opacity(0.72))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }

                Spacer(minLength: 4)

                Button {
                    Task { await appState.optimizeRAM() }
                } label: {
                    HStack(spacing: 5) {
                        Icon3D(name: .memory, size: 15)
                        Text(appState.isOptimizingRAM ? "Liberando…" : "RAM \(Int(appState.telemetry.memory.usedPercent))%")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(NotchButtonStyle())
                .disabled(appState.isOptimizingRAM)
                .help("Optimizar memoria RAM inactiva")
            }

            switch subTab {
            case .disk:
                diskMatrixBody
            case .dev:
                devRadarBody
            case .apps:
                unusedAppsBody
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDrop(of: [.fileURL], isTargeted: $isAppDropTargeted) { providers in
            handleAppDrop(providers: providers)
        }
    }

    private func cleanerBadge(_ tab: CleanerSubTab) -> String? {
        switch tab {
        case .disk: return nil
        case .dev:
            let n = appState.devArtifacts.filter { !$0.isActiveBuild }.count
            return n > 0 ? "\(n)" : nil
        case .apps:
            return appState.unusedApps.isEmpty ? nil : "\(appState.unusedApps.count)"
        }
    }

    private var diskMatrixBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top Row: 3D Disk Icon + Giant Used GB + "of Total GB" + Circular Refresh Button
            HStack(alignment: .center) {
                HStack(spacing: 10) {
                    Icon3D(name: .disk, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ByteFormat.compact(usedBytes))
                            .font(.system(size: 23, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text("\(ByteFormat.compact(disk.availableBytes)) disponibles")
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }

                Spacer()

                HStack(spacing: 9) {
                    Text("de \(ByteFormat.compact(disk.totalBytes))")
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.58))

                    Button {
                        Task { await appState.runSmartScan() }
                    } label: {
                        Group {
                            if appState.isScanningDev || appState.isScanningJunk {
                                ProgressView().controlSize(.mini).tint(.white).scaleEffect(0.72)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.11)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
                        .contentShape(Circle())
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.08))
                    .help("Volver a analizar disco y basura")
                }
            }

            // Centerpiece: Droppy 5-row Glowing Dot-Matrix Disk Bar
            DotMatrixStorageBar(
                appsFraction: Double(appsBytes) / Double(totalBytes),
                cleanableFraction: Double(cleanableBytes) / Double(totalBytes),
                systemFraction: Double(systemOtherBytes) / Double(totalBytes)
            )
            .frame(height: 44)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
            )

            // Category Legend Row (Apps · Limpiable · Sistema)
            HStack(spacing: 0) {
                categoryStat(icon: "square.grid.2x2.fill", tint: Color(hex: 0x3B82F6), label: "Apps", value: ByteFormat.compact(appsBytes))
                Spacer(minLength: 8)
                categoryStat(icon: "square.3.layers.3d.top.filled", tint: Color(hex: 0xF59E0B), label: "Basura", value: ByteFormat.compact(cleanableBytes))
                Spacer(minLength: 8)
                categoryStat(icon: "gearshape.fill", tint: Color.white.opacity(0.7), label: "Sistema", value: ByteFormat.compact(systemOtherBytes))
            }
            .padding(.horizontal, 4)

            Spacer(minLength: 0)

            // Bottom Row: Drop an App to Uninstall + Circular Sparkles (Smart Clean) + Circular Trash
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    if isAppDropTargeted {
                        Image(systemName: "arrow.down.app.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Mono.danger)
                    }
                    Text(
                        isAppDropTargeted
                            ? "Suelta la app para desinstalar con Touch ID"
                            : "Arrastra una app aquí para desinstalar"
                    )
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isAppDropTargeted ? .white : Color.white.opacity(0.55))
                    .lineLimit(1)
                }
                .padding(.horizontal, isAppDropTargeted ? 10 : 2)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isAppDropTargeted ? Mono.danger.opacity(0.18) : .clear)
                )

                Spacer(minLength: 6)

                Button {
                    confirmOrArm("smartClean") {
                        Task { await appState.runSmartClean() }
                    }
                } label: {
                    Group {
                        if appState.isCleaning {
                            ProgressView().controlSize(.mini).tint(Mono.healthy).scaleEffect(0.72)
                        } else if armedAction == "smartClean" {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x6EE7B7))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(armedAction == "smartClean" ? Mono.danger : Color(hex: 0x10B981).opacity(0.24))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(
                                armedAction == "smartClean" ? Mono.danger : Color(hex: 0x34D399).opacity(0.35),
                                lineWidth: 1
                            )
                    )
                    .contentShape(Circle())
                }
                .buttonStyle(NotchButtonStyle(hoverScale: 1.08))
                .disabled(appState.isCleaning || appState.totalSmartReclaimableBytes == 0)
                .opacity(appState.totalSmartReclaimableBytes == 0 ? 0.4 : 1)
                .help("Limpieza inteligente (\(ByteFormat.compact(appState.totalSmartReclaimableBytes)))")

                Button {
                    confirmOrArm("trash") {
                        Task { await appState.emptyTrashNow() }
                    }
                } label: {
                    Image(systemName: armedAction == "trash" ? "trash.slash.fill" : "trash")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(armedAction == "trash" ? .white : Color.white.opacity(0.88))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(armedAction == "trash" ? Mono.danger : Color.white.opacity(0.12)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(NotchButtonStyle(hoverScale: 1.08))
                .disabled(appState.isCleaning)
                .help("Vaciar Papelera (\(ByteFormat.compact(appState.trashContents.totalBytes)))")
            }
        }
    }

    private var devRadarBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(ByteFormat.compact(appState.reclaimableDevBytes)) en target/, node_modules/, .build/")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.6))
                Spacer()
                Button(armedAction == "devAll" ? "¿Confirmar?" : "Limpiar todo") {
                    confirmOrArm("devAll") {
                        Task { await appState.cleanSelectedDevArtifacts() }
                    }
                }
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(.white))
                .buttonStyle(NotchButtonStyle())
                .disabled(appState.reclaimableDevBytes == 0 || appState.isCleaning)
                .opacity(appState.reclaimableDevBytes == 0 ? 0.4 : 1)
            }

            if appState.devArtifacts.isEmpty {
                VStack(spacing: 5) {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Mono.healthy)
                    Text("Tus proyectos están ligeros")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(appState.devArtifacts.prefix(5)) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.ecosystem.symbolName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.7))
                                    .frame(width: 18)
                                Text(item.projectName)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(item.artifactKind)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.white.opacity(0.5))
                                Spacer()
                                Text(ByteFormat.compact(item.sizeBytes))
                                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                Button {
                                    Task { await appState.cleanSingleDevArtifact(item) }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(item.isActiveBuild ? .white.opacity(0.25) : .white.opacity(0.85))
                                        .frame(width: 24, height: 24)
                                        .background(Circle().fill(Color.white.opacity(0.08)))
                                }
                                .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                                .disabled(item.isActiveBuild || appState.isCleaning)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .notchHoverRow(cornerRadius: 8)
                        }
                    }
                }
            }
        }
    }

    private var unusedAppsBody: some View {
        Group {
            if let candidate = appState.unusedApps.first {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.appPath))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("¿Aún usas \(candidate.name)?")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Último uso \(ByteFormat.relativeAge(candidate.lastUsedDate)) · \(ByteFormat.compact(candidate.totalSizeBytes))")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Color.white.opacity(0.65))
                        }
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button("La uso") {
                            withAnimation(Mono.betweenSpring) {
                                appState.markAppDecision(candidate, decision: .keep)
                            }
                        }
                        .buttonStyle(MonoGhostButtonStyle())

                        Button("Luego") {
                            withAnimation(Mono.betweenSpring) {
                                appState.markAppDecision(candidate, decision: .snoozed, snoozeDays: 30)
                            }
                        }
                        .buttonStyle(MonoGhostButtonStyle())

                        Spacer()

                        Button {
                            Task { await appState.deepUninstallApp(candidate) }
                        } label: {
                            Label("Eliminar", systemImage: "touchid")
                        }
                        .buttonStyle(MonoPrimaryButtonStyle())
                        .disabled(appState.isCleaning)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            } else {
                VStack(spacing: 5) {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Mono.healthy)
                    Text("Todas tus apps están en uso")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func categoryStat(icon: String, tint: Color, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0.5) {
                Text(value)
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    .contentTransition(.numericText())
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
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

    private func handleAppDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let direct = item as? URL {
                        url = direct
                    } else {
                        url = nil
                    }
                    guard let url else { return }
                    Task { @MainActor in
                        if url.pathExtension.lowercased() == "app" {
                            if let match = appState.installedApps.first(where: { $0.appPath == url.path }) {
                                await appState.deepUninstallApp(match)
                            } else {
                                // Open Apps Audit tab in dashboard if not yet indexed
                                coordinator.isExpanded = false
                                appState.selectedSection = .appsAudit
                                appState.onOpenMainWindow?()
                            }
                        } else {
                            // Non-app files go straight to the Droppy File Shelf!
                            appState.productivity.addFiles([url])
                            withAnimation(Mono.openingSpring) {
                                coordinator.selectedTab = .shelf
                                coordinator.productivitySubTab = .shelf
                            }
                        }
                    }
                }
            }
        }
        return accepted
    }
}

/// 5-row glowing dot-matrix storage meter inspired by Droppy's Cleaner card.
/// Works seamlessly on both the dark Dynamic Notch and the Main Dashboard (dark & light mode).
struct DotMatrixStorageBar: View {
    let appsFraction: Double
    let cleanableFraction: Double
    let systemFraction: Double
    var forceDark: Bool = true

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = forceDark || scheme == .dark
        Canvas { context, size in
            let rows = 5
            let dotSize: CGFloat = 4.2
            let gapX: CGFloat = 3.8
            let gapY: CGFloat = 4.6
            let pitchX = dotSize + gapX
            let pitchY = dotSize + gapY
            let cols = max(10, Int((size.width + gapX) / pitchX))
            let totalDots = rows * cols

            let totalGridW = CGFloat(cols) * pitchX - gapX
            let totalGridH = CGFloat(rows) * pitchY - gapY
            let startX = (size.width - totalGridW) / 2
            let startY = (size.height - totalGridH) / 2

            let appsCount = max(appsFraction > 0.002 ? rows : 0, Int((appsFraction * Double(totalDots)).rounded()))
            let cleanCount = max(cleanableFraction > 0.002 ? rows : 0, Int((cleanableFraction * Double(totalDots)).rounded()))
            let sysCount = Int((systemFraction * Double(totalDots)).rounded())

            let appsEnd = min(totalDots, appsCount)
            let cleanEnd = min(totalDots, appsEnd + cleanCount)
            let sysEnd = min(totalDots, cleanEnd + sysCount)

            // Column-major order so vertical stripes sweep cleanly left → right like Droppy.
            for col in 0..<cols {
                for row in 0..<rows {
                    let idx = col * rows + row
                    let rect = CGRect(
                        x: startX + CGFloat(col) * pitchX,
                        y: startY + CGFloat(row) * pitchY,
                        width: dotSize,
                        height: dotSize
                    )
                    let color: Color
                    if idx < appsEnd {
                        color = Color(hex: 0x3B82F6).opacity(row == 0 || row == 4 ? 0.78 : 0.98)
                    } else if idx < cleanEnd {
                        color = Color(hex: 0xF59E0B).opacity(row == 0 || row == 4 ? 0.78 : 0.98)
                    } else if idx < sysEnd {
                        // Subtle organic luminance texture matching Droppy's dot matrix
                        let shimmer = ((col * 7 + row * 13) % 5 == 0) ? 0.42 : (((col + row) % 2 == 0) ? 0.68 : 0.56)
                        color = (dark ? Color.white : Color.black).opacity(shimmer)
                    } else {
                        color = (dark ? Color.white : Color.black).opacity(dark ? 0.11 : 0.10)
                    }
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.2), with: .color(color))
                }
            }
        }
    }
}
