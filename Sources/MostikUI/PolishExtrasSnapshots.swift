import SwiftUI
import MostikCore

/// Снимки П6-А: правила речи, контекст, сценарии, превью тона, стили-файлы, очередь агенту.
extension Snapshots {
    @MainActor
    static func renderPolishExtras(to dir: URL) {
        for dark in [false, true] {
            let model = demoModel()
            var p = PolishSettings(backend: .mlx, style: .plain)
            p.rules = SpeechRuleSettings(commands: true, scratch: true, lists: true, numbers: true)
            p.scenarios = [
                Scenario(id: "a", name: "Slack", apps: ["com.tinyspeck.slackmacgap"], hosts: ["app.slack.com"], style: .plain,
                         autoEnter: true),
                Scenario(id: "b", name: L("Почта по-английски", "Mail in English"), hosts: ["mail.google.com"],
                         translate: PolishTranslate(to: "en", tone: .business)),
            ]
            p.pack = "pismo-kollegam"
            p.streamInsert = true
            model.settings.polish = p
            model.settings.agentVoice.midTurn = true
            model.polishExtras.packs = [StylePackInfo(id: "pismo-kollegam", name: L("Письмо коллегам", "Note to colleagues"),
                                                      terms: 2, replacements: 1)]
            model.polishExtras.pendingMode = .task
            write(stage(PolishExtrasSection(model: model)), "settings-polish-extras" + (dark ? "-dark" : ""), dir,
                  width: 688, dark: dark)
        }
        // По умолчанию: причёсывание выключено, сценариев нет, очередь выключена.
        write(stage(PolishExtrasSection(model: demoModel())), "settings-polish-extras-default", dir, width: 688)

        let script = "/Users/demo/Library/Application Support/Mostik/hooks/mostik-queue.sh"
        let plan = AgentVoiceModel.HooksPlan(settingsPath: "/Users/demo/.claude/settings.json", scriptPath: script,
                                             preview: QueueHooks.preview(scriptPath: script),
                                             backupPath: "/Users/demo/.claude/settings.json.mostik-backup-2026-10-11T12-00-00Z")
        for dark in [false, true] {
            write(QueueHooksSheet(plan: plan, onInstall: {}, onCancel: {}), "agent-queue-hooks-install" + (dark ? "-dark" : ""), dir,
                  width: 520, dark: dark)
        }
    }

    @MainActor
    private static func stage<V: View>(_ view: V) -> some View {
        view
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Palette.canvas)
    }
}
