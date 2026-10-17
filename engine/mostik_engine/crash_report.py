"""Локальный отчёт о сбое движка (П8, пункт 6).

Приложение передаёт папку в `MOSTIK_CRASH_DIR` (`~/Library/Logs/Mostik/crashes`).
Необработанное исключение главного цикла — файл `engine-<время>-pid<N>.txt` с типом,
кадрами стека (файл, строка, функция, код) и сообщением, в котором строки в кавычках
заменены на «…»: в сообщении исключения может оказаться кусок текста диктовки.
Значения локальных переменных не пишутся. Нативное падение (SIGSEGV в MLX, torch)
ловит `faulthandler` — дамп уходит в stderr, то есть в `engine.log`, а отчёт по сигналу
пишет приложение. Ничего никуда не отправляется.
"""
from __future__ import annotations

import faulthandler
import os
import platform
import re
import sys
import time
import traceback
from pathlib import Path

KEEP = 20
_QUOTED = re.compile(r"'[^'\n]*'|\"[^\"\n]*\"|«[^»\n]*»")


def crash_dir() -> Path | None:
    raw = os.environ.get("MOSTIK_CRASH_DIR")
    return Path(raw) if raw else None


def enable_faulthandler() -> None:
    """Дамп стека всех потоков при SIGSEGV/SIGABRT/SIGBUS/SIGFPE — в stderr (engine.log)."""
    try:
        faulthandler.enable(file=sys.stderr, all_threads=True)
    except (RuntimeError, ValueError, OSError):
        pass


def redact(message: str, limit: int = 300) -> str:
    """Строки в кавычках → «…», переводы строк → пробел, длина ≤ limit."""
    flat = " ".join(_QUOTED.sub("«…»", message).split())
    return flat if len(flat) <= limit else flat[:limit] + "…"


def describe(error: BaseException) -> str:
    """`Тип: сообщение` для engine.log — сообщение через `redact` (П10 С6)."""
    return f"{type(error).__name__}: {redact(str(error))}"


def safe_traceback(error: BaseException | None = None) -> str:
    """Стек для engine.log вместо `traceback.format_exc()`: кадры те же, сообщения через `redact`.

    Цепочка `raise … from …` и контекст исключения сохраняются; значения переменных не пишутся.
    """
    if error is None:
        error = sys.exc_info()[1]
    if error is None:
        return ""
    chain: list[BaseException] = []
    seen: set[int] = set()
    current: BaseException | None = error
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        chain.append(current)
        current = current.__cause__ or (None if current.__suppress_context__ else current.__context__)
    parts = []
    for item in reversed(chain):
        lines = ["Traceback (most recent call last):"]
        for frame in traceback.extract_tb(item.__traceback__):
            lines.append(f'  File "{frame.filename}", line {frame.lineno}, in {frame.name}')
            if frame.line:
                lines.append(f"    {frame.line.strip()}")
        lines.append(describe(item))
        parts.append("\n".join(lines))
    return "\n\n-- затем / then --\n\n".join(parts)


def file_name(kind: str, when: float, pid: int) -> str:
    return f"{kind}-{time.strftime('%Y-%m-%d-%H%M%S', time.localtime(when))}-pid{pid}.txt"


def render(error: BaseException, version: str) -> str:
    frames = traceback.extract_tb(error.__traceback__)
    lines = [
        "Mostik — отчёт о сбое движка / engine crash report",
        "Только на этом Mac, никуда не отправляется. / Stays on this Mac, never sent.",
        "",
        f"version: {version}",
        f"python: {platform.python_version()}",
        f"system: {platform.platform()}",
        "kind: uncaught exception",
        f"exception: {type(error).__module__}.{type(error).__qualname__}",
        f"message: {redact(str(error))}",
        "",
        "traceback (most recent call last):",
    ]
    for frame in frames:
        lines.append(f'  File "{frame.filename}", line {frame.lineno}, in {frame.name}')
        if frame.line:
            lines.append(f"    {frame.line.strip()}")
    return "\n".join(lines) + "\n"


def prune(directory: Path, keep: int = KEEP) -> None:
    reports = sorted(
        (p for p in directory.glob("*.txt") if p.name.startswith(("app-", "engine-"))),
        key=lambda p: (p.name.split("-", 1)[1][:17], p.name),
        reverse=True,
    )
    for old in reports[keep:]:
        try:
            old.unlink()
        except OSError:
            pass


def write(error: BaseException, version: str, directory: Path | None = None,
          when: float | None = None) -> Path | None:
    """Записать отчёт; None — папка не задана или не записывается."""
    directory = directory or crash_dir()
    if directory is None:
        return None
    try:
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / file_name("engine", time.time() if when is None else when, os.getpid())
        path.write_text(render(error, version), encoding="utf-8")
        prune(directory)
        return path
    except OSError:
        return None
