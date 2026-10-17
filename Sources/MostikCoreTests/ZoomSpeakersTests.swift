import Foundation
import MostikCore

/// Имена говорящих из Zoom через Accessibility (прототип): разбор подписи плитки и лента смен.
func runZoomSpeakersTests() {
    // MARK: подпись плитки
    do {
        equal(ZoomSpeakers.tile(from: "Пётр Иванов, Computer audio, active speaker"),
              .init(name: "Пётр Иванов", active: true, isSelf: false), "англ. Zoom: говорит")
        equal(ZoomSpeakers.tile(from: "Мария (Host), Computer audio unmuted"),
              .init(name: "Мария", active: false, isSelf: false, unmuted: true), "роль в скобках — не имя")
        equal(ZoomSpeakers.tile(from: "Олег (Me), Computer audio, active speaker"),
              .init(name: "Олег", active: true, isSelf: true), "своя плитка")
        equal(ZoomSpeakers.tile(from: "Олег (Я), Звук компьютера"),
              .init(name: "Олег", active: false, isSelf: true), "русский Zoom (догадка до звонка)")
        equal(ZoomSpeakers.tile(from: "Mute, Alt+A"), nil, "кнопка — не плитка")
        equal(ZoomSpeakers.tile(from: "Пётр"), nil, "без состояния — не плитка")
        equal(ZoomSpeakers.tile(from: ", Computer audio"), nil, "пустое имя")
    }

    // MARK: настоящие подписи Zoom 7.2 (звонок, галерея, видео выключено)
    do {
        equal(ZoomSpeakers.tile(from: "Alex Morgan, Computer audio muted, Video off"),
              .init(name: "Alex Morgan", active: false, isSelf: false, unmuted: false), "микрофон выключен")
        equal(ZoomSpeakers.tile(from: "Alex Morgan, Computer audio unmuted, Video off"),
              .init(name: "Alex Morgan", active: false, isSelf: false, unmuted: true), "микрофон включён")
        equal(ZoomSpeakers.myAudio(from: "Unmute my audio"), false, "у меня выключен")
        equal(ZoomSpeakers.myAudio(from: "Mute my audio"), true, "у меня включён")
        equal(ZoomSpeakers.myAudio(from: "Audio options"), nil)

        // Один человек с двух устройств: имена одинаковые, своя плитка — по совпадению с моим микрофоном.
        let me = ZoomSpeakers.Tile(name: "Alex Morgan", active: false, isSelf: false, unmuted: false)
        let other = ZoomSpeakers.Tile(name: "Alex Morgan", active: false, isSelf: false, unmuted: true)
        let snap = ZoomSpeakers.Snapshot(tiles: [other, me], myUnmuted: false)
        equal(snap.selfIndex, 1, "своя — вторая")
        equal(snap.others, [other], "собеседник — первая")
        equal(ZoomSpeakers.Snapshot(tiles: [me, me], myUnmuted: false).selfIndex, nil, "обе как у меня — не ясно")
        equal(ZoomSpeakers.Snapshot(tiles: [other, me]).selfIndex, nil, "без кнопки — не ясно")

        var writer = SpeakerTimelineWriter(source: "zoom")
        check(writer.observe(snap, at: 40)?.contains("\"unmuted\":[\"Alex Morgan\"]") == true,
              "открытый микрофон собеседника — в ленту")
        var blind = SpeakerTimelineWriter(source: "zoom")
        check(blind.observe(ZoomSpeakers.Snapshot(tiles: [other, other]), at: 1)?.contains("\"unmuted\":[]") == true,
              "своя не найдена — открытые микрофоны не пишем")
    }

    // MARK: лента — строка только при смене говорящих
    do {
        var writer = SpeakerTimelineWriter(source: "zoom")
        let petr = ZoomSpeakers.Tile(name: "Пётр", active: true, isSelf: false)
        let me = ZoomSpeakers.Tile(name: "Олег", active: false, isSelf: true)
        let first = writer.observe([petr, me], at: 1.234)
        check(first?.contains("\"active\":[\"Пётр\"]") == true && first?.contains("\"at\":1.23") == true
              && first?.contains("\"self\":[\"Олег\"]") == true && first?.contains("\"source\":\"zoom\"") == true,
              "первая строка: говорящий, своё имя, источник")
        equal(writer.observe([petr, me], at: 1.5), nil, "тот же говорящий — без строки")
        check(writer.observe([], at: 3)?.contains("\"active\":[]") == true, "тишина — строкой")
        writer.reset()
        check(writer.observe([], at: 3.1) != nil, "после паузы снимок пишется заново")
    }

    // MARK: звонок вживую: сначала один я, потом собеседница; подпись отстаёт от кнопки
    do {
        func tiles(_ rows: [String]) -> [ZoomSpeakers.Tile] { rows.compactMap(ZoomSpeakers.tile(from:)) }
        var writer = SpeakerTimelineWriter(source: "zoom")
        _ = writer.observe(.init(tiles: tiles(["Олег, Computer audio muted"]), myUnmuted: false), at: 0.5)
        _ = writer.observe(.init(tiles: []), at: 1.8)  // окно на миг пропало — отсчёт не сбивается
        _ = writer.observe(.init(tiles: tiles(["Олег, Computer audio muted"])), at: 161)  // панель спрятана
        let known = writer.observe(.init(tiles: tiles(["Олег, Computer audio muted"]), myUnmuted: false), at: 224)
        check(known?.contains("\"self\":[\"Олег\"]") == true, "один в звонке дольше 5 с — это я")
        // Своя плитка уже «unmuted», кнопка ещё «Unmute»: по микрофону своей стала бы чужая.
        let lag = writer.observe(.init(tiles: tiles(["Мария, Computer audio muted, Video off",
                                                     "Олег, Computer audio unmuted, Video off"]),
                                       myUnmuted: false), at: 268)
        check(lag?.contains("\"unmuted\":[]") == true, "своя плитка узнана по имени, а не по отстающему микрофону")
        check(lag?.contains("\"present\":[\"Мария\",\"Олег\"]") == true, "состав окна — в ленту")
        let open = writer.observe(.init(tiles: tiles(["Олег, Computer audio unmuted, Video off",
                                                      "Мария, Computer audio unmuted, Video off"])), at: 290.5)
        check(open?.contains("\"unmuted\":[\"Мария\"]") == true, "без кнопки своя — по имени")

        var stranger = SpeakerTimelineWriter(source: "zoom")
        _ = stranger.observe(.init(tiles: tiles(["Мария, No audio connected"]), myUnmuted: false), at: 1)
        _ = stranger.observe(.init(tiles: tiles(["Мария, No audio connected"]), myUnmuted: false), at: 20)
        let early = stranger.observe(.init(tiles: tiles(["Мария, Computer audio muted", "Олег, Computer audio muted"]),
                                           myUnmuted: false), at: 21)
        check(early?.contains("\"self\":[]") == true, "чужая плитка, пока грузятся остальные, — не я")

        // Встреча: отметки «(я)» нет, одному побыть не довелось — узнаём по имени учётной записи.
        var account = SpeakerTimelineWriter(source: "zoom", accountName: "Alex  Morgan")
        let named = account.observe(.init(tiles: tiles(["Sam K. Rivera, Computer audio muted",
                                                        "Alex Morgan, Computer audio muted"])), at: 0.4)
        check(named?.contains("\"self\":[\"Alex Morgan\"]") == true, "своя плитка — по имени учётной записи")
        check(account.learnedName == "Alex Morgan", "узнанное имя отдаётся для памяти между встречами")

        // Имя в Zoom не совпадает с учётной записью, но узнано на прошлой встрече.
        var remembered = SpeakerTimelineWriter(source: "zoom", accountName: "test.user", knownSelf: ["Олег П."])
        let first = remembered.observe(.init(tiles: tiles(["Мария, Computer audio unmuted",
                                                           "Олег П., Computer audio unmuted"])), at: 0.5)
        check(first?.contains("\"self\":[\"Олег П.\"]") == true, "своё имя с прошлой встречи — с первой секунды")
        check(first?.contains("\"unmuted\":[\"Мария\"]") == true, "и сразу виден микрофон собеседницы")

        // Две знакомые плитки (два устройства или тёзки) — не угадываем.
        var twins = SpeakerTimelineWriter(source: "zoom", knownSelf: ["Олег"])
        let both = twins.observe(.init(tiles: tiles(["Олег, Computer audio unmuted", "Олег, Computer audio muted"])), at: 0.5)
        check(both?.contains("\"self\":[]") == true, "две плитки со своим именем — себя не назначаем")
    }
}
