import SwiftUI
import MostikCore

/// Снимки группы «Голос и агенты» (G5, G6, A1, A3, A5) и подтверждения установки хуков.
extension Snapshots {
    @MainActor
    static func renderAgentVoice(to dir: URL) {
        // Всё включено: tmux найден, две панели с агентами, озвучка ждёт установки хуков.
        for dark in [false, true] {
            let model = demoModel()
            var s = AgentVoiceSettings()
            s.tmuxPaste = true
            s.voiceSend = true
            s.announce = true
            model.settings.agentVoice = s
            model.agentVoice.tmuxPath = "/opt/homebrew/bin/tmux"
            model.agentVoice.panes = [
                .init(id: "%1", title: "frontend · claude · web-app", label: "frontend:0.1"),
                .init(id: "%4", title: "backend · codex · api-server", label: "backend:1.0"),
            ]
            write(agentVoiceStage(AgentVoiceSection(model: model)), "settings-agent-voice" + (dark ? "-dark" : ""), dir,
                  width: 688, dark: dark)
        }
        // По умолчанию и без tmux: адресная вставка недоступна, подпись объясняет почему.
        let off = demoModel()
        off.agentVoice.tmuxPath = nil
        off.agentVoice.hooksInstalled = false
        write(agentVoiceStage(AgentVoiceSection(model: off)), "settings-agent-voice-no-tmux", dir, width: 688)

        let installed = demoModel()
        installed.settings.agentVoice.announce = true
        installed.agentVoice.tmuxPath = "/opt/homebrew/bin/tmux"
        installed.agentVoice.hooksInstalled = true
        installed.agentVoice.hooksMessage = L("Готово. Новые сессии Claude Code подхватят хуки сами.",
                                              "Done. New Claude Code sessions pick up the hooks.")
        write(agentVoiceStage(AgentVoiceSection(model: installed)), "settings-agent-voice-hooks", dir, width: 688)

        let script = "/Users/demo/Library/Application Support/Mostik/hooks/mostik-notify.sh"
        let plan = AgentVoiceModel.HooksPlan(settingsPath: "/Users/demo/.claude/settings.json", scriptPath: script,
                                             preview: ClaudeHooks.preview(scriptPath: script),
                                             backupPath: "/Users/demo/.claude/settings.json.mostik-backup-2026-10-11T12-00-00Z")
        for dark in [false, true] {
            write(ClaudeHooksSheet(plan: plan, onInstall: {}, onCancel: {}), "agent-hooks-install" + (dark ? "-dark" : ""), dir,
                  width: 520, dark: dark)
        }
    }

    @MainActor
    private static func agentVoiceStage<V: View>(_ view: V) -> some View {
        view
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Palette.canvas)
    }
}
