import SwiftUI
import MostikCore

/// Снимки Настроек по разделам (5 разделов — решение автора): `settings-<раздел>.png`,
/// «Встречи» — `settings-meetings-pane` (имя `settings-meetings` занято снимком одной группы).
/// Кадр — вкладка Настроек без переключателя вкладок высотой под содержимое раздела, но не ниже её минимальной высоты 520 pt;
/// `main-settings-tab` — всё главное окно на вкладке Настроек.
/// Отдельно — «Приватность и данные» с раскрытым «Дополнительно», как его открывает «Нужны модели».
extension Snapshots {
    static func settingsPaneShot(_ pane: SettingsPane) -> (name: String, height: CGFloat) {
        switch pane {
        case .general: return ("settings-general", 720)
        case .text: return ("settings-text", 1190)
        case .meetings: return ("settings-meetings-pane", 720)
        case .agents: return ("settings-agents", 840)
        case .privacy: return ("settings-privacy", 1020)
        }
    }

    /// Каталог моделей как в манифесте движка (`engine/mostik_engine/models_manifest.json`).
    static func demoModelRows(llmInstalled: Bool = true) -> [ModelRow] {
        [
            ModelRow(key: "silero-vad", label: "Silero VAD", purpose: "vad", required: true, size: 2_327_554, installed: true),
            ModelRow(key: "gigaam-v3", label: "GigaAM v3 E2E RNNT", purpose: "ru", required: true, size: 892_410_829, installed: true),
            ModelRow(key: "whisper-turbo", label: "Whisper large-v3-turbo (MLX)", purpose: "en", required: true, size: 1_618_633_596, installed: true),
            ModelRow(key: "parakeet-v3", label: "Parakeet TDT 0.6B v3", purpose: "verifier-en", required: false, size: 2_549_805_955, installed: true),
            ModelRow(key: "gemma-4-e2b", label: "Gemma 4 E2B", purpose: "llm", required: false, size: 3_583_086_498,
                     installed: llmInstalled, missingBytes: llmInstalled ? 0 : 3_583_086_498),
        ]
    }

    @MainActor
    static func settingsDemo(_ pane: SettingsPane, reveal: String? = nil) -> AppModel {
        let model = demoModel()
        model.settingsPane = pane
        model.settingsReveal = reveal
        model.doctor.checks = doctorAllGood()
        model.updatesConfigurable = true
        model.agentTools.cliPath = L10n.neutralName ? "/Applications/App.app/Contents/MacOS/app"
                                                    : "/Applications/Mostik.app/Contents/MacOS/mostik"
        if L10n.neutralName {
            model.settings.projectPath = model.settings.projectPath.map { UIText.neutralize($0, russian: L10n.isRussian) }
            model.settings.enginePython = UIText.neutralize(model.settings.enginePython, russian: L10n.isRussian)
        }
        model.agentTools.agentFound = true
        model.models.update(demoModelRows())
        if pane == .text {
            model.settings.polish = PolishSettings(backend: .mlx, style: .business,
                                                   forcedOn: ["com.apple.mail"], forcedOff: ["ru.keepcoder.Telegram"])
            model.polishAvailable = ["claude": true, "mlx": true]
        }
        return model
    }

    @MainActor
    static func renderSettingsPanes(to dir: URL) {
        // Настройки — вкладка главного окна (B1): кадр всего окна с переключателем вкладок сверху.
        for dark in [false, true] {
            let model = settingsDemo(.general)
            model.selectedTab = .settings
            write(MainWindowView(model: model), "main-settings-tab" + (dark ? "-dark" : ""), dir,
                  width: 1080, height: 760, dark: dark)
        }
        for pane in SettingsPane.allCases {
            let shot = settingsPaneShot(pane)
            for dark in [false, true] {
                write(SettingsWindowView(model: settingsDemo(pane)), shot.name + (dark ? "-dark" : ""), dir,
                      width: 900, height: shot.height, dark: dark)
            }
        }
        // Проверка вёрстки (обрезанные строки, зазоры) в свёрнутых группах: только по MOSTIK_SNAPSHOT_SETTINGS_OPEN=1,
        // в docs/snapshots эти кадры не идут.
        if ProcessInfo.processInfo.environment["MOSTIK_SNAPSHOT_SETTINGS_OPEN"] == "1" {
            for (pane, reveal, name) in [(SettingsPane.general, "triggers", "general-triggers"), (.text, "voice", "text-voice"),
                                         (.text, "styles", "text-styles"), (.meetings, "more", "meetings-more"),
                                         (.agents, "more", "agents-more")] {
                write(SettingsWindowView(model: settingsDemo(pane, reveal: reveal)), "check-settings-" + name, dir,
                      width: 900, height: 2400)
            }
        }
        for dark in [false, true] {
            write(SettingsWindowView(model: settingsDemo(.privacy, reveal: SettingsRoute.advanced)),
                  "settings-privacy-advanced" + (dark ? "-dark" : ""), dir, width: 900, height: 2800, dark: dark)
        }
    }
}
