import CleanTrashCore
import SwiftUI

struct SystemJunkView: View {
    @Bindable var appState: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedCategory: JunkCategory? = nil
    @State private var confirmClean = false
    @State private var confirmTrash = false

    private var filtered: [JunkItem] {
        guard let cat = selectedCategory else { return appState.junkItems }
        return appState.junkItems.filter { $0.category == cat }
    }

    private var selectedBytes: UInt64 {
        filtered.filter(\.selected).reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            trashCard
            categoryGrid
            selectionBar
            itemList
        }
        .padding(20)
        .task { await appState.refreshTrashContents() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Icon3D(name: .trash, size: 58)
                .padding(.trailing, 8)
            VStack(alignment: .leading, spacing: 3) {
                Text("Limpieza del Sistema")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Mono.ink(scheme))
                Text("Cachés, registros viejos e instaladores que macOS y tus apps regeneran solos.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Mono.muted(scheme))
            }
            Spacer()

            Button {
                Task { await appState.scanSystemJunk() }
            } label: {
                Label(appState.isScanningJunk ? "Buscando…" : "Analizar", systemImage: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: appState.isScanningJunk && !reduceMotion)
            }
            .buttonStyle(MonoGhostButtonStyle())
            .disabled(appState.isScanningJunk)

            Button {
                confirmClean = true
            } label: {
                Label(
                    appState.isCleaning ? (appState.cleaningLabel ?? "Limpiando…") : "Limpiar \(ByteFormat.compact(appState.reclaimableJunkBytes))",
                    systemImage: "sparkles"
                )
            }
            .buttonStyle(MonoPrimaryButtonStyle())
            .disabled(appState.reclaimableJunkBytes == 0 || appState.isCleaning)
            .confirmationDialog(
                "¿Limpiar \(ByteFormat.compact(appState.reclaimableJunkBytes))?",
                isPresented: $confirmClean,
                titleVisibility: .visible
            ) {
                Button("Limpiar \(selectedCount) \(selectedCount == 1 ? "elemento" : "elementos")", role: .destructive) {
                    Task { await appState.cleanSelectedJunk() }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(appState.settings.useTrashByDefault
                     ? "Las cachés y registros se moverán a la Papelera. Lo que ya está en la Papelera se borra definitivamente."
                     : "Se borrarán definitivamente. Son archivos temporales que se regeneran solos.")
            }
        }
    }

    private var selectedCount: Int { appState.junkItems.filter(\.selected).count }

    // MARK: - Trash (dedicated, because it is the most common "it didn't work" spot)

    private var trashCard: some View {
        let trash = appState.trashContents
        let busyEmptying = appState.isCleaning && appState.cleaningLabel == "Vaciando Papelera…"
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Mono.ink(scheme).opacity(0.08))
                    .frame(width: 40, height: 40)
                Image(systemName: trash.itemCount > 0 ? "trash.fill" : "trash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Mono.ink(scheme))
                    .contentTransition(.symbolEffect(.replace))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Papelera")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Mono.ink(scheme))
                Text(trashDescription(trash))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Mono.muted(scheme))
                    .contentTransition(.numericText())
            }

            Spacer()

            if busyEmptying {
                ProgressView().controlSize(.small)
            }

            Button {
                confirmTrash = true
            } label: {
                Label(busyEmptying ? "Vaciando…" : "Vaciar Papelera", systemImage: "trash.slash")
            }
            .buttonStyle(MonoPrimaryButtonStyle())
            .disabled(appState.isCleaning || (trash.readable && trash.itemCount == 0))
            .confirmationDialog(
                "¿Vaciar la Papelera?",
                isPresented: $confirmTrash,
                titleVisibility: .visible
            ) {
                Button("Vaciar Papelera", role: .destructive) {
                    Task { await appState.emptyTrashNow() }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(trash.readable
                     ? "Se borrarán definitivamente \(trash.itemCount) \(trash.itemCount == 1 ? "elemento" : "elementos") (\(ByteFormat.compact(trash.totalBytes))). No se puede deshacer."
                     : "CleanTrash no puede leer la Papelera sin Acceso total al disco, así que pedirá a Finder que la vacíe. No se puede deshacer.")
            }
        }
        .padding(14)
        .monoCard(radius: 12)
        .animation(Mono.betweenSpring, value: trash)
    }

    private func trashDescription(_ trash: TrashContents) -> String {
        guard trash.readable else { return "Sin acceso para medirla · se vaciará con Finder" }
        guard trash.itemCount > 0 else { return "Vacía" }
        return "\(ByteFormat.compact(trash.totalBytes)) · \(trash.itemCount) \(trash.itemCount == 1 ? "elemento" : "elementos")"
    }

    // MARK: - Categories

    private var categoryGrid: some View {
        let cols = [GridItem(.adaptive(minimum: 160), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            ForEach(JunkCategory.allCases.filter { $0 != .trash }) { category in
                categoryCard(category)
            }
        }
    }

    private func categoryCard(_ category: JunkCategory) -> some View {
        let items = appState.junkItems.filter { $0.category == category }
        let bytes = items.reduce(0 as UInt64) { $0 + $1.sizeBytes }
        let isSelected = selectedCategory == category
        let isEmpty = items.isEmpty

        return Button {
            withAnimation(reduceMotion ? .none : Mono.betweenSpring) {
                selectedCategory = isSelected ? nil : category
            }
            AppKitHaptics.tap()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: category.symbolName)
                        .font(.system(size: 12))
                    Spacer()
                    if !isEmpty {
                        Text("\(items.count)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                    }
                }
                .foregroundStyle(isSelected ? Mono.primaryInk(scheme) : Mono.muted(scheme))

                Text(category.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isSelected ? Mono.primaryInk(scheme) : Mono.ink(scheme))
                    .lineLimit(1)

                Text(isEmpty ? (appState.isScanningJunk ? "…" : "Limpio") : ByteFormat.compact(bytes))
                    .font(.system(size: 13.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(isSelected ? Mono.primaryInk(scheme) : (isEmpty ? Mono.subtle(scheme) : Mono.ink(scheme)))
                    .contentTransition(.numericText())
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Mono.primaryFill(scheme) : Mono.card(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : Mono.hairline(scheme), lineWidth: 1)
            )
            .opacity(isEmpty ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isEmpty)
        .pointingHandCursor()
        .help(isEmpty ? "\(category.title): nada que limpiar" : "Filtrar por \(category.title)")
    }

    // MARK: - Selection bar

    private var selectionBar: some View {
        HStack(spacing: 8) {
            if let cat = selectedCategory {
                Button {
                    withAnimation(Mono.betweenSpring) { selectedCategory = nil }
                } label: {
                    Label(cat.title, systemImage: "xmark")
                }
                .buttonStyle(MonoGhostButtonStyle())
                .help("Quitar filtro")
            }
            Text("\(filtered.count) \(filtered.count == 1 ? "elemento" : "elementos") · \(ByteFormat.compact(selectedBytes)) seleccionados")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Mono.muted(scheme))
                .contentTransition(.numericText())
            Spacer()
            Button("Todo") { setSelection(true) }.buttonStyle(MonoGhostButtonStyle())
            Button("Nada") { setSelection(false) }.buttonStyle(MonoGhostButtonStyle())
        }
        .disabled(filtered.isEmpty)
    }

    // MARK: - Item list

    @ViewBuilder
    private var itemList: some View {
        if filtered.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                if appState.isScanningJunk {
                    ProgressView().controlSize(.regular)
                    Text("Buscando cachés, registros e instaladores…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Mono.muted(scheme))
                } else {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Mono.healthy)
                    Text("Nada que limpiar aquí")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                    Text("Pulsa Analizar para volver a buscar.")
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.muted(scheme))
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filtered) { item in
                        row(item)
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .leading))))
                    }
                }
                .animation(reduceMotion ? .none : Mono.betweenSpring, value: filtered.map(\.id))
            }
        }
    }

    private func row(_ item: JunkItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.selected ? "checkmark.square.fill" : "square")
                .font(.system(size: 14.5))
                .foregroundStyle(item.selected ? Mono.ink(scheme) : Mono.muted(scheme))
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(item.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                        .lineLimit(1)
                    MonoTag(text: item.category.title)
                }
                Text("\(item.reason) · \(item.path)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Mono.muted(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteFormat.compact(item.sizeBytes))
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(Mono.ink(scheme))

            Button {
                appState.revealInFinder(item.path)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Mono.muted(scheme))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Mono.ink(scheme).opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Mostrar en Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .monoCard(radius: 10)
        .opacity(item.selected ? 1 : 0.72)
        .contentShape(Rectangle())
        .onTapGesture {
            if let idx = appState.junkItems.firstIndex(where: { $0.id == item.id }) {
                withAnimation(Mono.fast) { appState.junkItems[idx].selected.toggle() }
            }
        }
    }

    private func setSelection(_ value: Bool) {
        let ids = Set(filtered.map(\.id))
        withAnimation(Mono.fast) {
            for idx in appState.junkItems.indices where ids.contains(appState.junkItems[idx].id) {
                appState.junkItems[idx].selected = value
            }
        }
    }
}
