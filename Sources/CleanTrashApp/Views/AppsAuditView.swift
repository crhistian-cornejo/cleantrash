import AppKit
import CleanTrashCore
import SwiftUI

private enum AppAuditFilter: String, CaseIterable, Identifiable {
    case unused = "Sin usar"
    case all = "Todas"
    case leftovers = "Archivos sobrantes"

    var id: String { rawValue }
}

struct AppsAuditView: View {
    @Bindable var appState: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var filter: AppAuditFilter = .unused
    @State private var searchText: String = ""
    @State private var inspectingApp: InstalledAppInfo?

    private var displayedApps: [InstalledAppInfo] {
        let base = filter == .unused ? appState.unusedApps : appState.installedApps
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apps y programas sin usar")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Mono.ink(scheme))
                    Text("Elimina apps completas y sus archivos ocultos en un clic, solo confirmando con tu huella.")
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.muted(scheme))
                }
                Spacer()
                Button {
                    Task { await appState.auditApplications() }
                } label: {
                    Label(appState.isAuditingApps ? "Buscando…" : "Actualizar", systemImage: "arrow.clockwise")
                }
                .buttonStyle(MonoGhostButtonStyle())
                .disabled(appState.isAuditingApps)
            }

            // Interactive "¿Aún la usas?" card with full-color real macOS app icon + 1-click Touch ID uninstall
            if filter == .unused, let topUnused = appState.unusedApps.first {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: topUnused.appPath))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            MonoTag(text: "¿AÚN LA USAS?", inverted: true)
                            MonoTag(text: ByteFormat.relativeAge(topUnused.lastUsedDate).uppercased())
                        }
                        Text(topUnused.name)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Mono.ink(scheme))
                        Text("Ocupa \(ByteFormat.compact(topUnused.totalSizeBytes)) · \(topUnused.relatedFiles.count) archivos extra incluidos")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Mono.muted(scheme))
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button("La uso") {
                            withAnimation(Mono.betweenSpring) {
                                appState.markAppDecision(topUnused, decision: .keep)
                            }
                        }
                        .buttonStyle(MonoGhostButtonStyle())

                        Button("Luego") {
                            withAnimation(Mono.betweenSpring) {
                                appState.markAppDecision(topUnused, decision: .snoozed, snoozeDays: 30)
                            }
                        }
                        .buttonStyle(MonoGhostButtonStyle())

                        Button {
                            Task { await appState.deepUninstallApp(topUnused) }
                        } label: {
                            Label(appState.isCleaning ? "Eliminando…" : "Eliminar", systemImage: "touchid")
                        }
                        .buttonStyle(MonoPrimaryButtonStyle())
                        .disabled(appState.isCleaning)
                    }
                }
                .padding(16)
                .monoCard(radius: 14, glass: true)
            }

            // Filter tabs + Search
            HStack(spacing: 8) {
                ForEach(AppAuditFilter.allCases) { tab in
                    let isSelected = filter == tab
                    let countLabel: String = {
                        switch tab {
                        case .unused: return "\(tab.rawValue) (\(appState.unusedApps.count))"
                        case .all: return "\(tab.rawValue) (\(appState.installedApps.count))"
                        case .leftovers: return "\(tab.rawValue) (\(appState.orphanLeftovers.count))"
                        }
                    }()
                    Button(countLabel) {
                        withAnimation(Mono.betweenSpring) { filter = tab }
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isSelected ? Mono.primaryInk(scheme) : Mono.ink(scheme).opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(isSelected ? Mono.primaryFill(scheme) : Mono.ink(scheme).opacity(0.09)))
                    .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Mono.hairline(scheme), lineWidth: 0.8))
                    .buttonStyle(.plain)
                }

                Spacer()

                if filter == .leftovers && !appState.orphanLeftovers.isEmpty {
                    let bytes = appState.orphanLeftovers.filter(\.selected).reduce(0 as UInt64) { $0 + $1.sizeBytes }
                    Button("Limpiar (\(ByteFormat.compact(bytes)))") {
                        Task { await appState.cleanSelectedOrphanLeftovers() }
                    }
                    .buttonStyle(MonoPrimaryButtonStyle())
                    .disabled(bytes == 0 || appState.isCleaning)
                } else {
                    TextField("Buscar aplicación…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(width: 210)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Mono.card(scheme)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Mono.hairline(scheme), lineWidth: 1))
                }
            }

            // Content List
            if filter == .leftovers {
                leftoversList
            } else {
                appsList
            }
        }
        .padding(20)
        .sheet(item: $inspectingApp) { app in
            AppDeepUninstallSheet(app: app, appState: appState) {
                inspectingApp = nil
            }
        }
    }

    private var appsList: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(displayedApps) { app in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.appPath))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Text(app.name)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(Mono.ink(scheme))
                                if app.isRunning {
                                    HStack(spacing: 4) {
                                        Circle().fill(Mono.healthy).frame(width: 6, height: 6)
                                        Text("Abierta")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Mono.healthy)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Mono.healthy.opacity(0.14)))
                                } else if app.isUnused(thresholdDays: appState.settings.unusedAppThresholdDays) {
                                    MonoTag(text: "SIN USAR")
                                }
                            }
                            Text("\(ByteFormat.relativeAge(app.lastUsedDate))\(app.relatedFiles.isEmpty ? "" : " · \(app.relatedFiles.count) archivos extra")")
                                .font(.system(size: 11))
                                .foregroundStyle(Mono.muted(scheme))
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(ByteFormat.compact(app.totalSizeBytes))
                            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Mono.ink(scheme))

                        if app.isUnused(thresholdDays: appState.settings.unusedAppThresholdDays) {
                            Button("Conservar") {
                                appState.markAppDecision(app, decision: .keep)
                            }
                            .buttonStyle(MonoGhostButtonStyle())
                        }

                        Button {
                            inspectingApp = app
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(Mono.muted(scheme))
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Mono.ink(scheme).opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .help("Ver archivos asociados")

                        Button {
                            Task { await appState.deepUninstallApp(app) }
                        } label: {
                            Label("Eliminar", systemImage: "touchid")
                        }
                        .buttonStyle(MonoGhostButtonStyle())
                        .disabled(app.isAppleSystemApp || appState.isCleaning)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .monoCard(radius: 11)
                }
            }
        }
    }

    private var leftoversList: some View {
        Group {
            if appState.orphanLeftovers.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No hay restos huérfanos en tu Librería.")
                        .font(.system(size: 13))
                        .foregroundStyle(Mono.muted(scheme))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .monoCard(radius: 14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(appState.orphanLeftovers) { item in
                            HStack(spacing: 12) {
                                Button {
                                    if let idx = appState.orphanLeftovers.firstIndex(where: { $0.id == item.id }) {
                                        appState.orphanLeftovers[idx].selected.toggle()
                                    }
                                } label: {
                                    Image(systemName: item.selected ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 14.5))
                                        .foregroundStyle(Mono.ink(scheme))
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(item.name)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(Mono.ink(scheme))
                                        MonoTag(text: item.location)
                                    }
                                    Text(item.path)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Mono.muted(scheme))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteFormat.compact(item.sizeBytes))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Mono.ink(scheme))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .monoCard(radius: 10)
                        }
                    }
                }
            }
        }
    }
}

private struct AppDeepUninstallSheet: View {
    let app: InstalledAppInfo
    @Bindable var appState: AppState
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var selectedPaths: Set<String>

    init(app: InstalledAppInfo, appState: AppState, onDismiss: @escaping () -> Void) {
        self.app = app
        self.appState = appState
        self.onDismiss = onDismiss
        self._selectedPaths = State(initialValue: Set(app.relatedFiles.map(\.path)))
    }

    private var totalSelectedBytes: UInt64 {
        app.bundleSizeBytes + app.relatedFiles
            .filter { selectedPaths.contains($0.path) }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.appPath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Desinstalar \(app.name) por completo")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Mono.ink(scheme))
                    Text("\(app.bundleID) · \(appState.settings.useTrashByDefault ? "Mueve la app y los archivos marcados a la Papelera" : "Borra la app y los archivos marcados")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Mono.muted(scheme))
                }
                Spacer()
            }

            // App bundle row
            HStack {
                Image(systemName: "app.fill")
                Text(app.appPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(ByteFormat.compact(app.bundleSizeBytes))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .padding(11)
            .monoCard(radius: 10)

            Text("ARCHIVOS ASOCIADOS (\(app.relatedFiles.count))")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Mono.muted(scheme))

            ScrollView {
                VStack(spacing: 6) {
                    if app.relatedFiles.isEmpty {
                        Text("Esta app no dejó archivos extra en la Librería.")
                            .font(.system(size: 12))
                            .foregroundStyle(Mono.muted(scheme))
                            .padding(.vertical, 16)
                    } else {
                        ForEach(app.relatedFiles) { file in
                            let isOn = selectedPaths.contains(file.path)
                            HStack(spacing: 10) {
                                Button {
                                    if isOn { selectedPaths.remove(file.path) } else { selectedPaths.insert(file.path) }
                                } label: {
                                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(Mono.ink(scheme))
                                }
                                .buttonStyle(.plain)

                                MonoTag(text: file.kind.rawValue)
                                Text(file.path)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Mono.muted(scheme))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(ByteFormat.compact(file.sizeBytes))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Mono.ink(scheme))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .monoCard(radius: 8)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)

            HStack {
                Button("Cancelar", action: onDismiss)
                    .buttonStyle(MonoGhostButtonStyle())
                    .disabled(appState.isCleaning)
                Spacer()
                Button(appState.isCleaning ? "Uninstalling…" : "Move \(ByteFormat.compact(totalSelectedBytes)) to Trash") {
                    Task {
                        await appState.deepUninstallApp(app, selectedRelatedPaths: Array(selectedPaths))
                        onDismiss()
                    }
                }
                .buttonStyle(MonoPrimaryButtonStyle())
                .disabled(appState.isCleaning)
            }
        }
        .padding(24)
        .frame(width: 580)
        .background(Mono.canvas(scheme))
    }
}
