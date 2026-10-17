import Foundation
import MostikCore
import MostikKit
import MostikUI

/// CLI, MCP, скилл и хук для агентов (G1, G2, G4).
///
/// Установка — только по кнопке и после листа «что и куда»: скилл в `~/.claude/skills` или
/// `~/.codex/skills`, хук SessionStart в `settings.json` / `hooks.json`, MCP в `config.toml`
/// Codex. Для Claude Code MCP ставится командой `claude mcp add`, её пользователь запускает сам.
/// Симлинк `mostik` в PATH приложение не создаёт — только показывает команду.
/// Слияние конфигов — `AgentIntegration` (MostikCore, с тестами); здесь файлы и копии.
@MainActor
final class AgentToolsController {
    private let model: AppModel
    private let fm = FileManager.default

    init(model: AppModel) {
        self.model = model
        let tools = model.agentTools
        tools.cliPath = cliPath
        tools.onRefresh = { [weak self] in self?.refresh() }
        tools.onPrepare = { [weak self] target in self?.prepare(target) }
        tools.onInstall = { [weak self] in self?.install() }
    }

    func start() { refresh() }

    // MARK: пути

    private var home: URL { fm.homeDirectoryForCurrentUser }

    /// Ресурсы приложения, где лежат `bin/mostik` и `integrations/`; в отладке — корень репозитория.
    private var resources: URL {
        if let res = Bundle.main.resourceURL, fm.fileExists(atPath: res.appendingPathComponent("bin/mostik").path) {
            return res
        }
        // Только dev-сборка знает репозиторий; в релизе путей к машине сборщика нет (П8, пункт 1).
        return EngineLocator.devRepoRoot() ?? Bundle.main.resourceURL ?? URL(fileURLWithPath: "/")
    }

    private var cliPath: String { AgentIntegration.cliPath(resources: resources) }

    private func skillText(_ target: AgentTarget) -> String? {
        let folder = target == .claudeCode ? "claude-code" : "codex"
        let url = resources.appendingPathComponent("integrations/\(folder)/skills/\(AgentIntegration.skillName)/SKILL.md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: состояние

    func refresh() {
        let tools = model.agentTools
        tools.cliPath = cliPath
        let link = home.appendingPathComponent(".local/bin/mostik").path
        let target = (try? fm.destinationOfSymbolicLink(atPath: link)).map {
            $0.hasPrefix("/") ? $0 : URL(fileURLWithPath: link).deletingLastPathComponent().appendingPathComponent($0).path
        }
        tools.cliLinked = target.map { URL(fileURLWithPath: $0).standardizedFileURL.path == URL(fileURLWithPath: cliPath).standardizedFileURL.path } ?? false
        var installed: [AgentTarget: Bool] = [:]
        for agent in AgentTarget.allCases {
            let plan = AgentIntegration.plan(agent, home: home, cliPath: cliPath, skill: "")
            installed[agent] = plan.writes.allSatisfy { step in
                switch step.kind {
                case .writeFile: return fm.fileExists(atPath: step.path)
                case .mergeHook: return AgentIntegration.hasHook(try? Data(contentsOf: URL(fileURLWithPath: step.path)))
                case .appendToml: return AgentIntegration.hasCodexMCP((try? String(contentsOfFile: step.path, encoding: .utf8)) ?? "")
                case .manual: return true
                }
            }
        }
        tools.installed = installed
        tools.agentFound = [".claude", ".codex"].contains { fm.fileExists(atPath: home.appendingPathComponent($0).path) }
    }

    // MARK: установка

    private func prepare(_ target: AgentTarget) {
        let ru = L10n.isRussian
        let tools = model.agentTools
        guard fm.isExecutableFile(atPath: cliPath), let skill = skillText(target) else {
            tools.message = ru ? "В сборке нет bin/mostik или файлов команды /mostik — пересоберите приложение (scripts/bundle.sh)."
                               : "bin/mostik or the skill files are missing from the build — rebuild the app (scripts/bundle.sh)."
            return
        }
        let plan = AgentIntegration.plan(target, home: home, cliPath: cliPath, skill: skill)
        // Конфиг, который не разобрать, не трогаем: сразу говорим, а не после «Записать».
        for step in plan.writes where step.kind == .mergeHook {
            let data = try? Data(contentsOf: URL(fileURLWithPath: step.path))
            if (try? AgentIntegration.mergeHook(into: data, cliPath: cliPath)) == nil {
                tools.message = (ru ? "Файл не разобрать как JSON-объект, он не тронут: " : "Not a JSON object, left untouched: ")
                    + NSString(string: step.path).abbreviatingWithTildeInPath
                return
            }
        }
        let now = Date()
        var backups: [String: String] = [:]
        for step in plan.writes where fm.fileExists(atPath: step.path) {
            backups[step.path] = AgentIntegration.backupPath(for: step.path, now: now)
        }
        tools.message = nil
        tools.pending = .init(plan: plan, backups: backups)
    }

    private func install() {
        let ru = L10n.isRussian
        let tools = model.agentTools
        guard let pending = tools.pending else { return }
        tools.pending = nil
        var written: [String] = []
        do {
            for step in pending.plan.writes {
                let url = URL(fileURLWithPath: step.path)
                let current = try? Data(contentsOf: url)
                let next: Data?
                switch step.kind {
                case .writeFile:
                    let data = Data((step.content ?? "").utf8)
                    next = current == data ? nil : data
                case .mergeHook:
                    next = try AgentIntegration.mergeHook(into: current, cliPath: cliPath)
                case .appendToml:
                    next = AgentIntegration.appendCodexMCP(to: current.flatMap { String(data: $0, encoding: .utf8) }, cliPath: cliPath)
                        .map { Data($0.utf8) }
                case .manual:
                    next = nil
                }
                guard let next else { continue }
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if current != nil, let backup = pending.backups[step.path], !fm.fileExists(atPath: backup) {
                    try fm.copyItem(at: url, to: URL(fileURLWithPath: backup))
                }
                try next.write(to: url, options: .atomic)
                written.append(NSString(string: step.path).abbreviatingWithTildeInPath)
            }
            let manual = pending.plan.steps.first { $0.kind == .manual }
            var text = written.isEmpty ? (ru ? "Всё уже было установлено." : "Everything was already installed.")
                                       : (ru ? "Записано: " : "Written: ") + written.joined(separator: ", ") + "."
            if let manual {
                text += ru ? " Осталось открыть агенту доступ к встречам: \(manual.preview)" : " One step left for meeting access: \(manual.preview)"
            }
            text += ru ? " Новые сессии подхватят сами." : " New sessions pick it up."
            tools.message = text
        } catch {
            tools.message = (ru ? "Не удалось записать: " : "Couldn’t write: ") + error.localizedDescription
                + (written.isEmpty ? "" : (ru ? " Уже записано: " : " Already written: ") + written.joined(separator: ", "))
        }
        refresh()
    }
}
