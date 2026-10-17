import Foundation

/// Откуда открывают Настройки и в каком разделе (раунд 3, R3b; 5 разделов — решение автора).
/// Настройки — вкладка главного окна с боковой панелью разделов (отзыв автора, B1), ⌘, ведёт туда же.
/// Любой переход «в Настройки» идёт через `AppModel.openSettings(_:)` с одной из этих ссылок;
/// раздел — сырое значение `SettingsPane` (MostikUI), здесь — строкой, чтобы проверять без UI.
public enum SettingsRoute: Equatable, Sendable {
    /// Прямо в раздел: «Изменить» в сводке приватности, «Выбрать модель» в свёрнутой группе.
    case pane(String)
    /// Карточка «Нужны модели» над вкладками главного окна.
    case modelsNeeded
    /// «Вся диагностика» на последнем шаге онбординга.
    case fullCheckup
    /// Пустая история диктовок: «Настройки клавиши».
    case hotkey
    /// «Выбрать модель» на экранах встречи: ИИ работает на модели причёсывания.
    case chooseModel
    /// Строка меню и ⌘, — открыть на том разделе, где Настройки закрыли.
    case menu

    /// Разделы в порядке боковой панели; совпадает с `SettingsPane.allCases`.
    public static let panes = ["general", "text", "meetings", "agents", "privacy"]

    /// Раскрывающийся блок «Дополнительно» в разделе «Приватность и данные»:
    /// модели, перепроверка, тёплый микрофон, движок, диагностика.
    public static let advanced = "advanced"

    /// Прежние разделы (9 штук) → новый раздел и что в нём раскрыть.
    /// Старое имя могло остаться в ссылке из кода или в памяти окна — ведём туда, где теперь его настройки.
    public static let legacy: [String: (pane: String, reveal: String?)] = [
        "recognition": ("privacy", advanced),
        "polish": ("text", nil),
        "speechRules": ("text", nil),
        "scenarios": ("text", nil),
        "advanced": ("privacy", advanced),
    ]

    /// Раздел, который откроется; nil — остаётся прежний.
    public var pane: String? {
        switch self {
        case let .pane(name):
            if Self.panes.contains(name) { return name }
            return Self.legacy[name]?.pane
        case .modelsNeeded: return "privacy"
        case .fullCheckup: return "privacy"
        case .hotkey: return "general"
        case .chooseModel: return "text"
        case .menu: return nil
        }
    }

    /// Какой свёрнутый блок раскрыть сразу; nil — ничего.
    public var reveal: String? {
        switch self {
        case let .pane(name): return Self.panes.contains(name) ? nil : Self.legacy[name]?.reveal
        case .modelsNeeded, .fullCheckup: return Self.advanced
        case .hotkey, .chooseModel, .menu: return nil
        }
    }

    /// Разделы боковой панели. «Агенты» видны, только если на Mac найден агент
    /// (Claude Code или Codex) — иначе там нечего настраивать.
    public static func visiblePanes(agentFound: Bool) -> [String] {
        agentFound ? panes : panes.filter { $0 != "agents" }
    }
}
