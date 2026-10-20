import Foundation
import MostikCore

/// Выбор микрофона (R3b): только для захвата Mostik, вход по умолчанию в macOS не меняется.
func runMicChoiceTests() {
    let built = MicChoice.Device(id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    let usb = MicChoice.Device(id: 77, uid: "usb-mic", name: "USB Mic")
    let devices = [built, usb]

    // «Как в системе» идёт за системным входом.
    equal(MicChoice.resolve(chosenUID: "", devices: devices, systemDefault: 41),
          MicChoice.Resolution(device: 41, pinned: false, chosenMissing: false), "как в системе — системный вход")
    equal(MicChoice.resolve(chosenUID: "", devices: devices, systemDefault: 77).device, 77, "системный вход сменился — идём за ним")
    equal(MicChoice.resolve(chosenUID: "", devices: devices, systemDefault: nil).device, nil, "входа нет")

    // Выбранный закреплён: смена системного входа его не переключает.
    for system: UInt32? in [41, 77, 99, nil] {
        equal(MicChoice.resolve(chosenUID: "usb-mic", devices: devices, systemDefault: system),
              MicChoice.Resolution(device: 77, pinned: true, chosenMissing: false), "выбран USB, системный \(String(describing: system))")
    }
    // Выбранного нет — пишем с системного и говорим об этом.
    equal(MicChoice.resolve(chosenUID: "airpods", devices: devices, systemDefault: 41),
          MicChoice.Resolution(device: 41, pinned: false, chosenMissing: true), "выбранный не подключён — системный вход")

    let was = UIText.isRussian
    defer { UIText.isRussian = was }
    UIText.isRussian = true
    equal(MicChoice.hint(chosenUID: "airpods", chosenName: "AirPods Pro", devices: devices),
          "«AirPods Pro» не подключён — пишем с системного входа.")
    check(MicChoice.hint(chosenUID: "usb-mic", chosenName: "USB Mic", devices: devices).contains("системный микрофон не меняется"),
          "подсказка говорит, что система не меняется")

    // Тёплый микрофон с закреплённым входом: смена системного входа — не повод пересобирать движок.
    func state(_ system: UInt32?) -> WarmMicPolicy.State {
        let r = MicChoice.resolve(chosenUID: "usb-mic", devices: devices, systemDefault: system)
        return WarmMicPolicy.State(warmWanted: true, authorized: true, recording: false, running: true,
                                   boundDevice: 77, currentDevice: r.device, currentTransport: .usb)
    }
    equal(WarmMicPolicy.decide(state(41)), .none, "системный вход сменился, выбранный на месте — движок не трогаем")
    equal(WarmMicPolicy.decide(state(99)), .none, "и на Bluetooth-гарнитуре в системе — тоже")
    // Выбранный вынули: переезд на системный вход.
    let gone = MicChoice.resolve(chosenUID: "usb-mic", devices: [built], systemDefault: 41)
    equal(WarmMicPolicy.decide(WarmMicPolicy.State(warmWanted: true, authorized: true, recording: false, running: true,
                                                   boundDevice: 77, currentDevice: gone.device, currentTransport: .builtIn)),
          .restart, "выбранный вынули — перезапуск на системном входе")

    // Страж: Mostik не пишет вход по умолчанию в macOS.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let fm = FileManager.default
    var scanned = 0
    if let walker = fm.enumerator(atPath: root.path) {
        for case let path as String in walker where path.hasSuffix(".swift") && !path.hasPrefix("MostikCoreTests/") {
            guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { continue }
            scanned += 1
            check(!fileSetsDefault(text), "\(path): нет записи kAudioHardwarePropertyDefaultInputDevice")
        }
    }
    check(scanned > 50, "страж прошёл по исходникам (\(scanned) файлов)")
    // Страж ловит прежнюю запись системного входа.
    check(fileSetsDefault("""
        func setDefault(_ id: UInt32) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: 0, mElement: 0)
            return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, 4, &id) == noErr
        }
        """), "страж узнаёт запись системного входа")
    check(!fileSetsDefault("func read() { AudioObjectGetPropertyData(kAudioHardwarePropertyDefaultInputDevice) }"),
          "чтение системного входа — не нарушение")
}

/// Файл пишет системный вход: в одной функции адрес на `kAudioHardwarePropertyDefaultInputDevice`
/// и `AudioObjectSetPropertyData`.
private func fileSetsDefault(_ text: String) -> Bool {
    text.components(separatedBy: "func ").contains { body in
        body.contains("kAudioHardwarePropertyDefaultInputDevice") && body.contains("AudioObjectSetPropertyData")
    }
}

/// Залипший микрофон: нули от входа — шаги восстановления, живой звук — ничего не трогаем.
func runSilentInputWatchTests() {
    let tick = 0.1
    func run(_ watch: inout SilentInputWatch, seconds: Double, silent: Bool, vp: Bool) -> [SilentInputWatch.Action] {
        var actions: [SilentInputWatch.Action] = []
        for _ in 0..<Int((seconds / tick).rounded()) {
            let action = watch.feed(seconds: tick, silent: silent, voiceProcessing: vp)
            if action != .none { actions.append(action) }
        }
        return actions
    }

    var live = SilentInputWatch()
    equal(run(&live, seconds: 0.3, silent: true, vp: true), [], "обработка голоса молчит на старте до 0,3 с — не повод")
    equal(run(&live, seconds: 5, silent: false, vp: true), [], "пошёл звук — шагов нет")
    equal(run(&live, seconds: 5, silent: true, vp: true), [], "тишина после звука — пауза в речи, а не залипший вход")
    check(!live.gaveUp, "живой вход не «сдался»")

    var stuckVP = SilentInputWatch()
    equal(run(&stuckVP, seconds: 1.3, silent: true, vp: true), [.dropVoiceProcessing], "с обработкой голоса — сначала без неё")
    equal(run(&stuckVP, seconds: 1.3, silent: true, vp: false), [.reconnect], "потом — движок заново")
    equal(run(&stuckVP, seconds: 1.3, silent: true, vp: false), [.warn], "потом — сказать, что микрофон молчит")
    equal(run(&stuckVP, seconds: 10, silent: true, vp: false), [], "предупреждение одно")
    check(stuckVP.gaveUp, "запись так и не дала звука")

    var stuck = SilentInputWatch()
    equal(run(&stuck, seconds: 1.3, silent: true, vp: false), [.reconnect], "без обработки голоса — сразу движок заново")
    equal(run(&stuck, seconds: 0.2, silent: false, vp: false), [.recovered], "после переподключения пошёл звук")
    check(!stuck.gaveUp, "восстановился — не «сдался»")
    equal(run(&stuck, seconds: 3, silent: true, vp: false), [], "после восстановления тишина — уже речь с паузами")
}

/// Сбой 2026-10-19: движок останавливали прямо на `AVAudioEngineConfigurationChange`, пока HAL
/// пересобирал Bluetooth-агрегат. Сигналы склеиваются, перенастройка — одна, после тишины.
func runWarmMicSettleTests() {
    var settle = WarmMicPolicy.Settle()
    equal(settle.fire(0), nil, "без сигналов таймеру нечего делать")
    let first = settle.signal(formatChanged: false)
    let second = settle.signal(formatChanged: true)
    let third = settle.signal(formatChanged: false)
    equal(settle.fire(first), nil, "таймер раннего сигнала молчит: пачка ещё идёт")
    equal(settle.fire(second), nil, "и второго тоже")
    equal(settle.fire(third), true, "последний таймер — одна перенастройка; формат сменился в пачке")
    equal(settle.fire(third), nil, "повторно не срабатывает")
    let alone = settle.signal(formatChanged: false)
    equal(settle.fire(alone), false, "после сброса формат снова «не менялся»")
    check(WarmMicPolicy.settleDelay >= 0.2 && WarmMicPolicy.settleDelay <= 0.5,
          "пауза дольше пересборки агрегата (~150 мс в журнале) и незаметна при смене микрофона")
}
