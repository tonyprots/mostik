import Foundation
import MostikCore

/// Поиск по Настройкам (П9-А): каждая настройка — строка индекса с разделом и словами для поиска.
/// Технические слова (hooks, MCP, tmux, bundle id) живут здесь, а не в подписях: по ним
/// находят те, кто их знает, остальным они не мешают. Перечень сверяет SettingsInventoryTests.
struct SettingsIndex {
    struct Item: Identifiable {
        let id: String
        let pane: SettingsPane
        let title: String
        let keywords: String
        /// Свёрнутый блок раздела, где живёт настройка: при переходе из поиска он раскрывается.
        var reveal: String? = nil
    }

    static var items: [Item] {
        let adv = SettingsRoute.advanced
        return [
            // Основное
            Item(id: "myName", pane: .general, title: L("Имя и фамилия", "Your name"), keywords: "name имя фамилия я me zoom звонок участник"),
            Item(id: "holdKey", pane: .general, title: L("Клавиша записи", "Record key"), keywords: "hotkey option command fn клавиша хоткей shift latch защёлка ⇧"),
            Item(id: "handsFreeDoubleTap", pane: .general, title: L("Запись двойным нажатием", "Record with a double tap"), keywords: "hands-free без рук"),
            Item(id: "hudPosition", pane: .general, title: L("Окошко диктовки", "Dictation window"), keywords: "hud плашка место position drag перетащить вернуть"),
            Item(id: "microphone", pane: .general, title: L("Вход микрофона", "Microphone input"), keywords: "microphone микрофон input вход"),
            Item(id: "dictationVoiceProcessing", pane: .general, title: L("Шумоподавление", "Noise suppression"), keywords: "noise шум"),
            Item(id: "muteWhileRecording", pane: .general, title: L("Приглушать звук во время записи", "Mute sound while recording"), keywords: "mute music звук музыка"),
            Item(id: "language", pane: .general, title: L("Язык диктовки", "Dictation language"), keywords: "language русский english язык"),
            Item(id: "launchAtLogin", pane: .general, title: L("Запускать при входе в систему", "Open at login"), keywords: "login startup автозапуск вход запуск объекты входа"),
            Item(id: "autoLanguage", pane: .general, title: L("Русский и английский вперемешку", "Mixed Russian and English"), keywords: "auto language автоопределение определять язык"),
            Item(id: "toggleShortcut", pane: .general, title: L("Начать и остановить сочетанием", "Start and stop with a shortcut"), keywords: "⌥space option space toggle сочетание", reveal: "triggers"),
            Item(id: "mouseTrigger", pane: .general, title: L("Боковая кнопка мыши", "Side mouse button"), keywords: "mouse мышь", reveal: "triggers"),
            Item(id: "headsetTrigger", pane: .general, title: L("Кнопка гарнитуры", "Headset button"), keywords: "headset airpods гарнитура наушники", reveal: "triggers"),
            // Текст
            Item(id: "polishBackend", pane: .text, title: L("Чем причёсывать", "Polish with"), keywords: "claude gemma mlx облако cloud anthropic модель причёсывание"),
            Item(id: "polishStyle", pane: .text, title: L("Стиль", "Style"), keywords: "tone тон деловой business"),
            Item(id: "ruleLists", pane: .text, title: L("Списки из «во-первых, во-вторых»", "Lists from “first, second”"), keywords: "lists списки правила речи"),
            Item(id: "ruleNumbers", pane: .text, title: L("Числа цифрами", "Numbers as digits"), keywords: "numbers числа цифры правила речи"),
            Item(id: "voiceEdit", pane: .text, title: L("Голосовая правка", "Voice edit"), keywords: "edit правка выделение правый ⌘ command", reveal: "voice"),
            Item(id: "voiceIntents", pane: .text, title: L("Действия голосом", "Voice actions"), keywords: "voice commands команды календарь почта ⌃⌘K", reveal: "voice"),
            Item(id: "contextField", pane: .text, title: L("Текст вокруг курсора", "Text around the cursor"), keywords: "context контекст"),
            Item(id: "contextCloud", pane: .text, title: L("Отдавать контекст и в облако", "Send context to the cloud too"), keywords: "cloud облако"),
            Item(id: "scenarios", pane: .text, title: L("Приложения и сайты", "Apps and sites"), keywords: "bundle id сайт site scenario сценарии", reveal: "apps"),
            Item(id: "polishApps", pane: .text, title: L("Исключения: не причёсывать или всегда", "Exceptions: never or always polish"), keywords: "bundle id apps приложения исключения", reveal: "apps"),
            Item(id: "stylePacks", pane: .text, title: L("Свои стили", "Custom styles"), keywords: "prompt.md dictionary.txt styles стили ⌃⌘Y", reveal: "styles"),
            Item(id: "translateTone", pane: .text, title: L("Перевод на английский", "Translate to English"), keywords: "translate перевод ⌃⌘E", reveal: "styles"),
            Item(id: "taskMode", pane: .text, title: L("Мысли вслух → задача", "Thinking aloud → task"), keywords: "task задача ⌃⌘J", reveal: "styles"),
            Item(id: "tonePreview", pane: .text, title: L("Как это будет выглядеть", "How it will look"), keywords: "preview превью тон", reveal: "styles"),
            // Встречи
            Item(id: "meetingSuggest", pane: .meetings, title: L("Подсказывать о звонках", "Suggest recording calls"), keywords: "call звонок zoom напоминание reminder"),
            Item(id: "calendar", pane: .meetings, title: L("Календарь", "Calendar"), keywords: "calendar календарь"),
            Item(id: "calendarGoogle", pane: .meetings, title: L("Google Календарь", "Google Calendar"), keywords: "google gmail calendar account oauth календарь гугл аккаунт"),
            Item(id: "calendarYandex", pane: .meetings, title: L("Яндекс Календарь", "Yandex Calendar"), keywords: "yandex caldav calendar app password яндекс календарь пароль приложения"),
            Item(id: "calendarMac", pane: .meetings, title: L("Календарь macOS", "macOS Calendar"), keywords: "macos apple icloud exchange calendar eventkit календарь мак айклауд"),
            Item(id: "calendarCommand", pane: .meetings, title: L("Команда календаря", "Calendar command"), keywords: "calendar command external json exchange календарь команда внешний рабочий", reveal: "more"),
            Item(id: "meetingSlides", pane: .meetings, title: L("Снимать слайды звонка", "Capture call slides"), keywords: "slides слайды кадры frames экран screen презентация"),
            Item(id: "meetingAutoStop", pane: .meetings, title: L("Останавливать запись после встречи", "Stop recording after the meeting"), keywords: "stop стоп"),
            Item(id: "meetingAI", pane: .meetings, title: L("Заметки, сводка и задачи", "Notes, summary and tasks"), keywords: "summary сводка claude cloud"),
            Item(id: "voiceMemory", pane: .meetings, title: L("Узнавать собеседников по голосу", "Recognise people by voice"), keywords: "voiceprint голос память speakers"),
            Item(id: "archiveBrief", pane: .meetings, title: L("Справка перед встречей", "Pre-meeting brief"), keywords: "brief бриф архив", reveal: "more"),
            Item(id: "weeklyDigest", pane: .meetings, title: L("Итоги недели", "Weekly recap"), keywords: "digest неделя сводка", reveal: "more"),
            Item(id: "meetingHints", pane: .meetings, title: L("Подсказки во время встречи", "Hints during meetings"), keywords: "hints подсказки", reveal: "more"),
            Item(id: "meetingHotkey", pane: .meetings, title: L("Начать или остановить запись встречи", "Start or stop meeting recording"), keywords: "⌃⌘M hotkey shortcut сочетание", reveal: "more"),
            Item(id: "meetingVoiceProcessing", pane: .meetings, title: L("Шумо- и эхоподавление встречи", "Meeting noise and echo suppression"), keywords: "echo эхо", reveal: "more"),
            Item(id: "meetingHook", pane: .meetings, title: L("Своя команда после встречи", "Your command after a meeting"), keywords: "hook script shell команда obsidian", reveal: "more"),
            // Агенты
            Item(id: "claudeCode", pane: .agents, title: L("Подключение к Claude Code", "Claude Code connection"), keywords: "mcp skill hook скилл"),
            Item(id: "codex", pane: .agents, title: L("Подключение к Codex", "Codex connection"), keywords: "mcp skill config.toml"),
            Item(id: "voiceSend", pane: .agents, title: L("Отправлять голосом", "Send by voice"), keywords: "enter отправь send"),
            Item(id: "fileMentions", pane: .agents, title: L("Ссылки на файлы проекта", "Project file mentions"), keywords: "@file файл"),
            Item(id: "announce", pane: .agents, title: L("Озвучивать агента", "Speak agent updates"), keywords: "voice hooks озвучка голос premium"),
            Item(id: "midTurn", pane: .agents, title: L("Диктовать, пока агент занят", "Dictate while the agent is busy"), keywords: "queue hooks очередь"),
            Item(id: "tmuxPaste", pane: .agents, title: L("Вставлять в панель tmux", "Paste into a tmux pane"), keywords: "tmux terminal терминал", reveal: "more"),
            Item(id: "agentApps", pane: .agents, title: L("Приложения агентов", "Agent apps"), keywords: "bundle id cursor zed редактор", reveal: "more"),
            Item(id: "agentHint", pane: .agents, title: L("Ближайшая встреча — агенту на старте", "Your next meeting, to the agent at start"), keywords: "hook calendar календарь рабочие часы выходные участники attendees", reveal: "more"),
            Item(id: "mostikCommand", pane: .agents, title: L("Команда mostik в терминале", "The mostik command in a terminal"), keywords: "cli json spec", reveal: "more"),
            // Приватность и данные
            Item(id: "privacyLedger", pane: .privacy, title: L("Что уходит с этого Mac", "What leaves this Mac"), keywords: "privacy cloud облако приватность"),
            Item(id: "retentionDays", pane: .privacy, title: L("Хранить историю", "Keep history"), keywords: "history история дни"),
            Item(id: "keepAudio", pane: .privacy, title: L("Сохранять звук диктовок", "Keep dictation audio"), keywords: "audio звук запись"),
            Item(id: "meetingAudio", pane: .privacy, title: L("Звук встреч", "Meeting audio"), keywords: "trash корзина audio только текст text only"),
            Item(id: "permissions", pane: .privacy, title: L("Доступ: микрофон, универсальный доступ, звук собеседников, запись экрана", "Access: microphone, accessibility, other side’s audio, screen recording"), keywords: "permissions разрешения tcc"),
            Item(id: "updateFeed", pane: .privacy, title: L("Проверка обновлений", "Update checks"), keywords: "updates sparkle обновления проверять github"),
            Item(id: "verify", pane: .privacy, title: L("Второе распознавание терминов", "Second pass for terms"), keywords: "verify double-check перепроверка проверка второй движок", reveal: adv),
            Item(id: "warmMicrophone", pane: .privacy, title: L("Держать микрофон наготове", "Keep the microphone ready"), keywords: "microphone микрофон тёплый", reveal: adv),
            Item(id: "learnFromEdits", pane: .privacy, title: L("Учиться на правках", "Learn from edits"), keywords: "learn правки словарь", reveal: adv),
            Item(id: "autoProject", pane: .privacy, title: L("Определять проект сам", "Detect the project"), keywords: "project git проект", reveal: adv),
            Item(id: "projectPath", pane: .privacy, title: L("Папка проекта", "Project folder"), keywords: "folder папка словарь glossary", reveal: adv),
            Item(id: "contextClipboard", pane: .privacy, title: L("Буфер обмена как подсказка модели", "Clipboard as a hint for the model"), keywords: "clipboard буфер", reveal: adv),
            Item(id: "streamInsert", pane: .privacy, title: L("Вставлять по ходу причёсывания", "Insert while polishing"), keywords: "stream потоковая", reveal: adv),
            Item(id: "engine", pane: .privacy, title: L("Движок распознавания", "Recognition engine"), keywords: "engine python движок", reveal: adv),
            Item(id: "models", pane: .privacy, title: L("Модели", "Models"), keywords: "models download скачать модель parakeet whisper gemma", reveal: adv),
            Item(id: "doctor", pane: .privacy, title: L("Диагностика", "Diagnostics"), keywords: "doctor diagnostics логи logs проверка", reveal: adv),
        ]
    }

    /// Совпадение по подписи, разделу и словам, без учёта регистра и «ё».
    static func search(_ query: String) -> [Item] {
        let words = fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return items.filter { item in
            let haystack = fold(item.title + " " + item.pane.title + " " + item.keywords)
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
