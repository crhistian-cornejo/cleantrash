import AppKit
import ApplicationServices
import CleanTrashCore
import Foundation
import LocalAuthentication
import Observation
import SwiftUI

enum VaultAutoFillMode {
    case usernameAndPassword
    case usernameOnly
    case passwordOnly
}

/// Shared Touch ID–protected Password Vault controller used by BOTH the Main Dashboard (`VaultView`)
/// and the Dynamic Notch (Quick Search + Context-Aware AutoFill into Chrome, Safari, Arc, Brave, and macOS apps).
/// - Encrypts at rest using `VaultCryptoStore` (`CTV2`: HKDF-SHA256 + per-save salt + AES-GCM-256 + AAD + Keychain key)
/// - Automatically locks & clears decrypted secrets from RAM on screen lock, Mac sleep, or 5 minutes of inactivity
/// - Detects frontmost browser URL / active app so matching credentials appear first in the Notch
@MainActor
@Observable
final class VaultController {
    private(set) var isUnlocked = false
    private(set) var items: [VaultItem] = []
    var authError: String?
    private(set) var copiedItemID: UUID?
    private(set) var copiedLabel: String?

    // Context-aware browser/app matching
    private(set) var activeHost: String?
    private(set) var activeAppName: String?
    private(set) var lastExternalApp: NSRunningApplication?

    var onStatusMessage: ((String, BannerTone) -> Void)?

    @ObservationIgnored private let vaultURL: URL
    @ObservationIgnored private var idleLockTask: Task<Void, Never>?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    @ObservationIgnored private var screenLockObserver: NSObjectProtocol?
    @ObservationIgnored private var appActivateObserver: NSObjectProtocol?

    var audit: VaultAuditReport {
        VaultHygieneAuditor.audit(items)
    }

    var hasAccessibilityForAutoFill: Bool {
        AXIsProcessTrusted()
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.vaultURL = support.appendingPathComponent("CleanTrash/vault.ctvault")
        installSecurityObservers()
    }

    // MARK: - Touch ID Unlock & Automatic Memory-Zeroing Lock

    func authenticateAndUnlock(reason: String = "Desbloquear tu Bóveda cifrada de CleanTrash") {
        authError = nil
        let ctx = LAContext()
        var err: NSError?
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication

        ctx.evaluatePolicy(policy, localizedReason: reason) { [weak self] success, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    do {
                        self.items = try VaultCryptoStore.load(from: self.vaultURL)
                        withAnimation(Mono.openingSpring) {
                            self.isUnlocked = true
                        }
                        self.bumpActivityTimer()
                        self.refreshFrontmostContext()
                        AppKitHaptics.confirm()
                    } catch {
                        self.authError = "No se pudo descifrar la bóveda: \(error.localizedDescription)"
                    }
                } else {
                    self.authError = error?.localizedDescription ?? "Autenticación cancelada"
                }
            }
        }
    }

    func lock() {
        idleLockTask?.cancel()
        idleLockTask = nil
        withAnimation(Mono.betweenSpring) {
            isUnlocked = false
            items = [] // Purge decrypted secrets from memory immediately
        }
    }

    func bumpActivityTimer() {
        guard isUnlocked else { return }
        idleLockTask?.cancel()
        idleLockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5 * 60)) // 5 min auto-lock
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    // MARK: - CRUD, Import, Clean & Encrypted Backup

    func save() {
        bumpActivityTimer()
        do {
            try VaultCryptoStore.save(items, to: vaultURL)
        } catch {
            onStatusMessage?("Error al guardar bóveda cifrada: \(error.localizedDescription)", .error)
        }
    }

    func upsert(_ item: VaultItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
        } else {
            items.insert(item, at: 0)
        }
        save()
    }

    func delete(_ item: VaultItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func importCSV(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            let imported = VaultCSVCodec.importCSV(raw)
            guard !imported.isEmpty else {
                onStatusMessage?("No se encontraron contraseñas válidas en \(url.lastPathComponent).", .warning)
                return
            }
            items.append(contentsOf: imported)
            save()
            AppKitHaptics.confirm()
            onStatusMessage?("Importadas \(imported.count) cuentas desde \(url.lastPathComponent). Pulsa «Limpiar y ordenar» para quitar duplicados.", .success)
        } catch {
            onStatusMessage?("Error leyendo CSV: \(error.localizedDescription)", .error)
        }
    }

    func cleanAndOrganize() {
        let result = VaultHygieneAuditor.cleanAndOrganize(items)
        withAnimation(Mono.betweenSpring) {
            items = result.items
        }
        save()
        AppKitHaptics.confirm()
        onStatusMessage?("Bóveda limpia · \(result.removedDuplicates) duplicados eliminados · \(result.recategorizedCount) cuentas ordenadas.", .success)
    }

    func exportApplePasswordsCSV(to url: URL) {
        bumpActivityTimer()
        let csv = VaultCSVCodec.exportApplePasswordsCSV(items)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            onStatusMessage?("Exportado \(url.lastPathComponent). Ábrelo en Apple Contraseñas → Archivo → Importar contraseñas para sincronizar con tu iPhone y Safari.", .success)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            onStatusMessage?("No se pudo exportar CSV: \(error.localizedDescription)", .error)
        }
    }

    func exportEncryptedBackup(to url: URL, passphrase: String) {
        bumpActivityTimer()
        do {
            let blob = try VaultCryptoStore.encryptBackup(items, passphrase: passphrase)
            try blob.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            AppKitHaptics.confirm()
            onStatusMessage?("Respaldo cifrado guardado en \(url.lastPathComponent) (AES-256 + 120k rondas).", .success)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            onStatusMessage?("Error creando respaldo cifrado: \(error.localizedDescription)", .error)
        }
    }

    // MARK: - Context-Aware Search & Browser/App AutoFill (Chrome · Safari · Arc · Brave · macOS Apps)

    func refreshFrontmostContext() {
        let app = lastExternalApp ?? NSWorkspace.shared.frontmostApplication
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        activeAppName = app.localizedName
        let bundleID = app.bundleIdentifier ?? ""

        Task.detached(priority: .userInitiated) {
            let host = Self.readActiveBrowserHost(bundleID: bundleID)
            await MainActor.run { [weak self] in
                self?.activeHost = host
            }
        }
    }

    /// Returns items sorted with matching sites for the active Chrome/Safari/Arc tab at the very top!
    func searchItems(query: String) -> [VaultItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty {
            return items.filter { item in
                item.title.lowercased().contains(trimmed)
                    || item.username.lowercased().contains(trimmed)
                    || item.normalizedDomain.contains(trimmed)
                    || item.folder.lowercased().contains(trimmed)
            }
        }

        // Prioritize context matches for the active browser URL / app
        let scored = items.map { item -> (VaultItem, Int) in
            (item, VaultHygieneAuditor.matchScore(item: item, activeHost: activeHost, activeAppName: activeAppName))
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
        }.map(\.0)
    }

    var contextMatches: [VaultItem] {
        items.filter {
            VaultHygieneAuditor.matchScore(item: $0, activeHost: activeHost, activeAppName: activeAppName) >= 45
        }
    }

    /// Securely copies username or password with `ConcealedType + TransientType` so Clipboard History ignores it,
    /// and wipes the pasteboard automatically after 25 seconds.
    func copySecurely(_ value: String, itemID: UUID, label: String) {
        bumpActivityTimer()
        let pb = NSPasteboard.general
        pb.clearContents()
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let autoGen = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        pb.declareTypes([.string, concealed, transient, autoGen], owner: nil)
        pb.setString(value, forType: .string)
        pb.setData(Data(), forType: concealed)
        pb.setData(Data(), forType: transient)
        pb.setData(Data(), forType: autoGen)

        let expectedCount = pb.changeCount
        AppKitHaptics.confirm()
        withAnimation(Mono.fast) {
            copiedItemID = itemID
            copiedLabel = label
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.copiedItemID == itemID {
                withAnimation(Mono.fast) {
                    self?.copiedItemID = nil
                    self?.copiedLabel = nil
                }
            }
            try? await Task.sleep(for: .seconds(23))
            if NSPasteboard.general.changeCount == expectedCount {
                NSPasteboard.general.clearContents()
            }
        }
    }

    /// Auto-types credentials directly into the active browser (Chrome, Safari, Arc, Brave) or macOS app!
    /// Falls back gracefully to secure copy + Accessibility settings guidance if Accessibility is not yet granted.
    func autoFill(_ item: VaultItem, mode: VaultAutoFillMode = .usernameAndPassword, collapseNotch: () -> Void) {
        bumpActivityTimer()
        guard AXIsProcessTrusted() else {
            // Request Accessibility prompt & copy password securely so the user can still paste immediately (⌘V)
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            copySecurely(mode == .usernameOnly ? item.username : item.password, itemID: item.id, label: "Copiada (⌘V)")
            onStatusMessage?("Activa Accesibilidad para CleanTrash si quieres autocompletado automático en Chrome/Safari; ya copié tu clave (pulsa ⌘V).", .warning)
            return
        }

        let targetApp = lastExternalApp
        collapseNotch()

        let user = item.username
        let pass = item.password
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            targetApp?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                switch mode {
                case .usernameAndPassword:
                    if !user.isEmpty {
                        Self.typeUnicodeString(user)
                        Self.pressKey(virtualKey: 48) // Tab
                        usleep(60_000)
                    }
                    Self.typeUnicodeString(pass)
                case .usernameOnly:
                    Self.typeUnicodeString(user)
                case .passwordOnly:
                    Self.typeUnicodeString(pass)
                }
            }
        }
        AppKitHaptics.confirm()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private Security & Browser Helpers

    private func installSecurityObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        sleepObserver = ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.lock() }
        }
        appActivateObserver = ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self.lastExternalApp = app
                self.activeAppName = app.localizedName
            }
        }
        screenLockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.lock() }
        }
    }

    private nonisolated static func readActiveBrowserHost(bundleID: String) -> String? {
        let script: String?
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            script = "tell application \"Safari\" to if (count of windows) > 0 then return URL of current tab of front window"
        case "com.google.Chrome", "com.google.Chrome.canary":
            script = "tell application \"Google Chrome\" to if (count of windows) > 0 then return URL of active tab of front window"
        case "company.thebrowser.Browser":
            script = "tell application \"Arc\" to if (count of windows) > 0 then return URL of active tab of front window"
        case "com.brave.Browser":
            script = "tell application \"Brave Browser\" to if (count of windows) > 0 then return URL of active tab of front window"
        case "com.microsoft.edgemac":
            script = "tell application \"Microsoft Edge\" to if (count of windows) > 0 then return URL of active tab of front window"
        default:
            script = nil
        }
        guard let script else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let host = URL(string: raw)?.host else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private nonisolated static func typeUnicodeString(_ string: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for scalar in string.utf16 {
            var codeUnit = scalar
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(6_000)
        }
    }

    private nonisolated static func pressKey(virtualKey: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
