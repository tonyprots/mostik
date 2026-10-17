import AppKit
import SwiftUI
import MostikCore

/// Рендер всех экранов с вымышленными демо-данными в PNG (2x).
/// Приёмка дизайна без разрешений и без движка.
public enum Snapshots {
    /// Каждый светлый снимок дублируется тёмным `<имя>-dark` (для слепого теста: все экраны в обеих темах).
    nonisolated(unsafe) static var bothThemes = false

    /// Язык — `english` или `MOSTIK_SNAPSHOT_LANG=en`; обе темы — `bothThemes` или `MOSTIK_SNAPSHOT_THEMES=both`;
    /// нейтральное имя продукта — `neutralName` или `MOSTIK_SNAPSHOT_NEUTRAL=1`.
    @MainActor
    public static func render(to dir: URL, english: Bool? = nil, bothThemes: Bool? = nil, neutralName: Bool? = nil) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        let english = english ?? (env["MOSTIK_SNAPSHOT_LANG"] == "en")
        L10n.isRussian = !english
        // Слепые тесты (раунд 4): имя продукта в подписях выдаёт, чей это экран.
        L10n.neutralName = neutralName ?? (env["MOSTIK_SNAPSHOT_NEUTRAL"] == "1")
        Self.bothThemes = bothThemes ?? (env["MOSTIK_SNAPSHOT_THEMES"] == "both")

        // HUD
        for (name, phase) in [
            ("hud-recording", AppModel.HUDPhase.recording),
            ("hud-transcribing", .transcribing),
            ("hud-done", .done(summary: L("Вставлено", "Inserted"), doubts: 2, agent: true)),
            ("hud-copied", .done(summary: L("Скопировано", "Copied"), doubts: 0, agent: false)),
            ("hud-error", .error(L("Микрофон занят другим приложением", "Microphone is busy"))),
            // Доставка (R2, R4, H2)
            ("hud-not-inserted", .notice(title: L("Текст не вставлен", "Text not inserted"),
                                         detail: L("Расшифровка сохранена · в буфере, ⌘V", "Transcript saved · on clipboard, ⌘V"))),
            ("hud-cancelled", .notice(title: L("Отменено", "Cancelled"),
                                      detail: L("Текст сохранится в истории", "Text will be kept in history"))),
            ("hud-revert-refused", .notice(title: L("Поле уже изменилось", "Field has changed"),
                                           detail: L("Исходник в буфере · ⌘V", "Original on clipboard · ⌘V"))),
            ("hud-undone", .done(summary: L("Вставка отменена", "Insertion undone"), doubts: 0, agent: false)),
        ] {
            let model = demoModel()
            model.hud = phase
            write(hudStage(HUDView(model: model)), name, dir, width: 460, height: 108)
        }
        // Длинная диктовка ждёт вторую модель: полоса и «Вставить сразу».
        do {
            let model = demoModel()
            model.hud = .transcribing
            model.verifyProgress = 0.6
            write(hudStage(HUDView(model: model)), "hud-verifying", dir, width: 460, height: 108)
        }

        // Голосовая правка (D5): та же пилюля, своё содержимое.
        for (name, phase, hud, command) in [
            ("hud-edit-listening", VoiceEditModel.Phase.listening, AppModel.HUDPhase.recording, L("сделай списком", "make it a list")),
            ("hud-edit-working", .working, .transcribing, L("Сделать списком", "Make it a list")),
            ("hud-edit-done", .done, .done(summary: L("Заменено", "Replaced"), doubts: 0, agent: false),
             L("Перевести на английский", "Translate to Russian")),
            ("hud-edit-failed", .failed(.refused), .error(VoiceEditModel.message(.refused)), ""),
        ] {
            let model = demoModel()
            model.voiceEdit.phase = phase
            model.voiceEdit.command = command
            model.voiceEdit.selectionLength = 214
            model.hud = hud
            write(hudStage(HUDView(model: model)), name, dir, width: 460, height: 108)
        }

        // Меню-бар
        for dark in [false, true] {
            let menu = demoModel()
            menu.meetingSuggestion = L("Телемосте", "Zoom")
            write(menuStage(MenuBarContentView(model: menu), dark: dark), "menubar" + (dark ? "-dark" : ""), dir, width: 336, dark: dark)
        }
        // «Записать голос» во время записи: «Остановить запись» и таймер.
        for dark in [false, true] {
            let menu = demoModel()
            menu.menuVoicePhase = .recording
            menu.hud = .recording
            menu.recordingHandsFree = true
            menu.elapsed = 14.6
            write(menuStage(MenuBarContentView(model: menu), dark: dark), "menubar-recording" + (dark ? "-dark" : ""), dir, width: 336, dark: dark)
        }
        // Движок ещё грузится: состояние справа от «Записать голос» вместо сочетания клавиш.
        for dark in [false, true] {
            let menu = demoModel()
            menu.engineStatus = .loading("")
            write(menuStage(MenuBarContentView(model: menu), dark: dark), "menubar-loading" + (dark ? "-dark" : ""), dir, width: 336, dark: dark)
        }
        // R5: последние за сутки с пометками «отменено» и «не вставлено».
        let recovery = demoModel()
        recovery.history[0].outcome = "cancelled"
        recovery.history[1].outcome = "clipboard"
        recovery.history[1].pasteCheck = "not_inserted"
        write(menuStage(MenuBarContentView(model: recovery), dark: false), "menubar-recovery", dir, width: 336)
        // Запись встречи — в меню строки меню (M3, решение автора): раздел сверху со всеми действиями.
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            let live = liveMeetingModel()
            write(menuStage(MenuBarContentView(model: live), dark: dark), "menubar-meeting" + suffix, dir, width: 336, dark: dark)
            let paused = liveMeetingModel()
            paused.meetingPaused = true
            write(menuStage(MenuBarContentView(model: paused), dark: dark), "menubar-meeting-paused" + suffix, dir, width: 336, dark: dark)
            // W15 и W26: «только текст» и кадры окна звонка включены; пометок ещё нет.
            let options = liveMeetingModel()
            options.meetingMarks = []
            options.meetingLive.textOnly = true
            options.meetingAssist.framesConsent = true
            options.meetingAssist.framesCount = 3
            write(menuStage(MenuBarContentView(model: options), dark: dark), "menubar-meeting-options" + suffix, dir, width: 336, dark: dark)
        }
        let menuConsent = demoModel()
        menuConsent.meetingConsentPending = true
        write(menuStage(MenuBarContentView(model: menuConsent), dark: false), "menubar-consent", dir, width: 336)

        // Главное окно
        for dark in [false, true] {
            let main = demoModel()
            write(MainWindowView(model: main, entry: "d1"), "main-dictation" + (dark ? "-dark" : ""), dir,
                  width: 1080, height: 760, dark: dark)
        }
        let single = demoModel()
        write(MainWindowView(model: single, entry: "d4"), "main-dictation-single", dir, width: 1080, height: 700)

        let empty = demoModel()
        empty.history = []
        write(MainWindowView(model: empty), "main-dictation-empty", dir, width: 1080, height: 700)

        for dark in [false, true] {
            let meetings = demoModel()
            meetings.selectedTab = .meetings
            write(MainWindowView(model: meetings, entry: nil, meeting: "m2"), "main-meetings" + (dark ? "-dark" : ""), dir,
                  width: 1080, height: 760, dark: dark)
            // Идущая расшифровка: фаза, модель и доля — без дорожек и счётчиков окон.
            write(MainWindowView(model: meetings, entry: nil, meeting: "m1"), "main-meetings-processing" + (dark ? "-dark" : ""), dir,
                  width: 1080, height: 760, dark: dark)
        }
        let live = liveMeetingModel()
        live.selectedTab = .meetings
        write(MainWindowView(model: live, entry: nil, meeting: "m0"), "main-meetings-live", dir, width: 1080, height: 700)

        let consent = demoModel()
        consent.selectedTab = .meetings
        consent.meetingConsentPending = true
        write(MainWindowView(model: consent, entry: nil, meeting: "m2"), "main-meetings-consent", dir, width: 1080, height: 700)

        // ИИ встреч (M5–M7): сводка, заметки, задачи, состояния — MeetingAIDemo.swift.
        for scene in MeetingAIDemo.scenes() {
            write(MainWindowView(model: scene.model, entry: nil, meeting: "m2"), scene.name, dir,
                  width: 1080, height: scene.height, dark: scene.dark)
        }

        // Словарь и источники (S5)
        for dark in [false, true] {
            let glossary = demoModel()
            glossary.selectedTab = .glossary
            write(MainWindowView(model: glossary), "main-glossary" + (dark ? "-dark" : ""), dir, width: 1080, height: 760, dark: dark)
        }
        let repo = demoModel()
        repo.selectedTab = .glossary
        write(MainWindowView(model: repo, entry: nil, source: repo.sources[0].id), "main-glossary-repo", dir, width: 1080, height: 760)

        let calendarOff = demoModel()
        calendarOff.selectedTab = .glossary
        calendarOff.settings.calendarEnabled = false
        calendarOff.sources.removeAll { $0.kind == "calendar" }
        write(MainWindowView(model: calendarOff, entry: nil, source: "calendar:" + L("Календарь", "Calendar")),
              "main-glossary-calendar-off", dir, width: 1080, height: 700)

        let personal = demoModel()
        personal.selectedTab = .glossary
        write(MainWindowView(model: personal, entry: nil, source: "personal:" + L("Личный словарь", "Personal glossary")),
              "main-glossary-personal", dir, width: 1080, height: 700)

        let scanning = demoModel()
        scanning.selectedTab = .glossary
        scanning.sources = []
        scanning.terms = []
        scanning.sourcesScanning = true
        write(MainWindowView(model: scanning), "main-glossary-scanning", dir, width: 1080, height: 700)

        let nothing = demoModel()
        nothing.selectedTab = .glossary
        nothing.sources = []
        nothing.terms = []
        nothing.glossary = []
        nothing.settings.calendarEnabled = false
        write(MainWindowView(model: nothing), "main-glossary-empty", dir, width: 1080, height: 700)

        for dark in [false, true] {
            // Главный снимок Настроек — раздел «Основное».
            write(SettingsWindowView(model: settingsDemo(.general)), "main-settings" + (dark ? "-dark" : ""), dir,
                  width: 900, height: settingsPaneShot(.general).height, dark: dark)
        }

        // Встречи: внешний календарь-команда подключён и отдал события (docs/external-calendar.md).
        let extCal = settingsDemo(.meetings)
        extCal.settings.calendarEnabled = true
        extCal.settings.calendarCommand = "/Users/demo/bin/work-calendar"
        extCal.externalCalendarStatus = L("Событий: 14 · обновлено в 10:40", "Events: 14 · updated at 10:40")
        write(SettingsWindowView(model: extCal), "main-settings-meetings-calendar", dir,
              width: 900, height: settingsPaneShot(.meetings).height + 500)

        // Встречи: источники календаря — Google подключён, Яндекс нет, в macOS отмечен один календарь.
        let sources = settingsDemo(.meetings)
        sources.settings.calendarEnabled = true
        sources.googleCalendarAvailable = true
        sources.settings.calendarAccounts = CalendarAccounts(
            google: .init(login: "demo@gmail.com", calendars: [RemoteCalendar(id: "demo@gmail.com", name: L("Работа", "Work"), primary: true)]),
            mac: [RemoteCalendar(id: "icloud-home", name: L("Дом — iCloud", "Home — iCloud"))])
        sources.calendarSourceStatus[.google] = CalendarSourceStatus(L("demo@gmail.com · встреч: 9 · 10:40", "demo@gmail.com · meetings: 9 · 10:40"))
        write(SettingsWindowView(model: sources), "main-settings-meetings-sources", dir,
              width: 900, height: settingsPaneShot(.meetings).height + 200)

        // Причёсывание (D3, D4, G7): Claude включён с согласием, стиль «деловой», исключения по приложениям.
        for dark in [false, true] {
            let polish = demoModel()
            polish.settingsPane = .text
            polish.settings.polish = PolishSettings(backend: .claude, style: .business, cloudConsent: true,
                                                    forcedOn: ["com.apple.mail"], forcedOff: ["ru.keepcoder.Telegram"])
            polish.polishAvailable = ["claude": true, "mlx": false]
            write(SettingsWindowView(model: polish), "main-settings-polish" + (dark ? "-dark" : ""), dir,
                  width: 900, height: 1268, dark: dark)
        }
        let polishConsent = demoModel()
        polishConsent.settingsPane = .text
        polishConsent.polishConsentPending = true
        write(SettingsWindowView(model: polishConsent), "main-settings-polish-consent", dir, width: 900, height: 760)
        // Claude включён в «Тексте» — вопрос про встречи; во «Встречах» — согласие на месте выбора и включённое.
        let meetingOffer = demoModel()
        meetingOffer.settingsPane = .text
        meetingOffer.settings.polish = PolishSettings(backend: .claude, style: .plain, cloudConsent: true)
        meetingOffer.settings.meetingAICloudConsent = false
        meetingOffer.polishAvailable = ["claude": true]
        meetingOffer.meetingAI.offerAfterPolish = true
        write(SettingsWindowView(model: meetingOffer), "main-settings-polish-meeting-offer", dir, width: 900, height: 900)
        for (name, granted) in [("main-settings-meetings-ai-consent", false), ("main-settings-meetings-ai-on", true)] {
            let m = demoModel()
            m.settingsPane = .meetings
            m.settings.polish = PolishSettings(backend: .claude, style: .plain, cloudConsent: true)
            m.settings.meetingAIConsent = granted
            m.settings.meetingAICloudConsent = granted
            m.polishAvailable = ["claude": true]
            if !granted { m.meetingAI.consentFor = MeetingAIModel.settingsConsent }
            write(SettingsWindowView(model: m), name, dir, width: 900, height: 1400)
        }
        let polishLocal = demoModel()
        polishLocal.settingsPane = .text
        polishLocal.settings.polish = PolishSettings(backend: .mlx, style: .list)
        polishLocal.polishAvailable = ["claude": false, "mlx": false]
        write(SettingsWindowView(model: polishLocal), "main-settings-polish-local", dir, width: 900, height: 1136)

        // Голосовая правка в группе причёсывания: включена; и подсказка, когда нет согласия на облако.
        for (name, consent) in [("main-settings-voice-edit", true), ("main-settings-voice-edit-blocked", false)] {
            let edit = demoModel()
            edit.settingsPane = .text
            edit.settings.polish = PolishSettings(backend: consent ? .claude : .off, style: .plain, cloudConsent: consent)
            edit.settings.voiceEdit = true
            edit.polishAvailable = ["claude": true, "mlx": false]
            write(SettingsWindowView(model: edit), name, dir, width: 900, height: consent ? 1184 : 520)
        }

        // Онбординг (П8, пункт 7): микрофон, доступ и вставка, встречи по желанию, «Проверка».
        for step in 0..<5 {
            let model = demoModel()
            model.permissions = AppModel.Permissions(microphone: step > 0, accessibility: step > 1, postEvents: step > 1)
            model.doctor.checks = doctorAllGood()
            write(OnboardingView(model: model, step: step), "onboarding-\(step + 1)", dir, width: 560, height: 520)
        }
        // Модели распознавания на первом шаге: не скачаны и скачиваются.
        for downloading in [false, true] {
            let first = demoModel()
            first.permissions = AppModel.Permissions(microphone: true)
            first.models.language = first.settings.language
            first.models.known = true
            first.models.rows = [ModelRow(key: "silero-vad", label: "Silero VAD", purpose: "vad", required: true, size: 2_300_000, installed: true),
                                 ModelRow(key: "gigaam", label: "GigaAM v3", purpose: "ru", required: true, size: 1_050_000_000, installed: false, missingBytes: 1_050_000_000),
                                 ModelRow(key: "parakeet", label: "Parakeet", purpose: "en", required: true, size: 1_250_000_000, installed: false, missingBytes: 1_250_000_000)]
            if downloading {
                let key = first.models.missing.first?.key ?? "gigaam"
                first.models.start([key])
                first.models.progress[key] = ModelProgress(key: key, done: 420_000_000, total: 1_050_000_000)
            }
            write(OnboardingView(model: first, step: 0), downloading ? "onboarding-1-models-downloading" : "onboarding-1-models", dir, width: 560, height: 520)
            if !downloading {
                write(OnboardingView(model: first, step: 4), "onboarding-5-models", dir, width: 560, height: 520)
            }
        }
        // Шаг «Модель»: диктовка без модели, встречи на этом Mac — раскрыто «Настроить отдельно»,
        // Gemma качается.
        let split = demoModel()
        split.settings.meetingBackend = .mlx
        split.models.rows = [ModelRow(key: "gemma-4-e2b", label: "Gemma 4 E2B", purpose: "llm", required: false,
                                      size: 3_580_000_000, installed: false)]
        split.models.downloading = true
        split.models.progress["gemma-4-e2b"] = ModelProgress(key: "gemma-4-e2b", done: 1_250_000_000, total: 3_580_000_000)
        write(OnboardingView(model: split, step: 3), "onboarding-4-split", dir, width: 560, height: 520)
        // Доступ выдан на ходу: вставка включится после перезапуска.
        let relaunch = demoModel()
        relaunch.permissions = AppModel.Permissions(microphone: true, accessibility: true, postEvents: false)
        write(OnboardingView(model: relaunch, step: 1), "onboarding-2-relaunch", dir, width: 560, height: 520)
        // R3c: микрофон уже просили и не дали — предупреждение вместо нейтрального кружка.
        let denied = demoModel()
        denied.permissions = AppModel.Permissions()
        write(OnboardingView(model: denied, step: 0, asked: [.microphone]), "onboarding-1-denied", dir, width: 560, height: 520)
        // R3c: пробная диктовка удалась — «Получилось» и выделенное «Готово».
        let practiced = demoModel()
        practiced.doctor.checks = doctorAllGood()
        write(OnboardingView(model: practiced, step: 4, practice: L("Проверка связи, раз-два.", "Testing, one two.")),
              "onboarding-5-done", dir, width: 560, height: 520)
        renderAgentTools(to: dir)

        renderDoctor(to: dir)
        renderAgentVoice(to: dir)
        renderPolishExtras(to: dir)  // П6-А
        renderMeetingExtras(to: dir)
        renderMeetingSpeakers(to: dir)
        renderMeetingLive(to: dir)  // П6-Б
        renderMeetingAssist(to: dir)  // П7: M19, M9, W26
        renderGlossaryLearning(to: dir)
        renderVoiceIntents(to: dir)  // D6
        renderSettingsPanes(to: dir)  // П9-А: Настройки по разделам

        // Иконка — одна на все языки: в английском прогоне не перерисовываем.
        guard !english else { return }
        write(AppIconView(), "appicon-1024", dir, width: 1024, height: 1024, scale: 1, opaque: false)
        writeIconset(into: dir.appendingPathComponent("AppIcon.iconset"))
        let resources = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources")
        if fm.fileExists(atPath: URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Package.swift").path) {
            writeIconset(into: resources.appendingPathComponent("AppIcon.iconset"))
        }
    }

    // MARK: Рендер

    @MainActor
    static func write<V: View>(_ view: V, _ name: String, _ dir: URL, width: CGFloat, height: CGFloat? = nil,
                                       scale: CGFloat = 2, opaque: Bool = true, dark: Bool = false) {
        if bothThemes, !dark, opaque, !name.hasSuffix("-dark") {
            write(view, name + "-dark", dir, width: width, height: height, scale: scale, opaque: opaque, dark: true)
        }
        let content = view
            .frame(width: width, height: height)
            .tint(Palette.accent)
            .environment(\.mostikSnapshot, true)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, L10n.locale)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = opaque
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        // Динамические цвета палитры берут тему из текущего внешнего вида AppKit.
        var rendered: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            rendered = renderer.cgImage
        }
        guard let image = rendered else {
            print("не удалось отрисовать \(name)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = dir.appendingPathComponent(name + ".png")
        do {
            try data.write(to: url)
            print("\(name).png  \(image.width)×\(image.height)")
        } catch {
            print("не удалось записать \(url.path): \(error)")
        }
    }

    /// Все размеры, которые нужны `iconutil`.
    @MainActor
    private static func writeIconset(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for factor in [1, 2] {
                let px = base * factor
                let name = factor == 1 ? "icon_\(base)x\(base)" : "icon_\(base)x\(base)@2x"
                write(AppIconView(), name, dir, width: 1024, height: 1024, scale: CGFloat(px) / 1024, opaque: false)
            }
        }
    }

    /// HUD на подложке, похожей на рабочий стол: плавный градиент, чтобы было видно,
    /// что пилюля — полупрозрачный материал, а не белая заливка.
    @MainActor
    private static func hudStage<V: View>(_ view: V) -> some View {
        view
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(colors: [Color.dynamic(0xC9D6D0, 0x2F3A36), Color.dynamic(0xE6E1D6, 0x45403A)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    /// Окно меню-бара на подложке: виден его край и скругление.
    @MainActor
    private static func menuStage<V: View>(_ view: V, dark: Bool) -> some View {
        view
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.edgeStrong))
            .padding(8)
            .background(Color.dynamic(0xDDE3DF, 0x3A403D))
    }

    /// Идёт запись встречи: пометки, уровни, таймер.
    @MainActor
    static func liveMeetingModel() -> AppModel {
        let m = demoModel()
        let folder = URL(fileURLWithPath: "/tmp/mostik-demo/meetings")
        m.meetings.insert(AppModel.MeetingItem(id: "m0", title: L("Созвон с командой движка", "Engine team call"),
                                               startedAt: Date().addingTimeInterval(-754), duration: 754,
                                               state: .recording, folder: folder), at: 0)
        m.meetingElapsed = 754
        m.meetingMarks = [
            .init(at: 132, text: L("Бюджет на мониторы — до пятницы", "Monitor budget by Friday")),
            .init(at: 418, text: L("Решили: лимит сомнений пять", "Decided: doubt limit stays at five")),
            .init(at: 701, text: L("Вернуться к диаризации длинных файлов", "Revisit diarization on long files")),
        ]
        return m
    }

    // MARK: Демо-данные

    @MainActor
    static func demoModel() -> AppModel {
        let m = AppModel()
        let now = Date()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func at(_ dayOffset: Int, _ h: Int, _ min: Int) -> Date {
            let day = cal.date(byAdding: .day, value: dayOffset, to: today)!
            return cal.date(bySettingHour: h, minute: min, second: 0, of: day)!
        }

        m.engineStatus = .ready
        m.elapsed = 42
        m.meetingLive.voices = demoVoices
        m.levels = [0.12, 0.2, 0.35, 0.6, 0.82, 0.7, 0.5, 0.64, 0.9, 1.0, 0.76, 0.52,
                    0.4, 0.58, 0.72, 0.46, 0.3, 0.42, 0.66, 0.55, 0.34, 0.22, 0.3, 0.18]
        m.settings.projectPath = "/Users/demo/code/mostik"
        m.settings.language = L10n.isRussian ? "ru" : "en"  // по умолчанию язык Mac — снимки не зависят от машины
        m.settings.enginePython = "/Users/demo/code/mostik/engine/.venv/bin/python"
        m.settings.agentPolicy.forcedOn = ["dev.zed.Zed"]
        m.settings.agentPolicy.forcedOff = ["com.apple.Notes"]
        // Входы звука для строки «Микрофон» в Настройках (R3b).
        m.inputDevices = [InputDevice(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"),
                          InputDevice(id: 2, uid: "airpods-pro", name: "AirPods Pro")]
        m.inputDeviceID = 1
        m.permissions = AppModel.Permissions(microphone: true, accessibility: true, screenRecording: false)

        m.history = [
            HistoryEntry(id: "d1", createdAt: at(0, 16, 42),
                         text: L("Обнови parakeet_tdt в src/engine до версии 0.3, прогони тесты на длинных записях и покажи дифф. Если упадёт warm_mic, откати только его, остальное оставь.",
                                 "Bump parakeet_tdt in src/engine to 0.3, run the long-recording tests and show me the diff. If warm_mic fails, revert just that one and keep the rest."),
                         doubts: [Doubt(heard: L("паракит", "parakeet"), suggestion: "parakeet_tdt", context: L("обнови паракит в src engine", "bump parakeet in src engine")),
                                  Doubt(heard: L("ворм мик", "warm mike"), suggestion: "warm_mic", context: L("если упадёт ворм мик, откати", "if warm mike fails, revert"))],
                         corrections: [Correction(from: L("эс эр си энджин", "source engine"), to: "src/engine")],
                         language: L("ru", "en"), audioSeconds: 14.2, latencyMs: 780, appName: "Claude Code", agent: true,
                         audioPath: "/tmp/d1.wav", outcome: "inserted", verifier: "done"),
            HistoryEntry(id: "d2", createdAt: at(0, 15, 18),
                         text: "Refactor HistoryStore.prune so it streams lines instead of loading the whole file. Keep the public API.",
                         language: "en", audioSeconds: 9.8, latencyMs: 640, appName: "Cursor", agent: true,
                         audioPath: "/tmp/d2.wav"),
            HistoryEntry(id: "d3", createdAt: at(0, 13, 5),
                         text: L("Созвон по релизу перенесли на четверг, удобные слоты после обеда.",
                                 "The release call moved to Thursday; afternoon slots work best."),
                         audioSeconds: 5.1, latencyMs: 410, appName: "Telegram", agent: false),
            HistoryEntry(id: "d4", createdAt: at(0, 11, 47),
                         text: L("В DoubtBlock возьми лимит из настроек и покрой тестом случай с пустым suggestion.",
                                 "In DoubtBlock, read the limit from settings and add a test for an empty suggestion."),
                         doubts: [Doubt(heard: L("дабт блок", "doubt block"), suggestion: "DoubtBlock", context: L("в дабт блок возьми лимит", "in doubt block read the limit"))],
                         audioSeconds: 11.3, latencyMs: 820, appName: "Ghostty", agent: true,
                         audioPath: "/tmp/d4.wav"),
            HistoryEntry(id: "d5", createdAt: at(-1, 18, 30),
                         text: L("Посмотри, почему diarization падает на файлах длиннее часа. Начни с последнего журнала движка.",
                                 "Find out why diarization fails on files over an hour. Start with the latest engine log."),
                         doubts: [Doubt(heard: L("диаризейшн", "dire station"), suggestion: "diarization")],
                         audioSeconds: 16.0, latencyMs: 950, appName: "Ghostty", agent: true),
            HistoryEntry(id: "d6", createdAt: at(-1, 10, 12),
                         text: "Draft a short reply: thanks, I’ll send the benchmark numbers by Friday.",
                         language: "en", audioSeconds: 6.0, latencyMs: 380, appName: "Mail", agent: false,
                         outcome: "clipboard"),
            HistoryEntry(id: "d7", createdAt: at(-2, 17, 4),
                         text: L("Сделай ветку feature/warm-mic и вынеси прогрев микрофона в отдельный актор с таймаутом.",
                                 "Create a feature/warm-mic branch and move the mic warm-up into its own actor with a timeout."),
                         audioSeconds: 8.4, latencyMs: 700, appName: "Cursor", agent: true),
        ]

        // D2: у первой диктовки сырой текст отличается от вставленного.
        m.history[0].rawText = L("Обнови паракит в эс эр си энджин до версии ноль три, прогони тесты на длинных записях и покажи дифф. Если упадёт ворм мик, откати только его, остальное оставь.",
                                 "Bump parakeet in source engine to zero point three, run the long-recording tests and show me the diff. If warm mike fails, revert just that one and keep the rest.")
        m.history[1].rawText = m.history[1].text

        let folder = URL(fileURLWithPath: "/tmp/mostik-demo/meetings")
        m.meetings = [
            AppModel.MeetingItem(id: "m1", title: L("Планирование квартала", "Quarter planning"),
                                 startedAt: at(0, 17, 0), duration: 1460, state: .processing(MeetingProgressText.label(phase: "transcribe", model: "Whisper")),
                                 folder: folder, speakers: 0),
            AppModel.MeetingItem(id: "m2", title: L("Синк по словарю проекта", "Project glossary sync"),
                                 startedAt: at(0, 12, 0), duration: 1820, state: .done, folder: folder,
                                 transcriptPath: folder.appendingPathComponent("m2.md"), speakers: 3),
            AppModel.MeetingItem(id: "m3", title: L("Планирование спринта", "Sprint planning"),
                                 startedAt: at(-1, 11, 0), duration: 3180, state: .done, folder: folder, speakers: 5),
            AppModel.MeetingItem(id: "m4", title: L("Звонок с подрядчиком", "Vendor call"),
                                 startedAt: at(-2, 16, 30), duration: 940,
                                 state: .failed(L("Не хватило памяти для модели голосов", "Not enough memory for the voice model")),
                                 folder: folder),
        ]
        m.meetings[0].progress = 0.42
        m.meetingTranscripts["m2"] = [
            .init(id: 1, speaker: L("Анна", "Anna"), start: 4,
                  text: L("Начнём со словаря. Сейчас parakeet_tdt распознаётся как «паракит» примерно в каждой третьей диктовке.",
                          "Let’s start with the glossary. parakeet_tdt still comes out as “parakeet” in about every third dictation.")),
            .init(id: 10, speaker: "📌", start: 18,
                  text: L("> 📌 0:18 — Проверить «паракит» на свежей сборке", "> 📌 0:18 — Check “parakeet” on a fresh build")),
            .init(id: 2, speaker: L("Борис", "Boris"), start: 21,
                  text: L("Это лечится термином проекта. Если папка выбрана, имя модуля попадает в подсказку движку.",
                          "Project terms fix that. With a folder chosen, the module name goes into the engine hint.")),
            .init(id: 3, speaker: L("Анна", "Anna"), start: 38,
                  text: L("А для тех, кто пишет без проекта?", "And for people without a project?")),
            .init(id: 4, speaker: L("Вера", "Vera"), start: 44,
                  text: L("Тогда кнопка «Запомнить» в сомнениях. Одна правка — и слово в личном словаре.",
                          "Then the Remember button on a doubt. One fix and the word is in the personal glossary.")),
            .init(id: 11, speaker: "📌", start: 60,
                  text: L("> 📌 1:00 — Решили: лимит сомнений пять", "> 📌 1:00 — Decided: doubt limit stays at five")),
            .init(id: 5, speaker: L("Борис", "Boris"), start: 63,
                  text: L("Согласен. Лимит сомнений для агента оставим пять, больше он всё равно не переспросит.",
                          "Agreed. Keep the agent doubt limit at five; it won’t ask about more anyway.")),
        ]

        // S5: источники и термины с происхождением.
        m.currentProject = "/Users/demo/code/mostik"
        m.settings.calendarEnabled = true
        let scanned = now.addingTimeInterval(-2 * 3600 - 600)
        m.sources = [
            .init(kind: "repo", label: "mostik", path: "/Users/demo/code/mostik", scannedAt: scanned,
                  counts: ["identifier": 214, "tech": 38, "acronym": 17, "project": 6, "person": 3], total: 278, auto: true),
            .init(kind: "docs", label: L("Заметки по Mostik", "Mostik notes"), path: "/Users/demo/Documents/Notes/Mostik", scannedAt: scanned,
                  counts: ["person": 14, "project": 9, "tech": 21, "acronym": 8], total: 52),
            .init(kind: "calendar", label: L("Календарь", "Calendar"), scannedAt: now.addingTimeInterval(-1500),
                  counts: ["person": 11, "project": 4], total: 15),
            .init(kind: "personal", label: L("Личный словарь", "Personal glossary"), counts: ["tech": 4, "identifier": 3], total: 7),
        ]
        let inCal = L("календарь: ", "calendar: ")
        m.terms = [
            .init(term: "parakeet_tdt", kind: "identifier", origins: ["engine/asr/parakeet.py:14", "docs/bench.md:31", L("личный словарь", "personal glossary")]),
            .init(term: "DictationMachine", kind: "identifier", origins: ["Sources/MostikCore/DictationMachine.swift:4"]),
            .init(term: L("Анна Лебедева", "Anna Lebedeva"), kind: "person", origins: [inCal + L("Синк по словарю проекта", "Project glossary sync"), inCal + L("Планирование спринта", "Sprint planning")]),
            .init(term: "HistoryStore", kind: "identifier", origins: ["Sources/MostikCore/HistoryStore.swift:37", "Sources/Mostik/AppController.swift:61", "docs/architecture.md:88"]),
            .init(term: "GigaAM", kind: "tech", origins: ["docs/architecture.md:42", L("Notes/Mostik/модели.md:7", "Notes/Mostik/models.md:7")]),
            .init(term: L("Борис Ким", "Boris Kim"), kind: "person", origins: [inCal + L("Планирование квартала", "Quarter planning")]),
            .init(term: "VAD", kind: "acronym", origins: ["engine/vad.py:3", "docs/architecture.md:51"]),
            .init(term: L("Альфа", "Alpha"), kind: "project", origins: [L("Notes/Mostik/планы.md:12", "Notes/Mostik/plans.md:12"), inCal + L("Альфа: демо", "Alpha demo")]),
            .init(term: "warm_mic", kind: "identifier", origins: ["Sources/MostikKit/AudioCapture.swift:120", L("личный словарь", "personal glossary")]),
            .init(term: "EventKit", kind: "tech", origins: ["Sources/MostikKit/CalendarSource.swift:2"]),
            .init(term: L("Вера Соколова", "Vera Sokolova"), kind: "person", origins: [L("Notes/Mostik/встречи.md:3", "Notes/Mostik/meetings.md:3"), inCal + L("Синк по словарю проекта", "Project glossary sync")]),
            .init(term: "ASR", kind: "acronym", origins: ["docs/architecture.md:9", "engine/asr/__init__.py:1"]),
            .init(term: "diarize", kind: "identifier", origins: ["engine/meeting.py:204"]),
            .init(term: "pyannote", kind: "tech", origins: ["engine/requirements.txt:11"]),
            .init(term: "CATapDescription", kind: "identifier", origins: ["Sources/MostikKit/MeetingRecorder.swift:58"]),
            .init(term: L("Телемост", "Telemost"), kind: "project", origins: ["Sources/MostikKit/MeetingDetector.swift:19", inCal + L("Созвон в Телемосте", "Telemost call")]),
        ]

        m.glossary = [
            .init(canonical: "parakeet_tdt", aliases: L10n.isRussian ? ["паракит", "паракит тдт"] : ["parakeet", "parakeet tdt"], source: "personal"),
            .init(canonical: "DoubtBlock", aliases: [L("дабт блок", "doubt block")], source: "learned"),
            .init(canonical: "diarization", aliases: L10n.isRussian ? ["диаризация", "диаризейшн"] : ["dire station", "diary zation"], source: "personal"),
            .init(canonical: "Ghostty", aliases: [L("гости", "ghosty")], source: "learned"),
            .init(canonical: "HistoryStore", aliases: [L("хистори стор", "history store")], source: "learned"),
            .init(canonical: "SwiftPM", aliases: [L("свифт пи эм", "swift p m")], source: "personal"),
            .init(canonical: "warm_mic", aliases: L10n.isRussian ? ["ворм мик", "тёплый мик"] : ["warm mike", "worm mic"], source: "learned"),
        ]
        m.projectTerms = ["AppModel", "AppController", "DictationMachine", "DoubtBlock", "EngineMessage", "HistoryStore",
                          "HistoryEntry", "MostikSettings", "AgentAppPolicy", "FrontApp", "parakeet_tdt", "diarize",
                          "warm_mic", "src/engine", "verifier", "HUDView", "MenuBarContentView", "MostikPaths",
                          "prune()", "compose()", "isAgent()", "glossary.yaml", "history.jsonl", "pyannote",
                          "silero_vad", "CATapDescription", "iconutil", "SwiftPM"]
        m.doctor.checks = doctorAllGood()
        return m
    }
}
