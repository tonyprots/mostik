import Foundation
import MostikCore

/// Обучение на правках (L1): где в поле вставка и во что её превратили; язык диктовки (L5).
func runEditLearningTests() {
    // Одна всплывашка: с сомнениями ведёт плашка, карточка «Слово распознано не так?» молчит.
    check(!LearnPromptPolicy.showsSpellingChip(doubts: 2, corrections: 1), "сомнения — только плашка")
    check(!LearnPromptPolicy.showsSpellingChip(doubts: 0, corrections: 0), "нечего запоминать")
    check(LearnPromptPolicy.showsSpellingChip(doubts: 0, corrections: 1), "правки словаря без сомнений — карточка")

    // MARK: L1 — поиск вставки
    do {
        let value = "Привет. спроси клод про тесты. Пока"
        let inserted = "спроси клод про тесты."
        equal(EditWatch.locate(inserted, in: value, near: 8), 8..<30, "на месте вставки")
        equal(EditWatch.locate(inserted, in: value, near: nil), 8..<30, "без каретки — поиском")
        equal(EditWatch.locate("x", in: "x a x", near: 4), 4..<5, "ближайшее к каретке вхождение")
        equal(EditWatch.locate("нет", in: value, near: 0), nil)
        equal(EditWatch.locate("😀 клод", in: "a 😀 клод", near: 2), 2..<9, "UTF-16")
    }

    // MARK: L1 — правка вставки
    do {
        let after = "Привет. спроси клод про тесты. Пока"
        let range = 8..<30
        equal(EditWatch.edit(after: after, final: "Привет. спроси Claude про тесты. Пока", inserted: range),
              InsertionEdit(before: "спроси клод про тесты.", after: "спроси Claude про тесты."), "замена внутри")
        equal(EditWatch.edit(after: after, final: after, inserted: range), nil, "поле не меняли")
        equal(EditWatch.edit(after: after, final: after + " И ещё строка", inserted: range), nil, "только дописали")
        equal(EditWatch.edit(after: after, final: "Здравствуй. спроси клод про тесты. Пока", inserted: range), nil,
              "правили только чужой текст")
        equal(EditWatch.edit(after: after, final: "Привет. спроси клод про тесты. Пока-пока, до завтра", inserted: range),
              nil, "правка за вставкой")
        // Правка задела слово рядом: кусок расширяется до границ слов.
        equal(EditWatch.edit(after: "Сделай: открой гигам", final: "Сделай: открой GigaAM", inserted: 8..<20),
              InsertionEdit(before: "открой гигам", after: "открой GigaAM"))
        equal(EditWatch.edit(after: "ab спроси клод", final: "ab спроси", inserted: 3..<14),
              InsertionEdit(before: "спроси клод", after: "спроси"), "удаление слова")
        equal(EditWatch.edit(after: "abc", final: "abd", inserted: 0..<9), nil, "диапазон за концом")
        let far = String(repeating: "x", count: 60)
        equal(EditWatch.edit(after: far + " клод", final: "y" + far.dropFirst() + " Claude", inserted: 61..<65), nil,
              "правка далеко за пределами вставки")
    }

    // MARK: L1 — то же поле
    do {
        let record = InsertionRecord(entryID: "e", bundleID: "app", elementToken: 7, engine: .native, insertedText: "x",
                                     rawText: "x")
        check(EditWatch.sameField(FieldSnapshot(bundleID: "app", elementToken: 7, value: "x"), as: record))
        check(!EditWatch.sameField(FieldSnapshot(bundleID: "app", elementToken: 8, value: "x"), as: record), "другой элемент")
        check(!EditWatch.sameField(FieldSnapshot(bundleID: "other", elementToken: 7, value: "x"), as: record))
        check(!EditWatch.sameField(FieldSnapshot(bundleID: "app", elementToken: 7, subrole: "AXSecureTextField"), as: record),
              "пароль не читаем")
        check(!EditWatch.sameField(FieldSnapshot(bundleID: "app", elementToken: 7), as: record), "значение не прочитано")
        var electron = record
        electron.engine = .electron
        check(EditWatch.sameField(FieldSnapshot(bundleID: "app", elementToken: 99, value: "x"), as: electron),
              "Electron пересоздаёт элементы")
    }

    // MARK: L1 — предложения из ответа движка
    do {
        let reply: JSONValue = .array([
            .object(["heard": .string("клод"), "canonical": .string("Claude"), "language": .string("ru"), "count": .number(2)]),
            .object(["heard": .string("x")]),
        ])
        equal(GlossarySuggestion.parse(reply), [GlossarySuggestion(heard: "клод", canonical: "Claude", language: "ru", count: 2)])
        equal(GlossarySuggestion.parse(nil), [])
    }

    // MARK: L5 — язык диктовки
    do {
        equal(LanguageChoice.normalize(["ru-RU", "en-US", "de-DE", "en_GB", "uk"]), ["ru", "en"])
        equal(LanguageChoice.candidates(configured: nil, preferred: ["en-US", "ru-RU"]), ["en", "ru"], "языки Mac")
        equal(LanguageChoice.candidates(configured: ["ru"], preferred: ["en-US", "ru-RU"]), ["ru"], "свой список главнее")
        equal(LanguageChoice.candidates(configured: [], preferred: ["de-DE"]), [], "ничего поддерживаемого")
        var settings = MostikSettings()
        equal(LanguageChoice.request(settings: settings, preferred: ["ru-RU", "en-US"]), [], "по умолчанию выключено")
        settings.autoLanguage = true
        settings.language = "en"
        equal(LanguageChoice.request(settings: settings, preferred: ["ru-RU", "en-US"]), ["en", "ru"],
              "язык по умолчанию — первым")
        equal(LanguageChoice.request(settings: settings, preferred: ["ru-RU"]), [], "один язык — выбирать не из чего")
        settings.autoLanguages = ["ru", "de"]
        equal(LanguageChoice.request(settings: settings, preferred: ["ru-RU", "en-US"]), [],
              "язык по умолчанию не в списке — не определяем")
        let decoded = try? JSONDecoder().decode(MostikSettings.self, from: Data("{}".utf8))
        equal(decoded?.learnFromEdits, true, "обучение на правках включено по умолчанию")
        equal(decoded?.autoLanguage, false)
    }
}
