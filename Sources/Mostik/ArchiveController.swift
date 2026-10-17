import Foundation
import MostikCore
import MostikKit
import MostikUI

/// Архив встреч (П6-Г): расписание внутри приложения, без launchd — бриф за 10 минут до встречи
/// календаря в `briefs/` (W1), недельная сводка в `digests/` (W6), карточки людей (W3) и встреч (M18).
/// Показывать их в окне негде: это файлы в папке данных и инструменты MCP для агентов.
@MainActor
final class ArchiveController {
    private let model: AppModel
    private let engine: () -> EngineClient
    private let calendar = CalendarSource.shared
    private var timer: Timer?
    /// События, к которым бриф уже собран в этом запуске.
    private var briefed: Set<String> = []
    private var lastUpkeep: Date = .distantPast

    private var settings: ArchiveSettings { model.settings.archive }
    private static let digestKeyDefault = "MostikArchiveLastWeekDigest"

    init(model: AppModel, engine: @escaping () -> EngineClient) {
        self.model = model
        self.engine = engine
        // Минутный тик: бриф ловит окно «за 10 минут», сводка — свой час. Первый тик — после старта движка.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: расписание

    private func tick() {
        guard model.engineStatus == .ready else { return }
        let now = Date()
        if settings.brief, model.settings.calendarEnabled, calendar.isReady,
           let due = ArchiveSchedule.briefDue(events: calendar.meetings(around: now, days: 1), now: now,
                                              lead: TimeInterval(settings.briefLeadMinutes * 60), shown: briefed) {
            briefed.insert(due.id)
            brief(for: due)
        }
        if settings.weeklyDigest,
           let key = ArchiveSchedule.digestDue(now: now, weekday: settings.digestWeekday, hour: settings.digestHour,
                                               lastKey: UserDefaults.standard.string(forKey: Self.digestKeyDefault)) {
            UserDefaults.standard.set(key, forKey: Self.digestKeyDefault)
            digest("week", series: nil, write: true)
        }
        // Раз в час — пересобрать устаревшие карточки встреч и людей (дёшево: только изменённые).
        if now.timeIntervalSince(lastUpkeep) > 3600 {
            lastUpkeep = now
            let client = engine()
            Task {
                try? await client.archiveCards()
                _ = try? await client.archivePeople(write: true)
            }
        }
    }

    /// Бриф к встрече — файл в `briefs/`.
    private func brief(for event: CalendarEvent) {
        let client = engine()
        Task { _ = try? await client.archiveBrief(event: event, write: true) }
    }

    /// Сводка — файл в `digests/`.
    private func digest(_ kind: String, series: String?, write: Bool) {
        let client = engine()
        Task { _ = try? await client.archiveDigest(kind: kind, series: series, write: write) }
    }
}
