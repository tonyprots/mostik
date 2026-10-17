import SwiftUI
import MostikCore

/// Снимки личного словаря вокруг вставки (L1, L2, L3, L5, L6). Слова и правки вымышленные.
extension Snapshots {
    @MainActor
    static func renderGlossaryLearning(to dir: URL) {
        let suffix = { (dark: Bool) in dark ? "-dark" : "" }
        let suggestion = GlossarySuggestion(heard: L("клод код", "cloud code"), canonical: "Claude Code", language: L("ru", "en"), count: 2)

        // Карточка над HUD: предложение из правок и «Запомнить написание…».
        for dark in [false, true] {
            let learning = GlossaryLearningModel()
            learning.prompt = suggestion
            write(stage(LearnPromptCard(learning: learning)), "hud-learn-suggestion" + suffix(dark), dir,
                  width: 480, height: 96, dark: dark)
            let chip = GlossaryLearningModel()
            chip.spellingChipEntry = "d1"
            write(stage(LearnPromptCard(learning: chip)), "hud-learn-spelling" + suffix(dark), dir,
                  width: 480, height: 96, dark: dark)
        }

        // «Словарь» → личный: колонки (L3), предложения из правок (L1), просмотр импорта (L6).
        for dark in [false, true] {
            let model = demoModel()
            model.selectedTab = .glossary
            model.glossary = [
                .init(canonical: "Claude Code", aliases: L10n.isRussian ? ["клод код", "клот код"] : ["cloud code", "clod code"], source: "personal"),
                .init(canonical: "GigaAM", aliases: L10n.isRussian ? ["гигам", "гига ам"] : ["giga am", "gig am"], source: "learned"),
                .init(canonical: L("Мостик", "Mostik"), aliases: [L("мостик", "mostic")], source: "personal"),
                .init(canonical: "parakeet_tdt", aliases: [L("паракит", "parakeet")], source: "personal"),
            ]
            model.glossaryLearning.suggestions = [
                suggestion,
                GlossarySuggestion(heard: L("вормик", "warm mike"), canonical: "warm_mic", language: L("ru", "en"), count: 3),
            ]
            model.glossaryLearning.detected = ["handy": true, "wispr": true]
            model.glossaryLearning.importPreview = GlossaryImportPreview(
                source: "wispr", total: 14, duplicates: 3, newCount: 11,
                items: [.init(canonical: "Kubernetes", heard: L("кубернетис", "cooper netties")), .init(canonical: "Telemost"),
                        .init(canonical: "Postgres", heard: L("постгрес", "post grace")), .init(canonical: "Kafka")])
            write(MainWindowView(model: model, entry: nil, source: "personal:" + L("Личный словарь", "Personal glossary")),
                  "main-glossary-learning" + suffix(dark), dir, width: 1080, height: 1020, dark: dark)
        }

        // Диктовка: форма «Запомнить написание» открыта (L2).
        for dark in [false, true] {
            let model = demoModel()
            model.glossaryLearning.spellingEntryID = "d1"
            write(MainWindowView(model: model, entry: "d1"), "main-dictation-remember-spelling" + suffix(dark), dir,
                  width: 1080, height: 900, dark: dark)
        }

        // Настройки: автоопределение языка (L5) — языки Mac по умолчанию.
        for dark in [false, true] {
            let model = demoModel()
            model.settings.autoLanguage = true
            let rows = LanguageAutoRows(model: model, preferred: ["ru-RU", "en-US"])
                .padding(.horizontal, DS.Space.m)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Palette.canvas)
            write(rows, "settings-auto-language" + suffix(dark), dir, width: 688, dark: dark)
        }
    }

    @MainActor
    private static func stage<V: View>(_ view: V) -> some View {
        view
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.dynamic(0xDDE3DF, 0x3A403D))
    }
}
