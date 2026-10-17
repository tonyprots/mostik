import Foundation
import MostikCore

/// Говорящие в звонке-странице (Meet, Телемост) по дереву Accessibility. Деревья синтетические:
/// у Meet — по устройству дерева с реального звонка в Chrome (seashell), у Телемоста — по разведке DOM.
func runWebCallSpeakersTests() {
    typealias Node = WebCallSpeakers.Node

    func text(_ value: String) -> Node { Node(role: "AXStaticText", value: value) }

    /// Плитка Meet: обёртка, подпись с именем, значок звука (с классом «говорит» или без).
    func meetTile(_ name: String, speaking: Bool, signal: Bool = true) -> Node {
        var children = [Node(role: "AXGroup", classes: ["XEazBc", "adnwBd"], children: [text(name)])]
        if signal {
            children.append(Node(role: "AXGroup", classes: ["DYfzY", "cYKTje"] + (speaking ? ["HX2H7"] : ["sxlEM"])))
        }
        return Node(role: "AXGroup", classes: ["oZRSLe"],
                    children: [Node(role: "AXGroup", classes: ["koV58"], children: children)])
    }

    func meetPage(_ tiles: [Node], people: [(String, Bool)] = []) -> Node {
        var children = [Node(role: "AXGroup", classes: ["T4q2od"], children: tiles)]
        if !people.isEmpty {
            let rows = people.map { name, me in
                Node(role: "AXGroup", label: name, children: [text(name)] + (me ? [text("(You)")] : []))
            }
            children.append(Node(role: "AXList", label: "Participants", children: rows))
        }
        return Node(role: "AXApplication", children: [
            Node(role: "AXWindow", children: [Node(role: "AXWebArea", children: children)]),
        ])
    }

    // MARK: окно звонка по заголовку
    do {
        equal(WebCallSpeakers.kind(windowTitle: "Meet - abc-defg-hij"), .meet)
        equal(WebCallSpeakers.kind(windowTitle: "Meet – Планёрка"), .meet)
        equal(WebCallSpeakers.kind(windowTitle: "Встреча в Телемосте"), .telemost)
        equal(WebCallSpeakers.kind(windowTitle: "Yandex Telemost"), .telemost)
        equal(WebCallSpeakers.kind(windowTitle: "Почта — входящие"), nil, "чужая вкладка не читается")
        equal(WebCallSpeakers.kind(windowTitle: "Meeting notes"), nil, "слово «Meeting» — не Meet")
    }

    // MARK: Google Meet
    do {
        let snap = WebCallSpeakers.snapshot(meetPage([meetTile("Пётр", speaking: true), meetTile("Мария", speaking: false)]),
                                            kind: .meet)
        equal(snap.tiles, [.init(name: "Пётр", active: true, isSelf: false), .init(name: "Мария", active: false, isSelf: false)],
              "говорящий — по классу значка")

        let nested = Node(role: "AXGroup", classes: ["oZRSLe"], children: [meetTile("Пётр", speaking: true)])
        equal(WebCallSpeakers.snapshot(meetPage([nested]), kind: .meet).tiles.map(\.name), ["Пётр"],
              "плитка в плитке — контейнер раскладки, не участник")

        let stray = Node(role: "AXGroup", classes: ["DYfzY", "cYKTje", "Oaajhc"])
        let unknown = WebCallSpeakers.snapshot(meetPage([meetTile("Пётр", speaking: true), stray]), kind: .meet)
        equal(unknown.tiles.filter(\.active).count, 0, "значок «говорит» без плитки — никого не называем")

        let twoNames = Node(role: "AXGroup", classes: ["oZRSLe"], children: [
            Node(role: "AXGroup", classes: ["XEazBc", "adnwBd"], children: [text("Пётр"), text("Мария")]),
        ])
        equal(WebCallSpeakers.snapshot(meetPage([twoNames]), kind: .meet).tiles, [], "две подписи в плитке — не угадываем")

        let mine = WebCallSpeakers.snapshot(
            meetPage([meetTile("Пётр", speaking: false), meetTile("Олег", speaking: true)],
                     people: [("Пётр", false), ("Олег", true)]), kind: .meet)
        equal(mine.selfIndex, 1, "своя плитка — по «(You)» в панели участников")
        equal(mine.others.map(\.name), ["Пётр"])

        var writer = SpeakerTimelineWriter(source: "meet")
        let line = writer.observe(mine, at: 12)
        check(line?.contains("\"active\":[]") == true && line?.contains("\"self\":[\"Олег\"]") == true
              && line?.contains("\"source\":\"meet\"") == true, "своя речь в ленту говорящих не идёт")
    }

    // MARK: Телемост (догадка до снимка дерева на звонке)
    do {
        let stroke = Node(role: "AXGroup", classes: ["rootStroke_a1b2c"])
        let speaking = Node(role: "AXGroup", classes: ["tile_x9"], children: [
            Node(role: "AXGroup", children: [text("Мария")]), stroke,
        ])
        let quiet = Node(role: "AXGroup", classes: ["tile_x9"], children: [Node(role: "AXGroup", children: [text("Пётр")])])
        let root = Node(role: "AXApplication", children: [
            Node(role: "AXWindow", children: [Node(role: "AXWebArea", children: [speaking, quiet])]),
        ])
        equal(WebCallSpeakers.snapshot(root, kind: .telemost).tiles, [.init(name: "Мария", active: true, isSelf: false)],
              "обводка — говорящий, имя — текст его плитки")

        let far = Node(role: "AXGroup", children: [Node(role: "AXGroup", children: [Node(role: "AXGroup", children: [
            Node(role: "AXGroup", children: [Node(role: "AXGroup", children: [Node(role: "AXGroup", classes: ["rootStroke_q"])])]),
        ])]), text("Пётр")])
        equal(WebCallSpeakers.snapshot(far, kind: .telemost).tiles, [], "имя дальше четырёх уровней — не берём")
        equal(WebCallSpeakers.snapshot(Node(role: "AXApplication"), kind: .telemost).tiles, [], "пустое дерево")
    }
}
