import Foundation
import MostikCore

/// П7: вопросы по ходу встречи (M19) и подсказки (M9) — `engine/mostik_engine/meeting_questions.py`, `meeting_hints.py`.
extension EngineClient {
    public struct QuestionReply: Sendable {
        public var added: [MeetingQuestion]
        public var updated: [MeetingQuestion]
        /// Почему судья (локальная модель) работал или нет: `not_loaded`, `memory`, `timeout`…
        public var judgeReason: String?
        public var judgeAvailable: Bool
    }

    /// Строка живой расшифровки → новые вопросы и изменения статусов в `questions.json`.
    public func meetingQuestion(folder: URL, track: String, at: Double, text: String, judge: Bool = true) async throws -> QuestionReply {
        let reply = try await request("meeting_question", fields: [
            "folder": .string(folder.path), "track": .string(track), "at": .number(at), "text": .string(text),
            "judge": .bool(judge),
        ], timeout: 20)
        var available = false
        var reason: String?
        if case .object(let state)? = reply["judge"] {
            available = state["available"]?.boolValue ?? false
            reason = state["reason"]?.stringValue
        }
        return QuestionReply(added: MeetingQuestion.list(reply["questions"]), updated: MeetingQuestion.list(reply["updated"]),
                             judgeReason: reason, judgeAvailable: available)
    }

    /// Пересчёт статусов по готовой расшифровке; `closePending` — запись кончилась, ждущие → «нет ответа».
    public func meetingQuestionsFinalize(folder: URL, closePending: Bool) async throws -> [MeetingQuestion] {
        let reply = try await request("meeting_questions_finalize", fields: [
            "folder": .string(folder.path), "close_pending": .bool(closePending),
        ], timeout: 30)
        return MeetingQuestion.list(reply["items"])
    }

    /// Подсказка по своим источникам. Модель — только локальная и уже загруженная; `consent` — согласие на ИИ встреч.
    public func meetingHint(question: MeetingQuestion, folder: URL, sources: [String], project: String?,
                            consent: Bool) async throws -> MeetingHint? {
        var fields: [String: JSONValue] = [
            "question": .string(question.text), "question_id": .string(question.id), "folder": .string(folder.path),
            "sources": .array(sources.map { .string($0) }), "consent": .bool(consent),
        ]
        if let project { fields["project"] = .string(project) }
        let reply = try await request("meeting_hint", fields: fields, timeout: 40)
        return MeetingHint(id: question.id, payload: reply)
    }
}
