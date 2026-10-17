import Foundation
import MostikCore

/// П10 С1: движок запускается изолированно — `-I`, путь к движку аргументом, окружение без
/// `PYTHON*`, `DYLD_*`, `LD_*`; адреса и пути кода из окружения — только в debug-сборке.
func runEngineIsolationTests() {
    let dir = URL(fileURLWithPath: "/Applications/Mostik.app/Contents/Resources/engine", isDirectory: true)

    // MARK: аргументы
    do {
        let args = EngineLaunch.arguments(engineDir: dir, module: "mostik_engine")
        equal(args.first, "-I", "изолированный режим: без user site, PYTHON* и папки скрипта")
        check(args.contains("-u"), "небуферизованный вывод: PYTHONUNBUFFERED при -I не действует")
        check(!args.contains("-m"), "не -m: ему нужен PYTHONPATH, который -I игнорирует")
        guard let c = args.firstIndex(of: "-c") else { check(false, "есть загрузчик -c"); return }
        let boot = args[c + 1]
        check(boot.contains("runpy.run_module"), "модуль запускается через runpy")
        check(!boot.contains(dir.path), "путь к движку — аргументом, не внутри кода")
        equal(Array(args[(c + 2)...]), [dir.path, "mostik_engine"], "путь и модуль — отдельными аргументами")
    }

    // MARK: окружение
    do {
        let base = [
            "PATH": "/usr/bin", "HOME": "/Users/a", "LANG": "ru_RU.UTF-8",
            "PYTHONPATH": "/evil", "PYTHONHOME": "/evil", "PYTHONSTARTUP": "/evil/x.py", "PYTHONWARNINGS": "x",
            "PYTHONUSERBASE": "/evil", "PYTHONINSPECT": "1", "PYTHONUNBUFFERED": "1",
            "DYLD_INSERT_LIBRARIES": "/evil.dylib", "DYLD_LIBRARY_PATH": "/evil", "LD_PRELOAD": "/evil.so",
            "MOSTIK_MODELS_BASE_URL": "https://mirror.example.net",
            "MOSTIK_MODELS_MANIFEST": "/evil/manifest.json", "TRANSCRIBER_UNPIN": "1",
            "MOSTIK_TRANSCRIBER": "/evil/scripts", "MOSTIK_TRANSCRIBER_PYTHON": "/evil/py", "MOSTIK_LLM_PYTHON": "/evil/py",
        ]
        let env = EngineLaunch.environment(base: base, home: URL(fileURLWithPath: "/h"), crashDir: nil, debug: false)
        let leaked = env.keys.filter { $0.hasPrefix("PYTHON") || $0.hasPrefix("DYLD_") || $0.hasPrefix("LD_") }.sorted()
        equal(leaked, [], "PYTHON*, DYLD_*, LD_* не доходят до движка")
        for key in ["MOSTIK_MODELS_BASE_URL", "MOSTIK_MODELS_MANIFEST", "TRANSCRIBER_UNPIN",
                    "MOSTIK_TRANSCRIBER", "MOSTIK_TRANSCRIBER_PYTHON", "MOSTIK_LLM_PYTHON"] {
            check(env[key] == nil, "\(key) в выпуске из окружения не берётся")
        }
        equal(env["MOSTIK_HOME"], "/h")
        equal(env["HF_HUB_OFFLINE"], "1", "офлайн как раньше")
        equal(env["PATH"], ToolEnvironment.defaultPath, "PATH выпуска — только системный")
        equal(env["LANG"], "ru_RU.UTF-8", "обычные переменные остаются")

        let dev = EngineLaunch.environment(base: base, home: URL(fileURLWithPath: "/h"),
                                           crashDir: URL(fileURLWithPath: "/c"), debug: true)
        equal(dev["MOSTIK_MODELS_MANIFEST"], "/evil/manifest.json", "в debug-сборке переопределение работает")
        equal(dev["TRANSCRIBER_UNPIN"], "1")
        equal(dev["MOSTIK_TRANSCRIBER"], "/evil/scripts")
        check(dev["MOSTIK_MODELS_BASE_URL"] == nil, "адрес зеркала — только командой, как раньше")
        check(dev["PYTHONPATH"] == nil && dev["DYLD_INSERT_LIBRARIES"] == nil, "и в debug без PYTHON* и DYLD_*")
        equal(dev["MOSTIK_CRASH_DIR"], "/c")
    }

    // MARK: внешние бинарники и кэш моделей в выпуске не из окружения
    do {
        let base = ["PATH": "/evil/bin:/usr/bin", "HOME": "/Users/a",
                    "TRANSCRIBER_FLUIDAUDIO_BIN": "/evil/fluidaudiocli", "TRANSCRIBER_OTHER": "1",
                    "HF_HOME": "/evil/hf", "HF_HUB_CACHE": "/evil/hub", "HF_ENDPOINT": "https://evil.example",
                    "MOSTIK_CURATED_GLOSSARY": "/evil/g.yaml", "XDG_CACHE_HOME": "/evil/xdg"]
        let env = EngineLaunch.environment(base: base, home: URL(fileURLWithPath: "/h"), crashDir: nil, debug: false)
        equal(env["PATH"], ToolEnvironment.defaultPath, "PATH выпуска — системный, бандл добавляет движок")
        for key in ["TRANSCRIBER_FLUIDAUDIO_BIN", "TRANSCRIBER_OTHER", "HF_HOME", "HF_HUB_CACHE", "HF_ENDPOINT",
                    "MOSTIK_CURATED_GLOSSARY", "XDG_CACHE_HOME"] {
            check(env[key] == nil, "\(key) в выпуске из окружения не берётся")
        }
        equal(env["TRANSCRIBER_NO_UPDATE_CHECK"], "1", "свои офлайн-переменные остаются")
        equal(env["HF_HUB_OFFLINE"], "1")
        let dev = EngineLaunch.environment(base: base, home: URL(fileURLWithPath: "/h"), crashDir: nil, debug: true)
        equal(dev["PATH"], "/evil/bin:/usr/bin", "в debug-сборке PATH как был")
        equal(dev["TRANSCRIBER_FLUIDAUDIO_BIN"], "/evil/fluidaudiocli")
        equal(dev["HF_HOME"], "/evil/hf")
    }

    // MARK: старый путь окружения (EngineEnvironment) вычищает то же
    do {
        var env = ["MOSTIK_MODELS_MANIFEST": "/x", "TRANSCRIBER_UNPIN": "1", "PYTHONPATH": "/x", "DYLD_FOO": "1"]
        EngineEnvironment.apply(to: &env, debug: false)
        equal(env.keys.filter { !EngineEnvironment.offline.keys.contains($0) && $0 != "PATH" }.sorted(), [], "apply в выпуске")
    }
}

/// Внешние утилиты (git, tmux, хук встречи) — с урезанным окружением: только нужное для работы.
func runToolEnvironmentTests() {
    let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/a", "USER": "a", "LANG": "ru_RU.UTF-8", "TMPDIR": "/tmp/x",
                "SHELL": "/bin/zsh", "TERM": "xterm", "LC_ALL": "ru_RU.UTF-8",
                "GITHUB_TOKEN": "secret", "AWS_SECRET_ACCESS_KEY": "secret", "ANTHROPIC_API_KEY": "secret",
                "DYLD_INSERT_LIBRARIES": "/evil.dylib", "PYTHONPATH": "/evil", "GIT_DIR": "/evil", "TMUX": "/tmp/t,1,0"]
    let env = ToolEnvironment.minimal(base)
    // П10 р3 С-2: PATH родителя не наследуется — `launchctl setenv PATH` не подменит `cp` в хуке.
    equal(env["PATH"], ToolEnvironment.defaultPath)
    equal(ToolEnvironment.minimal(["PATH": "/evil:/usr/bin"])["PATH"], ToolEnvironment.defaultPath, "чужой PATH")
    equal(env["HOME"], "/Users/a")
    equal(env["LANG"], "ru_RU.UTF-8")
    equal(env["LC_ALL"], "ru_RU.UTF-8")
    equal(env["TMPDIR"], "/tmp/x")
    for key in ["GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY", "ANTHROPIC_API_KEY", "DYLD_INSERT_LIBRARIES", "PYTHONPATH",
                "GIT_DIR", "TMUX"] {
        check(env[key] == nil, "\(key) внешней утилите не передаётся")
    }
    equal(ToolEnvironment.minimal(["HOME": "/h"])["PATH"], ToolEnvironment.defaultPath, "PATH по умолчанию")
}

/// П10: `git` в чужом репозитории (список файлов проекта) — его `.git/config` ничего не запускает,
/// окружение урезано, без `GIT_*`; tmux и хук встречи — тоже с урезанным окружением.
func runSafeGitTests() {
    let args = SafeGit.arguments(root: "/r", ["ls-files", "-z"])
    for pair in [["-c", "core.fsmonitor=false"], ["-c", "core.hooksPath=/dev/null"]] {
        check(zip(args, args.dropFirst()).contains { [$0, $1] == pair }, "git \(pair[1])")
    }
    equal(Array(args.suffix(4)), ["-C", "/r", "ls-files", "-z"])
    let env = SafeGit.environment(["PATH": "/usr/bin", "HOME": "/h", "GIT_DIR": "/evil", "GIT_CONFIG_GLOBAL": "/evil",
                                   "GIT_EXTERNAL_DIFF": "/evil", "GITHUB_TOKEN": "s", "DYLD_INSERT_LIBRARIES": "/e"])
    equal(env["GIT_CONFIG_NOSYSTEM"], "1")
    equal(env["GIT_TERMINAL_PROMPT"], "0")
    for key in ["GIT_DIR", "GIT_CONFIG_GLOBAL", "GIT_EXTERNAL_DIFF", "GITHUB_TOKEN", "DYLD_INSERT_LIBRARIES"] {
        check(env[key] == nil, "git без \(key)")
    }
    equal(env["HOME"], "/h")

    // Хук встречи: свои переменные Mostik есть, секретов и DYLD_* родителя нет.
    let hook = MeetingHook.environment(folder: URL(fileURLWithPath: "/m/2026-01-01"), event: .transcript,
                                       base: ["PATH": "/usr/bin", "HOME": "/h", "ANTHROPIC_API_KEY": "s", "DYLD_X": "1"])
    equal(hook["MOSTIK_MEETING_DIR"], "/m/2026-01-01")
    check(hook["ANTHROPIC_API_KEY"] == nil && hook["DYLD_X"] == nil, "хук без окружения родителя")

    // П10 р3 С-2: отпечаток закрепляет текст команды, а PATH — то, какие программы она найдёт.
    // `launchctl setenv PATH /evil:/usr/bin` не должен подменить `cp` подтверждённой команды.
    let evil = ["PATH": "/evil:/usr/bin:/bin", "HOME": "/h"]
    equal(MeetingHook.environment(folder: URL(fileURLWithPath: "/m/x"), event: .transcript, base: evil)["PATH"],
          ToolEnvironment.defaultPath, "хук: PATH всегда системный")
    equal(SafeGit.environment(evil)["PATH"], ToolEnvironment.defaultPath, "git: PATH всегда системный")
    let tmuxEnv = Tmux.environment(parent: evil.merging(["TMUX": "/tmp/t,1,0", "TMUX_PANE": "%1",
                                                         "TMUX_TMPDIR": "/s"]) { $1 })
    equal(tmuxEnv["PATH"], ToolEnvironment.defaultPath, "tmux: PATH всегда системный")
    check(tmuxEnv["TMUX_TMPDIR"] == nil, "П10 р5 Р5-1: TMUX_TMPDIR не передаётся — сокет только по умолчанию")
    check(tmuxEnv["TMUX"] == nil && tmuxEnv["TMUX_PANE"] == nil, "tmux: без «текущей» сессии")

    // Исходники: git, tmux и хук вызываются с урезанным окружением.
    let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MostikKit", isDirectory: true)
    func source(_ name: String) -> String {
        (try? String(contentsOf: kit.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
    check(source("ProjectFiles.swift").contains("SafeGit."), "ProjectFiles: git через SafeGit")
    check(source("TmuxClient.swift").contains("Tmux.environment("), "tmux: урезанное окружение")
}
