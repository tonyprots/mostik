import AppKit
import SwiftUI
import MostikCore

/// Встреча по ходу записи и ремонт после (П6-Б): живая расшифровка (W10), «только текст» (W15),
/// продолжение записи (W16), ремонт говорящих (W17), цитата при наведении (W18),
/// предупреждение участникам (W19, W20), ⌃⌘M и автостарт (W24), выбор голоса (A1).
/// Своя модель, чтобы не толкаться в `AppModel` с соседними фичами.
@MainActor
public final class MeetingLiveModel: ObservableObject {
    /// Что сейчас звучит: фрагмент встречи `[start, end)`.
    public struct Playing: Equatable {
        public var meeting: String
        public var start: Double
        public var end: Double
        public init(meeting: String, start: Double, end: Double) { self.meeting = meeting; self.start = start; self.end = end }
    }

    // MARK: W10, W15 — идущая запись

    /// Строки живой расшифровки текущей записи.
    @Published public var transcript = LiveTranscript()
    /// Расшифровка по ходу недоступна или отстала: показать под строками.
    @Published public var liveNote: String?
    /// «Только текст» для текущей (или следующей) записи: звук после расшифровки не сохранится.
    @Published public var textOnly = false

    // MARK: W16 — продолжить

    /// Встречи, которые можно продолжить: не пишутся, аудио на месте.
    @Published public var continuable: Set<String> = []

    // MARK: W17, W18 — ремонт и прослушивание

    /// Реплики с `id` и меткой — по `MeetingItem.id`.
    @Published public var turns: [String: [TurnRef]] = [:]
    /// Фильтр расшифровки по говорящему (видимое имя) — по `MeetingItem.id`.
    @Published public var speakerFilter: [String: String] = [:]
    @Published public var playing: Playing?
    /// Время, на которое указала цитата сводки (W18): «Слушать с 12:34».
    @Published public var cue: [String: Double] = [:]
    /// Ответ ремонта: «Перенесено 4 реплики» или ошибка.
    @Published public var repairNote: [String: String] = [:]

    // MARK: W24, A1

    /// ⌃⌘M зарегистрирован (сочетание может быть занято другим приложением).
    @Published public var hotkeyActive = false
    @Published public var voices: [SystemVoiceInfo] = []

    public init() {}

    // MARK: Намерения

    public var onToggleTextOnly: () -> Void = {}
    public var onContinue: (String) -> Void = { _ in }
    /// Прослушать `[start, end)`; `track` — `mic`/`system`, nil — обе дорожки.
    public var onPlay: (_ meeting: String, _ start: Double, _ end: Double, _ track: String?) -> Void = { _, _, _, _ in }
    public var onStopPlaying: () -> Void = {}
    public var onReassignTurn: (_ meeting: String, _ turn: Int, _ label: String) -> Void = { _, _, _ in }
    public var onMergeLabel: (_ meeting: String, _ source: String, _ target: String) -> Void = { _, _, _ in }
    /// Открыть в почте черновик предупреждения (W20). Ничего не отправляется.
    public var onWarnParticipants: (UpcomingMeeting) -> Void = { _ in }
    /// Послушать голос: идентификатор и фраза.
    public var onPreviewVoice: (_ voice: String, _ sample: String) -> Void = { _, _ in }
    public var onRefreshVoices: () -> Void = {}

    // MARK: Помощники видов

    /// Текст живой расшифровки для буфера обмена.
    public var plainText: String { transcript.plainText(russian: L10n.isRussian) }

    public func turn(for line: AppModel.TranscriptLine, meeting: String) -> TurnRef? {
        TurnRef.find(turns[meeting] ?? [], start: line.start, speaker: line.speaker)
    }

    public func isHidden(_ line: AppModel.TranscriptLine, meeting: String) -> Bool {
        guard let filter = speakerFilter[meeting], !line.isMark else { return false }
        return line.speaker != filter
    }

    /// Прослушать реплику: от начала до начала следующей (или +15 с), своя дорожка.
    public func playLine(_ line: AppModel.TranscriptLine, meeting: String, next: Double?) {
        let ref = turn(for: line, meeting: meeting)
        let end = ref?.end ?? min(next ?? line.start + 15, line.start + 60)
        let track = ref?.source ?? (line.speaker == LiveTranscript.speaker("mic", russian: true)
                                    || line.speaker == LiveTranscript.speaker("mic", russian: false) ? "mic" : "system")
        onPlay(meeting, line.start, max(end, line.start + 1), track)
    }
}

@MainActor
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
