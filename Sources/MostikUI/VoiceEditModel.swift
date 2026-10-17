import Foundation
import SwiftUI
import MostikCore

/// Состояние голосовой правки выделенного (D5): фаза, распознанная команда, причина отказа.
/// Пишет `VoiceEditController`, читают пилюля HUD и строка в настройках.
@MainActor
public final class VoiceEditModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        /// Правый ⌘ зажат, идёт запись команды.
        case listening
        /// Команда распознаётся и уходит LLM.
        case working
        /// Выделение заменено.
        case done
        /// Выделение не тронуто.
        case failed(VoiceEditFailure)
    }

    @Published public var phase: Phase = .idle
    /// Команда: по ходу записи — живой текст распознавания, после ответа — как её поняла модель.
    @Published public var command: String = ""
    /// Длина выделения в символах; 0 — выделение прочитается после отпускания клавиши (⌘C).
    @Published public var selectionLength: Int = 0
    /// Подробность сбоя от движка (`edit_done.detail`) — для лога и подсказки.
    @Published public var detail: String = ""

    public init() {}

    /// Пилюля HUD показывает правку, а не диктовку.
    public var isShowing: Bool { phase != .idle }

    public func reset() {
        phase = .idle; command = ""; selectionLength = 0; detail = ""
    }

    /// Причина для HUD — коротко, в одну строку.
    public static func message(_ failure: VoiceEditFailure) -> String {
        switch failure {
        case .secureInput: return L("Защищённое поле — правки нет", "Secure field — no edit")
        case .noAccessibility: return L("Включите Mostik в Универсальном доступе", "Turn on Mostik in Accessibility")
        case .noSelection: return L("Нет выделенного текста", "No text selected")
        case .tooLong: return L("Выделение длиннее 20 000 знаков", "Selection over 20,000 characters")
        case .noMicrophone: return L("Нет доступа к микрофону", "No microphone access")
        case .busy: return L("Идёт диктовка — правка позже", "Dictation in progress")
        case .emptyCommand: return L("Команда не расслышана", "Didn’t catch the command")
        case .refused: return L("Команда не распознана — текст не тронут", "Command not recognised — text untouched")
        case .unchanged: return L("Править нечего — текст тот же", "Nothing to change")
        case .timeout: return L("Модель не ответила — текст не тронут", "Model timed out — text untouched")
        case .unavailable: return L("Модель недоступна — текст не тронут", "Model unavailable — text untouched")
        case .badOutput: return L("Ответ модели не разобран — текст не тронут", "Bad model reply — text untouched")
        case .engine: return L("Сбой движка — текст не тронут", "Engine error — text untouched")
        case .focusChanged: return L("Окно сменилось — результат в буфере", "Window changed — result copied")
        case .pasteFailed: return L("Вставка не удалась — результат в буфере", "Paste failed — result copied")
        case .excludedApp: return L("Здесь правки голосом нет — приложение в исключениях", "No voice edit here — app is excluded")
        }
    }
}

// MARK: - Пилюля HUD

/// Пилюля правки: та же капсула 280×44, что у диктовки, другое содержимое.
struct VoiceEditPill: View {
    @ObservedObject var model: AppModel
    @ObservedObject var edit: VoiceEditModel

    var body: some View {
        Group {
            switch edit.phase {
            case .idle:
                Color.clear
            case .listening:
                line(icon: AnyView(Circle().fill(Palette.record).frame(width: 8, height: 8)),
                     tail: edit.command.isEmpty ? L("скажите, что сделать", "say what to do") : edit.command,
                     chip: edit.selectionLength > 0 ? Fmt.characters(edit.selectionLength) : nil)
            case .working:
                line(icon: AnyView(Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)),
                     tail: (edit.command.isEmpty ? L("думаю", "thinking") : edit.command) + "…", chip: nil)
            case .done:
                line(icon: AnyView(MostikGlyph(bars: Palette.inkTertiary, caret: Palette.accent).frame(width: 18, height: 18)),
                     title: L("Заменено", "Replaced"), tail: edit.command, chip: nil)
            case .failed(let failure):
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.record)
                    Text(VoiceEditModel.message(failure))
                        .font(TType.bodyStrong)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func line(icon: AnyView, title: String = L("Правка", "Edit"), tail: String, chip: String?) -> some View {
        HStack(spacing: 0) {
            icon.frame(width: 18).padding(.trailing, 10)
            Group {
                Text(title + (tail.isEmpty ? "" : ": ")).foregroundStyle(Palette.ink)
                    + Text(tail).foregroundStyle(Palette.inkSecondary)
            }
            .font(TType.bodyStrong)
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: DS.Space.xs)
            if let chip {
                Text(chip)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Palette.sunken, in: Capsule(style: .continuous))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, chip == nil ? 18 : 11)
    }
}

extension Fmt {
    /// «120 зн.» / «120 chars» — длина выделения в пилюле.
    static func characters(_ n: Int) -> String {
        "\(n)" + L(" зн.", " chars")
    }
}

// MARK: - Настройки

/// Строка «Голосовая правка (правый ⌘)» в группе причёсывания.
struct VoiceEditSettingsRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let availability = model.settings.voiceEditAvailability
        // Клавиша правки — правый ⌘, а если им пишут, правый ⌥ (HoldKeys): конфликта не бывает.
        let key = HoldKeys.name(model.settings.voiceEditKey)
        FormToggle(title: L("Голосовая правка", "Voice edit"), keys: [key],
                   hint: hint(availability),
                   details: L("Выделите текст, зажмите \(key) и скажите: «сделай списком», «переведи на английский», «короче». Выделение заменится, ⌘Z вернёт как было. В менеджерах паролей, банках и приложениях-исключениях выделение не читается. Если правым ⌘ вы записываете, правка переходит на правый ⌥.",
                              "Select text, hold \(key) and say “make it a list”, “translate to Russian”, “shorter”. The selection is replaced; ⌘Z undoes it. In password managers, banks and excluded apps the selection is never read. If right ⌘ is your record key, voice edit moves to right ⌥."),
                   warning: warning(availability),
                   isOn: Binding(get: { model.settings.voiceEdit },
                                 set: { value in var s = model.settings; s.voiceEdit = value; model.onUpdateSettings(s) }))
    }

    private func warning(_ availability: VoiceEditAvailability) -> Bool {
        if case .blocked(let blocker) = availability { return blocker != .disabled }
        return false
    }

    private func hint(_ availability: VoiceEditAvailability) -> String {
        switch availability {
        case .ready, .blocked(.disabled):
            return L("Выделите текст и скажите, что с ним сделать.", "Select text and say what to do with it.")
        case .blocked(.noBackend):
            return L("Нужна модель: выберите её выше.", "Needs a model: pick one above.")
        case .blocked(.noConsent):
            return L("Нужно согласие на облако Claude — оно даётся выше.", "Needs consent for Claude’s cloud above.")
        }
    }
}
