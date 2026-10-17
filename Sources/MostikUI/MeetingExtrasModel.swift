import Foundation
import SwiftUI
import MostikCore

/// Состояние встреч вокруг записи (M11–M13, W2, W9, W11, W13, W14). Своя модель, чтобы правки
/// параллельных фич не сталкивались в `AppModel`. Наполняет `MeetingFolderController`.
@MainActor
public final class MeetingExtrasModel: ObservableObject {
    /// Плавающая карточка поверх всех окон: одна за раз, важнее — отсчёт автоостановки.
    public enum Prompt: Equatable {
        /// W14: звонок держит микрофон 10 с, а мы не пишем.
        case callSuggestion(app: String)
        /// M13: встреча из календаря начинается через минуту.
        case reminder(UpcomingMeeting)
        /// M13: событие кончилось или звонок закрылся — остановка через `deadline`.
        case autoStop(deadline: Date)
        /// M12: «нет звука» или дорожка не перезапустилась.
        case warning(title: String, detail: String)
        /// микрофон звучит, звук системы — тишина: похоже на отказ в разрешении.
        case systemAudioMissing
    }

    @Published public var prompt: Prompt? = nil
    /// Ближайшая встреча календаря для карточки «Скоро» во вкладке «Встречи» (W2).
    @Published public var upcoming: UpcomingMeeting? = nil
    /// Заметки до встречи по id события (W2).
    @Published public var prep: [String: String] = [:]
    /// Повестка текущей записи: пункты становятся пометками M1 по нажатию.
    @Published public var agenda: [String] = []
    @Published public var agendaUsed: Set<String> = []
    /// Флаг «чувствительная» по id встречи (W13).
    @Published public var sensitive: Set<String> = []
    /// Метрики говорения по id встречи (W11) — только про «Я».
    @Published public var metrics: [String: SpeakingMetrics] = [:]
    /// Статус записи по id встречи: recovered / incomplete (M12).
    @Published public var recordingStatus: [String: String] = [:]
    /// Аудио встречи ушло в Корзину (W13).
    @Published public var audioTrashed: Set<String> = []
    /// Ссылка на звонок по id встречи (M13).
    @Published public var links: [String: String] = [:]
    /// Итог последнего экспорта фрагмента (W9): путь к `.md` или текст ошибки.
    @Published public var clipResult: ClipResult? = nil

    public struct ClipResult: Equatable {
        public var meeting: String
        public var folder: URL?
        public var message: String
        public var ok: Bool
        public init(meeting: String, folder: URL?, message: String, ok: Bool) {
            self.meeting = meeting; self.folder = folder; self.message = message; self.ok = ok
        }
    }

    public init() {}

    // Намерения.
    public var onRecordNow: () -> Void = {}
    /// «Локально»: записать и сразу пометить «Только на этом Mac» — без облака, агентов и скриптов.
    public var onRecordLocal: () -> Void = {}
    public var onDismissPrompt: () -> Void = {}
    /// «Открыть настройки» у предупреждения о звуке системы.
    public var onOpenSystemAudio: () -> Void = {}
    public var onCancelAutoStop: () -> Void = {}
    /// «Завершить сейчас» в отсчёте автоостановки: обычная остановка записи, не отмена.
    public var onFinishNow: () -> Void = {}
    public var onJoin: (String) -> Void = { _ in }
    public var onUseAgendaItem: (String) -> Void = { _ in }
    public var onSetPrep: (_ eventID: String, _ text: String) -> Void = { _, _ in }
    public var onSetSensitive: (_ meeting: String, _ value: Bool) -> Void = { _, _ in }
    /// Выделенные реплики встречи → `.m4a` + `.md` в `clips/`.
    public var onExportClip: (_ meeting: String, _ lines: [AppModel.TranscriptLine]) -> Void = { _, _ in }
    public var onRevealClip: (URL) -> Void = { _ in }
}
