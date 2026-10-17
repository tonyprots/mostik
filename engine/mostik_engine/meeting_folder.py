"""Папка встречи как контракт (M10): `manifest.json`, `meeting.md`, `transcript.json`, `notes.md`.

Описание для людей и агентов — `docs/meeting-folder.md`, схемы — `docs/schemas/`.
Этот модуль — единственное место, где движок пишет `manifest.json` и
`meeting.md`; приложение (Swift) дописывает в манифест свои поля тем же
правилом слияния: читаем, меняем свои ключи, пишем атомарно.

Правила, на которые опираются чужие модули (MCP, CLI, хуки):

- встреча чувствительная, если `manifest.sensitive` истинно ИЛИ в YAML-шапке
  `meeting.md` стоит `sensitive: true` (`is_sensitive`). Такую встречу не
  получают хуки, рецепты, брифы и MCP;
- `meeting.md` генерируется. Правку человека (кроме строки `sensitive:`)
  перед перегенерацией сохраняем рядом как `meeting.edited-<время>.md`;
- старые папки без манифеста получают его при миграции; существующие файлы
  миграция не переписывает и не удаляет — только добавляет недостающие;
- `version` манифеста — версия схемы. Миграции только вперёд (`MIGRATIONS`,
  `upgrade_manifest`), при чтении; манифест новее этой сборки (откат на старую
  версию Mostik) читается как есть, его версия и незнакомые ключи при записи
  сохраняются (`deep_merge`, `max` версий). Поле не удаляется в той же версии,
  где появилось его замещение.
"""
from __future__ import annotations

import datetime as _dt
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any, Callable, Iterable

SCHEMA = "mostik.meeting"
VERSION = 1
TRANSCRIPT_SCHEMA = "mostik.transcript"

MANIFEST = "manifest.json"
MEETING_MD = "meeting.md"
NOTES_MD = "notes.md"
TRANSCRIPT_JSON = "transcript.json"
TRANSCRIPT_MD = "transcript.md"
SUMMARY_MD = "summary.md"
NOTES_JSON = "notes.json"

RECORDING_STATES = ("recording", "complete", "recovered", "incomplete")
TRANSCRIPT_STATES = ("pending", "processing", "done", "failed", "missing")
AUDIO_RE = re.compile(r"^(mic|system)(\.\d+)?\.wav$")
SENSITIVE_LINE = re.compile(r"^sensitive:\s*(true|false|yes|no|on|off)\s*$", re.I | re.M)
DECISION_RE = re.compile(
    r"^\s*(решил[иа]?|решено|договорил[ии]сь|согласовал[иа]?|утвердил[иа]?|приняли решение|"
    r"decided|agreed|approved|we will go with)\b",
    re.I,
)
GROUP_LABEL = {"ru": "группа", "en": "group"}


# --- время -----------------------------------------------------------------------

def now_iso() -> str:
    return _dt.datetime.now().astimezone().isoformat(timespec="seconds")


def folder_date(folder: Path) -> _dt.datetime | None:
    """Начало встречи из имени папки `yyyy-MM-dd-HHmmss` (старое — `yyyy-MM-dd-HHmm`, бывает суффикс `-2`)."""
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2})-(\d{6}|\d{4})(?:-\d+)?", Path(folder).name)
    if not match:
        return None
    pattern = "%Y-%m-%d-%H%M%S" if len(match.group(2)) == 6 else "%Y-%m-%d-%H%M"
    try:
        return _dt.datetime.strptime(f"{match.group(1)}-{match.group(2)}", pattern).astimezone()
    except ValueError:
        return None


def parse_iso(value: Any) -> _dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = _dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.astimezone()


# --- манифест --------------------------------------------------------------------

def manifest_path(folder: Path) -> Path:
    return Path(folder) / MANIFEST


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


# MIGRATIONS[n] переводит манифест версии n в n+1. Пока шагов нет: версия 1 — первая (выпуск 0.1.0).
MIGRATIONS: dict[int, Callable[[dict[str, Any]], dict[str, Any]]] = {}


def upgrade_manifest(data: dict[str, Any]) -> dict[str, Any]:
    """Довести манифест до `VERSION` шагами вперёд. Новее — без изменений: «миграций назад» нет."""
    try:
        version = int(data.get("version") or 1)
    except (TypeError, ValueError):
        version = 1
    if version >= VERSION:
        return data
    result = dict(data)
    while version < VERSION:
        step = MIGRATIONS.get(version)
        if step is None:
            raise RuntimeError(f"нет миграции манифеста встречи {version} → {version + 1}")
        result = step(result)
        version += 1
        result["version"] = version
    return result


def read_manifest(folder: Path) -> dict[str, Any] | None:
    data = read_json(manifest_path(folder))
    return upgrade_manifest(data) if isinstance(data, dict) else None


def write_json_atomic(path: Path, data: Any) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def deep_merge(base: dict[str, Any], patch: dict[str, Any]) -> dict[str, Any]:
    """Словари сливаются по ключам, всё остальное (списки, строки) заменяется целиком."""
    result = dict(base)
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def base_manifest(folder: Path) -> dict[str, Any]:
    started = folder_date(folder)
    return {
        "schema": SCHEMA,
        "version": VERSION,
        "id": folder.name,
        "title": None,
        "title_source": "default",
        "started": started.isoformat(timespec="seconds") if started else None,
        "ended": None,
        "duration_seconds": None,
        "language": None,
        "attendees": [],
        "calendar": None,
        "sensitive": False,
        "recording": {"status": "complete", "restarts": 0, "segments": [], "warnings": []},
        "transcript": {"status": "pending", "attempts": 0, "error": None},
        "summary": {"status": "none", "mode": None},
        "audio": {"kept": True, "trashed_at": None, "files": []},
        "files": {},
        "created_by": "mostik",
        "created_at": now_iso(),
        "updated_at": now_iso(),
    }


def update_manifest(folder: Path, patch: dict[str, Any]) -> dict[str, Any]:
    """Прочитать (или создать), слить `patch`, записать атомарно. Возвращает итог."""
    folder = Path(folder)
    current = read_manifest(folder) or base_manifest(folder)
    merged = deep_merge(current, patch)
    merged["schema"] = SCHEMA
    merged["version"] = max(VERSION, int(merged.get("version") or VERSION))
    merged["id"] = folder.name
    merged["files"] = present_files(folder)
    merged.setdefault("audio", {})["files"] = audio_files(folder)
    merged["updated_at"] = now_iso()
    write_json_atomic(manifest_path(folder), merged)
    return merged


def present_files(folder: Path) -> dict[str, str]:
    names = {
        "meeting_md": MEETING_MD, "notes_md": NOTES_MD, "transcript_json": TRANSCRIPT_JSON,
        "transcript_md": TRANSCRIPT_MD, "summary_md": SUMMARY_MD, "notes_json": NOTES_JSON,
    }
    return {key: name for key, name in names.items() if (folder / name).is_file()}


def audio_files(folder: Path) -> list[str]:
    try:
        return sorted(item.name for item in folder.iterdir() if AUDIO_RE.match(item.name))
    except OSError:
        return []


# --- чувствительность ------------------------------------------------------------

def front_matter(text: str) -> dict[str, Any]:
    """YAML-шапка между `---` в начале файла. PyYAML, если есть; иначе — простые `ключ: значение`."""
    match = re.match(r"^---\s*\n(.*?)\n---\s*(\n|$)", text, re.S)
    if not match:
        return {}
    block = match.group(1)
    try:
        import yaml  # type: ignore

        data = yaml.safe_load(block)
        return data if isinstance(data, dict) else {}
    except Exception:  # noqa: BLE001 — нет PyYAML или шапку правили руками
        result: dict[str, Any] = {}
        for line in block.splitlines():
            item = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
            if not item:
                continue
            raw = item.group(2).strip()
            if raw.lower() in ("true", "yes", "on"):
                result[item.group(1)] = True
            elif raw.lower() in ("false", "no", "off"):
                result[item.group(1)] = False
            elif raw.startswith('"'):
                try:
                    result[item.group(1)] = json.loads(raw)
                except ValueError:
                    result[item.group(1)] = raw.strip('"')
            else:
                result[item.group(1)] = raw or None
        return result


def is_sensitive(folder: Path) -> bool:
    """Встреча чувствительная: флаг в манифесте ИЛИ `sensitive: true` в шапке `meeting.md`."""
    folder = Path(folder)
    manifest = read_manifest(folder) or {}
    if bool(manifest.get("sensitive")):
        return True
    try:
        text = (folder / MEETING_MD).read_text(encoding="utf-8")
    except OSError:
        return False
    return front_matter(text).get("sensitive") is True


# --- YAML без зависимостей ---------------------------------------------------------

def _scalar(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return json.dumps(value)
    # Строка JSON — валидная двойная кавычка YAML: экранирование и юникод совпадают.
    return json.dumps(str(value), ensure_ascii=False)


def dump_yaml(data: dict[str, Any]) -> str:
    """Плоский словарь со списками строк и списками словарей скаляров — ровно то, что нужно шапке."""
    lines: list[str] = []
    for key, value in data.items():
        if isinstance(value, list):
            if not value:
                lines.append(f"{key}: []")
                continue
            lines.append(f"{key}:")
            for item in value:
                if isinstance(item, dict):
                    first = True
                    for sub_key, sub_value in item.items():
                        prefix = "  - " if first else "    "
                        lines.append(f"{prefix}{sub_key}: {_scalar(sub_value)}")
                        first = False
                else:
                    lines.append(f"  - {_scalar(item)}")
        else:
            lines.append(f"{key}: {_scalar(value)}")
    return "\n".join(lines)


# --- содержание meeting.md -------------------------------------------------------

def clock(seconds: Any) -> str:
    try:
        total = max(0, int(float(seconds)))
    except (TypeError, ValueError):
        total = 0
    hours, rest = divmod(total, 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes:02d}:{secs:02d}"


def best_mode(notes: Any) -> dict[str, Any] | None:
    """Последний удачный режим ИИ из `notes.json` (сначала `last_mode`, потом подробный)."""
    if not isinstance(notes, dict) or not isinstance(notes.get("modes"), dict):
        return None
    modes = notes["modes"]
    order = [notes.get("last_mode"), "detailed", "brief"]
    for name in order:
        mode = modes.get(name) if isinstance(name, str) else None
        if isinstance(mode, dict) and mode.get("status") in ("done", "partial"):
            return mode
    return None


def action_items(mode: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Задачи M7 → `action_items[{assignee, task, due}]`; «группа» — исполнитель-группа."""
    if not mode:
        return []
    language = "en" if mode.get("language") == "en" else "ru"
    items = []
    for task in mode.get("tasks") or []:
        if not isinstance(task, dict) or not str(task.get("text") or "").strip():
            continue
        assignee = task.get("assignee")
        if task.get("assignee_kind") == "group":
            assignee = GROUP_LABEL[language]
        items.append({
            "assignee": assignee or None,
            "task": " ".join(str(task["text"]).split()),
            "due": task.get("due") or None,
        })
    return items


def decisions(mode: dict[str, Any] | None) -> list[str]:
    """Решения: отдельный список модели, если есть; иначе пункты сводки, начинающиеся с «решили / договорились»."""
    if not mode:
        return []
    explicit = mode.get("decisions")
    if isinstance(explicit, list):
        return [" ".join(str(item.get("text") if isinstance(item, dict) else item).split())
                for item in explicit if item]
    result = []
    for point in mode.get("points") or []:
        text = " ".join(str(point.get("text") if isinstance(point, dict) else point or "").split())
        if text and DECISION_RE.search(text):
            result.append(text)
    return result


def attendee_names(manifest: dict[str, Any], transcript: dict[str, Any] | None) -> list[str]:
    names: list[str] = []
    for item in manifest.get("attendees") or []:
        name = item.get("name") if isinstance(item, dict) else item
        name = " ".join(str(name or "").split())
        if name and name not in names:
            names.append(name)
    if not names and transcript:
        for name in transcript.get("participants") or []:
            if name and name not in names:
                names.append(str(name))
    return names


def default_title(manifest: dict[str, Any], language: str = "ru") -> str:
    started = parse_iso(manifest.get("started"))
    word = "Meeting" if language == "en" else "Встреча"
    return f"{word} {started:%Y-%m-%d %H:%M}" if started else f"{word} {manifest.get('id') or ''}".strip()


def render_meeting_md(manifest: dict[str, Any], transcript: dict[str, Any] | None,
                      notes: dict[str, Any] | None) -> str:
    language = "en" if (manifest.get("language") == "en") else "ru"
    en = language == "en"
    mode = best_mode(notes)
    items = action_items(mode)
    decided = decisions(mode)
    title = manifest.get("title") or default_title(manifest, language)
    header = {
        "id": manifest.get("id"),
        "title": title,
        "started": manifest.get("started"),
        "ended": manifest.get("ended"),
        "duration_seconds": manifest.get("duration_seconds"),
        "attendees": attendee_names(manifest, transcript),
        "action_items": items,
        "decisions": decided,
        "sensitive": bool(manifest.get("sensitive")),
    }
    lines = ["---", dump_yaml(header), "---", "", f"# {title}", ""]
    started = parse_iso(manifest.get("started"))
    meta = []
    if started:
        meta.append(("Start" if en else "Начало") + f": {started:%Y-%m-%d %H:%M}")
    if manifest.get("duration_seconds"):
        meta.append(("Duration" if en else "Длительность") + f": {clock(manifest['duration_seconds'])}")
    if meta:
        lines.append("- " + " · ".join(meta))
    if header["attendees"]:
        lines.append(("- Attendees: " if en else "- Участники: ") + ", ".join(header["attendees"]))
    link = (manifest.get("calendar") or {}).get("link") if isinstance(manifest.get("calendar"), dict) else None
    if link:
        lines.append(("- Call link: " if en else "- Ссылка на звонок: ") + str(link))
    files = []
    if (transcript is not None):
        files.append(f"[{'transcript' if en else 'расшифровка'}]({TRANSCRIPT_MD})")
    files.append(f"[{'notes' if en else 'заметки'}]({NOTES_MD})")
    lines.append(("- Files: " if en else "- Файлы: ") + " · ".join(files))
    status = (manifest.get("recording") or {}).get("status")
    if status in ("recovered", "incomplete"):
        lines.append(("- Recording: " if en else "- Запись: ")
                     + {"recovered": ("recovered after a stall" if en else "восстановлена после сбоя"),
                        "incomplete": ("incomplete, part of the audio is missing" if en
                                       else "неполная, часть звука потеряна")}[status])
    lines.append("")
    if manifest.get("sensitive"):
        lines += [("> Marked sensitive: hooks, recipes, briefs and MCP do not get this meeting." if en else
                   "> Встреча помечена как чувствительная: её не получают хуки, рецепты, брифы и MCP."), ""]
    lines += [f"## {'Summary' if en else 'Сводка'}", ""]
    if mode:
        if mode.get("overview"):
            lines += [" ".join(str(mode["overview"]).split()), ""]
        for point in mode.get("points") or []:
            text = point.get("text") if isinstance(point, dict) else point
            if text:
                lines.append(f"- {' '.join(str(text).split())}")
        if mode.get("points"):
            lines.append("")
    elif transcript is None:
        lines += [("No transcript yet." if en else "Расшифровки пока нет."), ""]
    else:
        lines += [("No summary yet." if en else "Сводки пока нет."), ""]
    if decided:
        lines += [f"## {'Decisions' if en else 'Решения'}", ""] + [f"- {item}" for item in decided] + [""]
    if items:
        lines += [f"## {'Action items' if en else 'Поручения'}", ""]
        for item in items:
            who = item["assignee"] or ("not set" if en else "не указан")
            tail = f"; {'due' if en else 'срок'}: {item['due']}" if item["due"] else ""
            lines.append(f"- [ ] {item['task']} — {who}{tail}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _digest(text: str) -> str:
    """Отпечаток без строки `sensitive:`: её правит приложение, это не правка человека."""
    return hashlib.sha1(SENSITIVE_LINE.sub("", text).encode("utf-8")).hexdigest()


def write_meeting_md(folder: Path, manifest: dict[str, Any] | None = None) -> Path:
    """Перегенерировать `meeting.md`; правку человека сохранить рядом, его `sensitive: true` — уважать."""
    folder = Path(folder)
    manifest = manifest or read_manifest(folder) or base_manifest(folder)
    path = folder / MEETING_MD
    if path.is_file():
        old = path.read_text(encoding="utf-8")
        generated = (manifest.get("generated") or {}).get("meeting_md_sha1")
        edited = generated != _digest(old)
        if edited:
            stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
            backup = folder / f"meeting.edited-{stamp}.md"
            if not backup.exists():
                backup.write_text(old, encoding="utf-8")
        if edited and front_matter(old).get("sensitive") is True and not manifest.get("sensitive"):
            manifest = update_manifest(folder, {"sensitive": True})
    transcript = read_json(folder / TRANSCRIPT_JSON)
    notes = read_json(folder / NOTES_JSON)
    text = render_meeting_md(manifest, transcript if isinstance(transcript, dict) else None,
                             notes if isinstance(notes, dict) else None)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)
    update_manifest(folder, {"generated": {"meeting_md_sha1": _digest(text)}})
    return path


# --- notes.md ----------------------------------------------------------------------

MARKS_HEADING = {"ru": "## Пометки", "en": "## Marks"}


def render_notes_md(title: str, *, agenda: Iterable[str] = (), prep: str = "",
                    marks: Iterable[dict[str, Any]] = (), language: str = "ru") -> str:
    en = language == "en"
    lines = [f"# {'Notes' if en else 'Заметки'}: {title}", ""]
    agenda = [" ".join(str(item).split()) for item in agenda if str(item).strip()]
    if agenda:
        lines += [f"## {'Agenda' if en else 'Повестка'}", ""] + [f"- [ ] {item}" for item in agenda] + [""]
    if prep.strip():
        lines += [f"## {'Prep' if en else 'Подготовка'}", "", prep.strip(), ""]
    marks = list(marks)
    if marks:
        lines += [MARKS_HEADING[language], ""]
        lines += [f"- {clock(mark.get('at'))} — {' '.join(str(mark.get('text') or '').split())}" for mark in marks]
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def ensure_notes_md(folder: Path, title: str, *, agenda: Iterable[str] = (), prep: str = "",
                    marks: Iterable[dict[str, Any]] = (), language: str = "ru") -> Path:
    """Создать `notes.md`; если он уже есть (его пишет человек) — только дописать пометки, если их там нет."""
    folder = Path(folder)
    path = folder / NOTES_MD
    marks = [mark for mark in marks if str(mark.get("text") or "").strip()]
    # Та же блокировка, что у `meeting_store.append_note` (MCP дописывает заметки агента):
    # flock на самом файле, запись только дописыванием — без замены inode.
    with open(path, "a+", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            handle.seek(0)
            text = handle.read()
            if not text.strip():
                handle.write(render_notes_md(title, agenda=agenda, prep=prep, marks=marks, language=language))
            elif marks and MARKS_HEADING["ru"] not in text and MARKS_HEADING["en"] not in text:
                block = render_notes_md("", marks=marks, language=language).split("\n", 2)[2]
                handle.write(("" if text.endswith("\n\n") else "\n" if text.endswith("\n") else "\n\n") + block)
            handle.flush()
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
    return path


# --- после расшифровки и ИИ ------------------------------------------------------------

def after_transcript(folder: Path, payload: dict[str, Any], transcript: dict[str, Any]) -> dict[str, Any]:
    """Расшифровка готова: манифест, `notes.md` (пометки), `meeting.md`."""
    folder = Path(folder)
    patch: dict[str, Any] = {
        # `code` пишется всегда: `diarization_unavailable` — расшифровано без разделения по голосам,
        # повтор с fluidaudiocli код снимает.
        "transcript": {"status": "done", "error": None, "finished_at": now_iso(),
                       "code": (transcript.get("diarization") or {}).get("code")},
        "duration_seconds": transcript.get("duration_seconds"),
        "language": transcript.get("language"),
    }
    title = transcript.get("title")
    if title:
        patch["title"] = title
        patch["title_source"] = (read_manifest(folder) or {}).get("title_source") or "calendar"
        if patch["title_source"] == "default":
            patch["title_source"] = "calendar"
    attendees = payload.get("attendees")
    if attendees:
        patch["attendees"] = [
            {"name": item.get("name"), "self": bool(item.get("self"))} if isinstance(item, dict)
            else {"name": str(item), "self": False}
            for item in attendees if item
        ]
    for key in ("started", "ended", "calendar"):
        if payload.get(key):
            patch[key] = payload[key]
    if "sensitive" in payload:
        patch["sensitive"] = bool(payload["sensitive"])
    manifest = update_manifest(folder, patch)
    language = "en" if manifest.get("language") == "en" else "ru"
    ensure_notes_md(folder, manifest.get("title") or default_title(manifest, language),
                    agenda=payload.get("agenda") or [], marks=transcript.get("marks") or [], language=language)
    write_meeting_md(folder)
    return read_manifest(folder) or manifest


def transcript_failed(folder: Path, error: str, code: str | None = None) -> None:
    """Расшифровка упала; `code` (например, `diarization_memory`) приложение читает после перезапуска."""
    # `code` пишется всегда: слияние манифеста иначе оставило бы код прошлого сбоя.
    update_manifest(folder, {"transcript": {"status": "failed", "error": error[:500], "code": code or None,
                                            "finished_at": now_iso()}})


def transcript_started(folder: Path) -> dict[str, Any]:
    current = read_manifest(folder) or {}
    attempts = int((current.get("transcript") or {}).get("attempts") or 0) + 1
    return update_manifest(folder, {"transcript": {"status": "processing", "attempts": attempts, "code": None,
                                                   "started_at": now_iso()}})


def after_ai(folder: Path) -> None:
    """ИИ встречи записал `notes.json`: статус сводки в манифест и свежий `meeting.md`."""
    folder = Path(folder)
    notes = read_json(folder / NOTES_JSON)
    mode = best_mode(notes)
    status = mode.get("status") if mode else "failed"
    name = None
    if isinstance(notes, dict):
        name = notes.get("last_mode")
    update_manifest(folder, {"summary": {"status": status, "mode": name, "updated_at": now_iso()}})
    write_meeting_md(folder)


# --- миграция старых папок -----------------------------------------------------------

def looks_like_meeting(folder: Path) -> bool:
    if not folder.is_dir() or folder.name.startswith("."):
        return False
    return bool(audio_files(folder)) or (folder / TRANSCRIPT_JSON).is_file() or (folder / MANIFEST).is_file()


def wav_seconds(path: Path) -> float:
    try:
        size = path.stat().st_size
    except OSError:
        return 0.0
    # Рекордер пишет 16 кГц моно int16 с 44-байтным заголовком.
    return max(0, size - 44) / 32_000


def migrate_folder(folder: Path) -> bool:
    """Старая папка → контракт. Существующие файлы не трогаем; True — что-то добавили."""
    folder = Path(folder)
    if not looks_like_meeting(folder):
        return False
    changed = False
    manifest = read_manifest(folder)
    transcript = read_json(folder / TRANSCRIPT_JSON)
    transcript = transcript if isinstance(transcript, dict) else None
    if manifest is None:
        patch: dict[str, Any] = {"created_by": "migration", "migrated_at": now_iso()}
        if transcript:
            patch["transcript"] = {"status": "done", "attempts": 1, "error": None}
            patch["title"] = transcript.get("title") or None
            patch["title_source"] = "calendar" if transcript.get("title") else "default"
            patch["language"] = transcript.get("language")
            patch["duration_seconds"] = transcript.get("duration_seconds")
            patch["attendees"] = [{"name": str(name), "self": False} for name in transcript.get("attendees") or []]
            if not folder_date(folder) and transcript.get("date"):
                started = parse_iso(transcript.get("date"))
                patch["started"] = started.isoformat(timespec="seconds") if started else None
        else:
            # Старую нерасшифрованную встречу сами при запуске не гоняем: только по кнопке.
            patch["transcript"] = {"status": "missing", "attempts": 0, "error": None}
            seconds = max([wav_seconds(folder / name) for name in audio_files(folder)] or [0.0])
            patch["duration_seconds"] = round(seconds, 2) if seconds else None
        notes = read_json(folder / NOTES_JSON)
        mode = best_mode(notes)
        if mode:
            patch["summary"] = {"status": mode.get("status"), "mode": (notes or {}).get("last_mode")}
        manifest = update_manifest(folder, patch)
        changed = True
    if not (folder / MEETING_MD).is_file():
        write_meeting_md(folder, manifest)
        changed = True
    if transcript and transcript.get("marks") and not (folder / NOTES_MD).is_file():
        language = "en" if manifest.get("language") == "en" else "ru"
        ensure_notes_md(folder, manifest.get("title") or default_title(manifest, language),
                        marks=transcript.get("marks") or [], language=language)
        update_manifest(folder, {})
        changed = True
    return changed


def migrate_all(root: Path) -> dict[str, int]:
    root = Path(root).expanduser()
    stats = {"scanned": 0, "migrated": 0, "errors": 0}
    try:
        folders = sorted(item for item in root.iterdir() if item.is_dir())
    except OSError:
        return stats
    for folder in folders:
        if not looks_like_meeting(folder):
            continue
        stats["scanned"] += 1
        try:
            if migrate_folder(folder):
                stats["migrated"] += 1
        except OSError:
            stats["errors"] += 1
    return stats


def list_meetings(root: Path, *, include_sensitive: bool = False) -> list[dict[str, Any]]:
    """Манифесты встреч, новые первыми. Чувствительные — только по явному `include_sensitive`."""
    result = []
    root = Path(root).expanduser()
    try:
        folders = sorted((item for item in root.iterdir() if item.is_dir()), key=lambda p: p.name, reverse=True)
    except OSError:
        return result
    for folder in folders:
        manifest = read_manifest(folder)
        if manifest is None:
            continue
        sensitive = is_sensitive(folder)
        if sensitive and not include_sensitive:
            continue
        result.append({**manifest, "sensitive": sensitive, "path": str(folder)})
    return result
