"""Единственный читатель папок встреч для агентов (G1–G3).

CLI, MCP и хук читают встречи только через этот модуль. Он понимает два
формата папки:

- текущий: `transcript.json` (реплики, пометки, участники), `transcript.md`,
  `notes.json` (сводка и задачи ИИ встреч по режимам), `summary.md`;
- M10 (`docs/meeting-folder.md`, схемы в `docs/schemas/`): `manifest.json`
  (`title`, `started`, `sensitive`, `recording.status`, `transcript.status`) и
  `meeting.md` с YAML-шапкой (`action_items[{assignee, task, due}]`,
  `decisions`, `sensitive`). Если они есть, их поля главнее. Чувствительная
  встреча (`sensitive`) агентам не видна вовсе: ни в списке, ни по ID, ни в
  поиске, ни в задачах.

Переход на M10 — правка только здесь: остальной код видит `MeetingRecord`.

Правило «сырое не трогать» (G3): агент пишет только в `notes.md` — это
производное поле. Расшифровку, аудио, манифест и `meeting.md` модуль не
меняет, запись куда-то ещё он не умеет вовсе (`append_note` — единственная
запись, и путь у неё фиксирован).
"""
from __future__ import annotations

import datetime as _dt
import fcntl
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import paths
from .meeting_folder import front_matter, is_sensitive, upgrade_manifest

AGENT_NOTES = "notes.md"
# Сырое и исходное: агенту только читать (G3).
RAW_FILES = frozenset({
    "transcript.json", "transcript.md", "manifest.json", "meeting.md", "notes.json", "summary.md",
    "mic.wav", "system.wav", "mic.caf", "system.caf",
})
RAW_SUFFIXES = frozenset({".wav", ".caf", ".m4a", ".mp3", ".flac", ".aiff"})
MAX_NOTE_CHARS = 20_000
_ID = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._-]{0,79}$")
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


class MeetingError(Exception):
    """Ошибка для агента: код, текст и следующая команда."""

    def __init__(self, code: str, message: str, fix: str | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.fix = fix


def meetings_root() -> Path:
    return paths.mostik_home() / "meetings"


# --- чтение файлов -------------------------------------------------------------------

def _json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return None


def _clean(value: Any) -> str:
    return " ".join(str(value or "").split())


_NAME_DATE = re.compile(r"^(\d{4}-\d{2}-\d{2}-\d{4})(\d{2})?(?:-\d+)?$")


def _date_from_name(name: str) -> _dt.datetime | None:
    """`yyyy-MM-dd-HHmm`, `yyyy-MM-dd-HHmmss`, с суффиксом `-2` у занятой минуты."""
    match = _NAME_DATE.match(name)
    if not match:
        return None
    try:
        return _dt.datetime.strptime(match.group(1) + (match.group(2) or "00"), "%Y-%m-%d-%H%M%S")
    except ValueError:
        return None


def _iso(value: Any) -> str | None:
    if isinstance(value, _dt.datetime):
        return value.isoformat(timespec="minutes")
    if isinstance(value, _dt.date):
        return value.isoformat()
    if isinstance(value, str) and value.strip():
        try:
            return _dt.datetime.fromisoformat(value.strip().replace("Z", "+00:00")).isoformat(timespec="minutes")
        except ValueError:
            return value.strip()
    return None


# --- модель ---------------------------------------------------------------------------

@dataclass
class MeetingRecord:
    id: str
    folder: Path
    title: str
    date: str | None
    duration_seconds: float | None
    language: str | None
    participants: list[str]
    attendees: list[str]
    marks: list[dict[str, Any]]
    status: str  # transcribed | recorded | processing; у M10 ещё pending | failed
    recording: str | None  # M10: recording | complete | recovered | incomplete
    sensitive: bool  # M10: манифест или `sensitive: true` в шапке meeting.md — агентам не отдаём
    format: str  # v1 | m10
    has_summary: bool
    has_agent_notes: bool
    manifest: dict[str, Any] = field(default_factory=dict)
    header: dict[str, Any] = field(default_factory=dict)
    transcript: dict[str, Any] | None = None

    def brief(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "date": self.date,
            "duration_seconds": self.duration_seconds,
            "language": self.language,
            "participants": self.participants,
            "status": self.status,
            "recording": self.recording,
            "format": self.format,
            "has_summary": self.has_summary,
            "has_agent_notes": self.has_agent_notes,
        }


def valid_id(meeting_id: str) -> bool:
    return bool(_ID.match(meeting_id or "")) and ".." not in meeting_id


def folder_for(meeting_id: str, root: Path | None = None) -> Path:
    """Папка встречи по ID; ID с путями, `..` и прочим — отказ, а не обход."""
    root = (root or meetings_root()).resolve()
    if not valid_id(meeting_id):
        raise MeetingError("bad_request", f"неверный ID встречи: {meeting_id!r}", "mostik meetings list")
    folder = (root / meeting_id).resolve()
    if folder.parent != root or not folder.is_dir():
        raise MeetingError("not_found", f"встречи {meeting_id} нет", "mostik meetings list")
    return folder


def _is_meeting(folder: Path) -> bool:
    if not folder.is_dir() or not valid_id(folder.name):
        return False
    return any((folder / name).exists() for name in
               ("transcript.json", "manifest.json", "meeting.md", "mic.wav", "system.wav"))


def load(folder: Path, *, with_transcript: bool = False) -> MeetingRecord:
    manifest = _json(folder / "manifest.json")
    manifest = upgrade_manifest(manifest) if isinstance(manifest, dict) else {}
    meeting_md = _text(folder / "meeting.md")
    header = front_matter(meeting_md) if meeting_md else {}
    transcript = _json(folder / "transcript.json")
    transcript = transcript if isinstance(transcript, dict) else ({"turns": transcript} if isinstance(transcript, list) else None)
    data = transcript or {}

    def pick(*keys: str) -> Any:
        for source in (manifest, header, data):
            for key in keys:
                value = source.get(key)
                if value not in (None, "", []):
                    return value
        return None

    named = _date_from_name(folder.name)
    date = _iso(pick("started", "date", "started_at", "start")) or (named.isoformat(timespec="minutes") if named else None)
    title = _clean(pick("title"))
    if not title:
        moment = named or (_dt.datetime.fromisoformat(date) if date and len(date) >= 16 else None)
        title = f"Встреча {moment:%d.%m.%Y %H:%M}" if moment else f"Встреча {folder.name}"
    duration = pick("duration_seconds", "duration")
    try:
        duration = round(float(duration), 2) if duration is not None else None
    except (TypeError, ValueError):
        duration = None
    participants = [_clean(item) for item in pick("participants") or [] if _clean(item)]
    attendees = []
    for item in pick("attendees") or []:
        name = _clean(item.get("name") if isinstance(item, dict) else item)
        if name:
            attendees.append(name)
    marks = [mark for mark in data.get("marks") or [] if isinstance(mark, dict)]
    if (folder / "transcript.json").is_file():
        status = "transcribed"
    elif any((folder / name).is_file() for name in ("mic.wav", "system.wav")):
        status = "recorded"
    else:
        status = "processing"
    # M10: состояние расшифровки — `manifest.transcript.status`, записи — `manifest.recording.status`.
    stage = manifest.get("transcript") if isinstance(manifest.get("transcript"), dict) else {}
    if stage.get("status") == "done":
        status = "transcribed"
    elif isinstance(stage.get("status"), str) and stage["status"] not in ("done", "missing"):
        status = stage["status"]
    recording = manifest.get("recording") if isinstance(manifest.get("recording"), dict) else {}
    return MeetingRecord(
        id=folder.name, folder=folder, title=title, date=date, duration_seconds=duration,
        language=pick("language"), participants=participants, attendees=attendees, marks=marks,
        status=status, recording=recording.get("status") if isinstance(recording.get("status"), str) else None,
        sensitive=is_sensitive(folder),  # правило M10 — в одном месте, в meeting_folder
        format="m10" if (manifest or header) else "v1",
        has_summary=(folder / "notes.json").is_file() or (folder / "summary.md").is_file() or bool(header),
        has_agent_notes=(folder / AGENT_NOTES).is_file(), manifest=manifest, header=header,
        transcript=transcript if with_transcript else None,
    )


def list_meetings(root: Path | None = None, *, limit: int | None = None) -> list[MeetingRecord]:
    """Встречи, новые первыми (по имени папки — это дата)."""
    root = root or meetings_root()
    try:
        folders = sorted((item for item in root.iterdir() if _is_meeting(item)), key=lambda p: p.name, reverse=True)
    except OSError:
        return []
    records = [record for record in (load(folder) for folder in folders) if not record.sensitive]
    return records[: max(0, limit)] if limit is not None else records


def get(meeting_id: str, root: Path | None = None, *, with_transcript: bool = True) -> MeetingRecord:
    """Встреча по ID; чувствительная (M10) для агента выглядит как отсутствующая."""
    record = load(folder_for(meeting_id, root), with_transcript=with_transcript)
    if record.sensitive:
        raise MeetingError("not_found", f"встречи {meeting_id} нет", "mostik meetings list")
    return record


# --- производное: сводка, задачи, заметки агентов ------------------------------------

def _best_mode(record: MeetingRecord) -> tuple[str | None, dict[str, Any] | None]:
    """Режим ИИ из `notes.json`: `last_mode`, потом подробный и краткий — первый удачный (как в M10)."""
    notes = _json(record.folder / "notes.json")
    if not isinstance(notes, dict) or not isinstance(notes.get("modes"), dict):
        return None, None
    modes = notes["modes"]
    for name in (notes.get("last_mode"), "detailed", "brief"):
        mode = modes.get(name) if isinstance(name, str) else None
        if isinstance(mode, dict) and mode.get("status") in ("done", "partial"):
            return name, mode
    return None, None


def summary(record: MeetingRecord) -> dict[str, Any] | None:
    """Сводка: обзор и пункты из `notes.json`, решения из шапки `meeting.md` (M10), задачи — `actions`."""
    name, mode = _best_mode(record)
    decisions = [_clean(item) for item in record.header.get("decisions") or [] if _clean(item)]
    tasks = actions(record)
    if mode is None and not decisions and not tasks:
        return None
    result: dict[str, Any] = {"source": "notes.json" if mode is not None else "meeting.md"}
    if mode is not None:
        result.update({"mode": name, "status": mode.get("status"), "overview": mode.get("overview") or "",
                       "points": mode.get("points") or [], "notes": mode.get("notes") or []})
    result["decisions"] = decisions
    result["tasks"] = tasks
    return result


_CLOSED = frozenset({"done", "closed", "completed", "cancelled", "сделано", "закрыто"})


def _task_open(item: dict[str, Any]) -> bool:
    if item.get("done") is True or item.get("completed") is True:
        return False
    return str(item.get("status") or "").strip().lower() not in _CLOSED


def actions(record: MeetingRecord, states: dict[str, dict[str, Any]] | None = None) -> list[dict[str, Any]]:
    """Задачи встречи в одном виде: `{task, assignee, due, open, refs, key, due_date, status}`.

    W4: `due_date` — срок из речи датой (`due_dates`, относительно дня встречи), `status` —
    `open | done | dropped` с учётом отметок пользователя (`task_state`), `key` — ключ отметки.
    """
    from . import due_dates, task_state

    raw: list[Any] = []
    if isinstance(record.header.get("action_items"), list) and record.header["action_items"]:
        raw = record.header["action_items"]
    else:
        raw = (_best_mode(record)[1] or {}).get("tasks") or []
    states = task_state.load() if states is None else states
    items = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        task = _clean(item.get("task") or item.get("text"))
        if not task:
            continue
        key = task_state.task_key(task)
        marked = task_state.status(record.id, key, states)
        is_open = _task_open(item) if marked is None else marked == "open"
        due = _clean(item.get("due")) or None
        items.append({
            "task": task,
            "assignee": _clean(item.get("assignee")) or None,
            "owner": _clean(item.get("owner")) or None,
            "due": due,
            "open": is_open,
            "refs": [ref for ref in item.get("refs") or [] if isinstance(ref, int)],
            "key": key,
            "due_date": due_dates.due_date(due, record.date) if due else None,
            "status": marked or ("open" if is_open else "done"),
        })
    return items


def turns(record: MeetingRecord) -> list[dict[str, Any]]:
    data = record.transcript or _json(record.folder / "transcript.json") or {}
    raw = data if isinstance(data, list) else next(
        (data[key] for key in ("turns", "segments", "lines") if isinstance(data.get(key), list)), [])
    result = []
    for number, item in enumerate(raw):
        if not isinstance(item, dict):
            continue
        text = _clean(item.get("text"))
        if not text:
            continue
        try:
            start = round(float(item.get("start") or 0.0), 2)
        except (TypeError, ValueError):
            start = 0.0
        result.append({"n": number, "speaker": _clean(item.get("speaker")) or None, "start": start, "text": text})
    return result


def agent_notes(record: MeetingRecord) -> str | None:
    return _text(record.folder / AGENT_NOTES)


def append_note(meeting_id: str, text: str, *, author: str = "агент", root: Path | None = None,
                now: _dt.datetime | None = None) -> dict[str, Any]:
    """Дописать заметку агента в `notes.md` встречи. Единственная запись в папку встречи (G3)."""
    folder = get(meeting_id, root, with_transcript=False).folder
    body = _CONTROL.sub("", str(text or "")).strip()
    if not body:
        raise MeetingError("bad_request", "пустая заметка", f"mostik meetings note {meeting_id} \"текст\"")
    if len(body) > MAX_NOTE_CHARS:
        raise MeetingError("bad_request", f"заметка длиннее {MAX_NOTE_CHARS} знаков", None)
    author = _clean(_CONTROL.sub("", author)) or "агент"
    moment = (now or _dt.datetime.now()).strftime("%Y-%m-%d %H:%M")
    target = folder / AGENT_NOTES
    assert target.name == AGENT_NOTES and target.parent == folder  # G3: путь записи фиксирован
    with open(target, "a+", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            handle.seek(0, 2)
            prefix = "" if handle.tell() else f"# Заметки: {load(folder).title}\n"
            handle.write(f"{prefix}\n## {moment} · {author}\n\n{body}\n")
            handle.flush()
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
    return {"id": folder.name, "path": str(target), "chars": len(body), "author": author, "at": moment}
