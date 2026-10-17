import Foundation
import SwiftUI
import MostikCore

/// Говорящие встреч (M14, M15): имена, реплики на проверку, подсказки и настройки голосовой памяти.
/// Своя модель, чтобы не сталкиваться с параллельными правками `AppModel`. Наполняет `SpeakersController`.
@MainActor
public final class MeetingSpeakersModel: ObservableObject {
    /// Разобранный `transcript.json` по id встречи.
    @Published public var byMeeting: [String: MeetingSpeakers] = [:]
    /// Модель голоса и люди голосовой памяти (без векторов).
    @Published public var status = VoiceMemoryStatus()
    /// Встречи, по которым ждём ответ движка.
    @Published public var busy: Set<String> = []
    /// Последняя ошибка или итог действия — строкой под панелью.
    @Published public var message: [String: String] = [:]
    /// Экран согласия голосовой памяти открыт.
    @Published public var consentShown = false

    public init() {}

    public func speakers(_ meeting: String) -> MeetingSpeakers { byMeeting[meeting] ?? MeetingSpeakers() }

    // Намерения.
    public var onRename: (_ meeting: String, _ label: String, _ name: String) -> Void = { _, _, _ in }
    public var onConfirm: (_ meeting: String, _ label: String) -> Void = { _, _ in }
    public var onReject: (_ meeting: String, _ label: String) -> Void = { _, _ in }
    /// «Убрать имя» (E1): метка снова «Собеседник N».
    public var onUnname: (_ meeting: String, _ label: String) -> Void = { _, _ in }
    /// «Объединить с…» (E2): все реплики `source` — говорящему `target`.
    public var onMerge: (_ meeting: String, _ source: String, _ target: String) -> Void = { _, _, _ in }
    /// Реплика на проверке: другому говорящему (`label`) или «верно» (nil).
    public var onSetTurn: (_ meeting: String, _ turn: Int, _ label: String?) -> Void = { _, _, _ in }
    /// Реплика на проверке — человеку по имени: тому, кто уже есть на встрече, или новому говорящему.
    public var onSetTurnName: (_ meeting: String, _ turn: Int, _ name: String) -> Void = { _, _, _ in }
    /// Включить после согласия / выключить.
    public var onSetEnabled: (Bool) -> Void = { _ in }
    public var onRenamePerson: (_ id: String, _ name: String) -> Void = { _, _ in }
    /// nil — забыть всех.
    public var onForget: (_ id: String?) -> Void = { _ in }
    public var onRefreshStatus: () -> Void = {}
}
