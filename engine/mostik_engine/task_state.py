"""Отметки пользователя по поручениям встреч (W4): «сделано» и «снято».

Поручения живут в сгенерированных файлах встречи (`meeting.md`, `notes.json`), их
перегенерация затёрла бы отметку. Поэтому отметки лежат отдельно:
`<MOSTIK_HOME>/archive/tasks.json` — `{"tasks": {"<id встречи>:<ключ>": {status, at}}}`.
Ключ поручения — первые 12 знаков sha1 от нормализованного текста: он не
меняется, пока не поменялась формулировка.

Пишет только приложение (кнопки «Сделано» / «Не сделано» в брифе); агентам через
CLI и MCP — только чтение (G3).
"""
from __future__ import annotations

import datetime as _dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
from typing import Any

from . import paths

STATUSES = ("open", "done", "dropped")


def state_path() -> Path:
    return paths.mostik_home() / "archive" / "tasks.json"


def task_key(text: str) -> str:
    normalized = " ".join(str(text or "").replace("ё", "е").casefold().split())
    return hashlib.sha1(normalized.encode("utf-8")).hexdigest()[:12]


def load() -> dict[str, dict[str, Any]]:
    try:
        data = json.loads(state_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    tasks = data.get("tasks") if isinstance(data, dict) else None
    return {key: value for key, value in (tasks or {}).items() if isinstance(value, dict)}


def status(meeting_id: str, key: str, states: dict[str, dict[str, Any]] | None = None) -> str | None:
    entry = (states if states is not None else load()).get(f"{meeting_id}:{key}")
    value = entry.get("status") if entry else None
    return value if value in STATUSES else None


def set_status(meeting_id: str, key: str, value: str) -> dict[str, Any]:
    """Поставить отметку; `open` — снять её (поручение снова открыто)."""
    if value not in STATUSES:
        raise ValueError(f"status: одно из {', '.join(STATUSES)}")
    if not meeting_id or not key:
        raise ValueError("нужны meeting и key")
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = path.with_suffix(".lock")
    with open(lock, "a+", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            tasks = load()
            name = f"{meeting_id}:{key}"
            if value == "open":
                tasks.pop(name, None)
            else:
                tasks[name] = {"status": value, "at": _dt.datetime.now().astimezone().isoformat(timespec="seconds")}
            tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
            tmp.write_text(json.dumps({"schema": "mostik.tasks", "version": 1, "tasks": tasks},
                                      ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
            tmp.replace(path)
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
    return {"meeting": meeting_id, "key": key, "status": value}
