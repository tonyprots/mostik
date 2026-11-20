import Foundation
import MostikCore

/// Субтитры ВКС с именами: разбор Zoom, Meet, Teams, Slack и лента дописанных реплик.
func runCallCaptionsTests() {
    typealias Node = WebCallSpeakers.Node
    typealias Caption = CallCaptions.Caption
    func text(_ value: String) -> Node { Node(role: "AXStaticText", value: value) }

    // MARK: разбор
    do {
        equal(CallCaptions.zoom(rows: [["Пётр Иванов", "добрый день", "коллеги"], ["Мария"], []]),
              [Caption(name: "Пётр Иванов", text: "добрый день коллеги")], "Zoom: строка без текста пропущена")

        let teams = Node(role: "AXWebArea", children: [
            Node(role: "AXGroup", classes: ["fui-ChatMessageCompact__body"], children: [text("Мария"), text("начнём с цифр")]),
        ])
        equal(CallCaptions.captions(teams, kind: .teams), [Caption(name: "Мария", text: "начнём с цифр")], "Teams")
        equal(CallCaptions.captions(Node(role: "AXWebArea"), kind: .teams), nil, "нет субтитров — nil, а не пусто")

        let slack = Node(role: "AXWebArea", children: [
            Node(role: "AXGroup", classes: ["p-huddle_closed_caption_event__wrapper", "fade_out"],
                 children: [text("Пётр"), text(":"), text("всё готово")]),
        ])
        equal(CallCaptions.captions(slack, kind: .slack), [Caption(name: "Пётр", text: "всё готово")], "Slack: двоеточие убрано")

        func block(_ lines: [String], height: Double) -> Node {
            var node = Node(role: "AXGroup", children: lines.map(text)); node.height = height; return node
        }
        // Старый блок срезан сверху: первым идёт блок реплик без имени.
        let meet = Node(role: "AXWebArea", children: [
            Node(role: "AXGroup", label: "Captions", children: [
                block(["хвост старой реплики"], height: 25),
                block(["Пётр Иванов"], height: 16), block(["первая фраза", "вторая фраза"], height: 50),
                block(["Мария"], height: 16), block(["ответ"], height: 25),
            ]),
        ])
        equal(CallCaptions.captions(meet, kind: .meet), [
            Caption(name: "Пётр Иванов", text: "первая фраза"), Caption(name: "Пётр Иванов", text: "вторая фраза"),
            Caption(name: "Мария", text: "ответ"),
        ], "Meet: имена по высоте, срезанный блок без имени пропущен")
        let flat = Node(role: "AXGroup", label: "Captions", children: [
            block(["Мария"], height: 0), block(["ответ"], height: 0),
        ])
        equal(CallCaptions.captions(flat, kind: .meet), [], "без высот имён не угадываем")
        // Новый говорящий: блок с именем пришёл, реплики под ним ещё нет — по очерёдности имена и реплики поменялись бы.
        let fresh = Node(role: "AXGroup", label: "Captions", children: [
            block(["Мария"], height: 16), block(["ответ"], height: 25), block(["Пётр Иванов"], height: 16),
        ])
        equal(CallCaptions.captions(fresh, kind: .meet), [Caption(name: "Мария", text: "ответ")],
              "имя без реплики внизу не сдвигает остальные")
    }

    // MARK: лента реплик
    do {
        var tracker = CaptionTracker(source: "zoom")
        equal(tracker.observe([Caption(name: "Пётр", text: "добрый")], at: 10), [], "реплика растёт — ещё не пишем")
        equal(tracker.observe([Caption(name: "Пётр", text: "добрый день, коллеги")], at: 11.5), [], "та же реплика")
        equal(tracker.observe(nil, at: 13), [], "субтитры спрятаны — ждём, не закрываем")
        let lines = tracker.observe([Caption(name: "Мария", text: "здравствуйте")], at: 14)
        equal(lines.count, 1, "реплика пропала — дописана")
        check(lines.first?.contains("\"at\":10") == true && lines.first?.contains("\"end\":11.5") == true,
              "время появления и последней правки: \(lines)")
        check(lines.first?.contains("добрый день, коллеги") == true, "полный текст")
        equal(tracker.observe([Caption(name: "Пётр", text: "добрый день, коллеги")], at: 20).count, 1,
              "Мария дописана; Пётр снова на экране — уже записан, не дублируем")
        equal(tracker.finish(), [], "открытых нет")
        _ = tracker.observe([Caption(name: "Пётр", text: "добрый день, коллеги")], at: 90)
        equal(tracker.observe([], at: 92).count, 1, "та же фраза через минуту — новая реплика")
        var last = CaptionTracker(source: "meet")
        _ = last.observe([Caption(name: "Мария", text: "итог")], at: 1)
        equal(last.finish().count, 1, "конец записи дописывает открытое")
    }
}
