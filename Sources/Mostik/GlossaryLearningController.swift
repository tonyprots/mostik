import AppKit
import Foundation
import SwiftUI
import MostikCore
import MostikKit
import MostikUI

/// Личный словарь вокруг вставки: обучение на правках (L1), «Запомнить написание» (L2), импорт (L6).
///
/// L1: после вставки 60 секунд перечитываем поле, куда вставили, раз в 2 секунды — только когда
/// впереди то же приложение, только тот же элемент и никогда у паролей (`FocusedField` — только
/// чтение). По итогу `EditWatch` (MostikCore) вырезает правку вставки, движок прогоняет её через
/// фильтры и копит повторы; готовое предложение показывается карточкой с «Запомнить / Нет».
/// Без ответа предложение остаётся в «Словаре». Молча в словарь ничего не попадает.
@MainActor
final class GlossaryLearningController {
    private let model: AppModel
    private let engine: () -> EngineClient
    private var learning: GlossaryLearningModel { model.glossaryLearning }

    private struct Watch {
        let record: InsertionRecord
        let started: Date
        var last: String?
    }
    private var watch: Watch?
    private var timer: Timer?
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// Предложения, уже показанные карточкой в этом запуске: второй раз не всплывают.
    private var shown: Set<String> = []

    init(model: AppModel, engine: @escaping () -> EngineClient) {
        self.model = model
        self.engine = engine
        let learning = model.glossaryLearning
        learning.onDecide = { [weak self] suggestion, accept in self?.decide(suggestion, accept: accept) }
        learning.onImport = { [weak self] source in self?.startImport(source) }
        learning.onApplyImport = { [weak self] in self?.applyImport() }
        learning.onCancelImport = { [weak self] in
            self?.learning.importPreview = nil
            self?.learning.importError = nil
        }
        // C3: раньше здесь пополнялся только словарь, а запись с отметкой сомнения оставалась как была.
        learning.onRememberSpelling = { [weak self] entryID, heard, canonical in
            self?.rememberSpelling(entryID: entryID, heard: heard, canonical: canonical)
        }
        learning.onOpenSpelling = { [weak self] entryID in self?.openSpelling(entryID) }
        learning.onDismissPrompt = { [weak self] in self?.hidePrompt() }
    }

    /// После рукопожатия с движком: предложения, ждущие ответа, и что есть для импорта.
    func engineReady() async {
        if let suggestions = try? await engine().learnSuggestions() { learning.suggestions = suggestions }
        if let detected = try? await engine().glossaryImportDetect() { learning.detected = detected }
    }

    // MARK: L1 — слежение за полем

    /// Вставка дошла: следим за полем. Прошлое слежение досчитывается сразу.
    func inserted(_ record: InsertionRecord) {
        finishWatch()
        scheduleChip(for: record.entryID)
        guard model.settings.learnFromEdits, record.check != .notInserted, record.after != nil else { return }
        watch = Watch(record: record, started: Date(), last: record.after?.value)
        timer = Timer.scheduledTimer(withTimeInterval: EditWatch.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard var current = watch else { stopTimer(); return }
        if Date().timeIntervalSince(current.started) >= EditWatch.duration {
            finishWatch()
            return
        }
        // AX читаем, только когда впереди то же приложение: чужие окна не трогаем.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == current.record.bundleID else { return }
        let snapshot = FocusedField.snapshot()
        guard EditWatch.sameField(snapshot, as: current.record), let value = snapshot?.value else { return }
        current.last = value
        watch = current
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func finishWatch() {
        stopTimer()
        guard let current = watch else { return }
        watch = nil
        guard let after = current.record.after, let final = current.last, final != after.value else { return }
        let inserted = current.record.insertedText
        guard let range = EditWatch.locate(inserted, in: after.value, near: current.record.before?.selection.location),
              let edit = EditWatch.edit(after: after.value, final: final, inserted: range) else { return }
        let language = model.history.first(where: { $0.id == current.record.entryID })?.language ?? model.settings.language
        Task { [weak self] in
            guard let self, let suggestions = try? await self.engine().learnEdit(
                inserted: edit.before, edited: edit.after, language: language) else { return }
            self.update(suggestions)
        }
    }

    private func update(_ suggestions: [GlossarySuggestion]) {
        learning.suggestions = suggestions
        guard let fresh = suggestions.first(where: { !shown.contains($0.id) }) else { return }
        shown.insert(fresh.id)
        showPrompt(fresh)
    }

    private func decide(_ suggestion: GlossarySuggestion, accept: Bool) {
        if learning.prompt == suggestion { hidePrompt() }
        learning.suggestions.removeAll { $0 == suggestion }
        Task { [weak self] in
            guard let self else { return }
            if let rest = try? await self.engine().learnDecide(suggestion, accept: accept) { self.learning.suggestions = rest }
            if accept { await self.reloadGlossary() }
        }
    }

    // MARK: L2 — «Запомнить написание»

    /// Карточка после вставки — только если в диктовке были сомнения или правки словаря:
    /// тогда есть что запоминать, а на каждой вставке кнопка была бы шумом.
    private func scheduleChip(for entryID: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, self.learning.prompt == nil,
                  let entry = self.model.history.first(where: { $0.id == entryID }),
                  !entry.doubts.isEmpty || !entry.corrections.isEmpty else { return }
            self.learning.spellingChipEntry = entryID
            self.presentPanel(hideAfter: 5)
        }
    }

    private func openSpelling(_ entryID: String) {
        hidePrompt()
        model.selectedTab = .dictation
        learning.spellingEntryID = entryID
        model.onOpenMainWindow()
    }

    /// Словарь, текст записи и отметки сомнений — одним действием (`AppModel.onAcceptDoubt`).
    private func rememberSpelling(entryID: String, heard: String, canonical: String) {
        guard !canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.onAcceptDoubt(entryID, heard, canonical)
    }

    private func reloadGlossary() async {
        guard let items = try? await engine().glossaryList() else { return }
        model.glossary = items.map { AppModel.GlossaryItem(canonical: $0.canonical, aliases: $0.aliases, source: $0.source) }
    }

    // MARK: L6 — импорт

    private func startImport(_ source: String) {
        var path: String?
        var text: String?
        switch source {
        case "csv":
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.commaSeparatedText, .plainText]
            panel.allowsMultipleSelection = false
            panel.prompt = L10n.isRussian ? "Импортировать" : "Import"
            MenuBarPanel.activateApp()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            path = url.path
        case "lines":
            text = NSPasteboard.general.string(forType: .string) ?? ""
            if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                learning.importError = L10n.isRussian ? "В буфере нет текста" : "Clipboard has no text"
                return
            }
        default:
            break
        }
        learning.importBusy = true
        learning.importError = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.learning.importBusy = false }
            do {
                self.learning.importPreview = try await self.engine().glossaryImport(source: source, path: path, text: text,
                                                                                    apply: false)
            } catch {
                self.learning.importPreview = nil
                self.learning.importError = error.localizedDescription
            }
        }
    }

    private func applyImport() {
        guard let preview = learning.importPreview, preview.newCount > 0 else { learning.importPreview = nil; return }
        learning.importBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.learning.importBusy = false }
            do {
                _ = try await self.engine().glossaryImport(source: preview.source, path: preview.path, text: preview.text,
                                                           apply: true)
                self.learning.importPreview = nil
                await self.reloadGlossary()
            } catch {
                self.learning.importError = error.localizedDescription
            }
        }
    }

    // MARK: карточка над HUD

    private func showPrompt(_ suggestion: GlossarySuggestion) {
        learning.spellingChipEntry = nil
        learning.prompt = suggestion
        presentPanel(hideAfter: 15)
    }

    private func hidePrompt() {
        hideTask?.cancel()
        learning.prompt = nil
        learning.spellingChipEntry = nil
        panel?.orderOut(nil)
    }

    private func presentPanel(hideAfter seconds: Double) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hidePrompt()
        }
    }

    private func makePanel() -> NSPanel {
        let size = LearnPromptCard.size
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: LearnPromptCard(learning: learning).tint(Palette.accent))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        return panel
    }

    /// Над пилюлей диктовки, снизу по центру экрана с курсором.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = LearnPromptCard.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 40 + 76 + 8))
    }
}
