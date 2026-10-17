import Foundation
import MostikCore

// П4: CLI, MCP, скилл и хук для агентов (G1, G2, G4) — чистое слияние конфигов.
// Конфиги синтетические; чужие хуки в них выдуманы.
func runAgentIntegrationTests() {
    let cli = "/Applications/Mostik App.app/Contents/Resources/bin/mostik"

    // MARK: команды и кавычки
    do {
        equal(AgentIntegration.cliPath(resources: URL(fileURLWithPath: "/A/Resources")), "/A/Resources/bin/mostik")
        equal(AgentIntegration.shellQuote("/a b/it's"), "'/a b/it'\\''s'")
        equal(AgentIntegration.hookCommand(cliPath: cli), "'\(cli)' hook session-start")
        equal(AgentIntegration.symlinkCommand(cliPath: cli),
              "mkdir -p ~/.local/bin && ln -sf '\(cli)' ~/.local/bin/mostik")
        equal(AgentIntegration.claudeMCPCommand(cliPath: cli), "claude mcp add --scope user mostik -- '\(cli)' mcp")
        equal(AgentIntegration.codexMCPBlock(cliPath: "/x/\"q\"\\b"),
              "[mcp_servers.mostik]\ncommand = \"/x/\\\"q\\\"\\\\b\"\nargs = [\"mcp\"]\n")
    }

    // MARK: слияние хука: пустой файл, чужие хуки, повторная установка
    do {
        let fresh = try? AgentIntegration.mergeHook(into: nil, cliPath: cli)
        check(fresh != nil && AgentIntegration.hasHook(fresh), "хук в новый файл")
        check(!AgentIntegration.hasHook(Data("{}".utf8)))

        let foreign = """
        {"permissions": {"allow": ["Bash(ls)"]}, "model": "x",
         "hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "/usr/bin/true", "timeout": 5}]}],
                   "Stop": [{"hooks": [{"type": "command", "command": "/opt/other-notify.sh"}]}]}}
        """
        let once = try? AgentIntegration.mergeHook(into: Data(foreign.utf8), cliPath: cli)
        let twice = try? AgentIntegration.mergeHook(into: once, cliPath: cli + "-moved")
        guard let twice, let root = (try? JSONSerialization.jsonObject(with: twice)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let start = hooks["SessionStart"] as? [[String: Any]] else { check(false, "слияние не разобрано"); return }
        equal(start.count, 2, "чужой хук + один наш, без дубля после повторной установки")
        let commands = start.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        equal(commands, ["/usr/bin/true", "'\(cli)-moved' hook session-start"], "новый путь заменил старый")
        equal(start.last?["matcher"] as? String, "startup")
        check((hooks["Stop"] as? [Any])?.count == 1, "чужой Stop не тронут")
        check((root["permissions"] as? [String: Any]) != nil && root["model"] as? String == "x", "остальные ключи на месте")

        // Наш хук в одной группе с чужим: чужой остаётся в группе.
        let shared = """
        {"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "/usr/bin/true"},
                                               {"type": "command", "command": "'/old/mostik' hook session-start"}]}]}}
        """
        let merged = (try? AgentIntegration.mergeHook(into: Data(shared.utf8), cliPath: cli)) ?? Data()
        let groups = (((try? JSONSerialization.jsonObject(with: merged)) as? [String: Any])?["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]] ?? []
        equal(groups.count, 2)
        equal((groups.first?["hooks"] as? [Any])?.count, 1, "старый наш снят, чужой в группе остался")
    }

    // MARK: битый конфиг не трогаем
    do {
        var failed: AgentIntegration.MergeError?
        do { _ = try AgentIntegration.mergeHook(into: Data("[1, 2]".utf8), cliPath: cli) } catch let e as AgentIntegration.MergeError { failed = e } catch {}
        equal(failed, .notJSONObject)
        failed = nil
        do { _ = try AgentIntegration.mergeHook(into: Data("{oops".utf8), cliPath: cli) } catch let e as AgentIntegration.MergeError { failed = e } catch {}
        equal(failed, .notJSONObject)
        failed = nil
        do { _ = try AgentIntegration.mergeHook(into: Data("{\"hooks\": []}".utf8), cliPath: cli) } catch let e as AgentIntegration.MergeError { failed = e } catch {}
        equal(failed, .hooksNotObject)
        check((try? AgentIntegration.mergeHook(into: Data("  \n".utf8), cliPath: cli)) != nil, "пустой файл = нет файла")
    }

    // MARK: config.toml Codex
    do {
        let base = "model = \"gpt\"\n\n[mcp_servers.other]\ncommand = \"x\""
        let appended = AgentIntegration.appendCodexMCP(to: base, cliPath: cli) ?? ""
        check(appended.hasPrefix(base + "\n\n# Mostik"), "дописано в конец, прежний текст цел")
        check(appended.hasSuffix(AgentIntegration.codexMCPBlock(cliPath: cli)))
        equal(AgentIntegration.appendCodexMCP(to: appended, cliPath: cli), nil, "второй раз не дописываем")
        equal(AgentIntegration.appendCodexMCP(to: "[mcp_servers.\"mostik\"]\n", cliPath: cli), nil)
        equal(AgentIntegration.appendCodexMCP(to: nil, cliPath: cli)?.hasPrefix("# Mostik"), true)
        check(!AgentIntegration.hasCodexMCP("[mcp_servers.mostik-old]\n"), "другое имя — не наше")
    }

    // MARK: план: что и куда
    do {
        let home = URL(fileURLWithPath: "/Users/test")
        let claude = AgentIntegration.plan(.claudeCode, home: home, cliPath: cli, skill: "---\nname: mostik\n---\nbody")
        equal(claude.steps.map(\.kind), [.writeFile, .mergeHook, .manual])
        equal(claude.writes.map(\.path), ["/Users/test/.claude/skills/mostik/SKILL.md", "/Users/test/.claude/settings.json"])
        equal(claude.steps[0].content, "---\nname: mostik\n---\nbody")
        check(claude.steps[1].preview.contains("hook session-start") && claude.steps[1].preview.contains("startup"))
        equal(claude.steps[2].preview, AgentIntegration.claudeMCPCommand(cliPath: cli))
        let codex = AgentIntegration.plan(.codex, home: home, cliPath: cli, skill: "s")
        equal(codex.writes.map(\.path), ["/Users/test/.codex/skills/mostik/SKILL.md", "/Users/test/.codex/hooks.json",
                                         "/Users/test/.codex/config.toml"])
        let stamp = AgentIntegration.backupPath(for: "/u/.claude/settings.json", now: Date(timeIntervalSince1970: 0))
        check(stamp.hasPrefix("/u/.claude/settings.json.mostik-backup-19700101-") || stamp.hasPrefix("/u/.claude/settings.json.mostik-backup-1969"))
    }

    // MARK: настройки хука в settings.json
    do {
        var settings = MostikSettings()
        equal(settings.agentContext, AgentContextSettings(), "по умолчанию выключен, 9–19, без выходных")
        check(!settings.agentContext.hookEnabled, "подсказка агенту на старте по умолчанию выключена (решение автора 2026-10-12)")
        settings.agentContext.hookEnabled = false
        settings.agentContext.workEnd = 21
        let data = (try? JSONEncoder().encode(settings)) ?? Data()
        let back = try? JSONDecoder().decode(MostikSettings.self, from: data)
        equal(back?.agentContext.hookEnabled, false)
        equal(back?.agentContext.workEnd, 21)
        let old = try? JSONDecoder().decode(MostikSettings.self, from: Data("{\"language\": \"en\"}".utf8))
        equal(old?.agentContext, AgentContextSettings(), "старый файл без раздела")
        let json = String(data: data, encoding: .utf8) ?? ""
        check(json.contains("\"agentContext\"") && json.contains("\"hookEnabled\""), "ключи, которые читает движок")

        // Миграция: старый файл хранит `hookEnabled: true` как прежнее умолчание — не доверяем ему.
        func decode(_ text: String) -> AgentContextSettings? {
            (try? JSONDecoder().decode(MostikSettings.self, from: Data(text.utf8)))?.agentContext
        }
        equal(decode(#"{"agentContext":{"hookEnabled":true,"workStart":9}}"#)?.hookEnabled, false,
              "прежнее умолчание «вкл» без метки — новое умолчание «выкл»")
        equal(decode(#"{"agentContext":{"hookEnabled":false}}"#)?.hookEnabled, false, "явное «выкл» остаётся")
        equal(decode(#"{"agentContext":{"hookEnabled":true,"hookExplicit":true}}"#)?.hookEnabled, true,
              "включено руками после перехода — остаётся включённым")
        var chosen = MostikSettings()
        chosen.agentContext.hookEnabled = true
        chosen.agentContext.hookExplicit = true
        let kept = (try? JSONEncoder().encode(chosen)).flatMap { try? JSONDecoder().decode(MostikSettings.self, from: $0) }
        equal(kept?.agentContext.hookEnabled, true, "выбор руками переживает сохранение")
    }
}
