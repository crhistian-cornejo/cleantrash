import AppKit
import Charts
import CleanTrashCore
import SwiftUI

struct DiskMapView: View {
    @Bindable var appState: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var navigationStack: [DiskNode] = []
    @State private var hoveredNodeID: String?
    @State private var showCleanableOnly = false

    private var currentNode: DiskNode? {
        navigationStack.last ?? appState.diskRoot
    }

    private var displayedChildren: [DiskNode] {
        guard let node = currentNode else { return [] }
        if showCleanableOnly {
            return node.children.filter(\.isCleanableCandidate)
        }
        return node.children
    }

    private var categoryBreakdown: [(category: DiskCategory, bytes: UInt64)] {
        guard let node = currentNode else { return [] }
        var totals: [DiskCategory: UInt64] = [:]
        for child in node.children {
            totals[child.category, default: 0] += child.sizeBytes
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header + Scan scope selector
            HStack(alignment: .center) {
                Icon3D(name: .diskmap, size: 58)
                    .padding(.trailing, 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mapa de Disco")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Mono.ink(scheme))
                    Text("Visualiza qué archivos y carpetas ocupan más espacio en tu Mac y limpia lo que ya no necesitas.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Mono.muted(scheme))
                }
                Spacer()

                Button("Inicio (~)") {
                    navigationStack = []
                    Task { await appState.mapDisk(at: NSHomeDirectory()) }
                }
                .buttonStyle(MonoGhostButtonStyle())

                Button("Developer") {
                    navigationStack = []
                    Task { await appState.mapDisk(at: "\(NSHomeDirectory())/Developer") }
                }
                .buttonStyle(MonoGhostButtonStyle())

                Button("Librería") {
                    navigationStack = []
                    Task { await appState.mapDisk(at: "\(NSHomeDirectory())/Library") }
                }
                .buttonStyle(MonoGhostButtonStyle())

                Button("Apps") {
                    navigationStack = []
                    Task { await appState.mapDisk(at: "/Applications") }
                }
                .buttonStyle(MonoGhostButtonStyle())

                Button("Carpeta…") {
                    chooseFolder()
                }
                .buttonStyle(MonoGhostButtonStyle())

                Button {
                    navigationStack = []
                    Task { await appState.mapDisk(at: appState.diskScanTargetPath) }
                } label: {
                    Label(appState.isMappingDisk ? "Mapeando…" : "Reescanear", systemImage: "arrow.clockwise")
                }
                .buttonStyle(MonoPrimaryButtonStyle())
                .disabled(appState.isMappingDisk)
            }

            // Droppy Dot-Matrix Volume Summary Strip (matches the Notch Cleaner card!)
            diskMatrixStrip

            // Breadcrumb bar + Cleanable filter
            HStack(spacing: 6) {
                Button {
                    withAnimation(Mono.betweenSpring) {
                        navigationStack = []
                    }
                } label: {
                    Text(appState.diskRoot?.name ?? "Inicio")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(navigationStack.isEmpty ? Mono.ink(scheme) : Mono.muted(scheme))
                }
                .buttonStyle(.plain)

                ForEach(Array(navigationStack.enumerated()), id: \.element.id) { idx, node in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Mono.subtle(scheme))
                    Button {
                        withAnimation(Mono.betweenSpring) {
                            navigationStack = Array(navigationStack.prefix(idx + 1))
                        }
                    } label: {
                        Text(node.name)
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(idx == navigationStack.count - 1 ? Mono.ink(scheme) : Mono.muted(scheme))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if let current = currentNode {
                    let cleanableBytes = current.children
                        .filter { $0.isCleanableCandidate && !PathSafety.isProtectedPath($0.path) }
                        .reduce(0 as UInt64) { $0 + $1.sizeBytes }

                    Text("\(ByteFormat.compact(current.sizeBytes)) · \(current.fileCount) archivos")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Mono.muted(scheme))

                    if cleanableBytes > 0 {
                        Button("Limpiar \(ByteFormat.compact(cleanableBytes))") {
                            Task { await appState.cleanAllCleanableInDiskNode(current) }
                        }
                        .buttonStyle(MonoPrimaryButtonStyle())
                        .disabled(appState.isCleaning)
                    }
                }

                Toggle("Solo limpiables", isOn: $showCleanableOnly)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .monoCard(radius: 10)

            if appState.isMappingDisk {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Text("Midiendo bloques APFS… \(appState.diskScanCurrentFolder)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(Mono.muted(scheme))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .monoCard(radius: 14)
            } else if let current = currentNode, !displayedChildren.isEmpty {
                // Top Visual Row: Interactive Monochrome Treemap + Category Donut Chart
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Mapa interactivo · clic para entrar")
                                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(Mono.muted(scheme))
                            Spacer()
                            if let hoveredID = hoveredNodeID,
                               let node = displayedChildren.first(where: { $0.id == hoveredID }) {
                                Text("\(node.name) — \(ByteFormat.compact(node.sizeBytes))")
                                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Mono.ink(scheme))
                            }
                        }

                        MonochromeTreemap(
                            nodes: Array(displayedChildren.prefix(24)),
                            hoveredID: $hoveredNodeID
                        ) { node in
                            if node.isDirectory && !node.children.isEmpty {
                                withAnimation(Mono.betweenSpring) {
                                    navigationStack.append(node)
                                }
                            } else {
                                appState.revealInFinder(node.path)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 282, maxHeight: 282, alignment: .topLeading)
                    .monoCard(radius: 14)

                    // Category Breakdown Donut (Swift Charts)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Por categoría")
                            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(Mono.muted(scheme))

                        Chart(Array(categoryBreakdown.enumerated()), id: \.element.category.id) { idx, item in
                            SectorMark(
                                angle: .value("Bytes", item.bytes),
                                innerRadius: .ratio(0.62),
                                angularInset: 1.5
                            )
                            .foregroundStyle(Mono.categoryAccent(idx, scheme: scheme))
                            .cornerRadius(4)
                        }
                        .frame(height: 126)

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(categoryBreakdown.prefix(5).enumerated()), id: \.element.category.id) { idx, item in
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 2.5)
                                        .fill(Mono.categoryAccent(idx, scheme: scheme))
                                        .frame(width: 8, height: 8)
                                    Text(item.category.rawValue)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Mono.ink(scheme))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(ByteFormat.compact(item.bytes))
                                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(Mono.muted(scheme))
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(width: 252, height: 282, alignment: .topLeading)
                    .monoCard(radius: 14)
                }

                // Detailed Drill-Down List
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(displayedChildren) { node in
                            diskRow(node, parentTotal: max(1, current.sizeBytes))
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "internaldrive")
                        .font(.system(size: 28))
                        .foregroundStyle(Mono.muted(scheme))
                    Text("Elige una carpeta para mapear tu disco")
                        .font(.system(size: 13))
                        .foregroundStyle(Mono.muted(scheme))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .monoCard(radius: 14)
            }
        }
        .padding(20)
        .onAppear {
            if appState.diskRoot == nil && !appState.isMappingDisk {
                Task { await appState.mapDisk() }
            }
        }
    }

    private func diskRow(_ node: DiskNode, parentTotal: UInt64) -> some View {
        let share = Double(node.sizeBytes) / Double(parentTotal)
        return HStack(spacing: 12) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 13))
                .foregroundStyle(Mono.ink(scheme).opacity(node.isDirectory ? 0.85 : 0.55))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(node.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                        .lineLimit(1)
                    MonoTag(text: node.category.rawValue)
                    if let hint = node.cleanableHint {
                        MonoTag(text: hint, inverted: true)
                    }
                }
                MonoProgressBar(value: share, height: 3.5)
                    .frame(maxWidth: 280)
            }

            Spacer()

            Text(String(format: "%.1f%%", share * 100))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Mono.muted(scheme))
                .frame(width: 44, alignment: .trailing)

            Text(ByteFormat.compact(node.sizeBytes))
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(Mono.ink(scheme))
                .frame(width: 72, alignment: .trailing)

            if node.isDirectory && !node.children.isEmpty {
                Button {
                    withAnimation(Mono.betweenSpring) {
                        navigationStack.append(node)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Mono.ink(scheme).opacity(0.07)))
                }
                .buttonStyle(.plain)
            }

            Button {
                appState.revealInFinder(node.path)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Mono.muted(scheme))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Mono.ink(scheme).opacity(0.06)))
            }
            .buttonStyle(.plain)

            if !PathSafety.isProtectedPath(node.path) {
                Button {
                    Task { await appState.cleanDiskNode(node) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Mono.ink(scheme))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Mono.ink(scheme).opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(appState.settings.useTrashByDefault ? "Mover a la Papelera" : "Borrar definitivamente")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .monoCard(radius: 10)
    }

    private var diskMatrixStrip: some View {
        let disk = appState.telemetry.disk
        let total = max(1, disk.totalBytes)
        let apps = appState.installedApps.reduce(0 as UInt64) { $0 + $1.totalSizeBytes }
        let cleanable = appState.totalSmartReclaimableBytes + appState.trashContents.totalBytes
        let known = apps + cleanable
        let sys = disk.usedBytes > known ? disk.usedBytes - known : 0

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(ByteFormat.compact(disk.usedBytes))
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(Mono.ink(scheme))
                    Text("de \(ByteFormat.compact(disk.totalBytes)) · \(ByteFormat.compact(disk.availableBytes)) disponibles")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Mono.muted(scheme))
                }
                Spacer()
                HStack(spacing: 12) {
                    matrixPill("Apps", value: ByteFormat.compact(apps), color: Mono.appsAccent)
                    matrixPill("Basura", value: ByteFormat.compact(cleanable), color: Mono.junkAccent)
                    matrixPill("Sistema", value: ByteFormat.compact(sys), color: Mono.ink(scheme).opacity(0.62))
                }
            }

            DotMatrixStorageBar(
                appsFraction: Double(apps) / Double(total),
                cleanableFraction: Double(cleanable) / Double(total),
                systemFraction: Double(sys) / Double(total),
                forceDark: false
            )
            .frame(height: 32)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .monoCard(radius: 14, glass: true)
    }

    private func matrixPill(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6.5, height: 6.5)
            Text("\(label) \(value)")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Mono.muted(scheme))
                .lineLimit(1)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            navigationStack = []
            Task { await appState.mapDisk(at: url.path) }
        }
    }
}

// MARK: - Interactive Squarified Monochrome Treemap

private struct MonochromeTreemap: View {
    @Environment(\.colorScheme) private var scheme
    let nodes: [DiskNode]
    @Binding var hoveredID: String?
    let onSelect: (DiskNode) -> Void

    var body: some View {
        GeometryReader { geo in
            let rects = layoutRects(nodes: nodes, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(rects.enumerated()), id: \.element.node.id) { idx, item in
                    let isHovered = hoveredID == item.node.id
                    let rect = item.rect.insetBy(dx: 2, dy: 2)
                    if rect.width > 4 && rect.height > 4 {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(
                                    item.node.isCleanableCandidate
                                        ? Mono.primaryFill(scheme).opacity(isHovered ? 1.0 : 0.88)
                                        : Mono.shade(idx + 1, scheme: scheme).opacity(isHovered ? 0.95 : 0.72)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(
                                            isHovered ? Mono.ink(scheme) : Mono.canvas(scheme).opacity(0.6),
                                            lineWidth: isHovered ? 1.5 : 0.8
                                        )
                                )

                            if rect.width > 64 && rect.height > 34 {
                                let labelColor: Color = item.node.isCleanableCandidate
                                    ? Mono.primaryInk(scheme)
                                    : (idx <= 1 ? Mono.primaryInk(scheme) : Mono.ink(scheme))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.node.name)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(labelColor)
                                        .lineLimit(1)
                                    Text(ByteFormat.compact(item.node.sizeBytes))
                                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                        .foregroundStyle(labelColor.opacity(0.75))
                                        .lineLimit(1)
                                }
                                .padding(7)
                            }
                        }
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .onHover { hovering in
                            withAnimation(Mono.fast) {
                                hoveredID = hovering ? item.node.id : (hoveredID == item.node.id ? nil : hoveredID)
                            }
                        }
                        .onTapGesture {
                            onSelect(item.node)
                        }
                    }
                }
            }
        }
    }

    private struct LayoutTile {
        let node: DiskNode
        let rect: CGRect
    }

    /// Recursive binary-partition treemap layout that keeps tile aspect ratios balanced and readable.
    private func layoutRects(nodes: [DiskNode], in bounds: CGRect) -> [LayoutTile] {
        guard !nodes.isEmpty, bounds.width > 2, bounds.height > 2 else { return [] }
        let total = nodes.reduce(0.0) { $0 + Double($1.sizeBytes) }
        guard total > 0 else { return [] }
        return partition(nodes: nodes, total: total, rect: bounds)
    }

    private func partition(nodes: [DiskNode], total: Double, rect: CGRect) -> [LayoutTile] {
        if nodes.count == 1 {
            return [LayoutTile(node: nodes[0], rect: rect)]
        }

        // Split into two balanced halves by cumulative size
        var acc = 0.0
        var splitIdx = 1
        for i in 0..<(nodes.count - 1) {
            acc += Double(nodes[i].sizeBytes)
            splitIdx = i + 1
            if acc >= total * 0.48 { break }
        }

        let leftNodes = Array(nodes[0..<splitIdx])
        let rightNodes = Array(nodes[splitIdx..<nodes.count])
        let leftSum = leftNodes.reduce(0.0) { $0 + Double($1.sizeBytes) }
        let rightSum = max(1.0, total - leftSum)
        let ratio = CGFloat(leftSum / total)

        let (r1, r2): (CGRect, CGRect)
        if rect.width >= rect.height {
            let w1 = rect.width * ratio
            r1 = CGRect(x: rect.minX, y: rect.minY, width: w1, height: rect.height)
            r2 = CGRect(x: rect.minX + w1, y: rect.minY, width: rect.width - w1, height: rect.height)
        } else {
            let h1 = rect.height * ratio
            r1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h1)
            r2 = CGRect(x: rect.minX, y: rect.minY + h1, width: rect.width, height: rect.height - h1)
        }

        return partition(nodes: leftNodes, total: max(1.0, leftSum), rect: r1)
            + partition(nodes: rightNodes, total: rightSum, rect: r2)
    }
}
