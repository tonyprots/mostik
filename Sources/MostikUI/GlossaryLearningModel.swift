import Foundation
import SwiftUI
import MostikCore

/// Личный словарь: обучение на правках (L1), «Запомнить написание» (L2), импорт (L6).
/// Своя модель, чтобы правки не сталкивались в `AppModel`; намерения подставляет
/// `Mostik/GlossaryLearningController.swift`.
@MainActor
public final class GlossaryLearningModel: ObservableObject {
    /// Предложения, набравшие повторы, — ждут ответа; показываются в «Словаре».
    @Published public var suggestions: [GlossarySuggestion] = []
    /// Предложение в карточке над HUD прямо сейчас.
    @Published public var prompt: GlossarySuggestion? = nil
    /// Карточка после вставки: «Запомнить написание…» для этой диктовки.
    @Published public var spellingChipEntry: String? = nil
    /// Открыть форму «Запомнить написание» у этой диктовки во вкладке «Диктовка».
    @Published public var spellingEntryID: String? = nil
    /// Какие приложения для импорта нашлись на диске (по метаданным): "handy", "wispr".
    @Published public var detected: [String: Bool] = [:]
    /// Просмотр импорта: что нашлось и сколько нового.
    @Published public var importPreview: GlossaryImportPreview? = nil
    @Published public var importError: String? = nil
    @Published public var importBusy = false

    public init() {}

    // Намерения.
    public var onDecide: (_ suggestion: GlossarySuggestion, _ accept: Bool) -> Void = { _, _ in }
    /// `source`: "handy" | "wispr" | "csv" | "lines"; для "csv" без пути controller откроет NSOpenPanel,
    /// для "lines" текст берётся из буфера.
    public var onImport: (_ source: String) -> Void = { _ in }
    public var onApplyImport: () -> Void = {}
    public var onCancelImport: () -> Void = {}
    /// Явное «Запомнить написание» (L2) у диктовки: как распознано → как пишется. Слово идёт в словарь
    /// на языке диктовки, текст записи правится, отметка сомнения про это слово снимается (C3).
    public var onRememberSpelling: (_ entryID: String, _ heard: String, _ canonical: String) -> Void = { _, _, _ in }
    /// Кнопка в карточке после вставки: открыть форму у этой диктовки.
    public var onOpenSpelling: (_ entryID: String) -> Void = { _ in }
    public var onDismissPrompt: () -> Void = {}
}
