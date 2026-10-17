import SwiftUI
import MostikCore

// Личный словарь вокруг вставки: карточка над HUD (L1, L2), «Запомнить написание» у диктовки (L2),
// предложения из правок и импорт во вкладке «Словарь» (L1, L6).

// MARK: - Карточка над HUD

/// Над пилюлей диктовки: предложение из правок с «Запомнить / Нет» или «Запомнить написание…»
/// после вставки с сомнениями. Окно — `Mostik/GlossaryLearningController.swift`.
public struct LearnPromptCard: View {
    public static let size = CGSize(width: 440, height: 64)
    @ObservedObject var learning: GlossaryLearningModel

    public init(learning: GlossaryLearningModel) { self.learning = learning }

    public var body: some View {
        Group {
            if let prompt = learning.prompt {
                suggestion(prompt)
            } else if let entryID = learning.spellingChipEntry {
                spelling(entryID)
            } else {
                Color.clear
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func suggestion(_ s: GlossarySuggestion) -> some View {
        card {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Вы дважды поправили", "You corrected this twice"))
                    .font(TType.caption)
                    .foregroundStyle(Palette.inkSecondary)
                HStack(spacing: 6) {
                    Text(s.heard).font(TType.body).foregroundStyle(Palette.inkSecondary).strikethrough()
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.inkTertiary)
                    Text(s.canonical).font(TType.code.weight(.medium)).foregroundStyle(Palette.ink)
                }
                .lineLimit(1)
            }
            Spacer(minLength: DS.Space.xs)
            Button(L("Нет", "No")) { learning.onDecide(s, false) }
                .buttonStyle(.mostik(.quiet, compact: true))
            Button(L("Запомнить", "Remember")) { learning.onDecide(s, true) }
                .buttonStyle(.mostik(.primary, compact: true))
        }
    }

    private func spelling(_ entryID: String) -> some View {
        card {
            Image(systemName: "character.book.closed")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.accent)
            Text(L("Слово распознано не так?", "Misheard a word?"))
                .font(TType.body)
                .foregroundStyle(Palette.ink)
            Spacer(minLength: DS.Space.xs)
            Button(L("Запомнить написание…", "Remember spelling…")) { learning.onOpenSpelling(entryID) }
                .buttonStyle(.mostik(.secondary, compact: true))
            Button { learning.onDismissPrompt() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.mostik(.quiet, compact: true))
            .iconHelp(L("Скрыть", "Hide"))
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: DS.Space.s) { content() }
            .padding(.leading, DS.Space.m)
            .padding(.trailing, DS.Space.xs)
            .frame(height: 52)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card + 2, style: .continuous).strokeBorder(Palette.edgeStrong))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, 6)
    }
}

// MARK: - «Запомнить написание» у диктовки (L2)

struct RememberSpellingSection: View {
    @ObservedObject var learning: GlossaryLearningModel
    let entry: HistoryEntry
    @State private var open: Bool
    @State private var heard: String
    @State private var canonical: String
    @State private var saved: String?
    /// false — кнопку «Запомнить написание…» рисует строка действий диктовки, здесь только форма и итог.
    var showsOpener = true

    init(learning: GlossaryLearningModel, entry: HistoryEntry, open: Bool = false, showsOpener: Bool = true) {
        self.learning = learning
        self.entry = entry
        self.showsOpener = showsOpener
        let doubt = entry.doubts.first
        _open = State(initialValue: open)
        _heard = State(initialValue: doubt?.heard ?? "")
        _canonical = State(initialValue: doubt.map { $0.suggestion.isEmpty ? "" : $0.suggestion } ?? "")
    }

    private var isOpen: Bool { open || learning.spellingEntryID == entry.id }

    // Без обёртки-стека: закрытая секция без кнопки и итога не занимает места и не даёт зазора в родителе.
    @ViewBuilder var body: some View {
            if isOpen {
              VStack(alignment: .leading, spacing: DS.Space.xs) {
                GroupLabel(text: L("Запомнить написание", "Remember spelling"))
                HStack(spacing: DS.Space.xs) {
                    MostikTextField(placeholder: L("Как слышится", "Heard as"), text: $heard)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.inkTertiary)
                    MostikTextField(placeholder: L("Как пишется", "Spelling"), text: $canonical,
                                    monospaced: looksLikeIdentifier(canonical))
                }
                HStack(spacing: DS.Space.xs) {
                    Button(L("Запомнить", "Remember")) {
                        learning.onRememberSpelling(entry.id, heard, canonical)
                        withAnimation(Motion.quick) { saved = canonical; close() }
                    }
                    .buttonStyle(.mostikPrimary)
                    .disabled(canonical.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(L("Отмена", "Cancel")) { withAnimation(Motion.quick) { close() } }
                        .buttonStyle(.mostikQuiet)
                    Spacer()
                    Text(L("Дальше Mostik будет писать так в любом приложении",
                           "From now on Mostik spells it this way everywhere"))
                        .font(TType.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
              }
            } else if showsOpener || saved != nil {
                HStack(spacing: DS.Space.s) {
                    if showsOpener {
                        Button { withAnimation(Motion.quick) { open = true; saved = nil } } label: {
                            Label(L("Запомнить написание…", "Remember spelling…"), systemImage: "character.book.closed")
                        }
                        .buttonStyle(.mostikSecondary)
                    }
                    if let saved {
                        Label(L("«\(saved)» в словаре", "“\(saved)” saved"), systemImage: "checkmark")
                            .font(TType.callout)
                            .foregroundStyle(Palette.accent)
                    }
                }
            }
    }

    private func close() {
        open = false
        if learning.spellingEntryID == entry.id { learning.spellingEntryID = nil }
    }
}

// MARK: - Предложения из правок (L1)

struct LearnSuggestionsSection: View {
    @ObservedObject var learning: GlossaryLearningModel

    var body: some View {
        if !learning.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                GroupLabel(text: L("Предложения из ваших правок", "Suggestions from your edits"),
                           trailing: "\(learning.suggestions.count)")
                VStack(spacing: 0) {
                    ForEach(Array(learning.suggestions.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Hairline(inset: DS.Space.s) }
                        HStack(spacing: DS.Space.s) {
                            Text(s.canonical).font(TType.code.weight(.medium)).foregroundStyle(Palette.ink)
                                .frame(width: GlossaryColumns.first, alignment: .leading)
                            Text(s.heard).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                            Spacer(minLength: DS.Space.s)
                            Text(L10n.plural(s.count, ru: "правка", "правки", "правок", en: "edit", "edits"))
                                .font(TType.figure(11, .regular))
                                .foregroundStyle(Palette.inkTertiary)
                            Button(L("Нет", "No")) { learning.onDecide(s, false) }
                                .buttonStyle(.mostik(.quiet, compact: true))
                            Button(L("Запомнить", "Remember")) { learning.onDecide(s, true) }
                                .buttonStyle(.mostik(.secondary, compact: true))
                        }
                        .lineLimit(1)
                        .padding(.leading, DS.Space.s)
                        .padding(.trailing, DS.Space.xxs)
                        .padding(.vertical, 6)
                    }
                }
                .padding(DS.Space.xxs)
                .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                Text(L("Повторили одну правку дважды за неделю. Пока не нажмёте «Запомнить», словарь не меняется.",
                       "The same edit twice in a week. The glossary changes only when you press Remember."))
                    .font(TType.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }
}

// MARK: - Импорт (L6)

struct GlossaryImportSection: View {
    @ObservedObject var learning: GlossaryLearningModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            GroupLabel(text: L("Перенести слова", "Import words"))
            FlowLayout(spacing: DS.Space.xs) {
                if learning.detected["handy"] == true {
                    Button(L("Из Handy", "From Handy")) { learning.onImport("handy") }.buttonStyle(.mostikSecondary)
                }
                if learning.detected["wispr"] == true {
                    Button(L("Из Wispr Flow", "From Wispr Flow")) { learning.onImport("wispr") }.buttonStyle(.mostikSecondary)
                }
                Button(L("Из CSV-файла…", "From CSV file…")) { learning.onImport("csv") }.buttonStyle(.mostikSecondary)
                Button(L("Из буфера, построчно", "From clipboard, line by line")) { learning.onImport("lines") }
                    .buttonStyle(.mostikSecondary)
            }
            .disabled(learning.importBusy)
            if let error = learning.importError {
                Text(error).font(TType.callout).foregroundStyle(Palette.record)
            }
            if let preview = learning.importPreview { previewCard(preview) }
        }
    }

    private func sourceName(_ source: String) -> String {
        switch source {
        case "handy": return "Handy"
        case "wispr": return "Wispr Flow"
        case "csv": return L("CSV-файл", "CSV file")
        default: return L("Буфер обмена", "Clipboard")
        }
    }

    private func previewCard(_ p: GlossaryImportPreview) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(sourceName(p.source)).font(TType.bodyStrong).foregroundStyle(Palette.ink)
                Text(L("Найдено \(p.total), уже в словаре \(p.duplicates), новых \(p.newCount)",
                       "Found \(p.total), already in the glossary \(p.duplicates), new \(p.newCount)"))
                    .font(TType.figure(12, .regular))
                    .foregroundStyle(Palette.inkSecondary)
                if !p.items.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(p.items.prefix(6).enumerated()), id: \.offset) { _, item in
                            HStack(spacing: DS.Space.s) {
                                Text(item.canonical).font(TType.code).foregroundStyle(Palette.ink)
                                    .frame(width: GlossaryColumns.first, alignment: .leading)
                                if !item.heard.isEmpty {
                                    Text(item.heard).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                                }
                            }
                            .lineLimit(1)
                        }
                        if p.newCount > 6 {
                            Text(L("и ещё \(p.newCount - 6)", "and \(p.newCount - 6) more"))
                                .font(TType.caption)
                                .foregroundStyle(Palette.inkTertiary)
                        }
                    }
                }
                HStack(spacing: DS.Space.xs) {
                    Button(p.newCount > 0 ? L("Добавить \(p.newCount)", "Add \(p.newCount)") : L("Закрыть", "Close")) {
                        learning.onApplyImport()
                    }
                    .buttonStyle(.mostikPrimary)
                    if p.newCount > 0 {
                        Button(L("Отмена", "Cancel")) { learning.onCancelImport() }.buttonStyle(.mostikQuiet)
                    }
                }
                .disabled(learning.importBusy)
            }
        }
    }
}

// MARK: - Автоопределение языка (L5)

/// Строки в «Диктовке» Настроек: включатель и список языков. По умолчанию список — языки Mac.
struct LanguageAutoRows: View {
    @ObservedObject var model: AppModel
    var preferred: [String] = Locale.preferredLanguages

    /// Один переключатель вместо «Определять язык сам» и выбора языков (решение автора):
    /// языков два, выбор из них — всегда русский и английский.
    private var on: Bool {
        model.settings.autoLanguage
            && LanguageChoice.candidates(configured: model.settings.autoLanguages, preferred: preferred).count >= 2
    }

    var body: some View {
        FormToggle(title: L("Русский и английский вперемешку", "Mixed Russian and English"),
                   hint: on ? L("Язык — по первым секундам речи; не ясно — берётся язык выше.", "Language from the first seconds of speech; if unclear, the one above.")
                            : L("Включите, если диктуете на обоих языках.", "Turn on if you dictate in both languages."),
                   isOn: Binding(get: { on }, set: { value in
                       update {
                           $0.autoLanguage = value
                           if value { $0.autoLanguages = LanguageChoice.normalize(LanguageChoice.supported) }
                       }
                   }))
    }

    private func update(_ change: (inout MostikSettings) -> Void) {
        var s = model.settings
        change(&s)
        model.onUpdateSettings(s)
    }
}
