import SwiftUI
import MostikCore

/// Снимки группы «Агенты: CLI, MCP, скилл» (G1, G2, G4) и листа «что и куда запишется».
extension Snapshots {
    @MainActor
    static func renderAgentTools(to dir: URL) {
        let cli = "/Applications/Mostik.app/Contents/Resources/bin/mostik"
        // Ничего не установлено: команда для симлинка, две кнопки установки, рабочие часы.
        for dark in [false, true] {
            let model = demoModel()
            model.agentTools.cliPath = cli
            write(agentToolsStage(AgentToolsSection(model: model)), "settings-agent-tools" + (dark ? "-dark" : ""), dir,
                  width: 688, dark: dark)
        }
        // Установлено для Claude Code, симлинк есть, подсказка выключена.
        let done = demoModel()
        done.agentTools.cliPath = cli
        done.agentTools.cliLinked = true
        done.agentTools.installed = [.claudeCode: true, .codex: false]
        done.settings.agentContext.hookEnabled = false
        done.agentTools.message = L("Записано: ~/.claude/skills/mostik/SKILL.md, ~/.claude/settings.json. Осталось подключить MCP: claude mcp add --scope user mostik -- '\(cli)' mcp Новые сессии подхватят сами.",
                                    "Written: ~/.claude/skills/mostik/SKILL.md, ~/.claude/settings.json. One step left for MCP: claude mcp add --scope user mostik -- '\(cli)' mcp New sessions pick it up.")
        write(agentToolsStage(AgentToolsSection(model: done)), "settings-agent-tools-installed", dir, width: 688)

        let skill = "---\nname: mostik\ndescription: Meeting brief and debrief from Mostik…\n---\n\n# Mostik: brief before a meeting, debrief after\n\nMostik records meetings and dictation on this Mac…"
        let home = URL(fileURLWithPath: "/Users/demo")
        for (target, name) in [(AgentTarget.claudeCode, "agent-tools-install-claude"), (.codex, "agent-tools-install-codex")] {
            let plan = AgentIntegration.plan(target, home: home, cliPath: cli, skill: skill)
            var backups: [String: String] = [:]
            for step in plan.writes where step.kind != .writeFile {
                backups[step.path] = AgentIntegration.backupPath(for: step.path, now: Date(timeIntervalSince1970: 1_791_000_000))
            }
            for dark in [false, true] {
                write(AgentInstallSheet(pending: .init(plan: plan, backups: backups), onInstall: {}, onCancel: {}),
                      name + (dark ? "-dark" : ""), dir, width: 560, dark: dark)
            }
        }
    }

    @MainActor
    private static func agentToolsStage<V: View>(_ view: V) -> some View {
        view
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Palette.canvas)
    }
}
