import Foundation
import MostikCore

/// П10, прогон 5: последний пакет низких находок. Исходники приложения (`Mostik/*`) тестам не видны как модуль —
/// там, где решение принимает контроллер, сверяем его текст (как в Round4Tests).
private func appSource(_ relative: String) -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(relative)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

/// Тело функции `name` (до следующего `private func`/`func` того же уровня).
private func functionBody(_ source: String, _ name: String) -> String {
    guard let start = source.range(of: name) else { return "" }
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    func ")
    return String(end.map { rest[..<$0.lowerBound] } ?? rest)
}

private func tempDir(_ tag: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-r5-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Р5-1л: в памяти приложения — то же, что легло в файл: запись `secure_input` без текста и звука.
func runRound5SecureMemoryTests() {
    let dir = tempDir("mem")
    defer { try? FileManager.default.removeItem(at: dir) }
    let recordings = dir.appendingPathComponent("recordings", isDirectory: true)
    try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    let wav = recordings.appendingPathComponent("p.wav")
    FileManager.default.createFile(atPath: wav.path, contents: Data([1, 2, 3]))
    let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"), audioRoot: recordings)
    let secret = HistoryEntry(id: "p", createdAt: Date(timeIntervalSince1970: 1_800_000_000), text: "Корова42", insertedText: "Корова42", audioPath: wav.path,
                              outcome: SecureDictation.outcome, rawText: "корова сорок два")
    let kept = store.record(secret)
    equal(kept.text, "", "Р5-1л: в память — без текста пароля")
    equal(kept.insertedText, "")
    check(kept.rawText == nil && kept.audioPath == nil, "Р5-1л: в память — без сырого текста и звука")
    equal(store.load().first, kept, "Р5-1л: в памяти то же, что в файле")
    let normal = HistoryEntry(id: "n", text: "обычный", outcome: "inserted")
    equal(store.record(normal), normal, "обычная запись — как есть")

    // H3 «вставить ещё раз» пропускает отклонённую вставку, даже если запись старая (с текстом).
    let older = HistoryEntry(id: "o", createdAt: Date(timeIntervalSinceNow: -60), text: "раньше", outcome: "inserted")
    let leaked = HistoryEntry(id: "l", text: "Корова42", outcome: SecureDictation.outcome)
    equal(RecentDictations.lastWithText([leaked, older])?.id, "o", "Р5-1л: lastWithText пропускает secure_input")

    // Контроллер кладёт в память то, что вернул журнал, — во всех местах, а не саму запись.
    let controller = appSource("Mostik/AppController.swift")
    check(!controller.contains("model.history.insert(entry, at: 0)"),
          "Р5-1л: AppController кладёт в model.history результат history.record, а не исходную запись")
    check(functionBody(controller, "private func replaceEntry(").contains("history.record("),
          "Р5-1л: replaceEntry обновляет память тем, что легло в файл")
    // Поле пароля в момент вставки: ни очереди агенту, ни панели tmux, ни потоковой вставки.
    let insert = functionBody(controller, "private func insert(_ id: String) async {")
    let guardAt = insert.range(of: "SecureDictation.")?.lowerBound
    let queueAt = insert.range(of: "enqueueForAgent(")?.lowerBound
    check(guardAt != nil && queueAt != nil && guardAt! < queueAt!,
          "Р5-1л: insert проверяет поле пароля до очереди агенту, tmux и потоковой вставки")
    let delivery = appSource("Mostik/DeliveryController.swift")
    check(!delivery.contains("текст в истории") && !delivery.contains("text in history"),
          "Р5-1л: плашка поля пароля не обещает текст в истории — его там нет")
}

/// Поставка: поле пароля появилось посреди записи — проверка в `endRecording` до `engine.stop`.
func runRound5SecureStopTests() {
    check(SecureDictation.stopRefusal(secureInput: false, field: nil) == nil, "обычное поле — расшифровываем")
    check(SecureDictation.stopRefusal(secureInput: false, field: FieldSnapshot(bundleID: "a", role: "AXTextField")) == nil)
    let byFlag = SecureDictation.stopRefusal(secureInput: true, field: nil)
    let byRole = SecureDictation.stopRefusal(secureInput: false, field: FieldSnapshot(bundleID: "a", role: "AXTextField",
                                                                                      subrole: "AXSecureTextField"))
    check(byFlag != nil && byRole != nil, "поле пароля посреди записи — отказ")
    check(byFlag?.contains("Поле пароля") == true && byFlag?.contains("не сохранена") == true,
          "понятная строка в плашке: что случилось и что с записью")
    let end = functionBody(appSource("Mostik/AppController.swift"), "private func endRecording(")
    let checkAt = end.range(of: "SecureDictation.stopRefusal(")?.lowerBound
    let stopAt = end.range(of: "engine.stop(")?.lowerBound
    check(checkAt != nil && stopAt != nil && checkAt! < stopAt!,
          "endRecording проверяет поле пароля до engine.stop")
}

/// Р5-1: `TMUX_TMPDIR` выбирает сокет сервера — поддельный сервер мог бы велеть клиенту запустить программу.
func runRound5TmuxTests() {
    let env = Tmux.environment(parent: ["PATH": "/evil:/usr/bin", "HOME": "/h", "TMUX_TMPDIR": "/evil/socket"])
    check(env["TMUX_TMPDIR"] == nil, "Р5-1: TMUX_TMPDIR не передаётся tmux")
    equal(env["HOME"], "/h")
    let release = appSource("../docs/release.md")
    check(release.contains("`TMUX_TMPDIR`"), "Р5-1: Н-10 в docs/release.md говорит про TMUX_TMPDIR")
}

/// Р5-2: шим `/usr/bin/git` берёт путь к настоящему git из кэша xcrun (`xcrun_db`): кэш перенаправляет его.
/// Git — по пути из `xcode-select -p`, только из системных мест и только если файл есть.
func runRound5GitPathTests() {
    let exists: (String) -> Bool = { $0 == "/Library/Developer/CommandLineTools/usr/bin/git"
        || $0 == "/Applications/Xcode.app/Contents/Developer/usr/bin/git" }
    // Ф-1: владелец проверяется отдельно (runP10TailGitOwnerTests), здесь — только форма пути.
    let rootOnly: (String) -> SafeGit.PathStatus? = { _ in SafeGit.PathStatus(uid: 0, mode: 0o755, isSymlink: false) }
    func executable(developerDir: String?, isExecutable: (String) -> Bool) -> String? {
        SafeGit.executable(developerDir: developerDir, isExecutable: isExecutable, status: rootOnly)
    }
    equal(executable(developerDir: "/Library/Developer/CommandLineTools", isExecutable: exists),
          "/Library/Developer/CommandLineTools/usr/bin/git", "CLT")
    equal(executable(developerDir: "/Library/Developer/CommandLineTools/\n", isExecutable: exists),
          "/Library/Developer/CommandLineTools/usr/bin/git", "хвост вывода xcode-select")
    equal(executable(developerDir: "/Applications/Xcode.app/Contents/Developer", isExecutable: exists),
          "/Applications/Xcode.app/Contents/Developer/usr/bin/git", "Xcode")
    for bad in ["/tmp/evil", "/Users/a/Library/Developer/CommandLineTools", "/Applications/../tmp/x.app/Contents/Developer",
                "/Applications/Xcode.app/Contents/Developer/../../../../tmp", "CommandLineTools", "", "/"] {
        equal(executable(developerDir: bad, isExecutable: { _ in true }), nil, "Р5-2: не системный путь — \(bad)")
    }
    equal(executable(developerDir: nil, isExecutable: { _ in true }), nil, "xcode-select не ответил")
    equal(executable(developerDir: "/Library/Developer/CommandLineTools", isExecutable: { _ in false }), nil,
          "файла нет — без git (обход папки)")
    let files = appSource("MostikKit/ProjectFiles.swift")
    check(!files.contains("\"/usr/bin/git\""), "Р5-2: ProjectFiles не зовёт шим /usr/bin/git")
    check(files.contains("SafeGit.executable("), "Р5-2: путь git — через SafeGit.executable")
}

/// Р5-2л: осиротевшие `recordings/*.wav` (без записи в истории) живут не дольше звука диктовок.
func runRound5OrphanAudioTests() {
    let dir = tempDir("orphans")
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    let recordings = dir.appendingPathComponent("recordings", isDirectory: true)
    try? fm.createDirectory(at: recordings, withIntermediateDirectories: true)
    let now = Date()
    func file(_ name: String, age: TimeInterval) -> URL {
        let url = recordings.appendingPathComponent(name)
        fm.createFile(atPath: url.path, contents: Data([1]))
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }
    let oldOrphan = file("old.wav", age: 3 * 86_400)
    let freshOrphan = file("fresh.wav", age: 60)  // идёт запись или расшифровка
    let kept = file("kept.wav", age: 3 * 86_400)  // в истории, срок звука записи ещё не вышел
    let notAudio = file("note.txt", age: 3 * 86_400)
    let outside = dir.appendingPathComponent("outside.wav")
    fm.createFile(atPath: outside.path, contents: Data([1]))
    try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86_400)], ofItemAtPath: outside.path)

    let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"), audioRoot: recordings)
    try? store.append(HistoryEntry(id: "k", createdAt: now.addingTimeInterval(-3600), text: "t", audioPath: kept.path))
    _ = try? store.prune(retention: 7 * 86_400, audioRetention: 86_400, now: now)
    check(!fm.fileExists(atPath: oldOrphan.path), "Р5-2л: старый WAV без записи в истории удалён")
    check(fm.fileExists(atPath: freshOrphan.path), "свежий WAV (идёт запись) не трогаем")
    check(fm.fileExists(atPath: kept.path), "звук записи из истории — по сроку записи")
    check(fm.fileExists(atPath: notAudio.path), "только *.wav")
    check(fm.fileExists(atPath: outside.path), "только внутри папки звука")

    // Без своей папки звука (audioRoot по умолчанию — папка истории) сирот не ищем.
    let plainDir = tempDir("plain")
    defer { try? fm.removeItem(at: plainDir) }
    let stray = plainDir.appendingPathComponent("stray.wav")
    fm.createFile(atPath: stray.path, contents: Data([1]))
    try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86_400)], ofItemAtPath: stray.path)
    let plain = HistoryStore(fileURL: plainDir.appendingPathComponent("history.jsonl"))
    _ = try? plain.prune(retention: 7 * 86_400, audioRetention: 86_400, now: now)
    check(fm.fileExists(atPath: stray.path), "без явной папки звука файлы рядом с историей не трогаем")
}

/// Р5-3л: журнал хука — в `~/Library/Logs/Mostik/` с ротацией и правами 0600.
func runRound5HookLogTests() {
    let dir = tempDir("hooklog")
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = MostikLogPaths(root: dir)
    equal(paths.meetingHooks.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL,
          "журнал хука — рядом с app.log")
    let rotation = LogRotation(maxBytes: 100, keep: 3)
    let line = String(repeating: "x", count: 60) + "\n"
    for _ in 0..<5 { MeetingHookLog.append(line, to: paths.meetingHooks, rotation: rotation) }
    let fm = FileManager.default
    let size = (try? fm.attributesOfItem(atPath: paths.meetingHooks.path)[.size] as? Int) ?? 0
    check(size <= 100, "Р5-3л: журнал хука ротируется (\(size) байт)")
    check(fm.fileExists(atPath: paths.meetingHooks.path + ".1"), "старое — в .1")
    check(!fm.fileExists(atPath: paths.meetingHooks.path + ".3"), "не больше keep файлов")
    let mode = (try? fm.attributesOfItem(atPath: paths.meetingHooks.path)[.posixPermissions] as? Int) ?? 0
    equal(mode & 0o777, 0o600, "журнал хука — только владельцу")
    let controller = appSource("Mostik/MeetingFolderController.swift")
    check(!controller.contains("paths.logs.appendingPathComponent(\"meeting-hooks.log\")"),
          "Р5-3л: журнал хука не в Application Support/Mostik/logs")
    check(controller.contains("MeetingHookLog.append("), "Р5-3л: запись — через MeetingHookLog с ротацией")
}

/// Р5-4л: временные имена Mostik — с префиксом из `tempPrefixes`, и их убирают.
func runRound5TempNamesTests() {
    let temp = tempDir("tmp")
    defer { try? FileManager.default.removeItem(at: temp) }
    let fm = FileManager.default
    let draft = VoiceIntentICS.draftFolder(in: temp)
    check(StorageHygiene.tempPrefixes.contains { draft.lastPathComponent.hasPrefix($0) },
          "Р5-4л: папка .ics команд — с префиксом из tempPrefixes (\(draft.lastPathComponent))")
    check(draft.lastPathComponent != VoiceIntentICS.draftFolder(in: temp).lastPathComponent,
          "Р5-4л: своя папка на каждый черновик — уборка не снесёт открытый")
    check(StorageHygiene.tempPrefixes.contains("mostik-polish-"), "Р5-4л: mostik-polish- убирается после сбоя")
    let old = Date().addingTimeInterval(-3600)
    for name in ["Mostik-commands", "mostik-polish-abc", "mostik-commands-x"] {
        let url = temp.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        try? fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
    let removed = Set(StorageHygiene.cleanStaleTemp(in: temp))
    equal(removed, ["Mostik-commands", "mostik-polish-abc", "mostik-commands-x"],
          "Р5-4л: старая папка Mostik-commands и новые префиксы убираются")
    check(!appSource("Mostik/VoiceIntentController.swift").contains("\"Mostik-commands\""),
          "Р5-4л: VoiceIntentController берёт папку у VoiceIntentICS.draftFolder")
}

/// П10, хвост р5, Ф-1: `/Applications` открыт на запись админу, Xcode из `.xip`/Xcodes принадлежит пользователю —
/// git из папки разработчика берём, только если вся цепочка от `X.app` (или CLT) до файла git — root и без
/// записи группе и прочим. Владельца подставляем функцией: временная папка пользователя играет роль `/Applications`.
func runP10TailGitOwnerTests() {
    let fm = FileManager.default
    let base = tempDir("owner")
    defer { try? fm.removeItem(at: base) }
    let developer = "/Applications/Xcode.app/Contents/Developer"
    let bin = base.path + developer + "/usr/bin"
    try? fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
    let git = bin + "/git"
    fm.createFile(atPath: git, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    for dir in ["/Applications/Xcode.app", "/Applications/Xcode.app/Contents", developer, developer + "/usr",
                developer + "/usr/bin"] {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path + dir)
    }
    let mapped: (String) -> String = { base.path + $0 }
    let exists: (String) -> Bool = { fm.isExecutableFile(atPath: mapped($0)) }
    // Как есть: всё принадлежит текущему пользователю — Xcode пользователя уходит в обход папки.
    let asIs: (String) -> SafeGit.PathStatus? = { SafeGit.lstatus(mapped($0)) }
    equal(SafeGit.executable(developerDir: developer, isExecutable: exists, status: asIs), nil,
          "Ф-1: Xcode пользователя (uid ≠ 0) — без git")
    // Та же цепочка, будто владелец root: принимаем.
    let asRoot: (String) -> SafeGit.PathStatus? = { path in
        SafeGit.lstatus(mapped(path)).map { SafeGit.PathStatus(uid: 0, mode: $0.mode, isSymlink: $0.isSymlink) }
    }
    equal(SafeGit.executable(developerDir: developer, isExecutable: exists, status: asRoot), developer + "/usr/bin/git",
          "Ф-1: цепочка root без записи группе — git из Xcode")
    // Любое звено, открытое на запись группе или прочим, — отказ; и сам файл тоже.
    for (link, mode) in [("/Applications/Xcode.app", 0o775), ("/Applications/Xcode.app/Contents", 0o757),
                         (developer, 0o775), (developer + "/usr/bin", 0o777), (developer + "/usr/bin/git", 0o775)] {
        try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: mapped(link))
        equal(SafeGit.executable(developerDir: developer, isExecutable: exists, status: asRoot), nil,
              "Ф-1: \(link) с правами \(String(mode, radix: 8)) — без git")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mapped(link))
    }
    // Звено, которое не прочесть, — отказ.
    let missing: (String) -> SafeGit.PathStatus? = { $0.hasSuffix("/usr") ? nil : asRoot($0) }
    equal(SafeGit.executable(developerDir: developer, isExecutable: exists, status: missing), nil, "Ф-1: звено не читается — без git")
    // Чужое звено посреди цепочки: uid ≠ 0 только у Contents.
    let userContents: (String) -> SafeGit.PathStatus? = { path in
        path.hasSuffix(".app/Contents") ? SafeGit.PathStatus(uid: 501, mode: 0o755, isSymlink: false) : asRoot(path)
    }
    equal(SafeGit.executable(developerDir: developer, isExecutable: exists, status: userContents), nil,
          "Ф-1: Contents пользователя — без git")
    // Git — ссылка (даже на файл root): отказ, ссылку пользователь мог переставить.
    try? fm.removeItem(atPath: git)
    try? fm.createSymbolicLink(atPath: git, withDestinationPath: "/bin/sh")
    equal(SafeGit.executable(developerDir: developer, isExecutable: exists, status: asRoot), nil, "Ф-1: git-ссылка — без git")
    // Проверяется цепочка от самого .app, а не /Applications (root:admin 775 — так и задумано системой).
    let groupWritableApplications: (String) -> SafeGit.PathStatus? = { path in
        path == "/Applications" ? SafeGit.PathStatus(uid: 0, mode: 0o775, isSymlink: false)
            : SafeGit.PathStatus(uid: 0, mode: 0o755, isSymlink: false)
    }
    equal(SafeGit.executable(developerDir: developer, isExecutable: { _ in true }, status: groupWritableApplications),
          developer + "/usr/bin/git", "Ф-1: /Applications (root:admin 775) в цепочку не входит")
    // CLT: цепочка от /Library/Developer/CommandLineTools.
    let clt = SafeGit.commandLineTools
    var seen: [String] = []
    _ = SafeGit.executable(developerDir: clt, isExecutable: { _ in true },
                           status: { seen.append($0); return SafeGit.PathStatus(uid: 0, mode: 0o755, isSymlink: false) })
    equal(seen, [clt, clt + "/usr", clt + "/usr/bin", clt + "/usr/bin/git"], "Ф-1: цепочка CLT")
    // Живая система: CLT на этой машине принадлежит root — путь принимается настоящим lstat.
    if fm.isExecutableFile(atPath: clt + "/usr/bin/git"), SafeGit.lstatus(clt)?.uid == 0 {
        equal(SafeGit.executable(developerDir: clt, isExecutable: { fm.isExecutableFile(atPath: $0) }), clt + "/usr/bin/git",
              "Ф-1: настоящий CLT проходит")
    }
    // Проверка — при каждом запуске git, а не один раз за процесс: подмену .app после старта видно.
    let files = appSource("MostikKit/ProjectFiles.swift")
    check(!files.contains("static let git: String? = SafeGit.executable("), "Ф-1: путь git проверяется перед каждым запуском")
}

/// П10 хвост р5 Ф-5: `xcode-select -p` с таймаутом. Завис — как отказ: git нет, список файлов — обходом папки.
func runP10TailXcodeSelectTimeoutTests() {
    let fm = FileManager.default
    let dir = tempDir("xcsel")
    defer { try? fm.removeItem(at: dir) }
    func stub(_ name: String, _ body: String) -> String {
        let path = dir.appendingPathComponent(name).path
        fm.createFile(atPath: path, contents: Data("#!/bin/sh\n\(body)\n".utf8), attributes: [.posixPermissions: 0o755])
        return path
    }
    let slow = stub("slow", "exec /bin/sleep 30")
    let started = Date()
    equal(SafeGit.developerDir(tool: slow, timeout: 0.3), nil, "Ф-5: xcode-select завис — nil")
    check(Date().timeIntervalSince(started) < 5, "Ф-5: ждём не дольше таймаута")
    equal(SafeGit.developerDir(tool: stub("fast", "echo /Library/Developer/CommandLineTools"), timeout: 5),
          "/Library/Developer/CommandLineTools\n", "Ф-5: ответ xcode-select — как есть")
    equal(SafeGit.developerDir(tool: stub("fail", "echo /x; exit 2"), timeout: 5), nil, "Ф-5: ошибка — nil")
    equal(SafeGit.developerDir(tool: dir.appendingPathComponent("missing").path, timeout: 5), nil, "Ф-5: нет программы — nil")
    check(SafeGit.xcodeSelectTimeout > 0 && SafeGit.xcodeSelectTimeout <= 10, "Ф-5: таймаут по умолчанию — секунды")
    let files = appSource("MostikKit/ProjectFiles.swift")
    check(files.contains("SafeGit.developerDir(") && !files.contains("/usr/bin/xcode-select"),
          "Ф-5: ProjectFiles спрашивает xcode-select через SafeGit.developerDir с таймаутом")
}

/// П10 хвост р5 Ф-2: в выпуске `MOSTIK_LOG_DIR` не читается — туда шли бы вывод хука встречи и `engine.log`,
/// а `StorageHygiene.secure` ставит 0700 на любую папку из переменной. В debug и тестах — как раньше.
func runP10TailLogDirTests() {
    let env = ["MOSTIK_LOG_DIR": "/tmp/elsewhere"]
    let release = MostikLogPaths.resolve(environment: env, debug: false)
    check(release.root.path.hasSuffix("/Library/Logs/Mostik") && !release.root.path.hasPrefix("/tmp/elsewhere"),
          "Ф-2: выпуск игнорирует MOSTIK_LOG_DIR — \(release.root.path)")
    equal(release.meetingHooks.deletingLastPathComponent().path, release.root.path, "Ф-2: журнал хука — там же")
    equal(MostikLogPaths.resolve(environment: env, debug: true).root.path, "/tmp/elsewhere", "Ф-2: debug — по переменной")
    equal(MostikLogPaths.resolve(environment: ["MOSTIK_LOG_DIR": ""], debug: true).root.path, release.root.path,
          "пустая переменная — место по умолчанию")
    let releaseDoc = appSource("../docs/release.md")
    check(!releaseDoc.contains("`MOSTIK_SELFTEST*` и `MOSTIK_LOG_DIR` в выпуске"),
          "Ф-2: Р4-7 в docs/release.md не обещает, что MOSTIK_LOG_DIR в выпуске пишет фиксированный текст")
}

/// П10 хвост р5 Ф-4: `insert` смотрит не только флаг защищённого ввода, но и роль `AXSecureTextField` у фокуса,
/// и делает это до голосовой команды: иначе пароль, похожий на команду, ушёл бы в историю с исходом `command`.
func runP10TailInsertSecureFieldTests() {
    let insert = functionBody(appSource("Mostik/AppController.swift"), "private func insert(_ id: String) async {")
    let guardAt = insert.range(of: "SecureDictation.stopRefusal(secureInput: SecureInput.enabled, field: FocusedField.snapshot())")?
        .lowerBound
    let commandAt = insert.range(of: "voiceIntents.handle(")?.lowerBound
    check(guardAt != nil, "Ф-4: insert проверяет и флаг, и роль поля (SecureDictation.stopRefusal + FocusedField.snapshot)")
    check(guardAt != nil && commandAt != nil && guardAt! < commandAt!, "Ф-4: поле пароля — до ветки голосовой команды")
    check(!insert.contains("if SecureInput.enabled {"), "Ф-4: не только флаг защищённого ввода")
}

/// П10 хвост р5 Ф-3: Р5-2 в docs/release.md закрыт только для git самого Mostik — `claude` и хук встречи
/// по-прежнему зовут шим `/usr/bin/git`; это класс Н-10, принятый риск. И пункт говорит про владельца цепочки (Ф-1).
func runP10TailReleaseDocTests() {
    let doc = appSource("../docs/release.md")
    guard let start = doc.range(of: "- **git мимо шима.") else { return check(false, "Ф-3: пункт про git мимо шима в docs/release.md") }
    let rest = doc[start.upperBound...]
    let item = String(rest[..<(rest.range(of: "\n- **")?.lowerBound ?? rest.endIndex)])
    check(item.contains("`claude`") && item.contains("хук") && item.contains("тот же класс"),
          "Ф-3: пункт называет claude и хук встречи тем же классом, что программы из папок пользователя")
    check(item.contains("root"), "Ф-1: Р5-2 говорит, что цепочка до git должна принадлежать root")
}
