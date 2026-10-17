import SwiftUI
import MostikCore

// Голосовые команды-намерения (D6): модель, карточка над HUD, раздел Настроек и снимки.
// Решения — в MostikCore (`VoiceIntent.swift`); открытие черновиков — `Mostik/VoiceIntentController.swift`.

/// Своя модель, чтобы правки не сталкивались в `AppModel`.
@MainActor
public final class VoiceIntentModel: ObservableObject {
    /// ⌃⌘K нажата: следующая диктовка — команда.
    @Published public var armed = false
    /// Карточка над HUD прямо сейчас.
    @Published public var card: Card? = nil

    public struct Card: Equatable {
        public enum Kind: Equatable { case event, reminder, mail }
        public var kind: Kind
        public var headline: String
        public var detail: String
        public var openTitle: String

        public init(kind: Kind, headline: String, detail: String, openTitle: String) {
            self.kind = kind; self.headline = headline; self.detail = detail; self.openTitle = openTitle
        }

        /// Карточка по черновику: тексты — из MostikCore.
        public init(_ draft: VoiceIntentDraft, now: Date = Date(), calendar: Calendar = .current) {
            let ru = L10n.isRussian
            switch draft {
            case .event(let event): kind = event.reminder ? .reminder : .event
            case .mail: kind = .mail
            }
            headline = VoiceIntentCardText.headline(draft, russian: ru)
            detail = VoiceIntentCardText.detail(draft, now: now, calendar: calendar, russian: ru)
            openTitle = VoiceIntentCardText.openTitle(draft, russian: ru)
        }
    }

    public var onOpen: () -> Void = {}
    public var onCancel: () -> Void = {}

    public init() {}
}

/// Карточка над пилюлей диктовки: что получится и две кнопки. Ничего не открывается без «Открыть».
public struct VoiceIntentCardView: View {
    public static let size = CGSize(width: 520, height: 72)
    @ObservedObject var intent: VoiceIntentModel

    public init(intent: VoiceIntentModel) { self.intent = intent }

    public var body: some View {
        Group {
            if let card = intent.card { content(card) } else { Color.clear }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func content(_ card: VoiceIntentModel.Card) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: icon(card.kind))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 28, height: 28)
                .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.headline)
                    .font(TType.bodyStrong)
                    .foregroundStyle(Palette.ink)
                Text(card.detail)
                    .font(TType.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Отмена", "Cancel")) { intent.onCancel() }
                .buttonStyle(.mostik(.quiet, compact: true))
                .keyboardShortcut(.cancelAction)
            Button(card.openTitle) { intent.onOpen() }
                .buttonStyle(.mostik(.primary, compact: true))
                .fixedSize()
        }
        .padding(.leading, DS.Space.s + 2)
        .padding(.trailing, DS.Space.xs + 2)
        .frame(height: 56)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card + 2, style: .continuous).strokeBorder(Palette.edgeStrong))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.horizontal, 6)
    }

    private func icon(_ kind: VoiceIntentModel.Card.Kind) -> String {
        switch kind {
        case .event: return "calendar.badge.plus"
        case .reminder: return "bell"
        case .mail: return "envelope"
        }
    }
}

/// Настройки: включить команды и порог уверенности.
struct VoiceIntentSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // Порог уверенности — умолчание без контрола (решение автора).
        FormToggle(title: L("Встреча, напоминание, письмо", "Event, reminder, email"), keys: ["⌃", "⌘", "K"],
                       hint: model.settings.polish.effectiveBackend.isCloud && model.settings.voiceIntents.enabled
                           ? L("С Claude текст команды уходит в облако.", "With Claude, the command text goes to the cloud.")
                           : L("Черновик в Календаре или Почте — сохраняете вы.", "A draft in Calendar or Mail; you save and send it."),
                       details: modelHint + " " + L("Нажмите ⌃⌘K и продиктуйте: «создай встречу завтра в три», «напомни в шесть забрать посылку», «черновик письма Пете о сроках». Mostik покажет карточку, а событие или письмо откроет черновиком в Календаре или Почте — сохраняете и отправляете вы. Контакты не читаются, имя берётся как сказано.",
                                  "Press ⌃⌘K and say “set up a meeting tomorrow at three”, “remind me at six to pick up the parcel”, “draft an email to Pete about the deadline”. Mostik shows a card and opens the event or email as a draft in Calendar or Mail — you save and send it. Contacts aren’t read; the name is taken as said."),
                       warning: model.settings.polish.effectiveBackend.isCloud && model.settings.voiceIntents.enabled,
                       isOn: bind(\.voiceIntents.enabled))
    }

    private var modelHint: String {
        let base = L("Если Mostik не уверен, что это команда, текст вставится как обычная диктовка. ", "If Mostik isn’t sure it’s a command, the text goes in as a normal dictation. ")
        switch model.settings.polish.effectiveBackend {
        case .off: return base + L("Разбор — правилами; с моделью причёсывания он точнее.", "Parsed by rules; a polish model makes it sharper.")
        case .mlx: return base + L("Разбор — правилами и локальной моделью.", "Parsed by rules and the local model.")
        case .claude: return base + L("Разбор — правилами и Claude: текст команды уходит в облако.", "Parsed by rules and Claude: the command text goes to the cloud.")
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

// MARK: - Снимки

extension Snapshots {
    /// Карточки над HUD (событие, напоминание, письмо) и раздел Настроек. Фразы вымышленные.
    @MainActor
    static func renderVoiceIntents(to dir: URL) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let now = VoiceIntentPlan.parseLocal("2026-10-11T17:20", calendar: calendar)!
        let event = VoiceIntentEvent(title: L("Встреча с Петей по бюджету", "Meeting with Pete about the budget"),
                                     start: VoiceIntentPlan.parseLocal("2026-10-12T15:00", calendar: calendar)!,
                                     minutes: 60, uid: "demo")
        var reminder = event
        reminder.title = L("Забрать посылку", "Pick up the parcel")
        reminder.start = VoiceIntentPlan.parseLocal("2026-10-11T18:00", calendar: calendar)!
        reminder.reminder = true
        let mail = VoiceIntentMail(recipient: L("Пете", "Pete"),
                                   draft: MeetingEmailDraft(subject: L("О переносе релиза", "Release moved"),
                                                            body: L("Релиз переносим на пятницу: ждём проверку безопасности.",
                                                                    "We’re moving the release to Friday: waiting on the security review.")))
        let cards: [(String, VoiceIntentDraft)] = [("event", .event(event)), ("reminder", .event(reminder)), ("mail", .mail(mail))]
        for dark in [false, true] {
            for (name, draft) in cards {
                let model = VoiceIntentModel()
                model.card = VoiceIntentModel.Card(draft, now: now, calendar: calendar)
                write(intentStage(VoiceIntentCardView(intent: model)), "hud-intent-\(name)" + (dark ? "-dark" : ""), dir,
                      width: 560, height: 104, dark: dark)
            }
            let model = demoModel()
            model.settings.voiceIntents = VoiceIntentSettings(enabled: true, threshold: 0.6)
            model.settings.polish = PolishSettings(backend: .mlx, style: .plain)
            write(intentStage(VoiceIntentSettingsSection(model: model)), "settings-voice-intents" + (dark ? "-dark" : ""), dir,
                  width: 688, dark: dark)
        }
    }

    @MainActor
    private static func intentStage<V: View>(_ view: V) -> some View {
        view
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Palette.canvas)
    }
}
