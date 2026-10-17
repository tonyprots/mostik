import SwiftUI
import MostikCore

/// Настройки «Встречи» (M11, M13, W13, W14; 5 разделов — решение автора): подсказка о звонке
/// и напоминание — одним переключателем, календарь — здесь же, автоостановка. Автостарта записи нет:
/// встречу начинает «Записать?» или ⌃⌘M. Всё, что трогает данные или запускает чужой код, выключено по умолчанию.
struct MeetingSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let calendar = model.settings.calendarEnabled
        FormGroup(title: L("Звонки", "Calls")) {
            // «Предлагать запись» и «Напоминать о встрече» — одна настройка: оба про «Mostik подскажет записать».
            FormToggle(title: L("Подсказывать о звонках", "Suggest recording calls"),
                       hint: calendar ? L("Когда начнётся звонок, Mostik предложит его записать, а за минуту до встречи напомнит.",
                                          "When a call starts, Mostik offers to record it, and reminds you a minute before a meeting.")
                                      : L("Когда начнётся звонок, Mostik предложит его записать.", "When a call starts, Mostik offers to record it."),
                       details: L("Звонок занял микрофон — появится «Записать / Нет». С календарём ещё и напоминание за минуту до события: ссылка на звонок и кнопка записи. Сам Mostik запись не начинает.",
                                  "When a call takes the mic, “Record / No” appears. With the calendar on, you also get a reminder a minute before an event: the call link and a record button. Mostik never starts recording by itself."),
                       isOn: Binding(get: { model.settings.meetingSuggest },
                                     set: { on in update { $0.meetingSuggest = on; $0.meetingReminder = on } }))
            FormDivider()
            FormToggle(title: L("Календарь", "Calendar"),
                       hint: calendar ? L("Названия встреч, участники, напоминания и справка перед встречей.",
                                          "Meeting titles, attendees, reminders and the pre-meeting brief.")
                                      : L("Без него нет напоминаний, названий встреч и справки перед встречей.",
                                          "Without it there are no reminders, meeting titles or pre-meeting brief."),
                       details: L("Mostik читает события только из календарей, которые вы подключите ниже: Google, Яндекс или Календарь macOS. Берёт название, время, участников, ссылку на звонок; имена участников ещё и пополняют словарь.",
                                  "Mostik reads events only from the calendars you connect below: Google, Yandex or the macOS Calendar. It takes the title, time, attendees and call link; attendee names also go into the glossary."),
                       isOn: Binding(get: { calendar }, set: { model.onSetCalendarEnabled($0) }))
            if calendar {
                FormDivider()
                CalendarSourcesRows(model: model)
            }
            FormDivider()
            FormToggle(title: L("Останавливать запись после встречи", "Stop recording after the meeting"),
                       hint: L("Звонок закрылся — запись останавливается сразу. Кончилось только время в календаре — минута на отмену.", "Call closed — recording stops right away. Only the calendar time is up — a minute to cancel."),
                       isOn: bind(\.meetingAutoStop))
            FormDivider()
            // Слайды (W26, отзыв автора): постоянная настройка вместо кнопки у записи «на одну встречу».
            FormToggle(title: L("Снимать слайды звонка", "Capture call slides"),
                       hint: L("При смене слайда — снимок окна звонка в папку встречи. Нужна «Запись экрана».",
                               "On each slide change, a shot of the call window into the meeting folder. Needs Screen Recording."),
                       details: L("Mostik раз в \(model.settings.meetingAssist.frameInterval) с смотрит на окно звонка и сохраняет кадр, только когда слайд заметно сменился. Текст слайдов распознаётся на Mac и попадает в сводку встречи. Встречи «Только текст» не снимаются; у встреч «Только на этом Mac» кадры, как и расшифровка, не уходят в облако и агентам. В самой встрече съёмку можно выключить.",
                                  "Every \(model.settings.meetingAssist.frameInterval) s Mostik looks at the call window and saves a frame only when the slide clearly changed. Slide text is recognised on the Mac and goes into the meeting summary. “Text only” meetings are never captured; for “This Mac only” meetings frames, like the transcript, never go to the cloud or agents. You can turn it off during a meeting."),
                       isOn: Binding(get: { model.settings.meetingAssist.slides },
                                     set: { on in
                                         var s = model.settings
                                         s.meetingAssist.slides = on
                                         model.onUpdateSettings(s)
                                         if on { model.meetingAssist.onEnableSlides() }
                                     }))
        }
        .sheet(item: Binding(get: { model.calendarPicker }, set: { model.calendarPicker = $0 })) { picker in
            CalendarPickerSheet(state: picker,
                                onSave: { s in
                                    model.calendarPicker = nil
                                    model.onSaveCalendars(s.kind, s.calendars.filter { s.selected.contains($0.id) })
                                },
                                onCancel: { model.calendarPicker = nil })
        }
        .sheet(item: Binding(get: { model.yandexSignIn }, set: { if $0 == nil { model.onCancelCalendarSignIn() } })) { state in
            YandexSignInSheet(state: state, onSubmit: model.onSubmitYandex, onCancel: model.onCancelCalendarSignIn)
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<MostikSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func update(_ change: (inout MostikSettings) -> Void) {
        var s = model.settings
        change(&s)
        model.onUpdateSettings(s)
    }
}

/// Что делать со звуком встречи — одна строка вместо двух переключателей («Убирать в Корзину» и «Только текст»).
/// Живёт в «Приватность и данные → Хранение». «Только текст» — выбор для новых встреч; во вкладке и меню записи
/// переключателя нет (D4), там только строка-состояние.
struct MeetingAudioRow: View {
    @ObservedObject var model: AppModel

    enum Choice: Hashable { case keep, trash, none }

    private var choice: Choice {
        if model.settings.meetingLive.textOnlyDefault { return .none }
        return model.settings.trashAudioAfterSummary ? .trash : .keep
    }

    var body: some View {
        FormRow(title: L("Звук встреч", "Meeting audio"),
                hint: hint,
                details: L("«В Корзину» — когда расшифровка и сводка готовы, звук уходит в Корзину; пока он там, можно вырезать отрывок или распознать заново. «Не хранить» — звук удаляется сразу после расшифровки, без Корзины, даже если расшифровка не удалась. Выбор действует на все новые встречи.",
                           "“To Trash”: once the transcript and summary are ready, audio goes to the Trash; while it’s there you can cut a clip or re-transcribe. “Don’t keep”: audio is deleted right after transcription, bypassing the Trash, even if transcription fails. The choice applies to every new meeting.")) {
            Segmented(options: [(Choice.keep, L("Хранить", "Keep")),
                                (.trash, L("В Корзину", "To Trash")),
                                (.none, L("Не хранить", "Don’t keep"))],
                      selection: Binding(get: { choice }, set: { set($0) }))
        }
    }

    private var hint: String {
        switch choice {
        case .keep: L("Звук остаётся в папке встречи.", "Audio stays in the meeting folder.")
        case .trash: L("Звук уйдёт в Корзину после сводки. Текст остаётся.", "Audio goes to the Trash after the summary. The text stays.")
        case .none: L("Остаётся только текст расшифровки.", "Only the transcript text is kept.")
        }
    }

    private func set(_ value: Choice) {
        var s = model.settings
        s.meetingLive.textOnlyDefault = value == .none
        s.trashAudioAfterSummary = value == .trash
        model.onUpdateSettings(s)
    }
}

/// Своя команда после встречи — в «Встречи → Ещё». Лимит времени (60 с) и повтор после сводки —
/// умолчания без контрола (решение автора); подробности — в «i».
struct MeetingHookRows: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let hook = model.settings.meetingHook
        VStack(alignment: .leading, spacing: 0) {
            FormToggle(title: L("Своя команда после встречи", "Your command after a meeting"),
                       hint: L("Например, переложить заметки в Obsidian своим скриптом.", "E.g. copy notes to Obsidian with your own script."),
                       details: L("Ваша команда получит папку встречи в $1 и MOSTIK_MEETING_DIR — после расшифровки и ещё раз после сводки. Встречи «только на этом Mac» не передаются. Запуск — /bin/zsh без ~/.zprofile и ~/.zshrc, программы вне /usr/bin — по полному пути. Вывод — в ~/Library/Logs/Mostik/meeting-hooks.log.",
                                  "Your command gets the meeting folder as $1 and MOSTIK_MEETING_DIR — after the transcript and again after the summary. “This Mac only” meetings are skipped. It runs in /bin/zsh without ~/.zprofile or ~/.zshrc, so use full paths for programs outside /usr/bin. Output goes to ~/Library/Logs/Mostik/meeting-hooks.log."),
                       isOn: bind(\.meetingHook.enabled))
            if hook.enabled {
                MostikTextField(placeholder: L("например: ~/bin/to-obsidian.sh \"$1\"", "e.g. ~/bin/to-obsidian.sh \"$1\""),
                                text: bind(\.meetingHook.command), leadingSymbol: "terminal", monospaced: true)
                    .padding(.bottom, DS.Space.s)
            }
        }
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

/// Внешний календарь — команда (docs/external-calendar.md): для календаря, которого нет в Календаре macOS.
struct ExternalCalendarRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let path = model.settings.calendarCommand
        FormRow(title: L("Команда календаря", "Calendar command"),
                hint: path == nil
                    ? L("Команда, которая отдаёт встречи, если календаря нет в macOS.", "A command that provides meetings when the calendar isn’t in macOS.")
                    : model.externalCalendarStatus ?? (path! as NSString).lastPathComponent,
                details: L("Mostik раз в 5 минут запускает выбранный файл с аргументами --from и --to и читает из него события в JSON: название, время, участников, ссылку на звонок. Файл запускается без оболочки и без ключей Mostik. Формат — docs/external-calendar.md.",
                           "Every 5 minutes Mostik runs the chosen file with --from and --to and reads events as JSON: title, time, attendees, call link. It runs without a shell and without Mostik’s keys. Format: docs/external-calendar.md."),
                warning: model.externalCalendarStatus?.hasPrefix(L("Ошибка", "Error")) == true) {
            if path == nil {
                Button(L("Выбрать…", "Choose…")) { model.onChooseCalendarCommand() }
                    .buttonStyle(.mostik(.secondary, compact: true))
            } else {
                Button(L("Обновить", "Refresh")) { model.onRefreshCalendarCommand() }
                    .buttonStyle(.mostik(.quiet, compact: true))
                Button(L("Отключить", "Disconnect")) { model.onClearCalendarCommand() }
                    .buttonStyle(.mostik(.quiet, compact: true))
            }
        }
    }
}
