import Foundation
import MostikCore

/// Тексты Настроек по слепому раунду 4: число в сводке моделей, имя приложения без номера копии,
/// нейтральное имя продукта для снимков слепых тестов.
func runSettingsCopyTests() {
    let ru = UIText.isRussian
    defer { UIText.isRussian = ru; UIText.neutralName = false }

    // Сводка моделей: в «Дополнительно» было «· models installed» без числа.
    // Прежняя логика («модели на месте» при полном наборе) не проходит первую проверку: в строке нет цифры.
    func row(_ key: String, _ purpose: String, required: Bool = true, installed: Bool = true) -> ModelRow {
        ModelRow(key: key, label: key, purpose: purpose, required: required, size: 1, installed: installed)
    }
    let all = [row("vad", "vad"), row("gigaam", "ru"), row("whisper", "en"), row("parakeet", "verifier-en", required: false),
               row("gemma", "llm", required: false)]
    UIText.isRussian = false
    equal(ModelCatalog.summary(all, language: "ru"), "5 models installed", "полный набор — с числом")
    check(ModelCatalog.summary(all, language: "ru").contains { $0.isNumber }, "в сводке есть число")
    UIText.isRussian = true
    equal(ModelCatalog.summary(all, language: "ru"), "5 моделей установлено")
    var noLLM = all; noLLM[4].installed = false
    equal(ModelCatalog.summary(noLLM, language: "ru"), "4 модели установлены", "необязательная модель не в счёт недостающих")
    var noRU = all; noRU[1].installed = false
    equal(ModelCatalog.summary(noRU, language: "ru"), "1 модель не скачана", "не хватает нужной — это и пишем")
    equal(ModelCatalog.summary([], language: "ru"), "список моделей ещё не получен", "движок не ответил — не «0 моделей»")

    // Имя приложения: из Info.plist; имя файла — без «.app» и номера копии Finder.
    equal(AppDisplayName.resolve(bundleID: "ru.keepcoder.Telegram", bundleName: "Telegram", fileName: "Telegram 2.app"), "Telegram")
    equal(AppDisplayName.resolve(bundleID: "ru.keepcoder.Telegram", bundleName: nil, fileName: "Telegram 2.app"), "Telegram",
          "копия Finder без номера")
    equal(AppDisplayName.resolve(bundleID: "ru.keepcoder.Telegram", bundleName: nil, fileName: "Telegram 2"), "Telegram")
    equal(AppDisplayName.resolve(bundleID: "com.example.Things3", bundleName: nil, fileName: "Things3.app"), "Things3",
          "цифра в имени без пробела — часть имени")
    equal(AppDisplayName.resolve(bundleID: "dev.zed.Zed", bundleName: nil, fileName: nil), "Zed")
    equal(AppDisplayName.resolve(bundleID: "com.apple.mail", bundleName: " ", fileName: nil), "Mail", "пустое имя из plist не берём")

    // Нейтральное имя: только по флагу; падеж и регистр — по месту.
    UIText.isRussian = true
    equal(UIText.pick("Mostik ждёт этот язык", "x"), "Mostik ждёт этот язык", "без флага имя остаётся")
    UIText.neutralName = true
    equal(UIText.pick("Mostik ждёт этот язык", "x"), "Приложение ждёт этот язык")
    equal(UIText.pick("Если Mostik закроется с ошибкой", "x"), "Если приложение закроется с ошибкой")
    equal(UIText.pick("Отдаёт ему надиктованное из папки Mostik.", "x"), "Отдаёт ему надиктованное из папки приложения.")
    equal(UIText.pick("Включите Mostik в списке", "x"), "Включите приложение в списке")
    equal(UIText.pick("Скопируйте — сам Mostik ничего не шлёт. Сам Mostik запись не начинает.", "x"),
          "Скопируйте — само приложение ничего не шлёт. Само приложение запись не начинает.", "«сам» согласуется")
    equal(UIText.pick("Команда mostik в терминале", "x"), "Команда app в терминале", "команда — нейтральное имя команды")
    equal(UIText.pick("Записано: ~/.claude/skills/mostik/SKILL.md, '/Applications/Mostik.app/Contents/Resources/bin/mostik' mcp", "x"),
          "Записано: ~/.claude/skills/app/SKILL.md, '/Applications/App.app/Contents/Resources/bin/app' mcp", "пути тоже нейтральные")
    UIText.isRussian = false
    equal(UIText.pick("x", "Mostik expects this language. If Mostik crashes, the volume comes back."),
          "The app expects this language. If the app crashes, the volume comes back.")
    equal(UIText.pick("x", "Hands it what you dictated from Mostik’s folder."), "Hands it what you dictated from the app’s folder.")
    equal(UIText.pick("x", "“Mostik never sends anything”"), "“The app never sends anything”")
    check(!UIText.pick("x", "Mostik, Mostik’s and mostik").lowercased().contains("mostik"), "имени не осталось")
}
