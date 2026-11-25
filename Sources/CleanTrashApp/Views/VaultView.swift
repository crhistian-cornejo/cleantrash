import AppKit
import CleanTrashCore
import SwiftUI
import UniformTypeIdentifiers

/// Local CryptoKit AES-GCM 256-bit (`CTV2` + HKDF-SHA256 + AAD) Password Vault protected by Touch ID:
/// - Shares live unlocked state with the Dynamic Notch (`appState.vault` / `⌥⇧P` AutoFill)
/// - Import NordPass CSV (or Chrome/Apple Passwords CSV) via picker or drag & drop
/// - Audit duplicates, weak passwords, and reused credentials
/// - 1-click deduplicate, normalize URLs/titles & auto-organize folders
/// - Export directly to Apple Passwords CSV (iPhone Face ID AutoFill) or encrypted `.ctvault` backup (`CTB1`)
struct VaultView: View {
    @Bindable var appState: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var selectedFolder: String = "Todas"
    @State private var searchText: String = ""
    @State private var filterIssueOnly: String? = nil // "dups" | "weak" | "reused"
    @State private var revealedIDs: Set<UUID> = []
    @State private var showAddSheet = false
    @State private var editingItem: VaultItem?
    @State private var showIPhoneGuide = false
    @State private var showBackupSheet = false

    private var vault: VaultController { appState.vault }
    private var items: [VaultItem] { vault.items }
    private var audit: VaultAuditReport { vault.audit }

    private var folders: [String] {
        let set = Set(items.map(\.folder))
        return ["Todas"] + set.sorted()
    }

    private var filteredItems: [VaultItem] {
        items.filter { item in
            if selectedFolder != "Todas" && item.folder != selectedFolder { return false }
            if let issue = filterIssueOnly {
                switch issue {
                case "dups": if !audit.exactDuplicateIDs.contains(item.id) { return false }
                case "weak": if !audit.weakPasswordIDs.contains(item.id) { return false }
                case "reused": if !audit.reusedPasswordIDs.contains(item.id) { return false }
                default: break
                }
            }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                return item.title.lowercased().contains(q)
                    || item.username.lowercased().contains(q)
                    || item.url.lowercased().contains(q)
                    || item.folder.lowercased().contains(q)
            }
            return true
        }
    }

    var body: some View {
        Group {
            if vault.isUnlocked {
                unlockedBody
            } else {
                lockScreen
            }
        }
        .sheet(isPresented: $showAddSheet) {
            VaultItemEditorSheet(existing: nil) { newItem in
                vault.upsert(newItem)
            }
        }
        .sheet(item: $editingItem) { item in
            VaultItemEditorSheet(existing: item) { updated in
                vault.upsert(updated)
            }
        }
        .sheet(isPresented: $showBackupSheet) {
            VaultEncryptedBackupSheet { passphrase in
                exportEncryptedBackup(passphrase: passphrase)
            }
        }
    }

    // MARK: - Touch ID Lock Screen

    private var lockScreen: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Mono.ramAccent.opacity(scheme == .dark ? 0.22 : 0.14))
                    .frame(width: 146, height: 146)
                    .blur(radius: 36)
                Icon3D(name: .vault, size: 108, isActive: false)
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("Bóveda CleanTrash")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Mono.ink(scheme))
                    MonoTag(text: "CTV2 · HKDF · AES-256", tint: Mono.ramAccent)
                }
                Text("Cifrada localmente con llave derivada por guardado, AAD anti-manipulación y llave maestra en el Llavero.")
                    .font(.system(size: 13))
                    .foregroundStyle(Mono.muted(scheme))
                Text("Bloqueo automático al suspender o bloquear tu Mac · Accede desde el Notch con ⌥⇧P para Chrome, Safari y Apps.")
                    .font(.system(size: 12))
                    .foregroundStyle(Mono.subtle(scheme))
            }

            if let authError = vault.authError {
                Text(authError)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Mono.caution)
            }

            Button {
                vault.authenticateAndUnlock()
            } label: {
                Label("Desbloquear con Touch ID", systemImage: "touchid")
            }
            .buttonStyle(MonoPrimaryButtonStyle())

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Unlocked Vault Workspace

    private var unlockedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                Icon3D(name: .vault, size: 52, isActive: true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Bóveda")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(Mono.ink(scheme))
                            .lineLimit(1)
                            .fixedSize()
                        MonoTag(text: "CTV2 · AES-256 · HKDF", tint: Mono.ramAccent)
                    }
                    Text("Auto-bloqueo en 5 min · Portapapeles sin rastro (25s) · Acceso rápido en el Notch con ⌥⇧P.")
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.muted(scheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Button {
                    importNordPassCSV()
                } label: {
                    Label("Importar", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(MonoGhostButtonStyle())
                .help("Importar archivo CSV de NordPass, Chrome o Apple Passwords")

                Button {
                    showBackupSheet = true
                } label: {
                    Label("Respaldo", systemImage: "lock.doc")
                }
                .buttonStyle(MonoGhostButtonStyle())
                .disabled(items.isEmpty)
                .help("Exportar respaldo cifrado .ctvault con frase secreta (120k rondas)")

                Button {
                    exportForIPhone()
                } label: {
                    Label("iPhone", systemImage: "iphone.and.arrow.forward")
                }
                .buttonStyle(MonoGhostButtonStyle())
                .disabled(items.isEmpty)
                .help("Exportar CSV limpio para Apple Contraseñas y iCloud Keychain en iPhone")

                Button {
                    showAddSheet = true
                } label: {
                    Label("Nueva", systemImage: "plus")
                }
                .buttonStyle(MonoPrimaryButtonStyle())

                Button {
                    revealedIDs.removeAll()
                    vault.lock()
                    AppKitHaptics.tap()
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Mono.muted(scheme))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Mono.ink(scheme).opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Bloquear Bóveda y limpiar memoria")
            }

            // Audit & Hygiene Strip + 1-click Clean & Organize
            HStack(spacing: 12) {
                auditCard(
                    title: "Salud",
                    value: "\(audit.score)/100",
                    tint: audit.score >= 80 ? Mono.ramAccent : (audit.score >= 55 ? Mono.caution : Mono.danger),
                    active: filterIssueOnly == nil
                ) { filterIssueOnly = nil }

                auditCard(
                    title: "Duplicadas",
                    value: "\(audit.exactDuplicateIDs.count)",
                    tint: audit.exactDuplicateIDs.isEmpty ? Mono.ramAccent : Mono.junkAccent,
                    active: filterIssueOnly == "dups"
                ) { filterIssueOnly = (filterIssueOnly == "dups" ? nil : "dups") }

                auditCard(
                    title: "Reutilizadas",
                    value: "\(audit.reusedPasswordIDs.count)",
                    tint: audit.reusedPasswordIDs.isEmpty ? Mono.ramAccent : Mono.cpuAccent,
                    active: filterIssueOnly == "reused"
                ) { filterIssueOnly = (filterIssueOnly == "reused" ? nil : "reused") }

                auditCard(
                    title: "Débiles",
                    value: "\(audit.weakPasswordIDs.count)",
                    tint: audit.weakPasswordIDs.isEmpty ? Mono.ramAccent : Mono.danger,
                    active: filterIssueOnly == "weak"
                ) { filterIssueOnly = (filterIssueOnly == "weak" ? nil : "weak") }

                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        vault.cleanAndOrganize()
                    } label: {
                        Label("Limpiar y ordenar", systemImage: "sparkles")
                    }
                    .buttonStyle(MonoPrimaryButtonStyle())
                    .disabled(items.isEmpty)

                    Button {
                        withAnimation(Mono.betweenSpring) { showIPhoneGuide.toggle() }
                    } label: {
                        Text(showIPhoneGuide ? "Ocultar guía AutoFill / iPhone" : "AutoFill Chrome/Safari y iPhone")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Mono.gpuAccent)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                .padding(.leading, 4)
            }

            // Collapsible AutoFill (Chrome/Safari/Apps) & iPhone Migration Guide
            if showIPhoneGuide {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Autocompletado desde el Notch (Chrome · Safari · Arc · Brave · Apps)")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Mono.ink(scheme))
                        MonoTag(
                            text: vault.hasAccessibilityForAutoFill ? "ACCESIBILIDAD ACTIVA" : "PERMISO PENDIENTE",
                            tint: vault.hasAccessibilityForAutoFill ? Mono.ramAccent : Mono.caution
                        )
                        Spacer()
                        Button("Abrir Bóveda en Notch (⌥⇧P)") {
                            appState.onOpenNotchVault?()
                        }
                        .buttonStyle(MonoGhostButtonStyle())
                    }

                    Text("• Pulsa ⌥⇧P en cualquier navegador o app: el Notch detecta automáticamente el sitio abierto en Chrome/Safari/Arc y pone tus cuentas arriba con botón «Rellenar» (escribe Usuario + Tab + Contraseña).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mono.muted(scheme))
                    Text("• Para sincronizar con tu iPhone (AutoFill con Face ID): pulsa «iPhone» arriba → abre Contraseñas de Apple → Archivo → Importar contraseñas → ¡listo en iCloud Keychain!")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mono.muted(scheme))
                    Text("• Seguridad CTV2: cada guardado genera una sal criptográfica nueva + subllave HKDF-SHA256 + etiqueta AAD anti-manipulación + permisos 0600 + limpieza automática de memoria al bloquear o suspender el Mac.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mono.subtle(scheme))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .monoCard(radius: 14, glass: true)
            }

            // Folder filter pills + search
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(folders, id: \.self) { folder in
                            let selected = selectedFolder == folder
                            Button(folder) {
                                withAnimation(Mono.betweenSpring) { selectedFolder = folder }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? Mono.primaryInk(scheme) : Mono.muted(scheme))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(selected ? Mono.primaryFill(scheme) : Mono.ink(scheme).opacity(0.08)))
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                    }
                }

                TextField("Buscar cuenta, usuario o sitio…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(width: 230)
                    .background(Capsule().fill(Mono.card(scheme)))
                    .overlay(Capsule().strokeBorder(Mono.hairline(scheme), lineWidth: 0.9))
            }

            // Items List
            if filteredItems.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Icon3D(name: .vault, size: 52, isActive: false)
                    Text(items.isEmpty ? "Tu bóveda está vacía" : "Ninguna cuenta coincide con el filtro")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                    Text("Importa o arrastra tu archivo CSV de NordPass aquí, o agrega tu primera cuenta cifrada.")
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.muted(scheme))
                    if items.isEmpty {
                        Button("Importar NordPass (.csv)") { importNordPassCSV() }
                            .buttonStyle(MonoPrimaryButtonStyle())
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .monoCard(radius: 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(filteredItems) { item in
                            vaultRow(item)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(20)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var accepted = false
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
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
                    guard let url, url.pathExtension.lowercased() == "csv" else { return }
                    Task { @MainActor in
                        vault.importCSV(from: url)
                    }
                }
            }
            return accepted
        }
    }

    private func auditCard(title: String, value: String, tint: Color, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Mono.muted(scheme))
                Text(value)
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .monoCard(radius: 14, glass: active)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(active ? tint.opacity(0.6) : .clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func vaultRow(_ item: VaultItem) -> some View {
        let revealed = revealedIDs.contains(item.id)
        let isDup = audit.exactDuplicateIDs.contains(item.id)
        let isReused = audit.reusedPasswordIDs.contains(item.id)
        let strength = item.strength
        let strengthTint: Color = strength == .strong ? Mono.ramAccent : (strength == .fair ? Mono.caution : Mono.danger)
        let isCopied = vault.copiedItemID == item.id

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Mono.cpuAccent.opacity(0.16))
                    .frame(width: 34, height: 34)
                Text(String(item.title.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Mono.ink(scheme))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                        .lineLimit(1)
                    MonoTag(text: item.folder)
                    MonoTag(text: strength.label, tint: strengthTint)
                    if isDup { MonoTag(text: "DUPLICADA", tint: Mono.junkAccent) }
                    if isReused && !isDup { MonoTag(text: "REUTILIZADA", tint: Mono.cpuAccent) }
                }

                HStack(spacing: 8) {
                    Text(item.username.isEmpty ? item.normalizedDomain : item.username)
                        .font(.system(size: 11))
                        .foregroundStyle(Mono.muted(scheme))
                        .lineLimit(1)
                    if revealed {
                        Text("·  \(item.password)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Mono.ramAccent)
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 6)

            Button {
                vault.bumpActivityTimer()
                if revealed { revealedIDs.remove(item.id) } else { revealedIDs.insert(item.id) }
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(Mono.muted(scheme))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Mono.ink(scheme).opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(revealed ? "Ocultar" : "Mostrar contraseña")

            Button(isCopied ? (vault.copiedLabel ?? "Copiada ✓") : "Copiar") {
                vault.copySecurely(item.password, itemID: item.id, label: "Copiada ✓")
            }
            .buttonStyle(MonoGhostButtonStyle())

            Button {
                editingItem = item
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Mono.muted(scheme))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Mono.ink(scheme).opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            Button {
                vault.delete(item)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Mono.danger.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Mono.danger.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .monoCard(radius: 13)
    }

    // MARK: - Panels

    private func importNordPassCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Selecciona tu archivo CSV exportado desde NordPass (o Chrome / Apple Passwords)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vault.importCSV(from: url)
    }

    private func exportForIPhone() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CleanTrash-ApplePasswords.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Exporta tus contraseñas limpias para importarlas en Apple Passwords y sincronizarlas al iPhone por iCloud Keychain."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vault.exportApplePasswordsCSV(to: url)
    }

    private func exportEncryptedBackup(passphrase: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CleanTrash-Respaldo.ctvault"
        panel.allowedContentTypes = [.data]
        panel.message = "Guarda un respaldo cifrado (AES-256 + 120,000 rondas) que solo se abre con tu frase secreta."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vault.exportEncryptedBackup(to: url, passphrase: passphrase)
    }
}

private struct VaultEncryptedBackupSheet: View {
    let onExport: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var passphrase = ""
    @State private var confirm = ""

    private var canSave: Bool {
        passphrase.count >= 8 && passphrase == confirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Icon3D(name: .vault, size: 36, isActive: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Respaldo cifrado (.ctvault)")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Mono.ink(scheme))
                    Text("Cifrado CTB1 con AES-GCM-256 + 120,000 rondas SHA-256 + AAD.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mono.muted(scheme))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Frase secreta (mínimo 8 caracteres)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Mono.muted(scheme))
                SecureField("Frase maestra de respaldo", text: $passphrase)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Mono.ink(scheme).opacity(0.06)))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Confirmar frase secreta")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Mono.muted(scheme))
                SecureField("Repite tu frase secreta", text: $confirm)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Mono.ink(scheme).opacity(0.06)))
            }

            if !confirm.isEmpty && passphrase != confirm {
                Text("Las frases no coinciden.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Mono.caution)
            }

            HStack {
                Button("Cancelar") { dismiss() }
                    .buttonStyle(MonoGhostButtonStyle())
                Spacer()
                Button("Crear respaldo cifrado") {
                    let pass = passphrase
                    dismiss()
                    onExport(pass)
                }
                .buttonStyle(MonoPrimaryButtonStyle())
                .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Mono.canvas(scheme))
    }
}

private struct VaultItemEditorSheet: View {
    let existing: VaultItem?
    let onSave: (VaultItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var title: String
    @State private var url: String
    @State private var username: String
    @State private var password: String
    @State private var folder: String
    @State private var notes: String

    init(existing: VaultItem?, onSave: @escaping (VaultItem) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _title = State(initialValue: existing?.title ?? "")
        _url = State(initialValue: existing?.url ?? "")
        _username = State(initialValue: existing?.username ?? "")
        _password = State(initialValue: existing?.password ?? VaultHygieneAuditor.generateStrongPassword())
        _folder = State(initialValue: existing?.folder ?? "General")
        _notes = State(initialValue: existing?.notes ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Nueva cuenta cifrada" : "Editar cuenta")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Mono.ink(scheme))

            field("Nombre / Servicio", text: $title, placeholder: "GitHub, Stripe, Banco…")
            field("URL", text: $url, placeholder: "https://github.com")
            field("Usuario o correo", text: $username, placeholder: "tu@correo.com")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Contraseña")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Mono.muted(scheme))
                    Spacer()
                    Button("Generar fuerte (20 car.)") {
                        password = VaultHygieneAuditor.generateStrongPassword(length: 20)
                    }
                    .buttonStyle(MonoGhostButtonStyle())
                }
                TextField("Contraseña", text: $password)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Mono.ink(scheme).opacity(0.06)))
            }

            field("Carpeta", text: $folder, placeholder: "Desarrollo, Finanzas, Trabajo…")
            field("Notas", text: $notes, placeholder: "Opcional")

            HStack {
                Button("Cancelar") { dismiss() }
                    .buttonStyle(MonoGhostButtonStyle())
                Spacer()
                Button("Guardar cifrado") {
                    let cleanURL = VaultHygieneAuditor.normalizeURL(url)
                    let item = VaultItem(
                        id: existing?.id ?? UUID(),
                        title: title.isEmpty ? VaultHygieneAuditor.prettyTitle(fromDomain: VaultHygieneAuditor.normalizeDomain(from: cleanURL, fallbackTitle: username)) : title,
                        url: cleanURL,
                        username: username,
                        password: password,
                        notes: notes,
                        folder: folder.isEmpty ? "General" : folder,
                        otpAuth: existing?.otpAuth ?? "",
                        source: existing?.source ?? "CleanTrash",
                        createdAt: existing?.createdAt ?? .now,
                        updatedAt: .now
                    )
                    onSave(item)
                    dismiss()
                }
                .buttonStyle(MonoPrimaryButtonStyle())
                .disabled(password.isEmpty && username.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Mono.canvas(scheme))
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Mono.muted(scheme))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Mono.ink(scheme).opacity(0.06)))
        }
    }
}
