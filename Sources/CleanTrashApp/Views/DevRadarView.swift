import CleanTrashCore
import SwiftUI

struct DevRadarView: View {
    @Bindable var appState: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var selectedEcosystem: DevEcosystem? = nil
    @State private var searchText: String = ""

    private var filtered: [DevArtifact] {
        appState.devArtifacts.filter { item in
            if let eco = selectedEcosystem, item.ecosystem != eco { return false }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                return item.projectName.lowercased().contains(q)
                    || item.artifactKind.lowercased().contains(q)
                    || item.path.lowercased().contains(q)
            }
            return true
        }
    }

    private var ecosystemTotals: [(ecosystem: DevEcosystem, bytes: UInt64)] {
        DevEcosystem.allCases.compactMap { eco in
            let sum = appState.devArtifacts.filter { $0.ecosystem == eco }.reduce(0) { $0 + $1.sizeBytes }
            return sum > 0 ? (eco, sum) : nil
        }
        .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Dev Radar")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Mono.ink(scheme))
                        HStack(spacing: 4) {
                            Circle().fill(Mono.healthy).frame(width: 6, height: 6)
                            Text("Vigilancia activa")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Mono.healthy)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Mono.healthy.opacity(0.14)))
                    }
                    Text("Detecta automáticamente carpetas pesadas de compilación (Rust, Node, Swift, Xcode e IA) que se regeneran solas.")
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.muted(scheme))
                }
                Spacer()
                Button {
                    Task { await appState.scanDevArtifacts() }
                } label: {
                    Label(appState.isScanningDev ? "Buscando…" : "Actualizar", systemImage: "arrow.clockwise")
                }
                .buttonStyle(MonoGhostButtonStyle())
                .disabled(appState.isScanningDev)

                Button {
                    Task { await appState.cleanSelectedDevArtifacts() }
                } label: {
                    Label("Limpiar (\(ByteFormat.compact(appState.reclaimableDevBytes)))", systemImage: "trash")
                }
                .buttonStyle(MonoPrimaryButtonStyle())
                .disabled(appState.reclaimableDevBytes == 0 || appState.isCleaning)
            }

            // Ecosystem breakdown bars (crisp aligned Swiss layout, zero label collisions)
            if !ecosystemTotals.isEmpty {
                let maxBytes = max(1, ecosystemTotals.first?.bytes ?? 1)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("ESPACIO POR ECOSISTEMA")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Mono.muted(scheme))
                        Spacer()
                        Text("TOTAL \(ByteFormat.compact(appState.totalDevBytes))")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Mono.ink(scheme))
                    }

                    VStack(spacing: 8) {
                        ForEach(ecosystemTotals, id: \.ecosystem.id) { entry in
                            let ratio = Double(entry.bytes) / Double(maxBytes)
                            let active = selectedEcosystem == nil || selectedEcosystem == entry.ecosystem
                            Button {
                                withAnimation(Mono.betweenSpring) {
                                    selectedEcosystem = (selectedEcosystem == entry.ecosystem) ? nil : entry.ecosystem
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    HStack(spacing: 6) {
                                        Image(systemName: entry.ecosystem.symbolName)
                                            .font(.system(size: 11))
                                            .frame(width: 15)
                                        Text(entry.ecosystem.rawValue)
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(Mono.ink(scheme).opacity(active ? 1.0 : 0.4))
                                    .frame(width: 144, alignment: .leading)

                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule()
                                                .fill(Mono.ink(scheme).opacity(0.10))
                                            Capsule()
                                                .fill(Mono.ink(scheme).opacity(active ? 0.94 : 0.28))
                                                .frame(width: max(6, geo.size.width * ratio))
                                        }
                                    }
                                    .frame(height: 8)

                                    Text(ByteFormat.compact(entry.bytes))
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Mono.ink(scheme).opacity(active ? 1.0 : 0.45))
                                        .frame(width: 68, alignment: .trailing)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
                .monoCard(radius: 14)
            }

            // Single-line filter pills + search
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterPill(title: "Todos", selected: selectedEcosystem == nil) {
                            selectedEcosystem = nil
                        }
                        ForEach(DevEcosystem.allCases) { eco in
                            filterPill(title: eco.rawValue, selected: selectedEcosystem == eco) {
                                selectedEcosystem = (selectedEcosystem == eco) ? nil : eco
                            }
                        }
                    }
                }

                TextField("Filtrar proyecto o ruta…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 210)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Mono.card(scheme)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Mono.hairline(scheme), lineWidth: 1))
            }

            // Artifact List
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 28))
                        .foregroundStyle(Mono.muted(scheme))
                    Text(appState.isScanningDev ? "Buscando en tus carpetas de proyectos…" : "No hay artefactos que coincidan")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Mono.muted(scheme))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .monoCard(radius: 14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { item in
                            artifactRow(item)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(20)
    }

    private func artifactRow(_ item: DevArtifact) -> some View {
        HStack(spacing: 12) {
            Button {
                if let idx = appState.devArtifacts.firstIndex(where: { $0.id == item.id }) {
                    appState.devArtifacts[idx].selected.toggle()
                }
            } label: {
                Image(systemName: item.selected && !item.isActiveBuild ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(item.isActiveBuild ? Mono.subtle(scheme) : Mono.ink(scheme))
            }
            .buttonStyle(.plain)
            .disabled(item.isActiveBuild)

            Image(systemName: item.ecosystem.symbolName)
                .font(.system(size: 14))
                .foregroundStyle(Mono.muted(scheme))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Mono.ink(scheme).opacity(0.06)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                    MonoTag(text: item.artifactKind)
                    if item.isActiveBuild {
                        MonoTag(text: "BUILDING NOW · PROTECTED", inverted: true)
                    } else if item.ageDays >= appState.settings.devStaleDays {
                        MonoTag(text: "STALE \(item.ageDays)D")
                    }
                }
                Text(item.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Mono.muted(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.compact(item.sizeBytes))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Mono.ink(scheme))
                Text(ByteFormat.relativeAge(item.lastModified))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Mono.muted(scheme))
            }

            Button {
                appState.revealInFinder(item.path)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Mono.muted(scheme))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Mono.ink(scheme).opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Mostrar en Finder")

            Button("Limpiar") {
                Task { await appState.cleanSingleDevArtifact(item) }
            }
            .buttonStyle(MonoGhostButtonStyle())
            .disabled(item.isActiveBuild || appState.isCleaning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .monoCard(radius: 12)
    }

    private func filterPill(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(selected ? Mono.primaryInk(scheme) : Mono.ink(scheme).opacity(0.78))
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background(Capsule().fill(selected ? Mono.primaryFill(scheme) : Mono.ink(scheme).opacity(0.09)))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Mono.hairline(scheme), lineWidth: 0.8))
            .buttonStyle(.plain)
    }
}
