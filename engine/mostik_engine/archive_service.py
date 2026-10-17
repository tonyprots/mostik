"""Команды движка для архива встреч (M18, W1, W3–W6, W12). `server.py` зовёт `handle(engine, op, command)`.

| Команда | Поля | Ответ |
|---|---|---|
| `archive_brief` | `event {id, title, start, attendees}` или `event_id`, или `within_minutes`; `write` | `{brief, path}`; `brief: null` — нечего сказать или события нет |
| `archive_people` | `write` | `{items, written?}` |
| `archive_digest` | `kind: week | series`, `series`, `days`, `write` | `{digest, path}` |
| `archive_cards` | `force` | `{written, fresh, skipped}` |

Все команды только читают встречи; пишут `card.md` в папку встречи и
файлы в `<MOSTIK_HOME>/people|briefs|digests` — производные, их можно стереть.
Долгое идёт в своём потоке, ответ — с тем же `id`.
"""
from __future__ import annotations

import threading
from pathlib import Path
from typing import Any, Callable

from . import crash_report
from . import archive
from . import polish as polish_mod


def _log(text: str) -> None:
    polish_mod._log(text)


def _language(command: dict) -> str:
    return "en" if command.get("language") == "en" else "ru"


def _background(engine: Any, command: dict, job: Callable[[], dict]) -> None:
    command_id = command.get("id")

    def run() -> None:
        try:
            fields = job()
        except ValueError as error:
            engine.error("bad_request", str(error), command_id=command_id)
            return
        except Exception as error:  # noqa: BLE001
            _log("архив:\n" + crash_report.safe_traceback())
            engine.error("internal", f"{type(error).__name__}: {error}", command_id=command_id)
            return
        engine.reply(command_id, **fields)

    threading.Thread(target=run, name="mostik-archive", daemon=True).start()


def brief(engine: Any, command: dict) -> None:
    def job() -> dict:
        event = command.get("event") if isinstance(command.get("event"), dict) else None
        if event is None:
            event = archive.next_event(event_id=command.get("event_id") or None,
                                       within_minutes=float(command.get("within_minutes") or 60 * 24))
        if event is None:
            return {"brief": None, "path": None}
        data = archive.brief(event, language=_language(command))
        path = archive.write_brief(data) if command.get("write") else None
        return {"brief": data if data["points"] else None, "path": str(path) if path else None}

    _background(engine, command, job)


def people(engine: Any, command: dict) -> None:
    def job() -> dict:
        fields: dict[str, Any] = {"items": archive.people()}
        if command.get("write"):
            fields["written"] = archive.write_people()
        return fields

    _background(engine, command, job)


def digest(engine: Any, command: dict) -> None:
    def job() -> dict:
        kind = command.get("kind") or "week"
        if kind == "week":
            data = archive.week_digest(days=float(command.get("days") or 7), language=_language(command))
        elif kind == "series":
            data = archive.series_digest(str(command.get("series") or ""), language=_language(command))
        else:
            raise ValueError("kind: week или series")
        path = archive.write_digest(data) if data and command.get("write") else None
        return {"digest": data, "path": str(path) if path else None}

    _background(engine, command, job)


def cards(engine: Any, command: dict) -> None:
    _background(engine, command, lambda: archive.write_cards(force=bool(command.get("force"))))


HANDLERS: dict[str, Callable[[Any, dict], None]] = {
    "brief": brief, "people": people, "digest": digest, "cards": cards,
}


def handle(engine: Any, op: str, command: dict) -> None:
    HANDLERS[op](engine, command)


__all__ = ["handle", "HANDLERS", "Path"]
