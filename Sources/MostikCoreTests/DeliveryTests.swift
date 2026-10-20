import Foundation
import MostikCore

/// Надёжная доставка (R1–R5, H2, H3, A7): решение о доставке, стык, проверка, откат, восстановление.
func runDeliveryTests() {
    let caret = { (value: String, at: Int) in CaretRange(location: at, length: 0) }

    // MARK: R1 — снимок поля
    do {
        let field = FieldSnapshot(bundleID: "a", role: "AXTextArea", value: "Привет", selection: caret("Привет", 6))
        equal(field.characterBeforeCaret, "т")
        equal(FieldSnapshot(bundleID: "a", value: "abc", selection: CaretRange(location: 0, length: 0)).characterBeforeCaret, nil,
              "каретка в начале")
        equal(FieldSnapshot(bundleID: "a", value: "😀x", selection: CaretRange(location: 2, length: 0)).characterBeforeCaret, "😀",
              "UTF-16: эмодзи из двух юнитов")
        equal(FieldSnapshot(bundleID: "a", value: "ab", selection: CaretRange(location: 9, length: 0)).characterBeforeCaret, nil,
              "каретка за концом — не верим")
        equal(FieldSnapshot(bundleID: "a", role: "AXTextField").editable, .yes)
        equal(FieldSnapshot(bundleID: "a", role: "AXGroup", valueSettable: true).editable, .yes, "contenteditable")
        equal(FieldSnapshot(bundleID: "a", role: "AXButton").editable, .no)
        equal(FieldSnapshot(bundleID: "a", role: "AXWebArea").editable, .unknown, "неизвестная роль — не «нет»")
        equal(FieldSnapshot(bundleID: "a").editable, .unknown, "фокус не прочитан")
        check(FieldSnapshot(bundleID: "a", role: "AXTextField", subrole: "AXSecureTextField").isSecure, "пароль")
    }

    // MARK: R1 — пробел на стыке
    do {
        equal(Joint.join("текст", after: "о"), " текст", "после буквы")
        equal(Joint.join("текст", after: "."), " текст", "после точки")
        equal(Joint.join("текст", after: " "), "текст", "после пробела")
        equal(Joint.join("текст", after: "\n"), "текст", "после перевода строки")
        equal(Joint.join("текст", after: nil), "текст", "начало поля")
        equal(Joint.join("текст", after: "("), "текст", "после скобки")
        equal(Joint.join("текст", after: "«"), "текст", "после кавычки")
        equal(Joint.join(", и ещё", after: "о"), ", и ещё", "запятая прилипает")
        equal(Joint.join(" уже с пробелом", after: "о"), " уже с пробелом")
        equal(Joint.join("", after: "о"), "", "пустой текст")
    }

    // MARK: R1 — решение о доставке
    do {
        let start = FieldSnapshot(bundleID: "app", elementToken: 1, role: "AXTextArea", value: "Ок", selection: caret("Ок", 2))
        func decide(_ now: FieldSnapshot?, front: String? = "app", secure: Bool = false, post: Bool = true,
                    start s: FieldSnapshot? = start) -> DeliveryDecision {
            DeliveryPlanner.decide(text: "дальше", start: s, now: now, expectedBundleID: "app", frontBundleID: front,
                                   secureInput: secure, canPost: post)
        }
        equal(decide(start), .paste(text: " дальше"), "то же поле, пробел на стыке")
        equal(decide(start, front: "other"), .clipboard(.focusChanged), "другое приложение")
        var other = start; other.elementToken = 2
        equal(decide(other), .clipboard(.focusChanged), "другое поле в том же приложении")
        var electron = other; electron.engine = .electron
        var electronStart = start; electronStart.engine = .electron
        equal(decide(electron, start: electronStart), .paste(text: " дальше"), "Electron пересоздаёт элементы — не сверяем")
        equal(decide(start, secure: true), .secureField, "Secure Input")
        var password = start; password.subrole = "AXSecureTextField"
        equal(decide(password), .secureField, "поле пароля не вставляем")
        equal(decide(start, post: false), .clipboard(.noAccessibility))
        equal(decide(FieldSnapshot(bundleID: "app", elementToken: 1, role: "AXButton")), .clipboard(.notEditable), "кнопка")
        equal(decide(nil), .paste(text: "дальше"), "фокус не прочитан — вставляем как раньше")
        equal(DeliveryPlanner.decide(text: "x", start: nil, now: nil, expectedBundleID: nil, frontBundleID: "z",
                                     secureInput: false, canPost: true), .paste(text: "x"), "H3: без ожидаемого приложения")
    }

    // MARK: R2 — проверка вставки
    do {
        let before = FieldState(value: "Ок", selection: CaretRange(location: 2, length: 0))
        let after = FieldState(value: "Ок дальше", selection: CaretRange(location: 9, length: 0))
        equal(PasteVerifier.judge(before: before, after: after, text: " дальше"), .confirmed)
        equal(PasteVerifier.judge(before: before, after: before, text: " дальше"), .notInserted, "ничего не изменилось")
        equal(PasteVerifier.judge(before: before, after: FieldState(value: "Ок", selection: CaretRange(location: 0, length: 0)),
                                  text: " дальше"), .unknown, "сдвинулась только каретка — не «не дошло»")
        equal(PasteVerifier.judge(before: nil, after: after, text: "x"), .unknown, "до вставки не прочитали")
        equal(PasteVerifier.judge(before: before, after: nil, text: "x"), .unknown)
        equal(PasteVerifier.judge(before: before, after: FieldState(value: "Ок **дальше**", selection: CaretRange(location: 13, length: 0)),
                                  text: "zzz"), .unknown, "поле изменилось, но текста не видно")
        let selected = FieldState(value: "старое", selection: CaretRange(location: 0, length: 6))
        equal(PasteVerifier.judge(before: selected, after: FieldState(value: "новое!", selection: CaretRange(location: 6, length: 0)),
                                  text: "новое!"), .confirmed, "замена выделения")
        let repeated = FieldState(value: "да", selection: CaretRange(location: 2, length: 0))
        equal(PasteVerifier.judge(before: repeated, after: FieldState(value: "дада", selection: CaretRange(location: 4, length: 0)),
                                  text: "да"), .confirmed, "текст уже был в поле, но поле выросло")
        equal(PasteVerifier.combine(.notInserted, .confirmed), .confirmed, "дошло со второго чтения")
        equal(PasteVerifier.combine(.notInserted, .notInserted), .notInserted)
        equal(PasteVerifier.combine(.notInserted, .unknown), .unknown)
        equal(PasteVerifier.combine(.unknown, .unknown), .unknown)
        check(PasteVerifier.restoresClipboard(after: .confirmed), "дошло — прежний буфер возвращается")
        check(!PasteVerifier.restoresClipboard(after: .unknown), "неизвестно — диктовка остаётся в буфере")
        check(!PasteVerifier.restoresClipboard(after: .notInserted), "не дошло — диктовка остаётся в буфере")
        check(AppTextEngine.electron.needsManualAccessibility, "Electron: дерево поля — по просьбе")
        check(!AppTextEngine.native.needsManualAccessibility && !AppTextEngine.gecko.needsManualAccessibility,
              "Cocoa и Gecko отдают поле сами")
    }

    // MARK: исправление слова во вставленном тексте
    do {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let before = FieldState(value: "Ок", selection: CaretRange(location: 2, length: 0))
        let after = FieldState(value: "Ок спроси клод", selection: CaretRange(location: 14, length: 0))
        let record = InsertionRecord(entryID: "e", bundleID: "app", elementToken: 1, before: before, after: after,
                                     insertedText: " спроси клод", rawText: "спроси клод", at: t0, check: .confirmed)
        let fix = PendingTextFix(entryID: "e", text: " спроси Claude", at: t0.addingTimeInterval(5))
        let same = FieldSnapshot(bundleID: "app", elementToken: 1, value: after.value, selection: after.selection)
        let soon = t0.addingTimeInterval(30)
        equal(TextFixPlanner.plan(fix, record: record, current: same, frontBundleID: "app", now: soon), .replace)
        equal(TextFixPlanner.plan(fix, record: record, current: same, frontBundleID: "app.mostik.mac", now: soon), .wait,
              "пока пользователь в Mostik — ждём")
        var clicked = same; clicked.selection = CaretRange(location: 0, length: 0)
        equal(TextFixPlanner.plan(fix, record: record, current: clicked, frontBundleID: "app", now: soon), .replace,
              "курсор сдвинули щелчком — текст тот же, меняем")
        var typed = same; typed.value = "Ок спроси клод!"
        equal(TextFixPlanner.plan(fix, record: record, current: typed, frontBundleID: "app", now: soon),
              .refuse(.fieldChanged), "дописали — не трогаем")
        var otherField = same; otherField.elementToken = 9
        equal(TextFixPlanner.plan(fix, record: record, current: otherField, frontBundleID: "app", now: soon),
              .refuse(.focusChanged), "другое поле")
        equal(TextFixPlanner.plan(fix, record: record, current: FieldSnapshot(bundleID: "app"), frontBundleID: "app", now: soon),
              .refuse(.unreadable), "поле не прочитать — вслепую не меняем")
        equal(TextFixPlanner.plan(fix, record: record, current: same, frontBundleID: "app",
                                  now: t0.addingTimeInterval(TextFixPlanner.window + 1)), .refuse(.expired))
        equal(TextFixPlanner.plan(PendingTextFix(entryID: "old", text: "x"), record: record, current: same,
                                  frontBundleID: "app", now: soon), .nothing, "исправление к прошлой диктовке")
        equal(TextFixPlanner.plan(PendingTextFix(entryID: "e", text: " спроси клод"), record: record, current: same,
                                  frontBundleID: "app", now: soon), .nothing, "текст не изменился")
        var failed = record; failed.check = .notInserted
        equal(TextFixPlanner.plan(fix, record: failed, current: same, frontBundleID: "app", now: soon), .nothing)
        check(TextFixPlanner.undoRestored(before: before, now: before), "⌘Z вернул поле как было")
        check(!TextFixPlanner.undoRestored(before: before, now: FieldState(value: "Ок", selection: CaretRange(location: 0, length: 0))),
              "курсор не там — исправленный текст не вставляем")
        check(!TextFixPlanner.undoRestored(before: before, now: after), "⌘Z не сработал")
    }

    // MARK: R4, A7 — откат
    do {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let before = FieldState(value: "Ок", selection: CaretRange(location: 2, length: 0))
        let after = FieldState(value: "Ок дальше", selection: CaretRange(location: 9, length: 0))
        let record = InsertionRecord(entryID: "e", bundleID: "app", elementToken: 1, before: before, after: after,
                                     insertedText: " дальше", rawText: "дальше сыро", at: t0, check: .confirmed)
        let same = FieldSnapshot(bundleID: "app", elementToken: 1, role: "AXTextArea", value: after.value, selection: after.selection)
        equal(RevertPlanner.plan(record, current: same, frontBundleID: "app", now: t0.addingTimeInterval(1)), .undo)
        var typed = same; typed.value = "Ок дальше!"
        equal(RevertPlanner.plan(record, current: typed, frontBundleID: "app", now: t0.addingTimeInterval(1)),
              .clipboard(text: "дальше сыро", reason: .fieldChanged), "поле изменили — исходник в буфер")
        var moved = same; moved.selection = CaretRange(location: 0, length: 0)
        equal(RevertPlanner.plan(record, current: moved, frontBundleID: "app", now: t0.addingTimeInterval(1)),
              .clipboard(text: "дальше сыро", reason: .fieldChanged), "каретку сдвинули")
        equal(RevertPlanner.plan(record, current: same, frontBundleID: "other", now: t0.addingTimeInterval(1)),
              .clipboard(text: "дальше сыро", reason: .focusChanged))
        var otherField = same; otherField.elementToken = 7
        equal(RevertPlanner.plan(record, current: otherField, frontBundleID: "app", now: t0.addingTimeInterval(1)),
              .clipboard(text: "дальше сыро", reason: .focusChanged), "другое поле")
        equal(RevertPlanner.plan(record, current: FieldSnapshot(bundleID: "app"), frontBundleID: "app", now: t0.addingTimeInterval(1)),
              .clipboard(text: "дальше сыро", reason: .unreadable), "поле не прочитать — откат вслепую не делаем")
        equal(RevertPlanner.plan(record, current: same, frontBundleID: "app", now: t0.addingTimeInterval(RevertPlanner.window + 1)),
              .clipboard(text: "дальше сыро", reason: .expired))
        var failed = record; failed.check = .notInserted
        equal(RevertPlanner.plan(failed, current: same, frontBundleID: "app", now: t0), .nothing, "не дошло — откатывать нечего")
        equal(RevertPlanner.plan(nil, current: same, frontBundleID: "app"), .nothing)
        var noRaw = record; noRaw.rawText = ""
        equal(RevertPlanner.plan(noRaw, current: typed, frontBundleID: "app", now: t0),
              .clipboard(text: " дальше", reason: .fieldChanged), "без сырого — вставленный текст")

        check(RevertPlanner.escapeReverts(record, now: t0.addingTimeInterval(1)), "Esc сразу после вставки")
        check(!RevertPlanner.escapeReverts(record, now: t0.addingTimeInterval(RevertPlanner.escapeWindow + 0.5)), "Esc позже — не откат")
        check(!RevertPlanner.escapeReverts(failed, now: t0), "Esc после провала — не откат")
        check(RevertPlanner.undoWorked(before: before, now: FieldState(value: "Ок", selection: CaretRange(location: 2, length: 0))))
        check(!RevertPlanner.undoWorked(before: before, now: after), "⌘Z не сработал")
        check(!RevertPlanner.undoWorked(before: nil, now: after))
    }

    // MARK: H2 — Esc на любом этапе
    do {
        var m = DictationMachine(minimumHold: 0.25, makeSessionID: { "e1" })
        m.handle(.holdBegan(at: 0))
        equal(m.handle(.abort), [.discardRecording(session: "e1")], "Esc во время записи")
        m.handle(.holdBegan(at: 1))
        m.handle(.holdEnded(at: 3))
        equal(m.handle(.cancel), [], "случайная отмена расшифровку не трогает")
        equal(m.handle(.abort), [.abandonTranscription(session: "e1")], "Esc во время расшифровки")
        equal(m.state, .idle, "после Esc можно диктовать снова")
        equal(m.handle(.resultReady), [], "опоздавший результат не вставляется")
        m.handle(.holdBegan(at: 10))
        m.handle(.holdEnded(at: 12))
        m.handle(.resultReady)
        equal(m.handle(.abort), [.abortInsertion(session: "e1")], "Esc во время вставки")
        equal(m.state, .idle)
        equal(m.handle(.inserted), [], "конец вставки после Esc ничего не ломает")
        equal(m.handle(.abort), [], "Esc в покое — дело контроллера (A7)")
        m.handle(.holdBegan(at: 20))
        m.handle(.failure("x"))
        equal(m.handle(.abort), [], "Esc закрывает ошибку")
        equal(m.state, .idle)
    }

    // MARK: R5, H3 — восстановление и повтор
    do {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func entry(_ id: String, hoursAgo: Double, text: String = "т", audio: String? = nil) -> HistoryEntry {
            HistoryEntry(id: id, createdAt: now.addingTimeInterval(-hoursAgo * 3600), text: text, audioPath: audio)
        }
        let entries = [entry("old", hoursAgo: 30), entry("b", hoursAgo: 2), entry("a", hoursAgo: 1),
                       entry("c", hoursAgo: 3), entry("d", hoursAgo: 4), entry("empty", hoursAgo: 0.5, text: ""),
                       entry("audio", hoursAgo: 0.2, text: "", audio: "/tmp/x.wav")]
        equal(RecentDictations.recoverable(entries, now: now).map(\.id), ["audio", "a", "b"],
              "три свежих, пустые без аудио не в счёт")
        equal(RecentDictations.recoverable([entry("old", hoursAgo: 25)], now: now).map(\.id), [], "старше суток")
        equal(RecentDictations.lastWithText(entries)?.id, "a", "повтор берёт последнюю с текстом")
        equal(RecentDictations.lastWithText([]), nil)

        // «За сутки»: встречи вперемешку с диктовками, новые первыми, всего 4.
        struct Meeting { let id: String; let hoursAgo: Double; var recording = false }
        let meetings = [Meeting(id: "m1", hoursAgo: 1.5), Meeting(id: "m-old", hoursAgo: 26),
                        Meeting(id: "m-live", hoursAgo: 0.1, recording: true), Meeting(id: "m-future", hoursAgo: -1)]
        func labels(_ items: [RecentDictations.Item<Meeting>]) -> [String] {
            items.map { item in
                switch item {
                case let .dictation(entry): return entry.id
                case let .meeting(meeting): return meeting.id
                }
            }
        }
        let mixed = RecentDictations.withMeetings(entries, meetings: meetings,
                                                  startedAt: { now.addingTimeInterval(-$0.hoursAgo * 3600) },
                                                  include: { !$0.recording }, now: now)
        equal(labels(mixed), ["audio", "a", "m1", "b"], "встреча между диктовками по времени; идущая, старая и будущая — нет")
        let onlyMeetings = RecentDictations.withMeetings([], meetings: meetings,
                                                         startedAt: { now.addingTimeInterval(-$0.hoursAgo * 3600) }, now: now)
        equal(labels(onlyMeetings), ["m-live", "m1"], "без диктовок — одни встречи")
    }

    // MARK: История — новые поля читаются и без них
    do {
        let old = #"{"id":"x","createdAt":"2026-10-01T10:00:00Z","text":"t","insertedText":"","doubts":[],"corrections":[],"language":"ru","audioSeconds":1,"latencyMs":1,"appName":"","agent":false,"outcome":"inserted","verifier":"done","agentMisread":false}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode(HistoryEntry.self, from: Data(old.utf8))
        check(decoded != nil && decoded?.pasteCheck == nil, "старая запись без pasteCheck")
    }
}
