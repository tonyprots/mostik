"""Календарь как источник словаря (S1).

Приложение читает события EventKit на ±7 дней и шлёт их командой `calendar`.
Берём только встречи с двумя и более участниками (фильтр Foresight): личные
напоминания и блоки «фокус» словарю не помогают. Набор хранится в
`<home>/calendar.json` и каждый раз заменяется целиком.

Термины: участники (вид `person`, полное имя и его части), название встречи
(кодовые имена, аббревиатуры, CamelCase) и описание по правилам документов.
Происхождение — `"календарь: <название встречи>"`. Ближайшие к текущему
моменту встречи идут первыми: их имена важнее в подсказке проверяющей.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import time
from pathlib import Path
from typing import Any

from . import paths
from .extract import KINDS, name_terms, terms_from_document, terms_from_title

MIN_ATTENDEES = 2
MAX_EVENTS = 500


def calendar_path() -> Path:
    return paths.mostik_home() / "calendar.json"


def _parse_time(value: Any) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        moment = _dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.astimezone()
    return moment.timestamp()


def _attendee_name(item: Any) -> str:
    if isinstance(item, dict):
        return " ".join(str(item.get("name") or "").split())
    return " ".join(str(item or "").split())


def normalize_events(events: Any) -> list[dict[str, Any]]:
    """Сырые события → проверенные, только с ≥2 участниками."""
    if not isinstance(events, list):
        raise ValueError("events должен быть списком")
    kept: list[dict[str, Any]] = []
    for raw in events[:MAX_EVENTS]:
        if not isinstance(raw, dict):
            continue
        attendees = [name for name in (_attendee_name(item) for item in raw.get("attendees") or []) if name]
        if len(attendees) < MIN_ATTENDEES:
            continue
        kept.append(
            {
                "id": str(raw.get("id") or ""),
                "title": " ".join(str(raw.get("title") or "").split()),
                "start": str(raw.get("start") or ""),
                "end": str(raw.get("end") or ""),
                "attendees": attendees,
                "notes": str(raw.get("notes") or ""),
            }
        )
    return kept


def store(events: Any) -> list[dict[str, Any]]:
    """Заменить сохранённый набор целиком; вернуть принятые события."""
    kept = normalize_events(events)
    target = calendar_path()
    temp = target.with_suffix(".tmp")
    temp.write_text(
        json.dumps({"saved_at": time.time(), "events": kept}, ensure_ascii=False, indent=1),
        encoding="utf-8",
    )
    os.replace(temp, target)
    return kept


def load() -> list[dict[str, Any]]:
    try:
        payload = json.loads(calendar_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    events = payload.get("events") if isinstance(payload, dict) else None
    return [event for event in events or [] if isinstance(event, dict)]


def saved_at() -> float | None:
    try:
        payload = json.loads(calendar_path().read_text(encoding="utf-8"))
        return float(payload.get("saved_at"))
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def mtime() -> float:
    try:
        return calendar_path().stat().st_mtime
    except OSError:
        return 0.0


def origin(event: dict[str, Any]) -> str:
    return f"календарь: {event.get('title') or 'без названия'}"


def terms(events: list[dict[str, Any]], now: float | None = None) -> list[dict[str, Any]]:
    """Термины календаря `{term, kind, origins}`: ближайшие встречи первыми."""
    now = time.time() if now is None else now

    def distance(event: dict[str, Any]) -> float:
        start = _parse_time(event.get("start"))
        end = _parse_time(event.get("end")) or start
        if start is None:
            return float("inf")
        if start <= now <= (end or start):
            return 0.0
        return min(abs(start - now), abs((end or start) - now))

    entries: dict[str, dict[str, Any]] = {}

    def add(term: str, kind: str, where: str) -> None:
        key = term.casefold()
        entry = entries.get(key)
        if entry is None:
            entries[key] = {"term": term, "kind": kind if kind in KINDS else "tech", "origins": [where]}
        elif where not in entry["origins"] and len(entry["origins"]) < 3:
            entry["origins"].append(where)

    for event in sorted(events, key=distance):
        where = origin(event)
        for name in event.get("attendees") or []:
            for term in name_terms(str(name)):
                add(term, "person", where)
        for term, record in terms_from_title(str(event.get("title") or "")).items():
            add(term, str(record[1]), where)
        notes = str(event.get("notes") or "")
        if notes:
            for term, record in terms_from_document(notes, markdown=False).items():
                if record[3] and int(record[0]) < 2:
                    continue
                add(term, str(record[1]), where)
    return list(entries.values())
