"""Изолированный запуск дочерних процессов Python (П10 С1).

`-I` отключает пользовательский site (`~/.local/lib/python3.x/site-packages` и его `.pth`),
переменные `PYTHON*` и папку скрипта в `sys.path`. Путь к движку при `-I` через `PYTHONPATH`
не передать, поэтому он идёт аргументом в короткий загрузчик — тот же, что у приложения
(`Sources/MostikCore/ProcessIsolation.swift`, `EngineLaunch.bootstrap`).
"""
from __future__ import annotations

import os
from pathlib import Path

ENGINE_DIR = Path(__file__).resolve().parent.parent

# Загрузчик: sys.argv[1] — каталог движка, sys.argv[2] — модуль. Пути в код не подставляются.
BOOTSTRAP = (
    "import sys, runpy; d, m = sys.argv[1], sys.argv[2]; del sys.argv[1:3]; "
    "sys.path.insert(0, d); runpy.run_module(m, run_name='__main__', alter_sys=True)"
)

# Переменные, которыми чужой код попадает в процесс Python или в загрузчик macOS.
UNSAFE_PREFIXES = ("PYTHON", "DYLD_", "LD_")

# П10 р4 Р4-1: дочерним процессам — белый список, а не «всё, кроме опасного». Шимы `/usr/bin/git`, `xcrun`,
# `python3`, `swift` следуют `DEVELOPER_DIR`/`TOOLCHAINS`/`SDKROOT` и запускают `$DEVELOPER_DIR/usr/bin/xcrun`;
# `/bin/sh` читает `BASH_ENV`/`ENV`, node — `NODE_OPTIONS`. Всё это `launchctl setenv` выдаёт процессу Mostik,
# а ребёнок наследует его разрешения TCC. Список повторяет `ToolEnvironment.allowed` приложения.
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
BASE_KEYS = frozenset({"HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM", "__CF_USER_TEXT_ENCODING"})
BASE_PREFIXES = ("LC_",)
# Детям-Python (transcriber, MLX, проверяющая) и fluidaudiocli: свои настройки, офлайн-флаги, кэш моделей.
# Что из этого опасно в выпуске (`TRANSCRIBER_FLUIDAUDIO_BIN`, `HF_*` кроме офлайна), снимает `privacy.scrub_dev_overrides`.
CHILD_KEYS = BASE_KEYS | {"PATH", "MODEL_REGISTRY_URL", "REGISTRY_URL", "XDG_CACHE_HOME"}
CHILD_PREFIXES = BASE_PREFIXES + ("MOSTIK_", "TRANSCRIBER_", "HF_", "TRANSFORMERS_", "TOKENIZERS_")
# `claude`: вход и сеть (ключ API, прокси, корпоративный сертификат). Без `NODE_OPTIONS` и `CLAUDECODE`.
CLAUDE_KEYS = BASE_KEYS | {"PATH", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
                           "http_proxy", "https_proxy", "no_proxy", "all_proxy", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE"}
CLAUDE_PREFIXES = BASE_PREFIXES + ("ANTHROPIC_",)


def _pick(source, keys: frozenset[str] | set[str], prefixes: tuple[str, ...]) -> dict[str, str]:
    return {key: value for key, value in source.items()
            if (key in keys or key.startswith(prefixes)) and not key.startswith(UNSAFE_PREFIXES)}


def tool_env(base: dict[str, str] | None = None) -> dict[str, str]:
    """Окружение системных утилит (git, ps, pdftotext): белый список и системный `PATH`."""
    env = _pick(os.environ if base is None else base, BASE_KEYS, BASE_PREFIXES)
    env["PATH"] = SYSTEM_PATH
    return env


def claude_env(base: dict[str, str] | None = None) -> dict[str, str]:
    """Окружение `claude`: белый список, без переменных node и toolchain."""
    return _pick(os.environ if base is None else base, CLAUDE_KEYS, CLAUDE_PREFIXES)


def child_env(base: dict[str, str] | None = None) -> dict[str, str]:
    """Белый список окружения (Р4-1), без `PYTHON*`, `DYLD_*`, `LD_*`, зато с `PYTHONNOUSERSITE=1` и `PYTHONSAFEPATH=1`.

    Р2 Н2: `transcribe.py` идёт с `-s -E` и переменную не читает, а его воркеры (`worker`,
    `diarization_worker`) запускаются копией transcriber без `-s` — им user site и его `.pth`
    отключает только она. `sitecustomize.py` в бандле тут не помог бы: `site` исполняет `.pth`
    из user site раньше, чем импортирует `sitecustomize`.
    """
    env = _pick(os.environ if base is None else base, CHILD_KEYS, CHILD_PREFIXES)
    env["PYTHONNOUSERSITE"] = "1"
    # Р3 Н-3: внуки идут `python -m …` с `cwd=job_dir`, и рабочая папка встала бы в `sys.path` раньше
    # `PYTHONPATH` бандла. Python 3.11+ с этой переменной её не добавляет; `-s -E` у `transcribe.py`
    # её не читает (ему папка скрипта нужна), а внуки — читают.
    env["PYTHONSAFEPATH"] = "1"
    return env


def module_command(python: str, module: str, engine_dir: Path | str = ENGINE_DIR) -> list[str]:
    """`python -I -u -c <загрузчик> <каталог движка> <модуль>` — вместо `python -m` с PYTHONPATH."""
    return [str(python), "-I", "-u", "-c", BOOTSTRAP, str(engine_dir), module]
