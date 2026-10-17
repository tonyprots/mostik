import Foundation

/// Запись встречи в строке меню (решение автора): плавающего окошка внизу экрана нет —
/// оно закрывало часть экрана. Значок строки меню показывает, что идёт запись, и время рядом;
/// меню открывается разделом «Запись встречи · 12:34» со всеми действиями записи и кнопкой «Завершить».
public enum MeetingMenu {
    public enum State: Equatable, Sendable {
        case off
        case recording
        case paused
    }

    public static func state(recording: Bool, paused: Bool) -> State {
        guard recording else { return .off }
        return paused ? .paused : .recording
    }

    /// Заголовок раздела: «Запись встречи · 12:34», на паузе — «Встреча на паузе · 12:34».
    public static func title(_ state: State, elapsed: Double) -> String? {
        switch state {
        case .off: return nil
        case .recording: return UIText.pick("Запись встречи", "Meeting recording") + " · " + MenuVoice.timer(elapsed)
        case .paused: return UIText.pick("Встреча на паузе", "Meeting paused") + " · " + MenuVoice.timer(elapsed)
        }
    }

    /// Кнопки раздела слева направо; последняя — «Завершить», главная.
    public enum Action: Hashable, Sendable {
        case pause
        case resume
        /// Тот же путь, что обычная остановка записи: запись сохраняется, дальше расшифровка и сводка.
        case finish
    }

    public static func actions(_ state: State) -> [Action] {
        switch state {
        case .off: return []
        case .recording: return [.pause, .finish]
        case .paused: return [.resume, .finish]
        }
    }

    public static func label(_ action: Action) -> String {
        switch action {
        case .pause: return UIText.pick("Пауза", "Pause")
        case .resume: return UIText.pick("Продолжить", "Resume")
        case .finish: return UIText.pick("Завершить", "Finish")
        }
    }

    public static func help(_ action: Action) -> String {
        switch action {
        case .pause: return UIText.pick("Приостановить запись встречи", "Pause the meeting recording")
        case .resume: return UIText.pick("Продолжить запись встречи", "Resume the meeting recording")
        case .finish: return UIText.pick("Остановить запись и сохранить встречу: расшифровка и сводка будут как обычно",
                                         "Stop recording and save the meeting; the transcript and summary follow as usual")
        }
    }

    /// Сколько последних пометок видно в разделе: больше — в окне встречи.
    public static let recentMarksLimit = 3

    public static func recentMarks<Mark>(_ marks: [Mark]) -> [Mark] {
        Array(marks.suffix(recentMarksLimit))
    }

    // «Только текст» (W15) из меню убран (отзыв автора, D4): без пояснения он непонятен,
    // а выбор «звук не хранить» объяснён в Настройках → Приватность → «Звук встреч».

    /// Переключатель слайдов звонка: включён — сколько снято, выключен — что это только на эту встречу.
    public static func framesTitle(on: Bool, count: Int) -> String {
        on ? UIText.pick("Снимать слайды звонка — снято \(count)", "Capture call slides · \(count) taken")
           : UIText.pick("Снимать слайды звонка — только эта встреча", "Capture call slides for this meeting")
    }
}

/// Значок в строке меню: диктовка важнее встречи — во время диктовки он «дышит» голосом, как обычно;
/// время встречи остаётся рядом. «Уменьшить движение» — значок статичен и без бегущего времени.
public enum MenuBarStatus {
    public enum Dictation: Equatable, Sendable {
        case idle
        case recording
        case transcribing
    }

    public struct Look: Equatable, Sendable {
        /// SF Symbol значка.
        public var symbol: String
        /// Время записи встречи рядом со значком; nil — только значок.
        public var timer: String?
        /// Заливка значка следует за голосом (только запись диктовки).
        public var breathes: Bool
        /// Подпись для VoiceOver.
        public var spoken: String

        public init(symbol: String, timer: String?, breathes: Bool, spoken: String) {
            self.symbol = symbol; self.timer = timer; self.breathes = breathes; self.spoken = spoken
        }
    }

    public static func look(dictation: Dictation, meeting: MeetingMenu.State, meetingElapsed: Double,
                            reduceMotion: Bool) -> Look {
        let timer = meeting == .off || reduceMotion ? nil : MenuVoice.timer(meetingElapsed)
        let meetingSpoken: String? = switch meeting {
        case .off: nil
        case .recording: UIText.pick("идёт запись встречи", "meeting recording") + ", " + MenuVoice.timer(meetingElapsed)
        case .paused: UIText.pick("встреча на паузе", "meeting paused") + ", " + MenuVoice.timer(meetingElapsed)
        }
        func spoken(_ base: String?) -> String {
            ["Mostik", base, meetingSpoken].compactMap { $0 }.joined(separator: ", ")
        }
        switch dictation {
        case .recording:
            return Look(symbol: "waveform.circle.fill", timer: timer, breathes: !reduceMotion,
                        spoken: spoken(UIText.pick("идёт диктовка", "dictating")))
        case .transcribing:
            return Look(symbol: "waveform.circle", timer: timer, breathes: false,
                        spoken: spoken(UIText.pick("расшифровка", "transcribing")))
        case .idle:
            switch meeting {
            case .off: return Look(symbol: "waveform", timer: nil, breathes: false, spoken: spoken(nil))
            case .recording: return Look(symbol: "record.circle.fill", timer: timer, breathes: false, spoken: spoken(nil))
            case .paused: return Look(symbol: "pause.circle", timer: timer, breathes: false, spoken: spoken(nil))
            }
        }
    }
}
