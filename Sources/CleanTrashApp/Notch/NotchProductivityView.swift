import AppKit
import CleanTrashCore
import SwiftUI
import UniformTypeIdentifiers

enum ProductivitySubTab: String, CaseIterable, Identifiable {
    case shelf = "Archivos"
    case clipboard = "Clips"
    case vault = "Bóveda"
    case focus = "Focus"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .shelf: return "tray.and.arrow.down"
        case .clipboard: return "doc.on.clipboard"
        case .vault: return "key.fill"
        case .focus: return "timer"
        }
    }
}

private enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all = "Clipboard"
    case pinned = "Fijados"
    case colors = "Colores"

    var id: String { rawValue }
}

/// Droppy-style Productivity Hub inside the Notch:
/// 1. Drag & Drop File Shelf (stage, drag-out, zip, AirDrop/Share)
/// 2. Rich Horizontal Clipboard Cards (Text / Link / Full-Bleed Color HEX+RGB / Image)
/// 3. Touch ID Password Vault Quick-Search & Browser/App AutoFill (Chrome, Safari, Arc, Apps)
/// 4. Focus / Pomodoro Timer
struct NotchProductivityView: View {
    @Bindable var hub: ProductivityHub
    @Bindable var vault: VaultController
    @Binding var subTab: ProductivitySubTab
    let onCollapseNotch: () -> Void

    @Environment(\.notchSurface) private var surface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isZipping = false
    @State private var isDropTargeted = false
    @State private var clipFilter: ClipboardFilter = .all
    @State private var vaultQuery: String = ""

    var body: some View {
        VStack(spacing: 10) {
            subTabBar

            Group {
                switch subTab {
                case .shelf:
                    shelfBody
                case .clipboard:
                    clipboardBody
                case .vault:
                    vaultBody
                case .focus:
                    focusBody
                }
            }
            .id(subTab)
            .transition(.opacity.combined(with: .offset(y: 3)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(reduceMotion ? .none : Mono.betweenSpring, value: subTab)
        .onChange(of: subTab) { _, tab in
            if tab == .vault {
                vault.refreshFrontmostContext()
            }
        }
    }

    // MARK: - Sub-Tab Switcher

    private var subTabBar: some View {
        HStack(spacing: 5) {
            ForEach(ProductivitySubTab.allCases) { tab in
                let selected = subTab == tab
                Button {
                    withAnimation(reduceMotion ? .none : Mono.betweenSpring) {
                        subTab = tab
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 10, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                        if let count = subBadge(tab) {
                            Text(count)
                                .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(selected ? .white : .black)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(selected ? Color.black.opacity(0.65) : Color.white.opacity(0.85)))
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(selected ? .black : Color.white.opacity(0.75))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.09)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            Spacer(minLength: 4)

            // Droppy Text Capture (Native macOS Vision OCR from any screen region!)
            Button {
                Task { await hub.captureScreenText() }
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("OCR")
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.11)))
                .contentShape(Capsule())
            }
            .buttonStyle(NotchButtonStyle())
            .help("Capturar texto de cualquier parte de la pantalla (Vision OCR)")

            if subTab == .shelf && !hub.shelfItems.isEmpty {
                shelfActionPill("Zip", icon: "doc.zipper", disabled: isZipping) {
                    Task {
                        isZipping = true
                        _ = await hub.zipShelfItems(hub.shelfItems)
                        isZipping = false
                    }
                }
                shelfActionPill("AirDrop", icon: "square.and.arrow.up") {
                    hub.shareShelfItems(hub.shelfItems)
                }
                Button {
                    hub.clearShelf()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.09)))
                        .contentShape(Circle())
                }
                .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                .help("Vaciar bandeja")
            } else if subTab == .clipboard && !hub.clipboardEntries.isEmpty {
                Button {
                    hub.clearUnpinnedClipboard()
                } label: {
                    Text("Limpiar")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(Capsule().fill(Color.white.opacity(0.09)))
                }
                .buttonStyle(NotchButtonStyle())
                .help("Borrar elementos no fijados")
            }
        }
    }

    private func subBadge(_ tab: ProductivitySubTab) -> String? {
        switch tab {
        case .shelf:
            return hub.shelfItems.isEmpty ? nil : "\(hub.shelfItems.count)"
        case .clipboard:
            return hub.clipboardEntries.isEmpty ? nil : "\(hub.clipboardEntries.count)"
        case .vault:
            guard vault.isUnlocked else { return nil }
            let matches = vault.contextMatches.count
            return matches > 0 ? "\(matches)" : nil
        case .focus:
            return hub.isTimerRunning ? hub.timerFormatted : nil
        }
    }

    // MARK: - 3. Touch ID Password Vault Quick-Search & Browser/App AutoFill

    private var vaultBody: some View {
        Group {
            if !vault.isUnlocked {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        Icon3D(name: .vault, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bóveda cifrada (CTV2 · AES-256)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                            Text(vault.activeHost.map { "Listo para autocompletar en \($0)" } ?? "Desbloquea con Touch ID para buscar o autocompletar en Chrome, Safari y apps.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(2)
                        }
                    }

                    Button {
                        vault.authenticateAndUnlock(reason: "Acceder a tus contraseñas desde el Notch")
                    } label: {
                        Label("Desbloquear con Touch ID", systemImage: "touchid")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(NotchButtonStyle())
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let results = vault.searchItems(query: vaultQuery)
                VStack(spacing: 8) {
                    HStack(spacing: 7) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.5))
                            TextField(
                                vault.activeHost.map { "Buscar (detectado: \($0))…" } ?? "Buscar sitio, usuario o carpeta…",
                                text: $vaultQuery
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white)
                            if !vaultQuery.isEmpty {
                                Button { vaultQuery = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .background(Capsule().fill(Color.white.opacity(0.09)))

                        if let host = vault.activeHost, vaultQuery.isEmpty {
                            Text(host)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Mono.ramAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Mono.ramAccent.opacity(0.16)))
                                .lineLimit(1)
                        }

                        Button {
                            vault.lock()
                        } label: {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.white.opacity(0.10)))
                        }
                        .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                        .help("Bloquear Bóveda ahora")
                    }

                    if results.isEmpty {
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            Text(vault.items.isEmpty ? "Importa tus contraseñas desde Bóveda en la ventana principal." : "Sin coincidencias para «\(vaultQuery)»")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.55))
                            Spacer(minLength: 0)
                        }
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 5) {
                                ForEach(results.prefix(8)) { item in
                                    let isMatch = VaultHygieneAuditor.matchScore(item: item, activeHost: vault.activeHost, activeAppName: vault.activeAppName) >= 45
                                    let justCopied = vault.copiedItemID == item.id
                                    HStack(spacing: 8) {
                                        ZStack {
                                            Circle()
                                                .fill(isMatch ? Mono.ramAccent.opacity(0.24) : Color.white.opacity(0.10))
                                                .frame(width: 26, height: 26)
                                            Text(String(item.title.prefix(1)).uppercased())
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(isMatch ? Mono.ramAccent : .white)
                                        }

                                        VStack(alignment: .leading, spacing: 1) {
                                            HStack(spacing: 5) {
                                                Text(item.title)
                                                    .font(.system(size: 11.5, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(1)
                                                if isMatch {
                                                    Text("SITIO ACTUAL")
                                                        .font(.system(size: 7.5, weight: .heavy))
                                                        .foregroundStyle(.black)
                                                        .padding(.horizontal, 4.5)
                                                        .padding(.vertical, 1)
                                                        .background(Capsule().fill(Mono.ramAccent))
                                                }
                                            }
                                            Text(justCopied ? (vault.copiedLabel ?? "Copiado ✓") : (item.username.isEmpty ? item.normalizedDomain : item.username))
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(justCopied ? Mono.ramAccent : .white.opacity(0.55))
                                                .lineLimit(1)
                                        }

                                        Spacer(minLength: 4)

                                        Button("Rellenar") {
                                            vault.autoFill(item, mode: .usernameAndPassword, collapseNotch: onCollapseNotch)
                                        }
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(.white))
                                        .buttonStyle(NotchButtonStyle())
                                        .help("Autocompletar usuario + Tab + contraseña en la app o navegador activo")

                                        Button("User") {
                                            vault.copySecurely(item.username, itemID: item.id, label: "Usuario copiado ✓")
                                        }
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Color.white.opacity(0.11)))
                                        .buttonStyle(NotchButtonStyle())

                                        Button("Clave") {
                                            vault.copySecurely(item.password, itemID: item.id, label: "Clave copiada (25s) ✓")
                                        }
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Color.white.opacity(0.11)))
                                        .buttonStyle(NotchButtonStyle())
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .notchHoverRow(cornerRadius: 9)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            vault.refreshFrontmostContext()
        }
    }

    private func shelfActionPill(_ title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3.5) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.11)))
            .contentShape(Capsule())
        }
        .buttonStyle(NotchButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    // MARK: - 1. File Shelf (Droppy Drop Zone)

    private var shelfBody: some View {
        let highlighted = isDropTargeted || hub.isDragOverNotch
        return ZStack {
            if hub.shelfItems.isEmpty {
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(highlighted ? 0.18 : 0.08))
                            .frame(width: 48, height: 48)
                        Image(systemName: highlighted ? "arrow.down.doc.fill" : "tray.and.arrow.down")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(highlighted ? Mono.healthy : .white)
                            .scaleEffect(highlighted ? 1.15 : 1.0)
                    }
                    VStack(spacing: 3) {
                        Text(highlighted ? "Suelta para guardar en la bandeja" : "Bandeja de archivos Droppy")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Arrastra archivos hacia el Notch desde Finder o navegador. Luego arrástralos a cualquier app, comprímelos en .zip o compártelos.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.white.opacity(0.54))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 370)
                    }

                    Button {
                        pickFilesForShelf()
                    } label: {
                        Label("Elegir archivos…", systemImage: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(NotchButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(hub.shelfItems) { item in
                            shelfCard(item)
                        }

                        Button {
                            pickFilesForShelf()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.65))
                                Text("Agregar")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.5))
                            }
                            .frame(width: 80, height: 152)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(
                                        Color.white.opacity(highlighted ? 0.5 : 0.16),
                                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(NotchButtonStyle(hoverScale: 1.02))
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.white.opacity(highlighted ? 0.10 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(
                    highlighted ? Mono.healthy.opacity(0.7) : Color.white.opacity(0.11),
                    style: StrokeStyle(lineWidth: highlighted ? 1.5 : 1, dash: hub.shelfItems.isEmpty ? [6, 5] : [])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func shelfCard(_ item: ShelfItem) -> some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                Button {
                    hub.removeShelfItem(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            VStack(spacing: 1.5) {
                Text(item.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if item.sizeBytes > 0 {
                    Text(ByteFormat.compact(item.sizeBytes))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .frame(height: 36, alignment: .top)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Button { hub.copyPath(item) } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Copiar ruta")

                Button { hub.revealInFinder(item) } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Mostrar en Finder")

                Button { hub.shareShelfItems([item]) } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Compartir / AirDrop")

                if Self.isConvertibleImage(item) {
                    let isPNG = item.url.pathExtension.lowercased() == "png"
                    Button {
                        hub.convertImageItem(item, toPNG: !isPNG)
                    } label: {
                        Text(isPNG ? "JPG" : "PNG")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .frame(height: 22)
                            .background(Capsule().fill(Color.white.opacity(0.88)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Convertir a \(isPNG ? "JPEG" : "PNG")")

                    Button {
                        Task { await hub.ocrImageItem(item) }
                    } label: {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Capsule().fill(Color(hex: 0x3B82F6).opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Extraer texto de esta imagen (OCR)")
                }
            }
        }
        .padding(8)
        .frame(width: 110, height: 152)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .onDrag {
            NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL)
        }
        .help("Arrastra \(item.name) hacia cualquier app")
    }

    private static func isConvertibleImage(_ item: ShelfItem) -> Bool {
        let ext = item.url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(ext)
    }

    private func pickFilesForShelf() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            hub.addFiles(panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
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
                    if let url {
                        Task { @MainActor in
                            hub.addFiles([url])
                        }
                    }
                }
            }
        }
        return accepted
    }

    // MARK: - 2. Droppy Horizontal Rich Clipboard Cards (Exact Match to Image 3!)

    private var filteredClipboard: [ClipboardEntry] {
        let all = hub.sortedClipboardEntries
        switch clipFilter {
        case .all: return all
        case .pinned: return all.filter(\.isPinned)
        case .colors: return all.filter { $0.kind == .color }
        }
    }

    private var clipboardBody: some View {
        let items = filteredClipboard
        return VStack(alignment: .leading, spacing: 8) {
            // Droppy-style category filter pills: [Clipboard] [Fijados] [Colores]
            HStack(spacing: 6) {
                ForEach(ClipboardFilter.allCases) { f in
                    let active = clipFilter == f
                    Button {
                        withAnimation(Mono.betweenSpring) { clipFilter = f }
                    } label: {
                        HStack(spacing: 5) {
                            if f == .all {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 10, weight: .bold))
                            } else {
                                Circle()
                                    .fill(f == .pinned ? Color(hex: 0xF59E0B) : Color(hex: 0x34D399))
                                    .frame(width: 7, height: 7)
                            }
                            Text(f.rawValue)
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(active && f == .all ? Color(hex: 0x60A5FA) : (active ? .white : Color.white.opacity(0.68)))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .background(
                            Capsule()
                                .fill(active && f == .all
                                      ? Color(hex: 0x1D4ED8).opacity(0.32)
                                      : Color.white.opacity(active ? 0.16 : 0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                Spacer()
            }

            if items.isEmpty {
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.white.opacity(0.42))
                    Text(clipFilter == .all ? "Tu portapapeles está vacío" : "Sin elementos en \(clipFilter.rawValue)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Copia texto, enlaces, colores HEX (#6E7BF2) o imágenes y aparecerán aquí como tarjetas.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 9) {
                        ForEach(items) { entry in
                            clipboardCard(entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// Rich Droppy-style square/vertical card (Text / Link / Full-bleed Color / Image)
    private func clipboardCard(_ entry: ClipboardEntry) -> some View {
        let justCopied = hub.lastCopiedEntryID == entry.id
        let isColor = entry.kind == .color
        let hexRGB = entry.hexColor.flatMap(Self.rgbComponents)
        let cardBG: Color = isColor
            ? (entry.hexColor.flatMap(Self.colorFromHex) ?? Color(hex: 0x6E7BF2))
            : Color(hex: 0x161619)
        let useDarkInk = isColor && (hexRGB.map { (0.299 * Double($0.r) + 0.587 * Double($0.g) + 0.114 * Double($0.b)) > 140 } ?? false)
        let primaryText: Color = useDarkInk ? Color.black.opacity(0.88) : .white
        let secondaryText: Color = useDarkInk ? Color.black.opacity(0.58) : Color.white.opacity(0.55)

        return VStack(alignment: .leading, spacing: 8) {
            // Card Header: White Pill Badge + Pin / Delete
            HStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: cardTypeIcon(entry.kind))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(cardTypeTint(entry.kind))
                    Text(cardTypeLabel(entry.kind))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(.white))

                Spacer(minLength: 2)

                HStack(spacing: 4) {
                    Button { hub.togglePin(entry) } label: {
                        Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(entry.isPinned ? Color(hex: 0xEF4444) : Color.black.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()

                    Button { hub.removeClipboard(entry) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.55))
                            .frame(width: 18, height: 20)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                .padding(.horizontal, 4)
                .background(Capsule().fill(.white.opacity(0.94)))
            }

            // Card Content Body
            switch entry.kind {
            case .color:
                Spacer(minLength: 0)
                Text(entry.hexColor ?? entry.previewText)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(primaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
                if let rgb = hexRGB {
                    Text(justCopied ? "✓ Copiado" : "RGB \(rgb.r), \(rgb.g), \(rgb.b)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(justCopied ? Mono.healthy : secondaryText)
                }

            case .url:
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color(hex: 0x3B82F6).opacity(0.24))
                            .frame(width: 42, height: 42)
                        Image(systemName: "globe")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x60A5FA))
                    }
                    Spacer()
                }
                Spacer(minLength: 0)
                Text(justCopied ? "✓ Enlace copiado" : entry.previewText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(justCopied ? Mono.healthy : Color.white.opacity(0.75))
                    .lineLimit(2)
                    .truncationMode(.middle)

            case .image:
                if let data = entry.imageData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 132, height: 74)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Spacer(minLength: 0)
                Text(justCopied ? "✓ Imagen copiada" : (entry.imageDimensions ?? "Imagen"))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(justCopied ? Mono.healthy : secondaryText)

            case .text:
                Text(entry.previewText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(primaryText.opacity(0.92))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(justCopied ? "✓ Copiado" : "\((entry.fullText ?? entry.previewText).count) caracteres")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(justCopied ? Mono.healthy : secondaryText)
            }
        }
        .padding(10)
        .frame(width: 152, height: 146, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(cardBG))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    justCopied ? Mono.healthy.opacity(0.8) : Color.white.opacity(isColor ? 0.25 : 0.10),
                    lineWidth: justCopied ? 1.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { hub.copyBack(entry) }
        .pointingHandCursor()
        .help("Clic para copiar")
    }

    private func cardTypeIcon(_ kind: ClipboardEntryKind) -> String {
        switch kind {
        case .text: return "message.fill"
        case .url: return "safari.fill"
        case .color: return "paintpalette.fill"
        case .image: return "photo.fill"
        }
    }

    private func cardTypeTint(_ kind: ClipboardEntryKind) -> Color {
        switch kind {
        case .text: return Color(hex: 0x22C55E)
        case .url: return Color(hex: 0x3B82F6)
        case .color: return Color(hex: 0xEC4899)
        case .image: return Color(hex: 0xA855F7)
        }
    }

    private func cardTypeLabel(_ kind: ClipboardEntryKind) -> String {
        switch kind {
        case .text: return "Text"
        case .url: return "Link"
        case .color: return "Color"
        case .image: return "Image"
        }
    }

    private static func colorFromHex(_ hex: String) -> Color? {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        guard let value = UInt32(cleaned, radix: 16) else { return nil }
        return Color(hex: value)
    }

    private static func rgbComponents(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        guard let value = UInt32(cleaned, radix: 16) else { return nil }
        return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    // MARK: - 3. Focus / Pomodoro Timer

    private var focusBody: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.11), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: min(1, max(0.01, 1.0 - hub.timerProgress)))
                    .stroke(
                        LinearGradient(
                            colors: [hub.isTimerRunning ? Mono.healthy : .white, Color(hex: 0x60A5FA)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(Mono.betweenSpring, value: hub.timerRemainingSeconds)

                VStack(spacing: 2) {
                    Text(hub.timerLabel.uppercased())
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text(hub.timerFormatted)
                        .font(.system(size: 27, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                    Text(hub.isTimerRunning ? "En curso" : "En pausa")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(hub.isTimerRunning ? Mono.healthy : Color.white.opacity(0.45))
                }
            }
            .frame(width: 142, height: 142)
            .padding(.leading, 8)

            VStack(alignment: .leading, spacing: 10) {
                Text("SESIÓN RÁPIDA")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Color.white.opacity(0.45))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    ForEach(FocusPreset.defaults) { preset in
                        let active = hub.timerLabel == preset.label && hub.timerTotalSeconds == preset.minutes * 60
                        Button {
                            hub.startPreset(preset)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: preset.symbol)
                                    .font(.system(size: 10, weight: .semibold))
                                Text("\(preset.label) · \(preset.minutes)m")
                                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                    .lineLimit(1)
                            }
                            .foregroundStyle(active ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(active ? Color.white : Color.white.opacity(0.08))
                            )
                        }
                        .buttonStyle(NotchButtonStyle(hoverScale: 1.03))
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button { hub.toggleTimer() } label: {
                        Label(hub.isTimerRunning ? "Pausar" : "Iniciar", systemImage: hub.isTimerRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 7.5)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(NotchButtonStyle())

                    Button { hub.adjustTimer(byMinutes: 5) } label: {
                        Text("+5m")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7.5)
                            .background(Capsule().fill(Color.white.opacity(0.11)))
                    }
                    .buttonStyle(NotchButtonStyle())

                    Button { hub.resetTimer() } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.8))
                            .frame(width: 32, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.09)))
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.08))
                    .help("Reiniciar temporizador")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}
