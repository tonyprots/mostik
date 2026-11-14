import Foundation
import MostikCore

// Аудит 2026-11-14, вторая порция: жизненный цикл движка, очередь встреч.
func runAuditLifeTests() {
    runEngineSupervisorTests()
    runEngineOutboxTests()
    runHandshakeFailureTests()
    runMeetingRetryPolicyTests()
    runMeetingListMergeTests()
    runAgentByArgvTests()
    runSystemTapFollowTests()
}

private func runEngineSupervisorTests() {
    // Обычная жизнь: запуск, падение, перезапуск по таймеру.
    var s = EngineSupervisor()
    equal(s.phase, .idle)
    check(!s.holdsCommands, "до запуска команды не копим: запуска никто не обещал")
    guard let first = s.claimStart() else { check(false, "первый запуск разрешён"); return }
    check(s.mayRun(first), "билет в силе")
    check(s.claimStart() == nil, "второй запуск, пока поднимается первый, не нужен")
    s.launched(first)
    equal(s.phase, .running)
    check(s.claimStart() == nil, "работающий процесс второй раз не запускаем")
    guard case .restart(let attempt, let delay, let pending) = s.exited(uptime: 5) else { check(false, "падение → перезапуск"); return }
    equal(attempt, 1); equal(delay, 1)
    equal(s.phase, .waiting)
    check(s.holdsCommands, "в паузе после падения команды ждут запуска")
    guard let second = s.claimRestart(pending) else { check(false, "таймер запускает по своему билету"); return }
    check(s.claimRestart(pending) == nil, "тот же билет второй раз не срабатывает")
    s.launched(second)
    equal(s.phase, .running)

    // S6: остановка в паузе после падения — опоздавший таймер ничего не поднимает.
    var stopped = EngineSupervisor()
    stopped.launched(stopped.claimStart()!)
    guard case .restart(_, _, let ticket) = stopped.exited(uptime: 1) else { check(false, "падение"); return }
    stopped.shutdown()
    check(stopped.claimRestart(ticket) == nil, "S6: остановленный клиент по таймеру не запускается")
    equal(stopped.phase, .stopped)
    check(!stopped.holdsCommands, "остановленный клиент команды не копит")

    // S6: остановка пришла, когда таймер уже взял билет и готовит запуск.
    var midway = EngineSupervisor()
    midway.launched(midway.claimStart()!)
    guard case .restart(_, _, let t2) = midway.exited(uptime: 1), let claimed = midway.claimRestart(t2) else { check(false, "перезапуск взят"); return }
    midway.shutdown()
    check(!midway.mayRun(claimed), "S6: остановка между решением и запуском гасит билет")
    midway.launched(claimed)
    equal(midway.phase, .stopped, "погашенный билет не делает клиент «работающим»")

    // S6: явный запуск в паузе — таймер после него не поднимает второй процесс.
    var explicit = EngineSupervisor()
    explicit.launched(explicit.claimStart()!)
    guard case .restart(_, _, let t3) = explicit.exited(uptime: 1) else { check(false, "падение"); return }
    guard let manual = explicit.claimStart() else { check(false, "явный запуск в паузе разрешён"); return }
    check(explicit.claimRestart(t3) == nil, "S6: таймер после явного запуска — мимо")
    explicit.launched(manual)
    equal(explicit.phase, .running)

    // Таймер успел первым — явный запуск не дублирует.
    var timerFirst = EngineSupervisor()
    timerFirst.launched(timerFirst.claimStart()!)
    guard case .restart(_, _, let t4) = timerFirst.exited(uptime: 1), timerFirst.claimRestart(t4) != nil else { check(false, "таймер"); return }
    check(timerFirst.claimStart() == nil, "S6: явный запуск, когда таймер уже запускает, — мимо")

    // Паузы растут, шесть быстрых падений подряд — и первая ступень сдаётся.
    var loop = EngineSupervisor()
    var delays: [Double] = []
    var gaveUp = false
    var loopTicket = loop.claimStart()
    for _ in 0..<10 {
        guard let current = loopTicket else { break }
        loop.launched(current)
        switch loop.exited(uptime: 0.1) {
        case .restart(_, let delay, let pending): delays.append(delay); loopTicket = loop.claimRestart(pending)
        case .giveUp(let attempt): gaveUp = true; equal(attempt, 7); loopTicket = nil
        case .stopped: loopTicket = nil
        }
    }
    equal(delays, [1, 2, 4, 8, 16, 30], "паузы первой ступени")
    check(gaveUp, "после шести быстрых падений — отказ")
    equal(loop.phase, .failed)
    check(!loop.holdsCommands, "сдавшийся клиент команды не копит")
    check(loop.claimStart() != nil, "вторая ступень может запустить его снова")

    // Долго проживший процесс обнуляет счёт падений.
    var calm = EngineSupervisor()
    calm.launched(calm.claimStart()!)
    for _ in 0..<3 {
        guard case .restart(_, _, let pending) = calm.exited(uptime: 1), let next = calm.claimRestart(pending) else { check(false, "перезапуск"); return }
        calm.launched(next)
    }
    guard case .restart(let afterCalm, let delayAfterCalm, _) = calm.exited(uptime: 120) else { check(false, "падение после долгой работы"); return }
    equal(afterCalm, 1, "после минуты работы счёт падений начинается заново"); equal(delayAfterCalm, 1)

    // Выход после остановки — не падение.
    var quit = EngineSupervisor()
    quit.launched(quit.claimStart()!)
    quit.shutdown()
    equal(quit.exited(uptime: 3), .stopped, "процесс, остановленный нами, не перезапускается")
    equal(quit.attempt, 0)

    // Запуск не удался.
    var broken = EngineSupervisor()
    let bad = broken.claimStart()!
    broken.launchFailed(bad)
    equal(broken.phase, .failed)

    // S7: перезапуск из приложения — новый клиент ждёт остановки старого и копит команды.
    var fresh = EngineSupervisor()
    fresh.expectStart()
    equal(fresh.phase, .pending)
    check(fresh.holdsCommands, "S7: обещанный запуск — команды ждут")
    let go = fresh.claimStart()
    check(go != nil, "обещанный запуск состоится")
    fresh.shutdown()
    fresh.expectStart()
    equal(fresh.phase, .pending, "после остановки запуск можно пообещать снова")
    var live = EngineSupervisor()
    live.launched(live.claimStart()!)
    live.expectStart()
    equal(live.phase, .running, "работающему клиенту обещание запуска ничего не меняет")
}

private func runEngineOutboxTests() {
    var box = EngineOutbox(limit: 3)
    check(box.isEmpty)
    check(box.hold(id: 1, line: "a"))
    check(box.hold(id: 2, line: "b"))
    check(box.hold(id: 3, line: "c"))
    check(!box.hold(id: 4, line: "d"), "сверх потолка — прежний отказ")
    box.drop(id: 2)
    equal(box.ids, [1, 3], "вызывающий перестал ждать — строка движку не уйдёт")
    check(box.hold(id: 5, line: "e"))
    equal(box.drain().map(\.text), ["a", "c", "e"], "после запуска — в порядке поступления")
    check(box.isEmpty, "очередь отдана целиком")
    equal(box.drain().count, 0)
    check(EngineOutbox.resendable.contains("remember") && EngineOutbox.resendable.contains("forget"),
          "правки словаря переживают падение движка")
    check(!EngineOutbox.resendable.contains("meeting") && !EngineOutbox.resendable.contains("stop")
          && !EngineOutbox.resendable.contains("transcribe_file"), "тяжёлые и потоковые команды сами не повторяются")
}

private func runHandshakeFailureTests() {
    equal(EngineRecovery.handshakeFailure(processGone: true), .leaveToClient,
          "процесс умер посреди рукопожатия — клиент перезапускает его сам, статус его")
    equal(EngineRecovery.handshakeFailure(processGone: false), .secondStage,
          "S17: процесс жив, но не ответил — вторая ступень, а не «ошибка» навсегда")
}

private func runMeetingRetryPolicyTests() {
    equal(MeetingRetryPolicy.initialAttempts(engineLive: true), 1)
    equal(MeetingRetryPolicy.initialAttempts(engineLive: false), 0, "S7: команда без процесса никуда не ушла — попытку не тратим")
    // Отправили во время перезапуска → движок поднялся → первая настоящая отправка → упал → один повтор.
    var attempts = MeetingRetryPolicy.initialAttempts(engineLive: false)
    var sends = 0
    for _ in 0..<5 where MeetingRetryPolicy.mayResend(attempts: attempts) { attempts += 1; sends += 1 }
    equal(sends, 2, "S7: после перезапуска остаётся и отправка, и один повтор после падения")
    attempts = MeetingRetryPolicy.initialAttempts(engineLive: true)
    sends = 0
    for _ in 0..<5 where MeetingRetryPolicy.mayResend(attempts: attempts) { attempts += 1; sends += 1 }
    equal(sends, 1, "отправленному живому движку — один повтор, как раньше")
    // Встреча расшифровывается, движок перезапустили из Настроек, потом он упал по-настоящему.
    attempts = MeetingRetryPolicy.afterPlannedRestart(attempts: 1)
    equal(attempts, 0)
    sends = 0
    for _ in 0..<5 where MeetingRetryPolicy.mayResend(attempts: attempts) { attempts += 1; sends += 1 }
    equal(sends, 2, "S7: плановый перезапуск не съедает повтор после падения")
    equal(MeetingRetryPolicy.afterPlannedRestart(attempts: 0), 0, "ниже нуля не уходит")
}

private func runMeetingListMergeTests() {
    struct Item: Equatable { let id: String; let state: String }
    let merge = { (scanned: [Item], current: [Item]) in
        MeetingListMerge.merge(scanned: scanned, current: current, id: \.id) { $0.state == "recording" || $0.state == "queued" }
    }
    // S12: папка идущей записи уже на диске — скан видит её «не расшифрованной».
    let scanned = [Item(id: "a", state: "done"), Item(id: "rec", state: "failed"), Item(id: "q", state: "failed")]
    let current = [Item(id: "rec", state: "recording"), Item(id: "q", state: "queued"), Item(id: "a", state: "failed")]
    let merged = merge(scanned, current)
    equal(merged.first { $0.id == "rec" }?.state, "recording", "S12: идущую запись скан не перетирает")
    equal(merged.first { $0.id == "q" }?.state, "queued", "S12: встречу в очереди расшифровки — тоже")
    equal(merged.first { $0.id == "a" }?.state, "done", "неживую встречу берём с диска")
    equal(merged.count, 3, "без дублей")
    // Встреча начата после начала чтения: на диске её ещё не видели.
    let late = merge([Item(id: "a", state: "done")], [Item(id: "new", state: "recording"), Item(id: "a", state: "done")])
    equal(late.map(\.id), ["a", "new"], "встречи, начатые за время чтения, не теряем")
    equal(merge([], []).count, 0)
}

// S5: агент, чьё имя видно только в argv[0].
private func runAgentByArgvTests() {
    let names: Set<String> = ["claude", "codex", "gemini"]
    // Нативная сборка Claude Code: `~/.local/bin/claude` — ссылка на `…/versions/2.1.50`. Имя процесса и путь —
    // номер версии (проверено на этой macOS: proc_name и proc_pidpath дают имя файла, а не ссылки).
    let native = ProcessEntry(pid: 10, ppid: 1, name: "2.1.50", path: "/Users/x/.local/share/claude/versions/2.1.50",
                              args: ["claude", "--resume"])
    check(ProjectResolver.wantsArgs(native), "S5: argv читаем и у бинарника не из списка интерпретаторов")
    equal(ProjectResolver.agentName(native, names: names), "claude", "S5: агент по argv[0], когда имя бинарника — номер версии")
    // node после `process.title = "claude"`: argv[0] переписан, остальные аргументы затёрты нулями
    // (так выглядит настоящий буфер KERN_PROCARGS2 — снят с живого node 24).
    let titled = ProcessEntry(pid: 11, ppid: 1, name: "node", path: "/opt/homebrew/bin/node", args: ["claude", "", "", "", ""])
    equal(ProjectResolver.agentName(titled, names: names), "claude", "process.title под node")
    let titledArgs = ProcessEntry(pid: 12, ppid: 1, name: "node", path: "/opt/homebrew/bin/node", args: ["claude --resume", "", ""])
    equal(ProjectResolver.agentName(titledArgs, names: names), "claude", "S5: заголовок процесса с аргументами")
    // Не агент: имя агента — аргумент чужой программы, а не её argv[0].
    let other = ProcessEntry(pid: 13, ppid: 1, name: "rg", path: "/opt/homebrew/bin/rg", args: ["rg", "claude"])
    equal(ProjectResolver.agentName(other, names: names), nil, "слово в аргументах — не агент")
    let wrapper = ProcessEntry(pid: 14, ppid: 1, name: "2.1.50", path: "/Users/x/tools/2.1.50", args: ["/Users/x/tools/2.1.50", "claude"])
    equal(ProjectResolver.agentName(wrapper, names: names), nil, "у не-интерпретатора смотрим только argv[0]")
    // Чьи argv не читаем: системные процессы и приложения — их сотни, агентов среди них нет.
    check(!ProjectResolver.wantsArgs(ProcessEntry(pid: 1, ppid: 0, name: "launchd", path: "/sbin/launchd")), "системный процесс")
    check(!ProjectResolver.wantsArgs(ProcessEntry(pid: 2, ppid: 1, name: "mds", path: "/System/Library/Frameworks/CoreServices.framework/mds")), "/System")
    check(!ProjectResolver.wantsArgs(ProcessEntry(pid: 3, ppid: 1, name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude")), "приложение")
    check(!ProjectResolver.wantsArgs(ProcessEntry(pid: 4, ppid: 1, name: "x", path: "")), "процесс без пути (чужой пользователь)")
    check(ProjectResolver.wantsArgs(ProcessEntry(pid: 5, ppid: 1, name: "node", path: "/usr/local/bin/node")), "интерпретатор")
    check(!ProjectResolver.wantsArgs(ProcessEntry(pid: 6, ppid: 1, name: "codex", path: "/opt/homebrew/bin/codex"), names: names),
          "агент, известный по имени, в argv не нуждается")
    check(ProjectResolver.wantsArgs(ProcessEntry(pid: 7, ppid: 1, name: "zsh", path: "/bin/zsh")) == false, "/bin — системное")
}

// Звук системы идёт за устройством вывода.
private func runSystemTapFollowTests() {
    let speakers = SystemTapBinding(outputUID: "BuiltInSpeakerDevice", rate: 44_100)
    var follow = SystemTapFollow(bound: speakers)
    equal(follow.decide(current: speakers), .keep, "ничего не сменилось")
    equal(follow.decide(current: SystemTapBinding(outputUID: "BuiltInSpeakerDevice", rate: 44_100.2)), .keep, "та же частота с погрешностью")
    equal(follow.decide(current: SystemTapBinding(outputUID: "AirPods", rate: 44_100)), .rebuild,
          "наушники с той же частотой: часы агрегата — прежнее устройство")
    equal(follow.decide(current: SystemTapBinding(outputUID: "AirPods", rate: 48_000)), .rebuild, "наушники с другой частотой")
    equal(follow.decide(current: SystemTapBinding(outputUID: "BuiltInSpeakerDevice", rate: 48_000)), .rebuild,
          "то же устройство сменило частоту — пересчёт собран под прежнюю")
    equal(follow.decide(current: SystemTapBinding(outputUID: nil, rate: 48_000)), .keep, "вывода нет — привязываться не к чему")
    equal(follow.decide(current: SystemTapBinding(outputUID: "BuiltInSpeakerDevice", rate: 0)), .keep, "частота не прочиталась — не повод")
    // Пересборка: новая привязка, счётчик неудач сброшен.
    equal(follow.failed(), SystemTapFollow.retryAfter, "первая неудача — повтор")
    equal(follow.failed(), SystemTapFollow.retryAfter)
    equal(follow.failed(), SystemTapFollow.retryAfter)
    check(follow.failed() == nil, "после трёх повторов дорожку ведёт сторож встречи")
    let pods = SystemTapBinding(outputUID: "AirPods", rate: 48_000)
    follow.rebuilt(pods)
    equal(follow.bound, pods)
    equal(follow.failures, 0)
    equal(follow.decide(current: pods), .keep, "после пересборки новое устройство — своё")
    equal(follow.decide(current: speakers), .rebuild, "вернулись на динамики — снова пересборка")
    // Запись без устройства вывода на старте, потом оно появилось.
    let none = SystemTapFollow(bound: SystemTapBinding(outputUID: nil, rate: 48_000))
    equal(none.decide(current: speakers), .rebuild, "вывод появился посреди записи")

    // Разрыв на время пересборки: дорожка получает столько тишины, сколько не было буферов.
    var gap = TrackGap()
    gap.open(lastAudioEnd: 100.0, paused: false)
    check(abs(gap.close(bufferStart: 100.35) - 0.35) < 1e-9, "пересборка заняла 350 мс — 350 мс тишины")
    // Пауза записи посреди пересборки в тишину не идёт: на паузе стоят обе дорожки.
    var paused = TrackGap()
    paused.open(lastAudioEnd: 10, paused: false)
    paused.pause(at: 10.1)
    paused.resume(at: 15.1)
    check(abs(paused.close(bufferStart: 15.3) - 0.3) < 1e-9, "пауза не считается разрывом")
}

// MARK: C20 — имя участника Zoom с запятой

func runZoomCommaNameTests() {
    let tile = ZoomSpeakers.tile(from: "Иванов, Пётр, Computer audio unmuted, active speaker")
    equal(tile?.name, "Иванов, Пётр", "имя с запятой целиком — до состояния звука")
    equal(tile?.active, true, "пометка говорящего у имени с запятой")
    equal(tile?.unmuted, true, "микрофон у имени с запятой")
    equal(ZoomSpeakers.tile(from: "Smith, John (Me), Computer audio muted")?.name, "Smith, John", "своя пометка снимается и после запятой")
    equal(ZoomSpeakers.tile(from: "Smith, John (Me), Computer audio muted")?.isSelf, true, "своя плитка с запятой в имени")
    equal(ZoomSpeakers.tile(from: "Acme, Inc., Sales, active speaker")?.name, "Acme, Inc., Sales", "две запятые в имени")
    equal(ZoomSpeakers.tile(from: "Анна, Computer audio, active speaker")?.name, "Анна", "обычное имя как прежде")
    check(ZoomSpeakers.tile(from: "Share, Screen") == nil, "подпись без состояния звука — не плитка")
    check(ZoomSpeakers.tile(from: ", Computer audio") == nil, "пустое имя — не плитка")
}

// MARK: И5 — запись в файл настроек, который оказался ссылкой

func runLinkedFileTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("mostik-linked-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir.appendingPathComponent("dotfiles"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let real = dir.appendingPathComponent("dotfiles/settings.json")
    let link = dir.appendingPathComponent("settings.json")
    let second = dir.appendingPathComponent("again.json")
    try? Data("old".utf8).write(to: real)
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
    try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/settings.json")
    try? fm.createSymbolicLink(at: second, withDestinationURL: link)

    equal(LinkedFile.target(of: real)?.path, real.standardizedFileURL.path, "обычный файл — сам себе цель")
    equal(LinkedFile.target(of: link)?.path, real.standardizedFileURL.path, "относительная ссылка ведёт к настоящему файлу")
    equal(LinkedFile.target(of: second)?.path, real.standardizedFileURL.path, "цепочка ссылок проходится до конца")
    let fresh = dir.appendingPathComponent("none.json")
    equal(LinkedFile.target(of: fresh)?.path, fresh.standardizedFileURL.path, "файла ещё нет — пишем по тому же адресу")

    if let target = LinkedFile.target(of: second) { try? Data("new".utf8).write(to: target, options: .atomic) }
    check((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil, "ссылка после записи осталась ссылкой")
    equal(try? String(contentsOf: real, encoding: .utf8), "new", "новое содержимое попало в настоящий файл")
    equal((try? fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600, "права настоящего файла сохранились")

    let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
    try? fm.createSymbolicLink(at: a, withDestinationURL: b)
    try? fm.createSymbolicLink(at: b, withDestinationURL: a)
    check(LinkedFile.target(of: a) == nil, "петля ссылок — цели нет")

    // Как было: запись по адресу ссылки заменяет ссылку файлом.
    let plain = dir.appendingPathComponent("plain.json")
    try? fm.createSymbolicLink(at: plain, withDestinationURL: real)
    try? Data("x".utf8).write(to: plain, options: .atomic)
    check((try? fm.destinationOfSymbolicLink(atPath: plain.path)) == nil, "без обхода атомарная запись заменяет ссылку (дефект подтверждён)")
}

// MARK: Н2 — карантин снимается только с того же кода

func runQuarantineDecisionTests() {
    var asked = 0
    equal(AppLocation.quarantine(own: nil, matches: { asked += 1; return false }()), .clear, "сборка без подписи: сверять не с чем, как раньше")
    equal(asked, 0, "без своей подписи копию не проверяем")
    equal(AppLocation.quarantine(own: Data([1, 2]), matches: true), .clear, "та же подпись — карантин снимаем")
    equal(AppLocation.quarantine(own: Data([1, 2]), matches: false), .keep, "другой код — карантин остаётся")
    check(!AppLocation.mismatchHint(russian: true).isEmpty && !AppLocation.mismatchHint(russian: false).isEmpty, "текст о несовпадении на двух языках")
}

// MARK: Н6 — команда календаря закреплена по содержимому

func runCalendarCommandPinTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("mostik-calpin-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let file = dir.appendingPathComponent("calendar-events")
    let path = file.path
    try? Data("#!/bin/sh\necho '[]'\n".utf8).write(to: file)

    // Как было: отпечаток не зависит от содержимого — подмена файла незаметна.
    let legacy = CalendarCommandTrust.digest(path)
    try? Data("#!/bin/sh\ncurl evil\n".utf8).write(to: file)
    equal(CalendarCommandTrust.digest(path), legacy, "прежний отпечаток не видит подмену содержимого (дефект подтверждён)")
    check(CalendarCommandTrust.contentDigest(of: path) != nil, "содержимое читается")

    // Согласие прежнего вида не сбрасывается: дополняется текущим содержимым при первом запуске.
    let store = FakeHookDigestStore()
    store.stored = .value(legacy)
    check(CalendarCommandTrust.reconcile(path, store: store) == (path, nil), "прежнее согласие действует без вопроса")
    equal(store.writes.count, 0, "сверка пути ничего не пишет")
    equal(CalendarCommandTrust.gate(path, store: store), .run, "первый запуск с прежним согласием проходит")
    equal(store.writes.count, 1, "прежнее согласие дополнено содержимым")
    check(store.writes.last?.hasPrefix("v2:" + legacy + ":") == true, "новая запись — путь и содержимое")
    check(CalendarCommandTrust.reconcile(path, store: store) == (path, nil), "после дополнения путь по-прежнему подтверждён")
    equal(CalendarCommandTrust.gate(path, store: store), .run, "тот же файл запускается дальше")
    equal(store.writes.count, 1, "без перемен запись не переписывается")

    // Файл изменился — новый вопрос.
    try? Data("#!/bin/sh\necho changed\n".utf8).write(to: file)
    equal(CalendarCommandTrust.gate(path, store: store), .changed, "изменённый файл не запускается")
    check(CalendarCommandTrust.isTrusted(path, store: store), "путь при этом остаётся знакомым: спрашиваем про содержимое")
    check(CalendarCommandTrust.approve(path, store: store), "новое согласие записано")
    equal(CalendarCommandTrust.gate(path, store: store), .run, "после согласия новый файл запускается")

    // Ссылка: закреплён файл, который запустится.
    let link = dir.appendingPathComponent("link")
    let other = dir.appendingPathComponent("other")
    try? Data("other".utf8).write(to: other)
    try? fm.createSymbolicLink(at: link, withDestinationURL: file)
    let linked = FakeHookDigestStore()
    check(CalendarCommandTrust.approve(link.path, store: linked))
    equal(CalendarCommandTrust.gate(link.path, store: linked), .run, "ссылка на тот же файл")
    try? fm.removeItem(at: link)
    try? fm.createSymbolicLink(at: link, withDestinationURL: other)
    equal(CalendarCommandTrust.gate(link.path, store: linked), .changed, "ссылку перевели на другой файл — вопрос")

    // Файл пропал (том не подключён): согласие не теряется, запуск упрётся в проверку файла сам.
    try? fm.removeItem(at: file)
    equal(CalendarCommandTrust.gate(path, store: store), .run, "нет файла — решает проверка файла, согласие цело")
    check(CalendarCommandTrust.reconcile(path, store: store) == (path, nil), "пропавший файл не сбрасывает согласие")
    let before = store.writes.count
    let old = FakeHookDigestStore()
    old.stored = .value(legacy)
    equal(CalendarCommandTrust.gate(path, store: old), .run, "прежнее согласие без файла: ждём")
    equal(old.writes.count, 0, "пока файла нет, содержимое не закрепляется")
    equal(store.writes.count, before, "запись не тронута")

    // Чужое.
    let empty = FakeHookDigestStore()
    equal(CalendarCommandTrust.gate(path, store: empty), .changed, "без согласия не запускается")
    empty.stored = .value("v2:" + CalendarCommandTrust.digest("/other") + ":abc")
    check(!CalendarCommandTrust.isTrusted(path, store: empty), "запись про другой путь не подходит")
    empty.stored = .unreadable
    equal(CalendarCommandTrust.gate(path, store: empty), .changed, "нечитаемая запись — не согласие")
}

// MARK: Н9 — страница звонка сверяется по адресу, а не только по заголовку окна

func runCallPageOriginTests() {
    typealias Node = WebCallSpeakers.Node
    check(WebCallSpeakers.kind(windowTitle: "Meet – попался") == .meet, "заголовок задаёт страница: по нему любая вкладка — звонок (дефект подтверждён)")

    check(WebCallSpeakers.isCallURL("https://meet.google.com/abc-defg-hij", kind: .meet), "Meet")
    check(!WebCallSpeakers.isCallURL("https://telemost.corp.example/j/1", kind: .telemost), "свой домен без настройки — чужой")
    check(WebCallSpeakers.isCallURL("https://telemost.corp.example/j/1", kind: .telemost, extraTelemostDomains: ["Corp.Example"]),
          "свой домен Телемоста из настройки")
    check(!WebCallSpeakers.isCallURL("https://telemost.evil.example/j/1", kind: .telemost, extraTelemostDomains: ["corp.example", ""]),
          "настройка не открывает прочие домены")
    check(WebCallSpeakers.isCallURL("https://MEET.google.com/abc?authuser=0", kind: .meet), "регистр хоста")
    check(!WebCallSpeakers.isCallURL("https://meet.google.com.evil.example/abc", kind: .meet), "хост с чужим хвостом")
    check(!WebCallSpeakers.isCallURL("https://evil.example/meet.google.com", kind: .meet), "хост в пути")
    check(!WebCallSpeakers.isCallURL("http://meet.google.com/abc", kind: .meet), "не https")
    check(!WebCallSpeakers.isCallURL("data:text/html,<title>Meet - x</title>", kind: .meet), "data-страница")
    check(!WebCallSpeakers.isCallURL("https://telemost.yandex.ru/j/1", kind: .meet), "Телемост — не Meet")
    check(WebCallSpeakers.isCallURL("https://telemost.yandex.ru/j/123", kind: .telemost), "Телемост")
    check(WebCallSpeakers.isCallURL("https://telemost.360.yandex.ru/j/123", kind: .telemost), "Телемост 360")
    check(WebCallSpeakers.isCallURL("https://telemost.yandex.com/j/123", kind: .telemost), "Телемост на другом домене Яндекса")
    check(!WebCallSpeakers.isCallURL("https://telemost.evil.example/j/123", kind: .telemost), "telemost на чужом домене")
    check(!WebCallSpeakers.isCallURL("https://telemost.yandex.ru.evil.example/", kind: .telemost), "домен Яндекса в середине")
    check(!WebCallSpeakers.isCallURL("https://nottelemost.yandex.ru/", kind: .telemost), "другой сервис Яндекса")

    // Плитка Meet — как в `WebCallSpeakersTests`.
    func tile(_ name: String) -> Node {
        Node(role: "AXGroup", classes: ["T4q2od"], children: [
            Node(role: "AXGroup", classes: ["oZRSLe"], children: [Node(role: "AXGroup", classes: ["koV58"], children: [
                Node(role: "AXGroup", classes: ["XEazBc", "adnwBd"], children: [Node(role: "AXStaticText", value: name)]),
                Node(role: "AXGroup", classes: ["DYfzY", "cYKTje", "HX2H7"]),
            ])]),
        ])
    }
    func window(_ areas: [Node]) -> Node {
        Node(role: "AXApplication", children: [Node(role: "AXWindow", children: [Node(role: "AXGroup", children: areas)])])
    }
    func names(_ root: Node) -> [String] { WebCallSpeakers.snapshot(root, kind: .meet).tiles.map(\.name) }

    let fake = window([Node(role: "AXWebArea", children: [tile("Подставной")], url: "https://evil.example/")])
    equal(names(fake), ["Подставной"], "без сверки чужая страница даёт «участника»")
    let screenedFake = WebCallSpeakers.screened(fake, kind: .meet)
    equal(screenedFake.origin, .foreign, "чужой адрес")
    equal(names(screenedFake.tree), [], "чужая страница не читается")

    let real = window([Node(role: "AXWebArea", children: [tile("Пётр")], url: "https://meet.google.com/abc-defg-hij")])
    let screenedReal = WebCallSpeakers.screened(real, kind: .meet)
    equal(screenedReal.origin, .verified, "адрес звонка")
    equal(names(screenedReal.tree), ["Пётр"], "страница звонка читается как раньше")
    check(screenedReal.tree == real, "дерево настоящего звонка не меняется")

    let mixed = window([
        Node(role: "AXWebArea", children: [tile("Пётр")], url: "https://meet.google.com/abc-defg-hij"),
        Node(role: "AXWebArea", children: [tile("Из боковой панели")], url: "https://evil.example/"),
    ])
    equal(names(WebCallSpeakers.screened(mixed, kind: .meet).tree), ["Пётр"], "чужая область рядом со звонком убирается")

    let framed = window([Node(role: "AXWebArea", children: [
        tile("Пётр"), Node(role: "AXWebArea", children: [], url: "https://accounts.google.com/frame"),
    ], url: "https://meet.google.com/abc-defg-hij")])
    equal(names(WebCallSpeakers.screened(framed, kind: .meet).tree), ["Пётр"], "фрейм внутри страницы звонка её не портит")

    let silent = window([Node(role: "AXWebArea", children: [tile("Пётр")])])
    let screenedSilent = WebCallSpeakers.screened(silent, kind: .meet)
    equal(screenedSilent.origin, .unknown, "адреса нет — неизвестно")
    equal(names(screenedSilent.tree), ["Пётр"], "без адреса читаем как раньше")

    let half = window([
        Node(role: "AXWebArea", children: [tile("Без адреса")]),
        Node(role: "AXWebArea", children: [tile("Пётр")], url: "https://meet.google.com/abc-defg-hij"),
    ])
    equal(names(WebCallSpeakers.screened(half, kind: .meet).tree), ["Пётр"], "область без адреса рядом с известной не читается")
    equal(WebCallSpeakers.screened(window([]), kind: .meet).origin, .unknown, "веб-областей нет")
}
