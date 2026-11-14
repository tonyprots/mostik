// Живая проверка аудио-тракта на настоящем микрофоне (аудит 2026-11-14, S3/S4/S14/S19).
//   scripts/swift.sh run MostikMicCheck [tail|warm|recover|meeting|idle20|system …]
// «system» (тон через динамики) в общий прогон не входит: нужен доступ к записи звука системы.
// Системный вход не меняется: переключение идёт через выбор микрофона Mostik (`setMicDevice`),
// «другим устройством» служит виртуальный вход (Zoom, Teams). Сбой запуска входа подставляется.
import AVFoundation
import Foundation
import MostikCore
@_spi(Testing) import MostikKit

setvbuf(stdout, nil, _IONBF, 0)

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-miccheck-\(getpid())")
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }

let failures = Box(0)
func verdict(_ ok: Bool, _ text: String) {
    print(ok ? "  ✓ \(text)" : "  ✗ \(text)")
    if !ok { failures.update { $0 += 1 } }
}
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
func ms(_ seconds: Double) -> String { String(format: "%.0f мс", seconds * 1000) }
func sec(_ seconds: Double) -> String { String(format: "%.2f с", seconds) }
func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

/// Сэмплы WAV (PCM16 моно, заголовок 44 байта).
func samples(_ url: URL) -> [Int16] {
    guard let data = try? Data(contentsOf: url), data.count > 44 else { return [] }
    return data.dropFirst(44).withUnsafeBytes { raw in Array(raw.bindMemory(to: Int16.self)) }
}
func peak(_ xs: ArraySlice<Int16>) -> Int { xs.reduce(0) { max($0, abs(Int($1))) } }

guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
    print("Нет доступа к микрофону у процесса, из которого запущена проверка.")
    exit(2)
}
let inputs = AudioInputs.list()
let system = AudioInputs.systemDefaultID()
print("Входы:")
for device in inputs {
    print("  \(device.id == system ? "•" : " ") \(device.name) — \(AudioInputs.transport(of: device.id))")
}
guard let system, WarmMicPolicy.suitsWarm(AudioInputs.transport(of: system)) else {
    print("Системный вход не встроенный и не проводной — проверка рассчитана на него.")
    exit(2)
}
let other = inputs.first { $0.id != system && AudioInputs.transport(of: $0.id) == .virtual }
if let other { print("Второе устройство: \(other.name)") } else { print("Виртуального входа нет — сценарии со сменой устройства пропущу.") }

let wanted = Set(CommandLine.arguments.dropFirst())
func enabled(_ name: String) -> Bool { wanted.isEmpty || wanted.contains(name) }  // «idle12» — встреча без смены устройств, 12 с

let faults = Box(0)
let events = Box<[Recorder.InputTrouble]>([])
let recorder = Recorder()
recorder.startFault = { faults.update { left in
    guard left > 0 else { return nil }
    left -= 1
    return RecorderError.noInput
} }
recorder.onInputTrouble = { trouble in events.update { $0.append(trouble) } }
var takes = 0
func take() -> URL { takes += 1; return folder.appendingPathComponent("take-\(takes).wav") }

// MARK: S19 — хвост записи

if enabled("tail") {
    print("\nS19. Хвост записи: сколько звука попадает в файл с ожиданием последнего буфера и без")
    recorder.setWarm(true)
    pause(1.5)
    var extra: [Bool: [Double]] = [true: [], false: []]
    var waits: [Double] = []
    for trial in 0..<24 {
        let drain = trial % 2 == 0
        recorder.drainsTail = drain
        do {
            try recorder.begin(to: take())
            let started = now()
            pause(0.8 + Double.random(in: 0..<0.1))
            let released = now()
            let file = recorder.end()
            let ended = now()
            // Преролл тёплого микрофона одинаков в обоих режимах; разница средних — и есть хвост.
            extra[drain]?.append((file?.seconds ?? 0) - (released - started))
            if drain { waits.append(ended - released) }
        } catch { verdict(false, "запись не началась: \(error)") }
        pause(0.7)
    }
    recorder.drainsTail = true
    let gained = mean(extra[true] ?? []) - mean(extra[false] ?? [])
    print("  без ожидания: файл длиннее удержания в среднем на \(ms(mean(extra[false] ?? [])))")
    print("  с ожиданием:  на \(ms(mean(extra[true] ?? [])))")
    print("  ожидание в end(): в среднем \(ms(mean(waits))), худшее \(ms(waits.max() ?? 0))")
    verdict(gained >= 0.02, "в файл попадает на \(ms(gained)) больше звука с конца записи")
    verdict((waits.max() ?? 1) <= TailDrain.timeout + 0.05, "ожидание не дольше \(ms(TailDrain.timeout)) с запасом")

    // Холодный вход: тёплый выключен, движок стартует с записью.
    recorder.setWarm(false)
    pause(0.6)
    var cold: [Double] = []
    for _ in 0..<4 {
        do {
            try recorder.begin(to: take())
            pause(0.9)
            let released = now()
            let file = recorder.end()
            cold.append(now() - released)
            verdict((file?.seconds ?? 0) > 0.5, "холодный вход: записано \(sec(file?.seconds ?? 0)), ожидание хвоста \(ms(cold.last ?? 0))")
        } catch { verdict(false, "холодная запись не началась: \(error)") }
        pause(0.4)
    }
}

// MARK: S3 — тёплый микрофон после чужого входа

if enabled("warm"), let other {
    print("\nS3. Тёплый микрофон: ушли на «\(other.name)», вернулись, первый запуск входа сорван")
    recorder.setWarm(true)
    pause(1.5)
    verdict(recorder.isWarm, "на встроенном входе тёплый включён")
    recorder.setMicDevice(other.uid)
    pause(1)
    verdict(!recorder.isWarm, "на виртуальном входе тёплый выключен")
    faults.value = 1
    recorder.setMicDevice("")
    pause(2.2)
    verdict(faults.value == 0, "сбой запуска сработал")
    do {
        let url = take()
        try recorder.begin(to: url)
        pause(1)
        let file = recorder.end()
        let seconds = file?.seconds ?? 0
        // Преролл есть только у работающего тёплого входа: холодная запись дала бы около 1,0 с.
        verdict(seconds >= 1.35, "тёплый вернулся после сбоя: 1 с записи дала \(sec(seconds)) — с прероллом")
        verdict(peak(samples(url)[...]) > 0, "в записи живой звук, не нули")
    } catch { verdict(false, "запись после возврата не началась: \(error)") }
    recorder.setWarm(false)
    pause(0.6)
}

// MARK: S4 — вход не перезапустился посреди диктовки

if enabled("recover"), let other {
    print("\nS4. Посреди диктовки вход сменился, два запуска подряд сорваны")
    recorder.setWarm(false)
    recorder.setMicDevice("")
    pause(0.6)
    events.value = []
    do {
        let url = take()
        try recorder.begin(to: url)
        pause(1)
        faults.value = 2
        recorder.setMicDevice(other.uid)      // перезапуск входа: два сбоя, третья попытка проходит
        pause(2.2)
        let seen = events.value
        verdict(seen == [.retrying, .retrying, .recovered], "плашка получила: \(seen)")
        recorder.setMicDevice("")             // обратно на встроенный — уже без сбоев
        pause(1.5)
        let file = recorder.end()
        let all = samples(url)
        let lastSecond = all.suffix(16_000)
        verdict((file?.seconds ?? 0) >= 2.5, "запись продолжилась: \(sec(file?.seconds ?? 0))")
        verdict(peak(lastSecond) > 0, "после восстановления в записи живой звук")
    } catch { verdict(false, "запись не началась: \(error)") }

    print("\nS4. Вход не вернулся совсем: все повторы сорваны")
    events.value = []
    do {
        let url = take()
        try recorder.begin(to: url)
        pause(1)
        faults.value = 100
        recorder.setMicDevice(other.uid)
        pause(4.6)
        let seen = events.value
        verdict(seen == [.retrying, .retrying, .retrying, .lost], "плашка получила: \(seen)")
        faults.value = 0
        let file = recorder.end()
        verdict((file?.seconds ?? 0) >= 0.8, "записанное до сбоя сохранено: \(sec(file?.seconds ?? 0))")
    } catch { verdict(false, "запись не началась: \(error)") }
    recorder.setMicDevice("")
    pause(0.6)

    // После потери входа следующая диктовка должна работать как обычно.
    do {
        let url = take()
        try recorder.begin(to: url)
        pause(1)
        let file = recorder.end()
        verdict((file?.seconds ?? 0) >= 0.7 && peak(samples(url)[...]) > 0,
                "следующая диктовка после потери входа пишется: \(sec(file?.seconds ?? 0))")
    } catch { verdict(false, "следующая диктовка не началась: \(error)") }
}

// MARK: S14 — дорожки встречи при смене устройства

if enabled("meeting"), let other {
    print("\nS14. Встреча: вход меняется дважды посреди записи")
    for fills in [false, true] {
        let dir = folder.appendingPathComponent(fills ? "meeting-fill" : "meeting-plain")
        let meeting = MeetingRecorder(folder: dir)
        meeting.fillsGaps = fills
        do {
            // Эталон — собственные часы дорожки: от первого буфера до последнего она должна
            // занимать в файле столько же, сколько прошло времени.
            var firstAt: [MeetingWatchdog.Track: Double] = [:]
            let began = Date().timeIntervalSince1970
            try meeting.start()
            while firstAt.count < 2, Date().timeIntervalSince1970 - began < 3 {
                for (track, at) in meeting.poll().lastBuffer where firstAt[track] == nil { firstAt[track] = at }
                pause(0.005)
            }
            verdict(firstAt[.mic] != nil, "микрофон встречи пишет")
            pause(2)
            meeting.micDeviceUID = other.uid
            let switchStarted = now()
            meeting.simulateInputChange()
            let firstSwitch = now() - switchStarted
            pause(1.5)
            meeting.micDeviceUID = ""
            meeting.simulateInputChange()
            pause(2)
            let lastAt = meeting.poll().lastBuffer
            let files = meeting.stop()
            let label = fills ? "с заполнением" : "без заполнения (как было)"
            print("  \(label): перенастройка входа заняла \(ms(firstSwitch))")
            var drift: [MeetingWatchdog.Track: Double] = [:]
            for track in MeetingWatchdog.Track.allCases {
                let file = WAVInfo.duration(of: track == .mic ? files.mic : files.system) ?? 0
                guard let first = firstAt[track], let last = lastAt[track] else {
                    print("    \(track.rawValue): буферов не было"); continue
                }
                // Время прихода первого буфера — конец его звука, поэтому span короче файла на один буфер.
                drift[track] = file - (last - first)
                print("    \(track.rawValue): в файле \(sec(file)), по часам между первым и последним буфером \(sec(last - first)), разница \(ms(file - (last - first)))")
            }
            if fills, let mic = drift[.mic] {
                verdict(mic >= -0.05 && mic <= 0.2, "дорожка микрофона идёт вровень с часами: разница \(ms(mic))")
            }
        } catch {
            verdict(false, "запись встречи не началась: \(error.localizedDescription)")
        }
        pause(0.5)
    }
}

// MARK: звук системы — пересборка тапа при смене устройства вывода

/// Итог проверочной встречи: длина файлов дорожек и когда шли буферы (секунды от старта записи).
struct MeetingRun {
    var file: [MeetingWatchdog.Track: Double] = [:]
    var first: [MeetingWatchdog.Track: Double] = [:]
    var last: [MeetingWatchdog.Track: Double] = [:]
    /// На сколько файл дорожки длиннее времени между её первым и последним буфером.
    func drift(_ track: MeetingWatchdog.Track) -> Double? {
        guard let file = file[track], let first = first[track], let last = last[track] else { return nil }
        return file - (last - first)
    }
}

/// Встреча `seconds` секунд; `during` получает запись сразу после старта. Буферы опрашиваются всё время записи.
func meetingRun(_ name: String, fills: Bool = true, clockUID: String? = nil, seconds: Double,
                during: (MeetingRecorder) -> Void) -> MeetingRun? {
    let meeting = MeetingRecorder(folder: folder.appendingPathComponent(name))
    meeting.fillsGaps = fills
    meeting.systemClockUID = clockUID
    do {
        let began = Date().timeIntervalSince1970
        try meeting.start()
        let run = Box(MeetingRun())
        let polling = Box(true)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            while polling.value {
                let seen = meeting.poll().lastBuffer
                run.update { run in
                    for (track, at) in seen {
                        if run.first[track] == nil { run.first[track] = at - began }
                        run.last[track] = at - began
                    }
                }
                pause(0.005)
            }
            done.signal()
        }
        let until = now() + seconds
        during(meeting)
        while now() < until { pause(0.05) }
        polling.value = false
        done.wait()
        let files = meeting.stop()
        var result = run.value
        for track in MeetingWatchdog.Track.allCases {
            let file = WAVInfo.duration(of: track == .mic ? files.mic : files.system) ?? 0
            result.file[track] = file
            guard let first = result.first[track], let last = result.last[track] else {
                print("    \(track.rawValue): буферов не было, в файле \(sec(file))"); continue
            }
            print("    \(track.rawValue): в файле \(sec(file)); буферы с \(sec(first)) по \(sec(last)) от старта; файл длиннее промежутка на \(ms(file - (last - first)))")
        }
        return result
    } catch {
        verdict(false, "запись встречи не началась: \(error.localizedDescription)")
        return nil
    }
}

if enabled("tap") {
    print("\nЗвук системы: тап пересобирается, как при смене устройства вывода")
    // Системный вывод не меняем. Пересборка вызывается напрямую — тем же путём, каким её вызывает
    // уведомление Core Audio о смене вывода.
    for fills in [false, true] {
        print("  \(fills ? "с заполнением разрыва" : "без заполнения (так вела бы себя пересборка без тишины)"): 4 пересборки за 10 с")
        var took: [Double] = []
        var rebuilt = 0
        let run = meetingRun(fills ? "tap-fill" : "tap-plain", fills: fills, seconds: 10) { meeting in
            for _ in 0..<4 {
                pause(1.6)
                let began = now()
                meeting.simulateOutputChange()
                took.append(now() - began)
            }
            rebuilt = meeting.systemTapState?.rebuilds ?? 0
        }
        print("    пересборка: в среднем \(ms(mean(took))), худшая \(ms(took.max() ?? 0)); пересобрано \(rebuilt) раз")
        if let system = run?.drift(.system) {
            if fills {
                verdict(rebuilt == 4, "тап пересобран 4 раза и продолжает писать")
                verdict(abs(system) <= 0.2, "дорожка системы после 4 пересборок идёт вровень с часами: разница \(ms(system))")
            } else {
                print("    без тишины дорожка системы короче часов на \(ms(-system))")
            }
        } else { verdict(false, "дорожка системы не писалась") }
        if fills, let mic = run?.drift(.mic) { verdict(abs(mic) <= 0.2, "микрофон пересборка не задела: разница \(ms(mic))") }
        pause(0.5)
    }

    // Запись, начатая на одном устройстве вывода, когда вывод уже другой: агрегат привязываем к
    // виртуальному устройству с другой частотой, вывод по умолчанию остаётся как есть.
    let probe = MeetingRecorder(folder: folder.appendingPathComponent("tap-probe"))
    var home: SystemTapBinding?
    if (try? probe.start()) != nil { home = probe.systemTapState?.binding; probe.stop() }
    var foreign: (uid: String, rate: Double, name: String)?
    for device in inputs where AudioInputs.transport(of: device.id) == .virtual && foreign == nil {
        let trial = MeetingRecorder(folder: folder.appendingPathComponent("tap-probe-\(device.id)"))
        trial.systemClockUID = device.uid
        guard (try? trial.start()) != nil else { continue }
        if let bound = trial.systemTapState?.binding, bound.outputUID == device.uid, let home, abs(bound.rate - home.rate) > 1 {
            foreign = (device.uid, bound.rate, device.name)
        }
        trial.stop()
        pause(0.3)
    }
    if let home, let foreign {
        print(String(format: "  вывод по умолчанию: %.0f Гц; чужое устройство «%@»: %.0f Гц", home.rate, foreign.name, foreign.rate))
        for follows in [false, true] {
            print("  запись начата на чужом устройстве" + (follows ? "; через 4 с сверка замечает, что вывод другой" : "; сверки нет (как было)"))
            var before: SystemTapBinding?, after: SystemTapBinding?, rebuilds = 0
            let run = meetingRun(follows ? "tap-follow" : "tap-stale", clockUID: foreign.uid, seconds: 9) { meeting in
                before = meeting.systemTapState?.binding
                guard follows else { return }
                pause(4)
                meeting.systemClockUID = nil
                meeting.checkSystemOutput()  // то, что делает уведомление о смене вывода
                after = meeting.systemTapState?.binding
                rebuilds = meeting.systemTapState?.rebuilds ?? 0
                meeting.checkSystemOutput()
                verdict(meeting.systemTapState?.rebuilds == rebuilds, "повторная сверка без перемен тап не трогает")
            }
            guard let run else { continue }
            let micFile = run.file[.mic] ?? 0, systemFile = run.file[.system] ?? 0
            if follows {
                verdict(before?.outputUID == foreign.uid && abs((before?.rate ?? 0) - foreign.rate) < 1,
                        String(format: "до сверки тап привязан к чужому устройству на %.0f Гц", before?.rate ?? 0))
                verdict(rebuilds == 1 && after == home,
                        String(format: "сверка пересобрала тап под вывод по умолчанию: %.0f Гц (пересборок: %d)", after?.rate ?? 0, rebuilds))
                verdict(run.last[.system].map { $0 > 8 } ?? false, "после пересборки буферы системы идут до конца записи")
                verdict(abs(systemFile - micFile) <= 0.3,
                        "дорожки одной длины — начало системы не съехало: система \(sec(systemFile)), микрофон \(sec(micFile))")
            } else {
                print("    без сверки: система \(sec(systemFile)) против микрофона \(sec(micFile))")
            }
            pause(0.5)
        }
    } else {
        print("  виртуального устройства вывода с другой частотой нет — сценарий со сменой частоты пропущен")
    }
}

// MARK: звук системы — та ли частота и длительность

if wanted.contains("system") {
    print("\nЗвук системы: тихий тон 1000 Гц на 3 с через вывод по умолчанию")
    // Тон −40 дБ: в записи тапа виден отлично, из динамиков почти не слышен.
    let toneURL = folder.appendingPathComponent("tone.wav")
    let rate = 48_000, length = 3
    var tone = Data()
    func u32(_ v: Int) { var x = UInt32(v).littleEndian; tone.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: Int) { var x = UInt16(v).littleEndian; tone.append(Data(bytes: &x, count: 2)) }
    tone.append(contentsOf: Array("RIFF".utf8)); u32(36 + rate * length * 2)
    tone.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
    tone.append(contentsOf: Array("data".utf8)); u32(rate * length * 2)
    for i in 0..<(rate * length) {
        var x = Int16(sin(2 * Double.pi * 1000 * Double(i) / Double(rate)) * 328).littleEndian
        tone.append(Data(bytes: &x, count: 2))
    }
    try? tone.write(to: toneURL)
    let meeting = MeetingRecorder(folder: folder.appendingPathComponent("meeting-system"))
    do {
        try meeting.start()
        pause(1)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [toneURL.path]
        try player.run()
        player.waitUntilExit()
        pause(1)
        let files = meeting.stop()
        let xs = samples(files.system)
        let loud = xs.indices.filter { abs(Int(xs[$0])) > 60 }
        if let from = loud.first, let to = loud.last, to - from > 16_000 {
            // Частота — по переходам через ноль в середине тона.
            let middle = xs[(from + 1_600)..<(to - 1_600)]
            var crossings = 0
            var previous = middle.first ?? 0
            for x in middle.dropFirst() { if (previous < 0) != (x < 0) { crossings += 1 }; previous = x }
            let frequency = Double(crossings) / 2 / (Double(middle.count) / 16_000)
            let seconds = Double(to - from) / 16_000
            print(String(format: "  в записи: тон %.0f Гц длиной %.2f с (пик %d)", frequency, seconds, peak(xs[...])))
            verdict(abs(frequency - 1000) < 15, "частота тона сохранена")
            verdict(abs(seconds - 3) < 0.1, "длительность тона сохранена")
        } else {
            verdict(false, "тон в дорожке системы не найден (пик \(peak(xs[...])))")
        }
    } catch { verdict(false, "запись встречи не началась: \(error.localizedDescription)") }
}

// MARK: встреча без смены устройств — идут ли дорожки вровень с часами сами по себе

for name in (wanted.isEmpty ? ["idle10"] : Array(CommandLine.arguments.dropFirst())) where name.hasPrefix("idle") {
    let length = Double(name.dropFirst(4)) ?? 6
    print("\nВстреча без смены устройств, \(sec(length))")
    let meeting = MeetingRecorder(folder: folder.appendingPathComponent("meeting-\(name)"))
    do {
        var firstAt: [MeetingWatchdog.Track: Double] = [:]
        let began = Date().timeIntervalSince1970
        try meeting.start()
        while firstAt.count < 2, Date().timeIntervalSince1970 - began < 3 {
            for (track, at) in meeting.poll().lastBuffer where firstAt[track] == nil { firstAt[track] = at }
            pause(0.005)
        }
        var seen: [MeetingWatchdog.Track: Double] = firstAt
        var stalls: [MeetingWatchdog.Track: Double] = [:]
        let until = now() + length
        while now() < until {
            for (track, at) in meeting.poll().lastBuffer {
                stalls[track] = max(stalls[track] ?? 0, at - (seen[track] ?? at))
                seen[track] = at
            }
            pause(0.005)
        }
        let lastAt = meeting.poll().lastBuffer
        let files = meeting.stop()
        for track in MeetingWatchdog.Track.allCases {
            let file = WAVInfo.duration(of: track == .mic ? files.mic : files.system) ?? 0
            guard let first = firstAt[track], let last = lastAt[track] else { print("  \(track.rawValue): буферов не было"); continue }
            // Тап называл 48 кГц при устройстве на 44,1 — дорожка системы теряла 8 % времени.
            verdict(abs(file - (last - first)) <= 0.2, "\(track.rawValue): дорожка идёт вровень с часами, разница \(ms(file - (last - first)))")
            print("    \(track.rawValue): первый буфер через \(ms(first - began)) после старта, в файле \(sec(file)), по часам \(sec(last - first)), разница \(ms(file - (last - first))), самый долгий промежуток между буферами \(ms(stalls[track] ?? 0))")
        }
    } catch { verdict(false, "запись встречи не началась: \(error.localizedDescription)") }
}

let failed = failures.value
print(failed == 0 ? "\nИтог: всё прошло" : "\nИтог: не прошло проверок — \(failed)")
exit(failed == 0 ? 0 : 1)
