import Foundation
import MostikCore
import MostikKit
import MostikUI

/// Модели по кнопке (П8, пункт 5): статус из движка, загрузка с ходом и ошибкой, повтор рукопожатия
/// после установки. Движок сам ничего не качает — только эта кнопка.
@MainActor
final class ModelsController {
    private let model: AppModel
    private let engine: () -> EngineClient
    /// Обязательные модели встали — `AppController` повторяет рукопожатие и прогрев.
    var onInstalled: () -> Void = {}
    /// Встали модели разделения по голосам — обновить `hello.diarization`.
    var onDiarizationInstalled: () -> Void = {}

    init(model: AppModel, engine: @escaping () -> EngineClient) {
        self.model = model
        self.engine = engine
        model.models.onDownload = { [weak self] keys in self?.download(keys) }
        model.models.onCancel = { [weak self] in
            guard let self else { return }
            Task { await self.engine().cancelModelDownload() }
        }
    }

    /// Чего не хватает для диктовки на `language`; пусто — можно греть модели.
    /// Старый движок без команды `models` — считаем, что всё на месте (как раньше).
    func refresh(language: String) async -> [ModelRow] {
        model.models.language = language
        guard let rows = try? await engine().models() else { return [] }
        model.models.update(rows)
        return model.models.missing
    }

    /// Текст статуса движка, пока моделей нет: что нужно и где скачать.
    func blockedText(_ missing: [ModelRow]) -> String {
        let size = ModelCatalog.size(ModelCatalog.bytesToDownload(missing), russian: L10n.isRussian)
        return L10n.isRussian
            ? "Нужны модели (\(size)) — «Скачать» на главном экране или в Настройках → Приватность и данные → Дополнительно"
            : "Models needed (\(size)) — press Download on the main screen or in Settings → Privacy & Data → Advanced"
    }

    /// `models_progress` → полоса; true — событие наше.
    func progress(task: String, done: Int, total: Int) -> Bool {
        guard task.hasPrefix(ModelProgress.taskPrefix) else { return false }
        let key = String(task.dropFirst(ModelProgress.taskPrefix.count))
        model.models.progressed(key: key, done: Int64(done), total: Int64(total))
        return true
    }

    private func download(_ keys: [String]) {
        let wasMissing = !model.models.missing.isEmpty
        Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await self.engine().downloadModels(keys: keys)
                self.model.models.finished(rows)
                if wasMissing, self.model.models.missing.isEmpty { self.onInstalled() }
                if rows.contains(where: { $0.purpose == "diarization" && $0.installed && keys.contains($0.key) }) {
                    self.onDiarizationInstalled()
                }
            } catch EngineError.engine(let code, let message) {
                self.model.models.failed(ModelCatalog.errorText(code: code, message: message, russian: L10n.isRussian),
                                         cancelled: code == "models_cancelled")
                if let rows = try? await self.engine().models() { self.model.models.update(rows) }
            } catch {
                self.model.models.failed(error.localizedDescription)
            }
        }
    }
}
