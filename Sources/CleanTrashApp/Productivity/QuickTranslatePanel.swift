import AppKit
import CleanTrashCore
import Foundation
import Observation
import SwiftUI
import Translation

private struct UncheckedTranslationSession: @unchecked Sendable {
    let session: TranslationSession
}

struct TranslationLanguageOption: Identifiable, Hashable, Sendable {
    let code: String
    let label: String

    var id: String { code }
    var localeLanguage: Locale.Language { Locale.Language(identifier: code) }

    static let supported: [TranslationLanguageOption] = [
        .init(code: "es", label: "Español"),
        .init(code: "en", label: "Inglés"),
        .init(code: "fr", label: "Francés"),
        .init(code: "de", label: "Alemán"),
        .init(code: "pt", label: "Portugués"),
        .init(code: "it", label: "Italiano"),
        .init(code: "ja", label: "Japonés")
    ]
}

@MainActor
@Observable
final class QuickTranslateState {
    var sourceLanguage: TranslationLanguageOption = TranslationLanguageOption.supported[0] // Español
    var targetLanguage: TranslationLanguageOption = TranslationLanguageOption.supported[1] // Inglés
    var sourceText: String = ""
    var translatedText: String = ""
    var isTranslating: Bool = false
    var errorMessage: String?
    var copiedFeedback: Bool = false
    var translateNonce: Int = 0

    func swapLanguages() {
        let oldSource = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = oldSource
        if !translatedText.isEmpty {
            sourceText = translatedText
            translatedText = ""
            triggerTranslation()
        }
        AppKitHaptics.tap()
    }

    func loadFromClipboardAndTranslate() {
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clip.isEmpty {
            sourceText = String(clip.prefix(1500))
            triggerTranslation()
        }
    }

    func triggerTranslation() {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            translatedText = ""
            errorMessage = nil
            return
        }
        errorMessage = nil
        isTranslating = true
        translateNonce += 1
    }

    func copyTranslated() {
        let out = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(out, forType: .string)
        AppKitHaptics.confirm()
        withAnimation(Mono.fast) { copiedFeedback = true }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(Mono.fast) { self?.copiedFeedback = false }
        }
    }

    /// Copies the translation and attempts to paste (⌘V) into the previously active app if Accessibility is allowed.
    func copyAndReplace(closePanel: () -> Void) {
        copyTranslated()
        closePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            let src = CGEventSource(stateID: .hidSystemState)
            let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) // 'v'
            vDown?.flags = .maskCommand
            let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            vUp?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
        }
    }
}

/// Droppy-inspired On-Device Quick Translate floating Dynamic Glass pill (`En este Mac`):
/// Translates selected/clipboard text right beside the app you are using via Apple's native
/// macOS 15+ `Translation` framework, then Copy (`⌘C`) or Replace (`⏎`).
@MainActor
final class QuickTranslateWindowController {
    let state = QuickTranslateState()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(surface: NotchSurfaceMode, seedFromClipboard: Bool = true) {
        if let existing = panel, existing.isVisible {
            existing.orderOut(nil)
            return
        }
        show(surface: surface, seedFromClipboard: seedFromClipboard)
    }

    func show(surface: NotchSurfaceMode, seedFromClipboard: Bool = true) {
        if seedFromClipboard {
            state.loadFromClipboardAndTranslate()
        }

        if let existing = panel {
            positionNearMouseOrTopCenter(existing)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 456, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = QuickTranslatePillView(state: state, surface: surface) { [weak p] in
            p?.orderOut(nil)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = hosting
        positionNearMouseOrTopCenter(p)
        p.makeKeyAndOrderFront(nil)
        self.panel = p
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func positionNearMouseOrTopCenter(_ window: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let w = window.frame.width
        let h = window.frame.height
        let x = min(vf.maxX - w - 16, max(vf.minX + 16, mouse.x - w / 2))
        let y = min(vf.maxY - h - 16, max(vf.minY + 16, mouse.y - h - 18))
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct QuickTranslatePillView: View {
    @Bindable var state: QuickTranslateState
    let surface: NotchSurfaceMode
    let onClose: () -> Void

    @State private var translationConfig: TranslationSession.Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top bar: Language pair + "En este Mac" badge + Close
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "translate")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Mono.gpuAccent)

                    Menu {
                        ForEach(TranslationLanguageOption.supported) { opt in
                            Button(opt.label) {
                                state.sourceLanguage = opt
                                state.triggerTranslation()
                            }
                        }
                    } label: {
                        Text(state.sourceLanguage.label)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Button {
                        state.swapLanguages()
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Invertir idiomas")

                    Menu {
                        ForEach(TranslationLanguageOption.supported) { opt in
                            Button(opt.label) {
                                state.targetLanguage = opt
                                state.triggerTranslation()
                            }
                        }
                    } label: {
                        Text(state.targetLanguage.label)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Text("En este Mac")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.11)))

                Spacer(minLength: 4)

                Button {
                    state.loadFromClipboardAndTranslate()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Pegar y traducir del portapapeles")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            // Input field (compact)
            TextField("Escribe o pega texto para traducir…", text: $state.sourceText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                .onSubmit { state.triggerTranslation() }

            // Translated output area
            Group {
                if state.isTranslating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Traduciendo en este Mac…")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                } else if let err = state.errorMessage {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.caution)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                } else if !state.translatedText.isEmpty {
                    Text(state.translatedText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                } else {
                    Text("Copia cualquier texto y pulsa ⌥⇧T o escribe arriba para traducir al instante.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }

            // Bottom action row: Copy ⌘C · Replace ⏎
            HStack(spacing: 8) {
                Spacer()

                Button {
                    state.copyTranslated()
                } label: {
                    HStack(spacing: 5) {
                        Text(state.copiedFeedback ? "Copiado ✓" : "Copiar")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("⌘C")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("c", modifiers: .command)
                .disabled(state.translatedText.isEmpty)
                .pointingHandCursor()

                Button {
                    state.copyAndReplace(closePanel: onClose)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "text.insert")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("Reemplazar")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("⏎")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(hex: 0x2563EB).opacity(0.88)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(state.translatedText.isEmpty)
                .pointingHandCursor()
            }
        }
        .padding(16)
        .frame(width: 420)
        .floatingDockGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), surface: surface)
        .padding(18)
        .environment(\.colorScheme, .dark)
        .environment(\.notchSurface, surface)
        .onChange(of: state.translateNonce) { _, _ in
            scheduleTranslation()
        }
        .onAppear {
            if !state.sourceText.isEmpty && state.translatedText.isEmpty {
                scheduleTranslation()
            }
        }
        .translationTask(translationConfig) { session in
            let input = state.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else {
                state.isTranslating = false
                return
            }
            let box = UncheckedTranslationSession(session: session)
            do {
                let targetText = try await Self.runTranslation(box, input: input)
                state.translatedText = targetText
                state.errorMessage = nil
                state.isTranslating = false
            } catch {
                state.errorMessage = "Descarga el paquete de idioma \(state.sourceLanguage.label) ↔ \(state.targetLanguage.label) en Ajustes de macOS → General → Idioma y región → Traducción."
                state.isTranslating = false
            }
        }
    }

    private nonisolated static func runTranslation(_ box: UncheckedTranslationSession, input: String) async throws -> String {
        try await box.session.prepareTranslation()
        let response = try await box.session.translate(input)
        return response.targetText
    }

    private func scheduleTranslation() {
        let src = state.sourceLanguage.localeLanguage
        let dst = state.targetLanguage.localeLanguage
        if translationConfig?.source == src && translationConfig?.target == dst {
            translationConfig?.invalidate()
        } else {
            translationConfig = TranslationSession.Configuration(source: src, target: dst)
        }
    }
}
