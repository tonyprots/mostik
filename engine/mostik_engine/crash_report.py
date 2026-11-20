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


def stderr_line(text: str) -> None:
    """Строка журнала в stderr (`engine.log`). На выходе приложение закрывает канал раньше,
    чем движок гасит процессы моделей, и прощальная строка «процесс … остановлен» роняла
    движок с `BrokenPipeError` (0.1.2). Закрытый канал — не сбой: дальше пишем в /dev/null,
    чтобы и финальный сброс буфера при выходе интерпретатора не ругался."""
    try:
        print(text, file=sys.stderr, flush=True)
    except (BrokenPipeError, OSError, ValueError):
        try:
            devnull = os.open(os.devnull, os.O_WRONLY)
            os.dup2(devnull, sys.stderr.fileno())
            os.close(devnull)
        except (AttributeError, OSError, ValueError):
            pass


def redact(message: str, limit: int = 300) -> str:
    """Строки в кавычках → «…», переводы строк → пробел, длина ≤ limit."""
    flat = " ".join(_QUOTED.sub("«…»", message).split())
    return flat if len(flat) <= limit else flat[:limit] + "…"


_SIGNS = re.compile(
    r"\b[A-Z][A-Za-z]*(?:Error|Exception|Interrupt)\b|\bE[A-Z]{3,}\b|\bSIG[A-Z]+\b|\b[45]\d\d\b"
    r"|unauthori[sz]ed|authenticat\w*|logged out|log ?in|forbidden|rate.?limit\w*|quota|overloaded|usage limit"
    r"|timed? ?out|network|connection \w+|dns|proxy|not found|no such file|permission denied|killed"
    r"|out of memory|credit\w*|billing|api key|invalid \w+|Error Domain=\S+ Code=-?\d+"
    r"|fluidaudio|coreml|gigaam|whisper|parakeet|offline mode", re.IGNORECASE)


def diagnostic(output: str, limit: int = 160) -> str:
    """Вывод внешней программы (claude, codex, transcriber) для журнала: только признаки сбоя.

    В хвосте вывода бывает сам запрос — кусок диктовки или расшифровки, и не обязательно в кавычках,
    поэтому `redact` здесь мало. Оставляем известные слова диагностики, остальное считаем по длине.
    """
    flat = " ".join((output or "").split())
    if not flat:
        return ""
    signs: list[str] = []
    for match in _SIGNS.finditer(flat):
        sign = match.group(0).lower() if not match.group(0)[:1].isupper() else match.group(0)
        if sign not in signs:
            signs.append(sign)
    head = ", ".join(signs)[:limit]
    return f"{head} (вывод {len(flat)} зн. скрыт)" if head else f"(вывод {len(flat)} зн. скрыт)"


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


def answered(engine, command_id, job):
    """Обёртка фоновой задачи команды: сбой не оставляет приложение без ответа — уходит `error internal`."""
    def run() -> None:
        try:
            job()
        except Exception as error:  # noqa: BLE001
            try:
                stderr_line("сбой фоновой задачи:\n" + safe_traceback())
                engine.error("internal", f"{type(error).__name__}: {redact(str(error))}", command_id=command_id)
            except Exception:  # noqa: BLE001 — сообщить не вышло: поток всё равно не роняем
                pass
    return run


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
