import SwiftUI

/// Встреча, которую надо открыть на нужной реплике: подсказка по ходу встречи, меню «За сутки», архив.
public struct MeetingFocus: Equatable {
    public var meeting: String
    public var at: Double
    public var turn: Int?
    public init(meeting: String, at: Double, turn: Int? = nil) { self.meeting = meeting; self.at = at; self.turn = turn }
}

extension MeetingFocus {
    /// Реплика расшифровки, на которую указывает ссылка: ближайшая по времени начала (пометки не в счёт).
    func line(in lines: [AppModel.TranscriptLine], meeting id: String) -> Int? {
        guard meeting == id else { return nil }
        let speech = lines.filter { !$0.isMark }
        return speech.min { abs($0.start - at) < abs($1.start - at) }?.id
    }
}

extension View {
    /// Подсветка реплики, на которую ведёт ссылка (`MeetingFocus`).
    func meetingFocus(_ on: Bool) -> some View {
        background {
            if on {
                RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                    .fill(Palette.accentSoft)
                    .padding(.vertical, -6)
            }
        }
    }
}
