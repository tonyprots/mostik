import AppKit
import Combine
import Foundation
import MostikCore
import SwiftUI

/// Уровень микрофона для волны (шаг 2, п. 8): 20 раз в секунду — только у тех, кто рисует волну,
/// а не у всех видов, которые смотрят на `AppModel`.
@MainActor
public final class LevelMeter: ObservableObject {
    @Published public var levels: [Float] = Array(repeating: 0, count: 24)
    public init() {}
}

/// Часы записи (шаг 2, п. 8): публикуются раз в секунду — на экране минуты и секунды.
@MainActor
public final class LiveClock: ObservableObject {
    @Published public var elapsed: TimeInterval = 0
    @Published public var meetingElapsed: TimeInterval = 0
    public init() {}
}

/// Значок в строке меню (шаг 2, п. 8 и решение автора): меняется по смене фазы,
/// а при записи «дышит» голосом — ступенью уровня не чаще 10 раз в секунду (`MenuBarMeter`).
/// Во время записи встречи — значок записи и время рядом (`MenuBarStatus`): публикуется раз в секунду,
/// перерисовывается только значок, окна — нет. «Уменьшить движение» — без бегущего времени.
@MainActor
public final class MenuBarIcon: ObservableObject {
    public enum Phase: Equatable { case idle, recording, transcribing }
    @Published public private(set) var phase: Phase = .idle
    /// Ступень уровня 0…3 при записи; nil — статичный значок («Уменьшить движение», нет звука).
    @Published public private(set) var step: Int?
    @Published public private(set) var meeting: MeetingMenu.State = .off
    /// Время встречи рядом со значком; nil — только значок.
    @Published public private(set) var timer: String?
    private var meetingElapsed: Double = 0
    private var meter = MenuBarMeter()
    /// «Уменьшить движение» в системе; снимки и тесты подменяют.
    public var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    public init() {}

    public func set(_ phase: Phase) {
        guard phase != self.phase else { return }
        self.phase = phase
        meter = MenuBarMeter()
        if step != nil { step = nil }
    }

    public func level(_ level: Float, at now: Double, reduceMotion: Bool) {
        guard phase == .recording, !reduceMotion else { return }
        if let next = meter.update(level: level, at: now) { step = next }
    }

    /// Состояние встречи и её время; публикует, только если на значке что-то изменилось.
    public func setMeeting(_ state: MeetingMenu.State, elapsed: Double) {
        meetingElapsed = elapsed
        if state != meeting { meeting = state }
        let next = look.timer
        if next != timer { timer = next }
    }

    public var look: MenuBarStatus.Look {
        let dictation: MenuBarStatus.Dictation = switch phase {
        case .idle: .idle
        case .recording: .recording
        case .transcribing: .transcribing
        }
        return MenuBarStatus.look(dictation: dictation, meeting: meeting, meetingElapsed: meetingElapsed,
                                  reduceMotion: reduceMotion())
    }

    public var symbol: String { look.symbol }

    /// Доля заливки символа; nil — без переменного значения.
    public var variableValue: Double? { step.map(MenuBarMeter.variableValue(step:)) }
}

/// Живые данные записи — одна точка записи в модель для приложения и для бенча (`MostikBench`).
@MainActor
public enum LiveFeed {
    /// Новый уровень в ленту волны: рост мгновенный, спад ~120 мс (`LevelSmoothing`, шаг 3, п. 12).
    public static func pushLevel(_ level: Float, into model: AppModel) {
        var levels = model.meter.levels
        LevelSmoothing.push(level, into: &levels)
        model.meter.levels = levels
    }

    /// Тик таймера плашки: публикуем, только когда сменилась секунда.
    public static func tickElapsed(_ elapsed: TimeInterval, model: AppModel) {
        let shown = elapsed.rounded(.down)
        if model.clock.elapsed != shown { model.clock.elapsed = shown }
    }
}

/// Волна, которая сама следит за уровнем: родитель не перерисовывается 20 раз в секунду.
public struct MeterReader<Content: View>: View {
    @ObservedObject var meter: LevelMeter
    let content: ([Float]) -> Content
    public init(_ meter: LevelMeter, @ViewBuilder content: @escaping ([Float]) -> Content) {
        self.meter = meter
        self.content = content
    }
    public var body: some View { content(meter.levels) }
}

/// Текст с часами записи: перерисовывается раз в секунду только он.
public struct ClockReader<Content: View>: View {
    @ObservedObject var clock: LiveClock
    let content: (LiveClock) -> Content
    public init(_ clock: LiveClock, @ViewBuilder content: @escaping (LiveClock) -> Content) {
        self.clock = clock
        self.content = content
    }
    public var body: some View { content(clock) }
}
