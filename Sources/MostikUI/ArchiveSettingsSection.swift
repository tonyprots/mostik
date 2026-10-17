import SwiftUI
import MostikCore

/// Архив встреч (П6-Г): справка перед встречей (W1) и итоги недели (W6) — в «Встречи → Ещё».
/// Всё работает локально внутри приложения, без launchd; встречи «только на этом Mac» не участвуют.
/// День и час итогов — умолчание без контрола (решение автора): пятница, 17:00.
struct ArchiveSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormToggle(title: L("Справка перед встречей", "Pre-meeting brief"),
                       hint: model.settings.calendarEnabled ? L("О чём договорились в прошлый раз с теми же людьми — за 10 минут до начала.",
                                                                "What you agreed with the same people last time, 10 minutes ahead.")
                                                            : L("Нужен календарь — он включается выше.", "Needs the calendar, turned on above."),
                       details: L("За 10 минут до встречи из календаря: на чём остановились, открытые обещания и решения прошлых встреч с теми же людьми. Справка сохраняется файлом в папке briefs.",
                                  "10 minutes before a calendar meeting: where you left off, open promises and past decisions with the same people. Saved as a file in the briefs folder."),
                       warning: !model.settings.calendarEnabled,
                       isOn: bind(\.archive.brief))
            FormDivider()
            FormToggle(title: L("Итоги недели", "Weekly recap"),
                       hint: L("Темы, решения и открытые поручения — по пятницам в 17:00.", "Topics, decisions and open tasks, Fridays at 5 PM."),
                       details: L("Темы, решения и открытые поручения недели — файлом в папке digests. Пропущенный день не теряется: итоги соберутся при следующем запуске.",
                                  "The week’s topics, decisions and open tasks, saved to the digests folder. A missed day is caught up on the next launch."),
                       isOn: bind(\.archive.weeklyDigest))
        }
    }

    /// День по `Calendar`: 1 — воскресенье.
    static func weekday(_ day: Int) -> String {
        let ru = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]  // l10n-guard: пара — en ниже
        let en = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let i = min(6, max(0, day - 1))
        return L(ru[i], en[i])
    }

    private func bind<T>(_ keyPath: WritableKeyPath<MostikSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in
                    var s = model.settings
                    s[keyPath: keyPath] = value
                    model.onUpdateSettings(s)
                })
    }
}
