import SwiftUI
import MostikCore

/// Онбординг (П8, пункт 7): три разрешения по одному на шаг, каждое с живой проверкой,
/// и последний шаг — «Проверка» (R7) с переходом в полную группу в Настройках.
/// 1. Микрофон. 2. Универсальный доступ и право вставлять (отправка нажатий).
/// 3. Встречи — звук системы и запись экрана; шаг необязательный, только если нужны встречи.
/// Разрешения выдаёт человек в Системных настройках: кнопки открывают нужную панель,
/// сами мы ничего не включаем. Без звука. Статусы — из `model.permissions` (опрос раз в секунду).
public struct OnboardingView: View {
    @ObservedObject var model: AppModel
    /// Свой наблюдатель: ход загрузки моделей публикует `ModelsModel`, а не `AppModel`.
    @ObservedObject private var models: ModelsModel
    @State private var step: Int
    @State private var practice = ""
    /// Разрешения, которые уже просили: до первой попытки статус нейтральный (`circle.dashed`),
    /// и только после отказа — предупреждение.
    @State private var asked: Set<AppModel.PermissionKind> = []
    @Environment(\.mostikSnapshot) private var snapshot

    public init(model: AppModel) {
        self.model = model
        models = model.models
        // После перезапуска (право вставлять macOS даёт только новому процессу) — сразу к
        // первому невыполненному шагу, а не с начала.
        let p = model.permissions
        _step = State(initialValue: !p.microphone ? 0 : (!p.accessibility || !p.postEvents ? 1 : 2))
    }

    /// Для снимков: шаг, уже заданные вопросы и текст пробной диктовки.
    init(model: AppModel, step: Int, asked: Set<AppModel.PermissionKind> = [], practice: String = "") {
        self.model = model
        models = model.models
        _step = State(initialValue: step)
        _asked = State(initialValue: asked)
        _practice = State(initialValue: practice)
    }

    private func request(_ kind: AppModel.PermissionKind) {
        asked.insert(kind)
        model.onRequestPermission(kind)
    }

    /// Не выдано: до первой просьбы — «ещё не спрашивали», после — отказ.
    private func pending(_ kind: AppModel.PermissionKind) -> PermissionRow.State {
        asked.contains(kind) ? .denied : .notAsked
    }

    private let count = 5

    public var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, DS.Space.l)
            Spacer(minLength: DS.Space.m)
            Group {
                switch step {
                case 0: microphone
                case 1: accessibility
                case 2: meetings
                case 3: OnboardingModelStep(model: model)
                default: checkup
                }
            }
            .frame(maxWidth: 420)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 12)),
                                    removal: .opacity.combined(with: .offset(x: -8))))
            .id(step)
            Spacer(minLength: DS.Space.m)
            footer
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.bottom, DS.Space.l)
        .frame(width: 560, height: 520)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .animation(Motion.spring, value: step)
    }

    // MARK: Прогресс

    /// Шаги идут по порядку — здесь нумерация оправдана.
    private var progress: some View {
        VStack(spacing: DS.Space.xs) {
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Palette.accent : Palette.edgeStrong)
                        .frame(width: i == step ? 28 : 16, height: 4)
                }
            }
            .accessibilityHidden(true)
            Text(L("Шаг \(step + 1) из \(count)", "Step \(step + 1) of \(count)"))
                .font(TType.figure(11, .regular))
                .foregroundStyle(Palette.inkSecondary)
        }
    }

    // MARK: Шаги

    private var microphone: some View {
        stepBody(
            art: AnyView(LevelWave(levels: [0.25, 0.5, 0.8, 1, 0.7, 0.45, 0.6, 0.9, 0.55, 0.3, 0.2],
                                   color: Palette.accent, barWidth: 5, spacing: 5, height: 56)
                .accessibilityHidden(true)),
            title: L("Доступ к микрофону", "Microphone access"),
            text: L("Mostik записывает только по вашей команде. Звук не уходит с\u{00A0}этого Mac.",
                    "Mostik records only when you tell it to. Audio never leaves this Mac."),
            rows: [PermissionRow(title: L("Микрофон", "Microphone"),
                                 state: model.permissions.microphone ? .granted : pending(.microphone),
                                 hint: asked.contains(.microphone) && !model.permissions.microphone
                                   ? L("Включите Mostik в Системных настройках → Микрофон.", "Turn Mostik on in System Settings → Microphone.")
                                   : L("macOS спросит один раз.", "macOS asks once."),
                                 button: model.permissions.microphone ? nil
                                   : (asked.contains(.microphone) ? L("Открыть настройки", "Open Settings") : L("Разрешить", "Allow"),
                                      { request(.microphone) })),
                   speechModelsRow],
            footer: AnyView(languageLine)
        )
    }

    /// Модели распознавания — на первом шаге: к пробной диктовке они должны успеть
    /// скачаться, иначе первая фраза уходит в «модели не скачаны». Качаются только по кнопке.
    private var speechModelsRow: PermissionRow {
        let title = L("Распознавание речи", "Speech recognition")
        guard models.known else {
            return PermissionRow(title: title, state: .checking, hint: L("Mostik проверяет модели…", "Checking models…"))
        }
        let missing = models.missing
        if missing.isEmpty {
            return PermissionRow(title: title, state: .granted, hint: L("Модели на\u{00A0}этом Mac, без облака.", "Models on this Mac, no cloud."))
        }
        let size = ModelCatalog.size(ModelCatalog.bytesToDownload(missing), russian: L10n.isRussian)
        if missing.contains(where: { models.scheduled($0.key) }) {
            return PermissionRow(title: title, state: .downloading,
                                 hint: MeetingProgressText.percent(speechFraction)
                                   + L(" · можно идти дальше, загрузка не прервётся", " · you can go on, the download continues"))
        }
        return PermissionRow(title: title, state: models.error == nil ? .notAsked : .denied,
                             hint: models.error ?? L("Один раз, \(size). Звук распознаётся на\u{00A0}этом Mac.", "Once, \(size). Speech is recognized on this Mac."),
                             button: (L("Скачать", "Download"), { models.start(missing.map(\.key)) }))
    }

    /// Доля скачанного по обязательным моделям — как у карточки «Нужны модели».
    private var speechFraction: Double {
        let total = models.missing.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return 0 }
        let done = models.missing.reduce(Int64(0)) { $0 + (models.progress[$1.key]?.done ?? ($1.size - $1.missingBytes)) }
        return min(1, Double(done) / Double(total))
    }

    /// Язык диктовки — одной строкой: по умолчанию язык Mac, от него зависит,
    /// какую модель качать.
    private var languageLine: some View {
        HStack(spacing: DS.Space.s) {
            Text(L("Язык диктовки", "Dictation language")).font(TType.callout).foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: DS.Space.s)
            Segmented(options: [("ru", "Русский"), ("en", "English")],
                      selection: Binding(get: { model.settings.language }, set: { value in
                          var s = model.settings
                          s.language = value
                          model.onUpdateSettings(s)
                      }))
                .frame(width: 200)
        }
        .padding(.horizontal, DS.Space.m)
    }

    private var accessibility: some View {
        let p = model.permissions
        let pasteState: PermissionRow.State = p.postEvents ? .granted : (p.accessibility ? .relaunch : pending(.accessibility))
        return stepBody(
            art: AnyView(KeyCap(symbol: HUDHint.keySymbol(model.settings.holdKey), caption: HoldKeyCap.caption(model.settings.holdKey), size: 60).accessibilityHidden(true)),
            title: L("Универсальный доступ", "Accessibility"),
            text: L("Без этого доступа Mostik заметит \(HoldKeys.name(model.settings.holdKey)) только в своём окне. В Системных настройках включите Mostik в списке.",
                    "Without it, Mostik notices \(HoldKeys.name(model.settings.holdKey)) only in its own window. In System Settings, turn Mostik on in the list."),
            rows: [
                PermissionRow(title: L("Универсальный доступ", "Accessibility"),
                              state: p.accessibility ? .granted : pending(.accessibility),
                              hint: L("Клавиша записи в любом приложении.", "The record key in any app."),
                              button: p.accessibility ? nil : (L("Открыть настройки", "Open Settings"), { request(.accessibility) })),
                PermissionRow(title: L("Вставка текста", "Pasting text"),
                              state: pasteState,
                              hint: pasteState == .relaunch
                                ? L("macOS включит после перезапуска Mostik — он перезапустится сам.",
                                    "macOS applies it after Mostik relaunches — it relaunches on its own.")
                                : L("Текст встаёт туда, где курсор. Включится вместе с Универсальным доступом.",
                                    "Text lands at your cursor. Comes on together with Accessibility.")),
            ]
        )
    }

    private var meetings: some View {
        let p = model.permissions
        return VStack(spacing: DS.Space.l) {
            header(art: AnyView(Image(systemName: "person.2.wave.2")
                                    .font(.system(size: 46, weight: .regular))
                                    .foregroundStyle(Palette.accent)
                                    .accessibilityHidden(true)),
                   title: L("Запись встреч", "Meeting recording"),
                   text: L("Mostik запишет звонок в любом приложении: ваш голос и голоса собеседников. Потом — расшифровка с именами и сводка. Диктовке эти разрешения не нужны.",
                           "Mostik records a call in any app: your voice and the other side’s. Then a transcript with names and a summary. Dictation doesn’t need these permissions."))
            VStack(spacing: 0) {
                actionRow(PermissionRow(title: L("Звук собеседников", "Other side’s audio"),
                                        state: p.screenRecording ? .granted : .later,
                                        hint: p.screenRecording
                                          ? L("Встреча уже записывалась со звуком собеседников.", "A meeting was recorded with the other side’s audio.")
                                          : L("В macOS это «Запись экрана и звука». Система спросит при первой записи встречи.",
                                              "In macOS this is Screen & System Audio Recording. macOS asks on the first meeting recording."),
                                        button: p.screenRecording ? nil : (L("Открыть", "Open"), { request(.screenRecording) })))
                Hairline()
                actionRow(PermissionRow(title: L("Запись экрана", "Screen Recording"),
                                        state: p.screenCapture ? .granted : .optional,
                                        hint: L("Чтобы сохранять слайды со встречи. Включается отдельно на каждую встречу.",
                                                "To save slides from a meeting. Turned on separately for each meeting."),
                                        button: p.screenCapture ? nil : (L("Открыть", "Open"), { request(.screenCapture) })))
            }
            .padding(.horizontal, DS.Space.m)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
        }
    }

    /// Последний шаг: попробовать продиктовать в поле прямо здесь; ниже — «Проверка» (R7) коротко.
    private var checkup: some View {
        VStack(spacing: DS.Space.m) {
            header(art: nil,
                   title: L("Попробуйте продиктовать", "Try a dictation"),
                   text: models.needed
                     ? L("Сначала модели распознавания — без них фраза не превратится в текст.",
                         "Speech models first — without them nothing turns into text.")
                     : L("Нажмите на поле, зажмите \(HoldKeys.name(model.settings.holdKey)), скажите фразу и отпустите.",
                         "Click the field, hold \(HoldKeys.name(model.settings.holdKey)), say a sentence and let go."))
            // Клавиша диктовки — здесь, а не только в Настройках: ею сейчас и пробуют.
            HStack(spacing: DS.Space.s) {
                Text(L("Клавиша диктовки", "Dictation key")).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                Spacer(minLength: DS.Space.s)
                KeyPicker(selection: Binding(get: { model.settings.holdKey },
                                             set: { key in var s = model.settings; s.holdKey = key; model.onUpdateSettings(s) }))
            }
            if models.needed {
                // Без моделей пробная диктовка упадёт в «модели не скачаны» — сначала они.
                VStack(spacing: 0) { actionRow(speechModelsRow) }
                    .padding(.horizontal, DS.Space.m)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
            } else {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                MostikTextField(placeholder: L("Здесь появится ваш текст", "Your words land here"), text: $practice,
                                leadingSymbol: "mic")
                if practiced {
                    Label {
                        Text(L("Получилось", "It worked"))
                    } icon: {
                        // Знак Mostik оживает здесь один раз (решение автора).
                        LivelyMostikGlyph(bars: Palette.accent, caret: Palette.accent)
                            .frame(width: 15, height: 15)
                    }
                        .font(TType.calloutStrong)
                        .foregroundStyle(Palette.accent)
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: practiced)
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                let checks = checkupRows
                if checks.isEmpty {
                    Text(L("Mostik проверяет…", "Checking…")).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(checks) { check in checkRow(check) }
                }
            }
            .padding(.top, DS.Space.xxs)
            // Автозапуск: включён по умолчанию, выключить можно здесь и в Настройках → Основное.
            Toggle(isOn: Binding(get: { model.settings.launchAtLogin },
                                 set: { on in var s = model.settings; s.launchAtLogin = on; model.onUpdateSettings(s) })) {
                Text(L("Запускать Mostik при входе в систему", "Open Mostik at login"))
                    .font(TType.body).foregroundStyle(Palette.ink)
            }
            .toggleStyle(MostikCheckboxStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if !snapshot { model.doctor.onRun() } }
    }

    /// Пробная диктовка удалась: в поле появился текст.
    private var practiced: Bool { !practice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Строка чек-листа последнего шага: своё название без жаргона и сводный статус.
    struct CheckLine: Identifiable {
        var id: String { title }
        var title: String
        var status: DoctorCheck.Status
        var detail: String
    }

    /// Что важно в первый запуск, словами человека: «движок» и «модели» — одна строка «Распознавание готово».
    private var checkupRows: [CheckLine] {
        let checks = model.doctor.checks
        func line(_ kinds: [DoctorCheck.Kind], _ title: String) -> CheckLine? {
            let found = kinds.compactMap { kind in checks.first { $0.kind == kind } }
            guard let worst = found.map(\.status).max() else { return nil }
            return CheckLine(title: title, status: worst, detail: found.map(\.detail).filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        return [
            line([.microphone], L("Микрофон", "Microphone")),
            line([.accessibility], L("Клавиша работает везде", "Record key in any app")),
            line([.postEvents], L("Вставка текста", "Pasting text")),
            line([.engine, .models], L("Распознавание готово", "Speech recognition ready")),
            line([.systemAudio], L("Звук собеседников", "Other side’s audio")),
        ].compactMap { $0 }
    }

    /// Строка проверки: символ статуса и название; подробность — в подсказке и для VoiceOver.
    private func checkRow(_ check: CheckLine) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: symbol(check.status))
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(color(check.status))
                .frame(width: 18)
                .accessibilityLabel(statusLabel(check.status))
            Text(check.title).font(TType.body).foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
        .help(check.detail)
        .accessibilityElement(children: .combine)
        .accessibilityValue(check.detail)
    }

    private func symbol(_ status: DoctorCheck.Status) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .unknown: "clock"
        }
    }

    private func color(_ status: DoctorCheck.Status) -> Color {
        switch status {
        case .ok: Palette.accent
        case .warning: Palette.doubt
        case .failed: Palette.record
        case .unknown: Palette.inkTertiary
        }
    }

    private func statusLabel(_ status: DoctorCheck.Status) -> String {
        switch status {
        case .ok: L("в порядке", "OK")
        case .warning: L("внимание", "warning")
        case .failed: L("ошибка", "failed")
        case .unknown: L("не проверено", "not checked")
        }
    }

    // MARK: Строительные блоки

    struct PermissionRow {
        /// `notAsked` — ещё не просили (нейтрально), `denied` — просили и не дали.
        enum State { case granted, notAsked, denied, relaunch, later, optional, downloading, checking }
        var title: String
        var state: State
        var hint: String
        /// Действие прямо в строке разрешения: «Разрешить», «Открыть настройки».
        var button: (String, () -> Void)? = nil
    }

    private func header(art: AnyView?, title: String, text: String) -> some View {
        VStack(spacing: DS.Space.l) {
            if let art { art.frame(height: 64) }
            VStack(spacing: DS.Space.xs) {
                Text(title).font(.system(size: 28, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(text)
                    .font(TType.body)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stepBody(art: AnyView, title: String, text: String, rows: [PermissionRow], footer: AnyView? = nil) -> some View {
        VStack(spacing: DS.Space.l) {
            header(art: art, title: title, text: text)
            VStack(spacing: DS.Space.s) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Hairline() }
                        actionRow(row)
                    }
                }
                .padding(.horizontal, DS.Space.m)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
                if let footer { footer }
            }
        }
    }

    private func actionRow(_ row: PermissionRow) -> some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            stateMark(row.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(TType.bodyStrong).foregroundStyle(Palette.ink)
                Text(row.hint).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
            // Кнопка сама говорит, что не выдано; статус текстом — когда кнопки нет.
            if let button = row.button {
                // Обязательное разрешение — главное действие шага; необязательное — вторичное.
                Button(button.0, action: button.1)
                    .buttonStyle(.mostik(row.state == .notAsked || row.state == .denied ? .primary : .secondary, compact: true))
                    .accessibilityHint(stateText(row.state))
            } else {
                Text(stateText(row.state)).font(TType.callout)
                    .foregroundStyle(row.state == .granted ? Palette.accent : Palette.inkSecondary)
            }
        }
        .padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .combine)
    }

    /// Статус разрешения символом 15 pt: выдано — заполненная галка акцентом, остальное — контурные знаки.
    private func stateMark(_ state: PermissionRow.State) -> some View {
        let name: String = switch state {
        case .granted: "checkmark.circle.fill"
        case .notAsked: "circle.dashed"
        case .denied: "exclamationmark.circle"
        case .relaunch: "arrow.clockwise.circle"
        case .later: "clock"
        case .optional: "circle.dashed"
        case .downloading: "arrow.down.circle"
        case .checking: "circle.dashed"
        }
        return Image(systemName: name)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(state == .granted ? Palette.accent : (state == .denied ? Palette.doubt : Palette.inkSecondary))
            .frame(width: 18)
            .accessibilityHidden(true)
    }

    private func stateText(_ state: PermissionRow.State) -> String {
        switch state {
        case .granted: L("Разрешено", "Allowed")
        case .notAsked: L("Ещё не спрашивали", "Not asked yet")
        case .denied: L("Не разрешено", "Not allowed")
        case .relaunch: L("После перезапуска", "After relaunch")
        case .later: L("Спросят позже", "Asked later")
        case .optional: L("Можно позже", "Can wait")
        case .downloading: L("Скачивается", "Downloading")
        case .checking: ""
        }
    }

    // MARK: Низ

    /// Низ: «Назад» слева, одна кнопка справа. Без «Позже» и неактивной «Продолжить» (Антон: две кнопки
    /// и сноска ломали вёрстку): что будет без разрешения, говорит сама строка разрешения.
    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            if step > 0 {
                Button(L("Назад", "Back")) { step -= 1 }.buttonStyle(.mostikQuiet)
            }
            Spacer(minLength: DS.Space.s)
            if step < count - 1 {
                // Залитая — когда шаг сделан; до того главное действие — «Разрешить» в строке.
                Button(L("Дальше", "Next")) { step += 1 }
                    .buttonStyle(.mostik(stepDone ? .primary : .secondary, large: true))
                    .keyboardShortcut(.defaultAction)
            } else {
                // «Готово» выделяется, только когда пробная диктовка удалась.
                Button(L("Готово", "Done")) { finish() }
                    .buttonStyle(.mostik(practiced ? .primary : .secondary, large: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func finish() {
        var s = model.settings
        s.onboarded = true
        model.onUpdateSettings(s)
    }

    private var stepDone: Bool {
        switch step {
        case 0: model.permissions.microphone
        case 1: model.permissions.accessibility && model.permissions.postEvents
        default: true  // встречи — по желанию
        }
    }
}

/// Подпись на картинке клавиши записи: «правый» у ⌥ и ⌘, у fn подписи нет.
enum HoldKeyCap {
    static func caption(_ holdKey: String) -> String? {
        holdKey == HoldKeys.fn ? nil : L("правый", "right")
    }
}
