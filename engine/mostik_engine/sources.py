"""Сводка источников словаря (S5): репозиторий, папки документов, календарь, личный словарь.

Ответ команд `sources` и `rescan` и словарь сессии собираются здесь, чтобы
экран «Источники» и распознавание видели один и тот же набор терминов.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any, Iterable

from . import calendar_terms
from .extract import KINDS, shape_kind
from .project_glossary import BACKGROUND_WAIT_S, ProjectGlossaries, count_kinds, iso_time

MAX_TERMS = 5000
# `path` календаря и личного словаря в ответе `sources` и в поле `in` терминов.
CALENDAR_ID = "calendar"
PERSONAL_ID = "personal"
MAX_ORIGINS = 5


def clean_paths(raw: Any) -> list[str]:
    """`sources` из команды → список путей без пустых и повторов, порядок сохраняется."""
    if raw is None:
        return []
    if isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, list):
        raise ValueError("sources должен быть списком путей")
    result: list[str] = []
    for item in raw:
        text = str(item or "").strip()
        if text and text not in result:
            result.append(text)
    return result


def personal_kind(term: str) -> str:
    kind = shape_kind(term)
    if kind:
        return kind
    if term[:1].isupper() and any("а" <= char.lower() <= "я" or char in "ёЁ" for char in term):
        return "person"
    return "tech"


def personal_entries(personal: Any) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in personal.list():
        term = str(item.get("canonical") or "").strip()
        if not term or term.casefold() in seen:
            continue
        seen.add(term.casefold())
        entries.append({"term": term, "kind": personal_kind(term), "origins": ["личный словарь"]})
    return entries


def _summary(kind: str, label: str, path: str | None, scanned_at: str | None,
             entries: list[dict[str, Any]], **extra: Any) -> dict[str, Any]:
    counts = count_kinds(entries)
    return {
        "kind": kind,
        "label": label,
        "path": path,
        "scanned_at": scanned_at,
        "counts": counts,
        "total": len(entries),
        **extra,
    }


def _merge(entries: Iterable[tuple[str, dict[str, Any]]], limit: int | None = None) -> list[dict[str, Any]]:
    """Термины всех источников в одном списке.

    Первый источник задаёт вид; происхождения копятся; `in` — значения
    `path` источников, где термин нашёлся (для фильтра в интерфейсе).
    """
    merged: dict[str, dict[str, Any]] = {}
    for source, entry in entries:
        key = entry["term"].casefold()
        current = merged.get(key)
        if current is None:
            merged[key] = {"term": entry["term"], "kind": entry["kind"],
                           "origins": list(entry["origins"]), "in": [source]}
            continue
        if source not in current["in"]:
            current["in"].append(source)
        for where in entry["origins"]:
            if where not in current["origins"] and len(current["origins"]) < MAX_ORIGINS:
                current["origins"].append(where)
    return list(merged.values())[: MAX_TERMS if limit is None else limit]


def _interleave(groups: list[tuple[str, list[dict[str, Any]]]]) -> list[tuple[str, dict[str, Any]]]:
    """По одному термину из каждого источника по кругу: лимит 5000 не съедает один источник."""
    result: list[tuple[str, dict[str, Any]]] = []
    index = 0
    while any(index < len(group) for _, group in groups):
        for source, group in groups:
            if index < len(group):
                result.append((source, group[index]))
        index += 1
    return result


def collect(
    projects: ProjectGlossaries,
    personal: Any,
    project: str | None,
    folders: list[str],
    *,
    force: bool = False,
) -> dict[str, Any]:
    """Ответ `sources`/`rescan`: `{sources: [...], terms: [...]}`."""
    summaries: list[dict[str, Any]] = []
    groups: list[tuple[str, list[dict[str, Any]]]] = []
    roots: list[tuple[str, str]] = []
    if project:
        roots.append(("repo", project))
    roots.extend(("docs", folder) for folder in folders)
    for kind, root in roots:
        result = projects.scan(root, kind, force=force)
        label = Path(root).expanduser().name or root
        if result is None:
            summaries.append(_summary(kind, label, root, None, [], error="нет папки"))
            continue
        entries = result["entries"]
        # path — как прислало приложение: по нему интерфейс сверяет `in` у терминов.
        summaries.append(
            _summary(kind, label, root, result["scanned_at"], entries,
                     files=result["files"], truncated=result["truncated"])
        )
        groups.append((root, entries))
    events = calendar_terms.load()
    calendar_entries = calendar_terms.terms(events)
    saved = calendar_terms.saved_at()
    summaries.append(
        _summary("calendar", "Календарь", CALENDAR_ID,
                 iso_time(saved) if saved else None, calendar_entries, events=len(events))
    )
    groups.append((CALENDAR_ID, calendar_entries))
    personal_list = personal_entries(personal)
    try:
        personal_mtime = personal.path.stat().st_mtime
    except (OSError, AttributeError):
        personal_mtime = None
    summaries.append(
        _summary("personal", "Личный словарь", PERSONAL_ID,
                 iso_time(personal_mtime) if personal_mtime else None, personal_list)
    )
    groups.append((PERSONAL_ID, personal_list))
    return {"sources": summaries, "terms": _merge(_interleave(groups))}


def session_terms(
    projects: ProjectGlossaries,
    project: str | None,
    folders: list[str],
) -> tuple[list[str], list[str], list[str]]:
    """Термины сессии без личного словаря: (проект, документы, календарь)."""
    # Старт сессии не ждёт обход дольше BACKGROUND_WAIT_S: дальше — прошлый результат.
    project_terms = projects.terms(project, "repo", wait_s=BACKGROUND_WAIT_S) if project else []
    docs: list[str] = []
    for folder in folders:
        docs.extend(projects.terms(folder, "docs", wait_s=BACKGROUND_WAIT_S))
    calendar = [entry["term"] for entry in calendar_terms.terms(calendar_terms.load())]
    return project_terms, docs, calendar


__all__ = ["KINDS", "MAX_TERMS", "clean_paths", "collect", "personal_entries", "session_terms"]
