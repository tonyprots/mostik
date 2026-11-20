import Foundation
import MostikCore

/// Десктопный Телемост: Qt-дерево окна звонка и журнал `qt.log`.
func runTelemostDesktopTests() {
    typealias Node = WebCallSpeakers.Node
    let base = "TApplication.TelemostWindowTelemes.centralwidget.Telemost::QWidgetRestrictedToDeleteLater.MainConferenceView."

    func window(title: String, count: String?, mic: String?, extra: [Node] = []) -> Node {
        var children: [Node] = [
            Node(role: "AXButton", identifier: base + "QWidget.SlotThumbnailView.QWidget.VideoTrackWidget."),
            Node(role: "AXButton", label: "Leave meeting", identifier: base + "ControlPanelWidget.endCallButton"),
        ]
        if let mic {
            children.append(Node(role: "AXCheckBox", label: mic, identifier: base + "ControlPanelWidget.microphoneButton"))
        }
        if let count {
            children.append(Node(role: "AXCheckBox", label: "View the participant list",
                                 identifier: base + "ControlPanelWidget.centralWidget.participantsButton", title: "Participants",
                                 children: [Node(role: "AXStaticText", value: count,
                                                 identifier: base + "ControlPanelWidget.centralWidget.participantsButton")]))
        }
        return Node(role: "AXApplication", title: "Yandex Telemost", children: [
            Node(role: "AXWindow", title: "Yandex Telemost: 12 new messages", children: [
                Node(role: "AXGroup", identifier: "TApplication.Messenger::MessengerWindow.frame"),
            ]),
            Node(role: "AXWindow", title: title, children: children + extra),
        ])
    }

    // MARK: окно звонка
    do {
        let snap = TelemostDesktop.snapshot(window(title: "1х1 Пётр / Мария", count: "2", mic: "Turn off microphone"))
        equal(snap?.count, 2, "счётчик на кнопке «Участники»")
        equal(snap?.myUnmuted, true, "«Turn off microphone» — микрофон включён")
        equal(snap?.title, "1х1 Пётр / Мария", "название встречи — заголовок окна звонка, не мессенджера")
        equal(snap?.tiles ?? [ZoomSpeakers.Tile(name: "x", active: false, isSelf: false)], [], "без списка имён нет")

        let muted = TelemostDesktop.snapshot(window(title: "Yandex Telemost", count: "245", mic: "Turn on microphone"))
        equal(muted?.myUnmuted, false, "«Turn on microphone» — выключен")
        equal(muted?.count, 245, "большая встреча")
        equal(muted?.title, nil, "общий заголовок — не название")

        let blank = TelemostDesktop.snapshot(window(title: "Планёрка", count: "", mic: nil))
        equal(blank?.count, nil, "пустой счётчик — неизвестно")
        equal(blank?.myUnmuted, nil, "кнопки нет — неизвестно")

        let messengerOnly = Node(role: "AXApplication", children: [
            Node(role: "AXWindow", title: "Yandex Telemost", children: [
                Node(role: "AXGroup", identifier: "TApplication.Messenger::MessengerWindow.frame"),
            ]),
        ])
        check(TelemostDesktop.snapshot(messengerOnly) == nil, "только мессенджер — не звонок")
    }

    // MARK: подписи микрофона и заголовки
    do {
        equal(TelemostDesktop.microphone("Выключить микрофон"), true, "русский интерфейс: включён")
        equal(TelemostDesktop.microphone("Включить микрофон"), false, "русский интерфейс: выключен")
        equal(TelemostDesktop.microphone("Turn off camera"), nil, "камера — не микрофон")
        equal(TelemostDesktop.meetingTitle("Яндекс Телемост"), nil, "общий заголовок по-русски")
        equal(TelemostDesktop.meetingTitle("  Синк   команды "), "Синк команды", "пробелы схлопнуты")
    }

    // MARK: открытый список участников
    do {
        let list = base + "ParticipantListWidget.QScrollArea.ParticipantListItemWidget"
        func row(_ texts: [String], mic: String? = nil) -> Node {
            Node(role: "AXGroup", identifier: list, children:
                    texts.map { Node(role: "AXStaticText", value: $0, identifier: list + ".QLabel") }
                    + (mic.map { [Node(role: "AXButton", label: $0, identifier: list + ".micButton")] } ?? []))
        }
        let panel = Node(role: "AXGroup", identifier: base + "ParticipantListWidget", children: [
            row(["Пётр Иванов (вы)"], mic: "Turn off microphone"),
            row(["Мария Смирнова", "Организатор"], mic: "Microphone is off"),
            row(["Гость 42"]),
            row(["3"]),
        ])
        let snap = TelemostDesktop.snapshot(window(title: "Синк", count: "3", mic: "Turn off microphone", extra: [panel]))
        equal(snap?.tiles.map(\.name) ?? [], ["Пётр Иванов", "Мария Смирнова", "Гость 42"], "имена из строк списка")
        equal(snap?.tiles.map(\.isSelf) ?? [], [true, false, false], "пометка «(вы)»")
        equal(snap?.tiles.map(\.unmuted) ?? [], [true, false, nil], "микрофон по значку строки")
        equal(snap?.selfIndex, 0, "своя строка находится")
    }

    // MARK: журнал qt.log
    do {
        let info = #" "{\"data\":{\"method\":\"handleMeetingInfo\",\"payload\":{\"meetingId\":\"https://telemost.360.yandex.ru/j/111\",\"meetingName\":\"Синк \\\"Альфа\\\"\"}},\"id\":\"a\",\"type\":\"request\"}""#
        let count = #" "{\"data\":{\"method\":\"handleMeetingParticipantsCountChanged\",\"payload\":{\"count\":2,\"meetingId\":\"https://telemost.360.yandex.ru/j/111\"}},\"id\":\"b\",\"type\":\"request\"}""#
        let bye = #" "{\"data\":{\"method\":\"handleMeetingDisconnect\",\"payload\":{\"id\":\"self\",\"meetingId\":\"https://telemost.360.yandex.ru/j/111\",\"source\":\"end-call\"}},\"id\":\"c\",\"type\":\"request\"}""#
        equal(TelemostLog.event(info), .init(method: "handleMeetingInfo", meetingID: "https://telemost.360.yandex.ru/j/111",
                                             meetingName: "Синк \"Альфа\""), "название с кавычками внутри")
        equal(TelemostLog.event(count)?.count, 2, "число участников")
        equal(TelemostLog.event(#""MainMes" Request(T->M) to web:"#), nil, "служебная строка — не событие")
        equal(TelemostLog.event(#" "{\"data\":{\"method\":\"handleChatOpened\",\"payload\":{}}}""#), nil, "чужой метод")

        var state = TelemostLog.State()
        check(state.apply(TelemostLog.event(info)!), "название — изменение")
        check(state.apply(TelemostLog.event(count)!), "счётчик — изменение")
        check(!state.apply(TelemostLog.event(count)!), "тот же счётчик — без изменений")
        equal(state.count, 2, "счётчик запомнен")
        equal(state.meetingName, "Синк \"Альфа\"", "название запомнено")
        state.apply(.init(method: "handleMeetingParticipantsCountChanged", meetingID: "https://telemost.360.yandex.ru/j/222", count: 5))
        equal(state.meetingName, nil, "другая встреча сбрасывает название")
        equal(state.count, 5, "и берёт свой счётчик")
        state.apply(TelemostLog.event(bye)!)
        equal(state.count, 5, "выход из чужой встречи не трогает текущую")

        // Хвост файла: неполная строка ждёт, обрезанный журнал читается сначала.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("telemost-qt-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try? (info + "\n" + String(count.prefix(30))).write(to: url, atomically: true, encoding: .utf8)
        let first = TelemostLog.tail(url, from: 0)
        equal(first.events.map(\.method), ["handleMeetingInfo"], "полная строка прочитана")
        try? (info + "\n" + count + "\n").write(to: url, atomically: true, encoding: .utf8)
        let second = TelemostLog.tail(url, from: first.offset)
        equal(second.events.map(\.count), [2], "дописанная строка дочитана")
        try? (bye + "\n").write(to: url, atomically: true, encoding: .utf8)
        equal(TelemostLog.tail(url, from: second.offset).events.map(\.method), ["handleMeetingDisconnect"],
              "журнал пересоздан — с начала")
    }

    // MARK: лента пишет число участников и название
    do {
        var writer = SpeakerTimelineWriter(source: "telemost-desktop")
        let line = writer.observe(ZoomSpeakers.Snapshot(tiles: [], myUnmuted: true, count: 2, title: "Синк"), at: 1)
        check(line?.contains("\"count\":2") == true, "count в строке ленты")
        check(line?.contains("\"title\":\"Синк\"") == true, "title в строке ленты")
        check(writer.observe(ZoomSpeakers.Snapshot(tiles: [], myUnmuted: true, count: 2, title: "Синк"), at: 2) == nil,
              "без перемен — без строки")
        check(writer.observe(ZoomSpeakers.Snapshot(tiles: [], myUnmuted: true, count: 3, title: "Синк"), at: 3) != nil,
              "новый счётчик — новая строка")
        var zoom = SpeakerTimelineWriter(source: "zoom")
        check(zoom.observe([.init(name: "Пётр", active: true, isSelf: false)], at: 0)?.contains("count") == false,
              "без счётчика поле не пишется")
    }
}
