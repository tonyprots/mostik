import Foundation

/// Хук SessionStart для агентов (G4): что говорить агенту на старте сессии и когда.
/// Читает движок (`agent_api.hook_settings`) из `settings.json` → `agentContext`.
public struct AgentContextSettings: Codable, Equatable, Sendable {
    /// Хук отвечает агенту; выключено — молчит, даже если установлен.
    /// По умолчанию выключен (решение автора): подсказка уходит в облако агента.
    public var hookEnabled: Bool = false
    /// Переключатель «Подсказка агенту на старте» трогали руками в Настройках после смены умолчания.
    /// Раньше умолчание было «вкл», а файл настроек пишется целиком, поэтому `hookEnabled: true`
    /// в старом файле не отличить от прежнего умолчания. Без этой метки сохранённое значение
    /// не доверяется и действует новое умолчание «выкл»; явное «выкл» остаётся «выкл».
    public var hookExplicit: Bool = false
    /// Рабочие часы: с `workStart` до `workEnd` (не включая), локальное время.
    public var workStart: Int = 9
    public var workEnd: Int = 19
    /// В субботу и воскресенье тоже.
    public var weekends: Bool = false
    /// Имена участников встречи в подсказке агенту. По умолчанию выключено: агент отправляет
    /// свой контекст в облако своей модели, поэтому без явного выбора уходит только название встречи.
    public var includeAttendees: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = AgentContextSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hookExplicit = try c.decodeIfPresent(Bool.self, forKey: .hookExplicit) ?? d.hookExplicit
        let stored = try c.decodeIfPresent(Bool.self, forKey: .hookEnabled)
        hookEnabled = hookExplicit ? (stored ?? d.hookEnabled) : d.hookEnabled
        workStart = try c.decodeIfPresent(Int.self, forKey: .workStart) ?? d.workStart
        workEnd = try c.decodeIfPresent(Int.self, forKey: .workEnd) ?? d.workEnd
        weekends = try c.decodeIfPresent(Bool.self, forKey: .weekends) ?? d.weekends
        includeAttendees = try c.decodeIfPresent(Bool.self, forKey: .includeAttendees) ?? d.includeAttendees
    }
}

/// Для какого агента ставим скилл, хук и MCP.
public enum AgentTarget: String, CaseIterable, Sendable, Identifiable {
    case claudeCode, codex
    public var id: String { rawValue }
}

/// Один шаг установки: что и куда запишется. Показывается до записи.
public struct AgentInstallStep: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// Новый файл целиком (скилл). Прежний — в копию рядом.
        case writeFile
        /// Слияние хука в JSON (`settings.json`, `hooks.json`): чужие записи не трогаются.
        case mergeHook
        /// Блок в конец TOML (`config.toml` Codex), если такого раздела ещё нет.
        case appendToml
        /// Команду выполняет пользователь сам — приложение её только показывает.
        case manual
    }

    public var kind: Kind
    /// Абсолютный путь файла; у `manual` — пусто.
    public var path: String
    /// Одна строка: что произойдёт.
    public var summary: String
    /// Что именно запишется (фрагмент) или команда для `manual`.
    public var preview: String
    /// Для `writeFile` — полный текст файла.
    public var content: String?
    public var id: String { kind.rawValue + ":" + path + ":" + summary }

    public init(kind: Kind, path: String, summary: String, preview: String, content: String? = nil) {
        self.kind = kind; self.path = path; self.summary = summary; self.preview = preview; self.content = content
    }
}

public struct AgentInstallPlan: Equatable, Sendable {
    public var target: AgentTarget
    public var steps: [AgentInstallStep]
    public init(target: AgentTarget, steps: [AgentInstallStep]) { self.target = target; self.steps = steps }
    /// Шаги, которые пишет приложение (без ручных).
    public var writes: [AgentInstallStep] { steps.filter { $0.kind != .manual } }
}

/// CLI, MCP, скилл и хук для агентов (G1, G2, G4): пути, команды и чистое слияние конфигов.
/// Сама запись — в `AgentToolsController`; здесь только то, что можно проверить тестом.
public enum AgentIntegration {
    public static let skillName = "mostik"
    public static let mcpName = "mostik"
    /// Метка в команде хука: по ней находим и заменяем свою запись, не трогая чужие.
    public static let hookMarker = "hook session-start"

    /// `bin/mostik` внутри ресурсов приложения (или репозитория при `swift run`).
    public static func cliPath(resources: URL) -> String {
        resources.appendingPathComponent("bin/mostik").path
    }

    /// Одинарные кавычки для shell: путь с пробелами и кавычками остаётся одним словом.
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Симлинк в PATH — команда для пользователя; приложение само в систему не пишет.
    public static func symlinkCommand(cliPath: String) -> String {
        "mkdir -p ~/.local/bin && ln -sf \(shellQuote(cliPath)) ~/.local/bin/mostik"
    }

    public static func hookCommand(cliPath: String) -> String {
        "\(shellQuote(cliPath)) \(hookMarker)"
    }

    public static func claudeMCPCommand(cliPath: String) -> String {
        "claude mcp add --scope user \(mcpName) -- \(shellQuote(cliPath)) mcp"
    }

    public static func codexMCPBlock(cliPath: String) -> String {
        "[mcp_servers.\(mcpName)]\ncommand = \(tomlString(cliPath))\nargs = [\"mcp\"]\n"
    }

    static func tomlString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// Запись хука SessionStart: только старт сессии (`matcher: startup`), таймаут 5 с.
    public static func hookEntry(cliPath: String) -> [String: Any] {
        ["matcher": "startup", "hooks": [["type": "command", "command": hookCommand(cliPath: cliPath), "timeout": 5]]]
    }

    /// Что уходит агенту — показывается в листе установки до записи (приватность, п. 3).
    /// Агент (Claude Code, Codex) отправляет свой контекст в облако своей модели: всё, что Mostik
    /// отдал хуком или по MCP, уходит туда вместе с ним.
    public static func privacyNotice(includeAttendees: Bool) -> String {
        let hook = includeAttendees
            ? UIText.pick("Подсказка на старте сессии выключена, пока вы её не включите. Включённая, она передаёт агенту название ближайшей встречи, имена её участников (их можно выключить в Настройках) и словарь проекта.",
                          "The session-start hint stays off until you turn it on. When on, it gives the agent the title of the next meeting, its attendees’ names (you can turn attendees off in Settings) and the project glossary.")
            : UIText.pick("Подсказка на старте сессии выключена, пока вы её не включите. Включённая, она передаёт агенту название ближайшей встречи и словарь проекта. Имена участников не передаются — их можно включить отдельно в Настройках.",
                          "The session-start hint stays off until you turn it on. When on, it gives the agent the title of the next meeting and the project glossary. Attendees’ names are not sent — you can turn them on separately in Settings.")
        return hook + " " + UIText.pick(
            "По MCP и команде mostik агент сам читает встречи, расшифровки, календарь и участников, когда ему нужно. Всё это агент отправляет вместе со своим контекстом в облако своей модели (Anthropic для Claude Code, OpenAI для Codex) — Mostik это уже не контролирует.",
            "Through MCP and the mostik command the agent reads meetings, transcripts, the calendar and attendees itself when it needs them. The agent sends all of it with its own context to its model’s cloud (Anthropic for Claude Code, OpenAI for Codex) — Mostik no longer controls that.")
    }

    /// План установки. `home` — домашняя папка, `skill` — текст `SKILL.md` для этого агента.
    public static func plan(_ target: AgentTarget, home: URL, cliPath: String, skill: String) -> AgentInstallPlan {
        let hookPreview = prettyJSON(["hooks": ["SessionStart": [hookEntry(cliPath: cliPath)]]])
        switch target {
        case .claudeCode:
            let base = home.appendingPathComponent(".claude")
            return AgentInstallPlan(target: target, steps: [
                AgentInstallStep(kind: .writeFile, path: base.appendingPathComponent("skills/\(skillName)/SKILL.md").path,
                                 summary: UIText.pick("Скилл /mostik: справка перед встречей и разбор после", "Skill /mostik: pre-meeting brief and debrief"),
                                 preview: firstLines(skill, 6), content: skill),
                AgentInstallStep(kind: .mergeHook, path: base.appendingPathComponent("settings.json").path,
                                 summary: UIText.pick("Хук SessionStart: название встречи в ближайший час и словарь проекта", "SessionStart hook: title of a meeting within the hour and the project glossary"),
                                 preview: hookPreview),
                AgentInstallStep(kind: .manual, path: "",
                                 summary: UIText.pick("MCP-сервер Mostik — команда для Терминала", "Mostik MCP server — command for Terminal"),
                                 preview: claudeMCPCommand(cliPath: cliPath)),
            ])
        case .codex:
            let base = home.appendingPathComponent(".codex")
            return AgentInstallPlan(target: target, steps: [
                AgentInstallStep(kind: .writeFile, path: base.appendingPathComponent("skills/\(skillName)/SKILL.md").path,
                                 summary: UIText.pick("Скилл mostik: справка перед встречей и разбор после", "Skill mostik: pre-meeting brief and debrief"),
                                 preview: firstLines(skill, 6), content: skill),
                AgentInstallStep(kind: .mergeHook, path: base.appendingPathComponent("hooks.json").path,
                                 summary: UIText.pick("Хук SessionStart: название встречи в ближайший час и словарь проекта", "SessionStart hook: title of a meeting within the hour and the project glossary"),
                                 preview: hookPreview),
                AgentInstallStep(kind: .appendToml, path: base.appendingPathComponent("config.toml").path,
                                 summary: UIText.pick("MCP-сервер Mostik в конец config.toml", "Mostik MCP server appended to config.toml"),
                                 preview: codexMCPBlock(cliPath: cliPath)),
            ])
        }
    }

    public enum MergeError: Error, Equatable {
        /// Файл есть, но это не объект JSON — не трогаем, чтобы не испортить чужой конфиг.
        case notJSONObject
        case hooksNotObject
    }

    /// Слить хук в `settings.json` / `hooks.json`: своя прежняя запись (по `hookMarker` и `mostik`)
    /// заменяется, чужие записи и остальные ключи остаются как были. `nil` на входе — файла нет.
    public static func mergeHook(into data: Data?, cliPath: String) throws -> Data {
        var root: [String: Any] = [:]
        if let data, !data.isEmpty, !(String(data: data, encoding: .utf8) ?? "").allSatisfy(\.isWhitespace) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data), let object = parsed as? [String: Any] else {
                throw MergeError.notJSONObject
            }
            root = object
        }
        var hooks: [String: Any] = [:]
        if let existing = root["hooks"] {
            guard let object = existing as? [String: Any] else { throw MergeError.hooksNotObject }
            hooks = object
        }
        var entries = (hooks["SessionStart"] as? [Any]) ?? []
        entries = entries.compactMap { entry -> Any? in
            guard var group = entry as? [String: Any], let list = group["hooks"] as? [Any] else { return entry }
            let kept = list.filter { !isOwnHook($0) }
            if kept.count == list.count { return entry }
            if kept.isEmpty { return nil }
            group["hooks"] = kept
            return group
        }
        entries.append(hookEntry(cliPath: cliPath))
        hooks["SessionStart"] = entries
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Наш ли это хук: команда с `mostik` и `hook session-start`.
    public static func isOwnHook(_ hook: Any) -> Bool {
        guard let object = hook as? [String: Any], let command = object["command"] as? String else { return false }
        return command.contains(hookMarker) && command.contains("mostik")
    }

    /// Установлен ли наш хук в этом JSON.
    public static func hasHook(_ data: Data?) -> Bool {
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any], let entries = hooks["SessionStart"] as? [Any] else { return false }
        return entries.contains { entry in ((entry as? [String: Any])?["hooks"] as? [Any] ?? []).contains(where: isOwnHook) }
    }

    /// Дописать блок MCP в `config.toml`; `nil` — раздел `[mcp_servers.mostik]` уже есть, ничего не меняем.
    public static func appendCodexMCP(to toml: String?, cliPath: String) -> String? {
        let text = toml ?? ""
        if hasCodexMCP(text) { return nil }
        var out = text
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        return out + "# Mostik: MCP-сервер встреч и словаря (добавлено приложением Mostik)\n" + codexMCPBlock(cliPath: cliPath)
    }

    public static func hasCodexMCP(_ toml: String) -> Bool {
        toml.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "[mcp_servers.\(mcpName)]" || trimmed == "[mcp_servers.\"\(mcpName)\"]"
        }
    }

    /// Имя копии прежнего файла перед правкой: `settings.json.mostik-backup-20261011-1430`.
    public static func backupPath(for path: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return path + ".mostik-backup-" + formatter.string(from: now)
    }

    static func prettyJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func firstLines(_ text: String, _ count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.prefix(count).joined(separator: "\n") + (lines.count > count ? "\n…" : "")
    }
}
