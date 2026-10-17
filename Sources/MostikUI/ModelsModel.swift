import Foundation
import SwiftUI
import MostikCore

/// Модели распознавания и LLM (П8, пункт 5): что стоит, что качается, что не так.
/// Загрузку начинает только кнопка; без сети приложение показывает «Нужны модели», а не падает.
@MainActor
public final class ModelsModel: ObservableObject {
    @Published public var rows: [ModelRow] = []
    /// Язык диктовки: от него зависит, какие модели обязательны.
    @Published public var language: String = "ru"
    @Published public var downloading = false
    @Published public var progress: [String: ModelProgress] = [:]
    @Published public var error: String?
    /// Движок ответил на `models` хотя бы раз.
    @Published public var known = false

    public var onDownload: ([String]) -> Void = { _ in }
    public var onCancel: () -> Void = {}

    public init() {}

    /// Обязательные для текущего языка и не стоящие модели.
    public var missing: [ModelRow] { ModelCatalog.missing(rows, language: language) }
    /// Экран «Нужны модели»: движок ответил, а нужного нет.
    public var needed: Bool { known && !missing.isEmpty }

    public func update(_ rows: [ModelRow]) {
        self.rows = rows
        known = true
    }

    public func progressed(key: String, done: Int64, total: Int64) {
        progress[key] = ModelProgress(key: key, done: done, total: total)
    }

    /// Очередь загрузок: вторая «Скачать» встаёт в очередь, распознавание вытесняет LLM.
    public private(set) var queue = ModelDownloadQueue()

    /// Ключ качается сейчас или ждёт в очереди — кнопка «Скачать» у него не нужна.
    public func scheduled(_ key: String) -> Bool { queue.running.contains(key) || queue.pending.contains(key) }
    /// Ждёт своей очереди: другая загрузка ещё идёт.
    public func queued(_ key: String) -> Bool { queue.pending.contains(key) }

    /// Качается ли что-то из обязательного для языка: «Остановить» у карточки «Нужны модели» — только тогда.
    public var downloadingNeeded: Bool { missing.contains { queue.running.contains($0.key) } }

    public func finished(_ rows: [ModelRow]) {
        update(rows)
        progress = [:]
        error = nil
        if let next = queue.finished() {
            onDownload(next)
        } else {
            downloading = false
        }
    }

    /// `cancelled` — загрузка остановлена (своей кнопкой или ради более важной модели).
    public func failed(_ text: String, cancelled: Bool = false) {
        if let next = queue.failed(cancelled: cancelled) {
            onDownload(next)
            return
        }
        downloading = false
        error = text
    }

    public func start(_ keys: [String]) {
        let rowsByKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        switch queue.request(keys, priority: { ModelDownloadQueue.priority(rowsByKey[$0]) }) {
        case .start(let next):
            downloading = true
            error = nil
            onDownload(next)
        case .cancelRunning:
            onCancel()
        case .wait:
            break
        }
    }

    /// «Остановить» человеком: идущая загрузка встаёт, очередь не продолжается.
    public func cancel() {
        queue.userCancelled()
        onCancel()
    }
}
