"""Архив встреч без векторов: карточки, люди, брифы, серии, сводки, темы.

M18 — карточка встречи (`card.md` в папке встречи): решения, открытые вопросы,
люди, цитаты со ссылками `<id>/transcript.md:<строка>`, версия правил в шапке.

W1 — бриф перед встречей: 2–3 пункта по прошлым встречам с теми же людьми и серией.
W3 — карточка человека `<MOSTIK_HOME>/people/<имя>.md`.
W4 — сроки поручений датой (`due_dates`) и контроль по серии: «в прошлый раз
Х обещал Y — сделано?».
W5 — область: человек или клиент, серия, период, список встреч (`Scope`).
W6 — сводка за неделю и по серии (`<MOSTIK_HOME>/digests/`).
W12 — где упоминались свои слова-триггеры.

Всё локально и детерминированно: модели здесь нет. Встречи читаются только
через `meeting_store`. Чувствительные встречи (`meeting_folder.is_sensitive`) не
попадают в брифы, карточки людей, сводки и ответы агентам; `include_sensitive`
есть только у поиска тем — это собственный просмотр пользователя в приложении.

Функции без `write_` в имени ничего не пишут: их зовут CLI и MCP (G3).
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from . import meeting_store as store
from . import paths, task_state
from .textnorm import normalize, query_terms, tokens

CARD_FILE = "card.md"
CARD_VERSION = 1
# Версия правил извлечения карточки. Карточка с другой версией считается устаревшей
# и перестраивается; когда карточку начнёт собирать модель — «llm-<n>» с версией промпта.
CARD_PROMPT_VERSION = "rules-1"
ME = "Я"
BRIEF_POINTS = 3
BRIEF_LOOKBACK = 10
_LABEL = re.compile(r"^(собеседник|speaker|говорящий)\s*\d*$", re.I)
_DEFAULT_TITLE = re.compile(r"^(встреча|meeting)\s+[\d.\-: ]+$", re.I)
_GROUP = frozenset({"группа", "group", "все", "мы", "команда", "team"})
_UNRESOLVED = re.compile(
    r"\b(не знаю|уточню|уточнить|вернусь|вернёмся|вернемся|позже|подумаем|подумаю|не уверен|выясню|"
    r"обсудим потом|later|not sure|i'?ll check|let me check|get back|tbd|follow up)\b", re.I)


# --- общее -------------------------------------------------------------------------

def person_key(name: Any) -> str:
    return " ".join(str(name or "").replace("ё", "е").replace("Ё", "Е").casefold().split())


def _clean(value: Any) -> str:
    return " ".join(str(value or "").split())


def _parse(value: Any) -> _dt.datetime | None:
    if isinstance(value, _dt.datetime):
        return value if value.tzinfo else value.astimezone()
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        moment = _dt.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo else moment.astimezone()


def _now(now: _dt.datetime | None = None) -> _dt.datetime:
    return (now or _dt.datetime.now()).astimezone()


def _date_label(value: Any, language: str = "ru") -> str:
    moment = _parse(value)
    if not moment:
        return ""
    return f"{moment:%d.%m}" if language != "en" else f"{moment:%b %d}"


def default_title(title: str) -> bool:
    return bool(_DEFAULT_TITLE.match(_clean(title)))


def records(root: Path | None = None, *, include_sensitive: bool = False) -> list[store.MeetingRecord]:
    """Встречи, новые первыми. Чувствительные — только по явному флагу (собственный просмотр в приложении)."""
    if not include_sensitive:
        return store.list_meetings(root)
    root = root or store.meetings_root()
    try:
        folders = sorted((item for item in root.iterdir() if store._is_meeting(item)), key=lambda p: p.name,
                         reverse=True)
    except OSError:
        return []
    return [store.load(folder) for folder in folders]


def self_names(items: Iterable[store.MeetingRecord]) -> set[str]:
    """Как зовут самого пользователя: «Я» и участники с `self: true` из манифестов."""
    names = {person_key(ME), "me"}
    for record in items:
        for attendee in record.manifest.get("attendees") or []:
            if isinstance(attendee, dict) and attendee.get("self") and attendee.get("name"):
                names.add(person_key(attendee["name"]))
    return names


def people_of(record: store.MeetingRecord, selves: set[str]) -> list[str]:
    """Собеседники встречи: участники из календаря и названные говорящие, без себя и безымянных меток."""
    found: dict[str, str] = {}
    for name in [*record.attendees, *record.participants]:
        name = _clean(name)
        key = person_key(name)
        if not key or key in selves or key in _GROUP or _LABEL.match(name):
            continue
        found.setdefault(key, name)
    return list(found.values())


def series_id(event_id: Any) -> str | None:
    """Серия по событию календаря: `<внешний id>@<начало>` → `cal:<внешний id>` (одинаков у повторов)."""
    raw = _clean(event_id)
    if not raw:
        return None
    return "cal:" + re.sub(r"@\d+$", "", raw)


def _title_key(title: str) -> str | None:
    title = _clean(title)
    if not title or default_title(title):
        return None
    return "title:" + person_key(title)


def series_map(items: list[store.MeetingRecord]) -> dict[str, str]:
    """ID встречи → ключ серии. Календарная серия главнее; без календаря — одинаковое название (≥2 встреч)."""
    result: dict[str, str] = {}
    by_title: dict[str, list[str]] = {}
    title_to_cal: dict[str, str] = {}
    for record in items:
        calendar = record.manifest.get("calendar") if isinstance(record.manifest.get("calendar"), dict) else {}
        key = series_id(calendar.get("event_id"))
        title = _title_key(record.title)
        if key:
            result[record.id] = key
            if title:
                title_to_cal.setdefault(title, key)
        elif title:
            by_title.setdefault(title, []).append(record.id)
    for title, ids in by_title.items():
        if title in title_to_cal:
            for meeting_id in ids:
                result[meeting_id] = title_to_cal[title]
        elif len(ids) >= 2:
            for meeting_id in ids:
                result[meeting_id] = title
    return result


@dataclass
class Meeting:
    """Встреча архива: запись хранилища плюс то, что архив выводит сам."""

    record: store.MeetingRecord
    started: _dt.datetime | None
    people: list[str]
    series: str | None
    tasks: list[dict[str, Any]] = field(default_factory=list)

    @property
    def id(self) -> str:
        return self.record.id

    @property
    def title(self) -> str:
        return self.record.title

    def ref(self) -> dict[str, Any]:
        return {"id": self.id, "title": self.title, "date": self.record.date, "series": self.series}


def archive(root: Path | None = None, *, include_sensitive: bool = False) -> list[Meeting]:
    items = records(root, include_sensitive=include_sensitive)
    selves = self_names(records(root, include_sensitive=True) if not include_sensitive else items)
    series = series_map(items)
    states = task_state.load()
    result = []
    for record in items:
        result.append(Meeting(record=record, started=_parse(record.date), people=people_of(record, selves),
                              series=series.get(record.id), tasks=store.actions(record, states)))
    return result


# --- область (W5) --------------------------------------------------------------------

PERIODS = {"day": 1, "week": 7, "month": 31, "quarter": 92, "year": 366}


@dataclass
class Scope:
    """Область вопроса: с кем, какая серия, за какой срок, какие встречи. Пустая — весь архив."""

    who: str | None = None
    series: str | None = None
    days: float | None = None
    since: _dt.datetime | None = None
    until: _dt.datetime | None = None
    meetings: list[str] | None = None
    project: str | None = None

    @classmethod
    def from_payload(cls, payload: Any) -> "Scope":
        data = payload if isinstance(payload, dict) else {}
        days = data.get("days")
        period = data.get("period")
        if days in (None, "") and isinstance(period, str):
            days = PERIODS.get(period)
        try:
            days = float(days) if days not in (None, "") else None
        except (TypeError, ValueError):
            raise ValueError(f"days: ожидалось число, пришло {days!r}") from None
        meetings = data.get("meetings")
        return cls(who=_clean(data.get("who") or data.get("person")) or None,
                   series=_clean(data.get("series")) or None, days=days,
                   since=_parse(data.get("since")), until=_parse(data.get("until")),
                   meetings=[str(item) for item in meetings] if isinstance(meetings, list) else None,
                   project=_clean(data.get("project")) or None)

    def empty(self) -> bool:
        return not any((self.who, self.series, self.days, self.since, self.until, self.meetings))

    def describe(self, language: str = "ru") -> str:
        en = language == "en"
        parts = []
        if self.who:
            parts.append((f"with {self.who}" if en else f"с «{self.who}»"))
        if self.series:
            parts.append("this series" if en else "эта серия")
        if self.days:
            parts.append(f"last {int(self.days)} days" if en else f"за {int(self.days)} дн.")
        if self.meetings:
            parts.append(f"{len(self.meetings)} meetings" if en else f"встреч: {len(self.meetings)}")
        if self.project:
            parts.append("project folder" if en else "папка проекта")
        return ", ".join(parts)


def select(items: list[Meeting], scope: Scope, now: _dt.datetime | None = None) -> list[Meeting]:
    now = _now(now)
    since = scope.since or (now - _dt.timedelta(days=scope.days) if scope.days else None)
    wanted = person_key(scope.who) if scope.who else ""
    chosen = []
    for meeting in items:
        if scope.meetings is not None and meeting.id not in scope.meetings:
            continue
        if scope.series and meeting.series != scope.series:
            continue
        if since and (meeting.started is None or meeting.started < since):
            continue
        if scope.until and (meeting.started is None or meeting.started > scope.until):
            continue
        if wanted:
            haystack = [person_key(name) for name in meeting.people] + [person_key(meeting.title)]
            if not any(wanted in value for value in haystack):
                continue
        chosen.append(meeting)
    return chosen


# --- строки transcript.md -------------------------------------------------------------

def transcript_lines(folder: Path) -> dict[int, int]:
    """Номер реплики → строка `transcript.md` (1-based). Реплика — строка `**говорящий** [время] текст`."""
    try:
        lines = (folder / "transcript.md").read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    mapping: dict[int, int] = {}
    turn = 0
    for number, line in enumerate(lines, 1):
        if line.startswith("**"):
            mapping[turn] = number
            turn += 1
    return mapping


def turn_ref(meeting_id: str, turn: int, lines: dict[int, int]) -> str | None:
    line = lines.get(turn)
    return f"{meeting_id}/transcript.md:{line}" if line else None


# --- карточка встречи (M18) ---------------------------------------------------------------

def _source_digest(folder: Path) -> str:
    digest = hashlib.sha1()
    for name in ("transcript.json", "notes.json", "meeting.md", "manifest.json"):
        try:
            stat = (folder / name).stat()
        except OSError:
            continue
        digest.update(f"{name}:{stat.st_size}:{int(stat.st_mtime)}".encode())
    digest.update(f"{CARD_VERSION}:{CARD_PROMPT_VERSION}".encode())
    return digest.hexdigest()[:16]


def _best_turn(text: str, turns: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Реплика, сильнее всего совпадающая по основам с пунктом (≥2 общих основы)."""
    wanted = set(query_terms(text))
    if len(wanted) < 2:
        return None
    best: tuple[int, dict[str, Any]] | None = None
    for turn in turns:
        score = len(wanted & set(normalize(turn["text"]).split()))
        if score >= 2 and (best is None or score > best[0]):
            best = (score, turn)
    return best[1] if best else None


def _quote(text: str, limit: int = 220) -> str:
    text = _clean(text)
    if len(text) <= limit:
        return text
    return text[:limit].rsplit(" ", 1)[0].rstrip(",;:—-") + "…"


def _open_questions(turns: list[dict[str, Any]], mode: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Открытые вопросы: из ИИ встречи, если он их дал; иначе вопрос без ответа по правилам.

    Вопрос (≥4 слов, на «?») считается открытым, если в двух следующих репликах есть
    «не знаю / уточню / вернёмся / позже», или если он прозвучал в последней пятой части встречи.
    """
    given = (mode or {}).get("open_questions") or (mode or {}).get("questions")
    if isinstance(given, list) and given:
        result = []
        for item in given:
            text = _clean(item.get("text") if isinstance(item, dict) else item)
            refs = item.get("refs") if isinstance(item, dict) else None
            if text:
                result.append({"text": text, "turn": refs[0] if isinstance(refs, list) and refs
                               and isinstance(refs[0], int) else None, "speaker": None, "source": "ai"})
        return result[:5]
    result = []
    tail = max(0, int(len(turns) * 0.8))
    for index, turn in enumerate(turns):
        text = turn["text"]
        if not text.rstrip().endswith("?") or len(text.split()) < 4:
            continue
        following = " ".join(item["text"] for item in turns[index + 1:index + 3])
        if _UNRESOLVED.search(following) or index >= tail:
            result.append({"text": text, "turn": turn["n"], "speaker": turn["speaker"], "source": "rules"})
    return result[-5:]


def meeting_card(record: store.MeetingRecord) -> dict[str, Any]:
    """Карточка встречи: решения, открытые вопросы, люди, цитаты; у каждого пункта — `путь:строка`."""
    folder = record.folder
    turns = store.turns(record)
    by_n = {turn["n"]: turn for turn in turns}
    lines = transcript_lines(folder)
    summary = store.summary(record) or {}
    _name, mode = store._best_mode(record)
    selves = self_names([record])

    def ref_for(turn_no: int | None) -> str | None:
        return turn_ref(record.id, turn_no, lines) if turn_no is not None else None

    decisions = []
    for text in summary.get("decisions") or []:
        turn = _best_turn(text, turns)
        decisions.append({"text": text, "ref": ref_for(turn["n"]) if turn else None})

    tasks = []
    raw_tasks = {person_key(item.get("text")): item for item in (mode or {}).get("tasks") or [] if isinstance(item, dict)}
    for task in store.actions(record):
        refs = task["refs"] or [ref for ref in (raw_tasks.get(person_key(task["task"])) or {}).get("refs") or []
                                if isinstance(ref, int)]
        turn_no = refs[0] if refs else ((_best_turn(task["task"], turns) or {}).get("n"))
        tasks.append({**task, "ref": ref_for(turn_no)})

    questions = [{**item, "ref": ref_for(item["turn"])} for item in _open_questions(turns, mode)]

    counts: dict[str, int] = {}
    for turn in turns:
        if turn["speaker"]:
            counts[turn["speaker"]] = counts.get(turn["speaker"], 0) + 1
    people = [{"name": name, "turns": counts.get(name, 0), "self": person_key(name) in selves}
              for name in dict.fromkeys([*record.attendees, *counts])]

    quotes: list[dict[str, Any]] = []
    seen: set[int] = set()
    for item in [*decisions, *tasks]:
        ref = item.get("ref")
        if not ref:
            continue
        line = int(ref.rsplit(":", 1)[1])
        turn_no = next((n for n, value in lines.items() if value == line), None)
        if turn_no is None or turn_no in seen or turn_no not in by_n:
            continue
        seen.add(turn_no)
        quotes.append({"speaker": by_n[turn_no]["speaker"], "text": _quote(by_n[turn_no]["text"]), "ref": ref,
                       "at": by_n[turn_no]["start"]})
    return {
        "id": record.id, "title": record.title, "date": record.date,
        "card_version": CARD_VERSION, "prompt_version": CARD_PROMPT_VERSION,
        "source_digest": _source_digest(folder),
        "overview": summary.get("overview") or "",
        "decisions": decisions, "open_questions": questions, "tasks": tasks, "people": people,
        "quotes": quotes[:6],
    }


def render_card_md(card: dict[str, Any]) -> str:
    def ref(value: str | None) -> str:
        return f" ([{value}])" if value else ""

    header = {
        "id": card["id"], "title": card["title"], "date": card["date"], "card_version": card["card_version"],
        "prompt_version": card["prompt_version"], "source_digest": card["source_digest"],
    }
    lines = ["---", *[f"{key}: {json.dumps(value, ensure_ascii=False)}" for key, value in header.items()], "---", "",
             f"# Карточка: {card['title']}", ""]
    if card["overview"]:
        lines += [card["overview"], ""]
    sections = [
        ("Решения", [f"- {item['text']}{ref(item['ref'])}" for item in card["decisions"]]),
        ("Открытые вопросы", [f"- {item['text']}" + (f" — {item['speaker']}" if item.get("speaker") else "")
                              + ref(item["ref"]) for item in card["open_questions"]]),
        ("Поручения", [f"- [{'x' if not item['open'] else ' '}] {item['task']} — {item['assignee'] or 'не указан'}"
                       + (f"; срок: {item['due']}" + (f" ({item['due_date']})" if item.get("due_date") else "")
                          if item["due"] else "") + ref(item["ref"]) for item in card["tasks"]]),
        ("Люди", [f"- {item['name']}" + (" (вы)" if item["self"] else "")
                  + (f" — реплик: {item['turns']}" if item["turns"] else "") for item in card["people"]]),
        ("Цитаты", [f"- {item['speaker'] or '—'}: «{item['text']}»{ref(item['ref'])}" for item in card["quotes"]]),
    ]
    for title, body in sections:
        if body:
            lines += [f"## {title}", "", *body, ""]
    return "\n".join(lines).rstrip() + "\n"


def card_header(folder: Path) -> dict[str, Any]:
    from .meeting_folder import front_matter

    try:
        return front_matter((folder / CARD_FILE).read_text(encoding="utf-8"))
    except OSError:
        return {}


def card_stale(folder: Path) -> bool:
    header = card_header(folder)
    return (header.get("prompt_version") != CARD_PROMPT_VERSION or header.get("card_version") != CARD_VERSION
            or header.get("source_digest") != _source_digest(folder))


def write_card(folder: Path, *, force: bool = False) -> Path | None:
    """`card.md` в папке встречи; чувствительной встрече карточку не строим. None — не нужно или нельзя."""
    from .meeting_folder import is_sensitive

    folder = Path(folder)
    if is_sensitive(folder) or not (folder / "transcript.json").is_file():
        return None
    if not force and not card_stale(folder):
        return folder / CARD_FILE
    text = render_card_md(meeting_card(store.load(folder, with_transcript=True)))
    path = folder / CARD_FILE
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)
    return path


def write_cards(root: Path | None = None, *, force: bool = False) -> dict[str, int]:
    stats = {"written": 0, "fresh": 0, "skipped": 0}
    for record in records(root):
        before = card_stale(record.folder)
        path = write_card(record.folder, force=force)
        if path is None:
            stats["skipped"] += 1
        elif before or force:
            stats["written"] += 1
        else:
            stats["fresh"] += 1
    return stats


# --- поручения и серии (W4) ------------------------------------------------------------

def _is_me(name: Any, selves: set[str]) -> bool:
    return person_key(name) in selves


def task_view(meeting: Meeting, task: dict[str, Any], today: _dt.date) -> dict[str, Any]:
    due = task.get("due_date")
    overdue = bool(task["open"] and due and due < today.isoformat())
    return {**task, "meeting_id": meeting.id, "meeting_title": meeting.title, "meeting_date": meeting.record.date,
            "overdue": overdue}


def followup_text(task: dict[str, Any], selves: set[str], language: str = "ru") -> str:
    """«В прошлый раз Иван обещал «смета» — сделано?»; для себя — «вы обещали»."""
    en = language == "en"
    who = task.get("assignee")
    due = task.get("due_date")
    tail = ""
    if due:
        moment = _dt.date.fromisoformat(due)
        tail = (f" (due {moment:%b %d}" if en else f" (срок {moment:%d.%m}") + \
               ((", overdue" if en else ", просрочено") if task.get("overdue") else "") + ")"
    if not who or person_key(who) in _GROUP:
        lead = "Last time the team agreed to" if en else "В прошлый раз договорились"
        return f"{lead}: «{task['task']}»{tail} — {'done' if en else 'сделано'}?"
    if _is_me(who, selves):
        return (f"Last time you promised: «{task['task']}»{tail} — done?" if en
                else f"В прошлый раз вы обещали: «{task['task']}»{tail} — сделано?")
    return (f"Last time {who} promised: «{task['task']}»{tail} — done?" if en
            else f"В прошлый раз {who} обещал(а): «{task['task']}»{tail} — сделано?")


# --- бриф (W1) ------------------------------------------------------------------------

def _event_people(event: dict[str, Any], selves: set[str]) -> list[str]:
    result = []
    for item in event.get("attendees") or []:
        name = _clean(item.get("name") if isinstance(item, dict) else item)
        if name and person_key(name) not in selves and name not in result:
            result.append(name)
    return result


def related_meetings(items: list[Meeting], event: dict[str, Any], selves: set[str]) -> list[Meeting]:
    start = _parse(event.get("start")) or _now()
    series = series_id(event.get("id"))
    people = {person_key(name) for name in _event_people(event, selves)}
    title = _title_key(event.get("title") or "")
    result = []
    for meeting in items:
        if meeting.started and meeting.started >= start - _dt.timedelta(minutes=5):
            continue
        same_series = bool(series and meeting.series == series) or bool(title and _title_key(meeting.title) == title)
        shared = people & {person_key(name) for name in meeting.people}
        if same_series or shared:
            result.append(meeting)
    return result[:BRIEF_LOOKBACK]


def brief(event: dict[str, Any], *, root: Path | None = None, now: _dt.datetime | None = None,
          language: str = "ru") -> dict[str, Any]:
    """Бриф к событию: на чём остановились, открытые обещания, о чём договорились. До трёх пунктов.

    Только локальный архив и календарь; чувствительные встречи не участвуют.
    """
    en = language == "en"
    items = archive(root)
    selves = self_names(records(root, include_sensitive=True))
    today = _now(now).date()
    related = related_meetings(items, event, selves)
    people = _event_people(event, selves)
    keys = {person_key(name) for name in people}
    series = series_id(event.get("id"))
    points: list[dict[str, Any]] = []
    followups: list[dict[str, Any]] = []
    if related:
        last = related[0]
        summary = store.summary(last.record) or {}
        gist = _clean(summary.get("overview")) or next(
            (_clean(p.get("text") if isinstance(p, dict) else p) for p in summary.get("points") or []), "")
        when = _date_label(last.record.date, language)
        lead = (f"Last time ({when}, «{last.title}»)" if en else f"В прошлый раз ({when}, «{last.title}»)")
        if gist:
            points.append({"kind": "last", "text": f"{lead}: {_quote(gist, 260)}", "meeting": last.id})
        elif summary.get("decisions"):
            points.append({"kind": "last", "text": f"{lead}: {summary['decisions'][0]}", "meeting": last.id})
        else:
            points.append({"kind": "last", "text": lead + (": no summary yet." if en else ": сводки нет."),
                           "meeting": last.id})
        # Открытые обещания: серия целиком, а вне серии — только те, где исполнитель из участников или вы.
        for meeting in related:
            in_series = bool(series and meeting.series == series)
            for task in meeting.tasks:
                if not task["open"]:
                    continue
                who = person_key(task.get("assignee"))
                if in_series or who in keys or who in selves or (who in _GROUP and meeting is last):
                    followups.append(task_view(meeting, task, today))
        followups.sort(key=lambda task: (not task["overdue"], task.get("due_date") or "9999"))
        if followups:
            shown = followups[:3]
            text = "; ".join(followup_text(task, selves, language) for task in shown)
            more = len(followups) - len(shown)
            if more > 0:
                text += f" (+{more})"
            points.append({"kind": "promises", "text": text,
                           "tasks": [{"meeting": t["meeting_id"], "key": t["key"]} for t in shown]})
        decided = list(summary.get("decisions") or [])
        if decided:
            points.append({"kind": "decisions",
                           "text": ("Agreed: " if en else "Договорились: ") + "; ".join(decided[:2]),
                           "meeting": last.id})
    title = _clean(event.get("title")) or ("meeting" if en else "встреча")
    lines = [f"Brief: {title}" if en else f"Бриф: {title}"] + [f"- {point['text']}" for point in points[:BRIEF_POINTS]]
    return {
        "event": {"id": event.get("id"), "title": title, "start": event.get("start"), "attendees": people},
        "series": series if series and any(m.series == series for m in related) else None,
        "related": [meeting.ref() for meeting in related],
        "points": points[:BRIEF_POINTS],
        "followups": followups,
        "text": "\n".join(lines) if points else "",
    }


def next_event(*, now: _dt.datetime | None = None, within_minutes: float = 60 * 24,
               event_id: str | None = None) -> dict[str, Any] | None:
    """Событие из `calendar.json`: по id или ближайшее ещё не начавшееся в пределах `within_minutes`."""
    from . import calendar_terms

    now = _now(now)
    best: tuple[_dt.datetime, dict[str, Any]] | None = None
    for event in calendar_terms.load():
        if event_id:
            if str(event.get("id")) == event_id:
                return event
            continue
        start = _parse(event.get("start"))
        if start is None or start < now or start > now + _dt.timedelta(minutes=within_minutes):
            continue
        if best is None or start < best[0]:
            best = (start, event)
    return best[1] if best else None


def write_brief(data: dict[str, Any]) -> Path | None:
    """`<MOSTIK_HOME>/briefs/<дата>-<id>.md`; пустой бриф не пишем."""
    if not data.get("text"):
        return None
    start = _parse(data["event"].get("start")) or _now()
    slug = re.sub(r"[^0-9A-Za-zА-Яа-яЁё_-]+", "-", _clean(data["event"].get("title")))[:40].strip("-") or "meeting"
    folder = paths.mostik_home() / "briefs"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{start:%Y-%m-%d-%H%M}-{slug}.md"
    path.write_text(data["text"] + "\n", encoding="utf-8")
    return path


# --- люди (W3) ----------------------------------------------------------------------------

PEOPLE_DIR = "people"
MY_NOTES = "## Мои заметки"


def people_dir() -> Path:
    return paths.mostik_home() / PEOPLE_DIR


def file_name(name: str) -> str:
    safe = re.sub(r"[\\/:*?\"<>|\x00-\x1f]+", " ", _clean(name)).strip(" .")
    return (safe[:80] or "без имени") + ".md"


def _voice_people() -> dict[str, dict[str, Any]]:
    """Люди голосовой памяти (M14) по имени — только имена и число образцов, без векторов."""
    try:
        from .voices import VoiceStore

        return {person_key(item["name"]): item for item in VoiceStore().people()}
    except Exception:  # noqa: BLE001 — нет памяти голосов: карточки людей работают без неё
        return {}


def people(root: Path | None = None) -> list[dict[str, Any]]:
    """Все собеседники архива: имя, число встреч, последняя встреча, открытые обещания."""
    items = archive(root)
    index: dict[str, dict[str, Any]] = {}
    for meeting in items:
        for name in meeting.people:
            entry = index.setdefault(person_key(name), {"name": name, "meetings": 0, "last": None, "open": 0})
            entry["meetings"] += 1
            if entry["last"] is None:
                entry["last"] = meeting.ref()
            entry["open"] += sum(1 for task in meeting.tasks
                                 if task["open"] and person_key(task.get("assignee")) == person_key(name))
    voices = _voice_people()
    result = []
    for key, entry in index.items():
        entry["voice"] = key in voices
        entry["file"] = file_name(entry["name"])
        result.append(entry)
    result.sort(key=lambda item: (-(item["meetings"]), item["name"].casefold()))
    return result


def person(name: str, *, root: Path | None = None, now: _dt.datetime | None = None) -> dict[str, Any] | None:
    """Карточка человека: все встречи, его открытые обещания, ваши обещания ему, последний разговор."""
    from . import calendar_terms

    key = person_key(name)
    if not key:
        return None
    items = archive(root)
    selves = self_names(records(root, include_sensitive=True))
    today = _now(now).date()
    meetings = [meeting for meeting in items if key in {person_key(n) for n in meeting.people}]
    if not meetings:
        return None
    display = next(n for n in meetings[0].people if person_key(n) == key)
    promises, mine = [], []
    for meeting in meetings:
        for task in meeting.tasks:
            if not task["open"]:
                continue
            who = person_key(task.get("assignee"))
            if who == key:
                promises.append(task_view(meeting, task, today))
            elif who in selves:
                mine.append(task_view(meeting, task, today))
    last = meetings[0]
    summary = store.summary(last.record) or {}
    upcoming = []
    now_dt = _now(now)
    for event in calendar_terms.load():
        start = _parse(event.get("start"))
        if start and start >= now_dt and key in {person_key(a) for a in event.get("attendees") or []}:
            upcoming.append({"id": event.get("id"), "title": event.get("title"), "start": event.get("start")})
    upcoming.sort(key=lambda item: item["start"] or "")
    voice = _voice_people().get(key)
    return {
        "name": display,
        "meetings": [meeting.ref() for meeting in meetings],
        "promises": promises,
        "my_promises": mine,
        "last": {**last.ref(), "overview": _clean(summary.get("overview")),
                 "points": [_clean(p.get("text") if isinstance(p, dict) else p) for p in summary.get("points") or []][:5],
                 "decisions": summary.get("decisions") or []},
        "upcoming": upcoming[:5],
        "voice": {"id": voice["id"], "samples": voice["samples"]} if voice else None,
    }


def render_person_md(card: dict[str, Any], notes: str = "") -> str:
    def task_line(task: dict[str, Any]) -> str:
        due = f"; срок: {task['due']}" if task.get("due") else ""
        if task.get("due_date"):
            due += f" ({task['due_date']}{', просрочено' if task.get('overdue') else ''})"
        return f"- [ ] {task['task']}{due} — встреча `{task['meeting_id']}`"

    last = card["last"]
    lines = [
        "---", f"name: {json.dumps(card['name'], ensure_ascii=False)}", f"meetings: {len(card['meetings'])}",
        f"voice_memory: {'true' if card.get('voice') else 'false'}", "generated_by: mostik", "---", "",
        f"# {card['name']}", "",
        "> Файл собирает Mostik из встреч. Своё пишите в разделе «Мои заметки» — он сохраняется.", "",
        "## О чём говорили в последний раз", "",
        f"«{last['title']}», {_date_label(last['date'])} — встреча `{last['id']}`",
    ]
    if last["overview"]:
        lines += ["", last["overview"]]
    for point in last["points"]:
        lines.append(f"- {point}")
    if last["decisions"]:
        lines += ["", "Решения:"] + [f"- {item}" for item in last["decisions"]]
    lines += ["", "## Обещания", ""]
    lines += [task_line(task) for task in card["promises"]] or ["Открытых нет."]
    if card["my_promises"]:
        lines += ["", "## Ваши обещания на встречах с ним", ""] + [task_line(task) for task in card["my_promises"]]
    if card["upcoming"]:
        lines += ["", "## Ближайшие встречи в календаре", ""]
        lines += [f"- {item['title']} — {_date_label(item['start'])}" for item in card["upcoming"]]
    lines += ["", "## Все встречи", ""]
    lines += [f"- {_date_label(m['date'])} «{m['title']}» — `{m['id']}`" for m in card["meetings"]]
    if card.get("voice"):
        lines += ["", f"Голос узнаётся (образцов: {card['voice']['samples']})."]
    lines += ["", MY_NOTES, "", notes.strip()] if notes.strip() else ["", MY_NOTES, ""]
    return "\n".join(lines).rstrip() + "\n"


def _my_notes(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return ""
    position = text.find(MY_NOTES)
    return text[position + len(MY_NOTES):].strip() if position >= 0 else ""


def write_people(root: Path | None = None, *, now: _dt.datetime | None = None) -> dict[str, Any]:
    """Перестроить `people/<имя>.md`. Файл человека, которого в видимом архиве больше нет
    (встреча стала чувствительной), переписывается заглушкой — содержимое не остаётся."""
    folder = people_dir()
    folder.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    for entry in people(root):
        card = person(entry["name"], root=root, now=now)
        if card is None:
            continue
        path = folder / entry["file"]
        _write_text(path, render_person_md(card, _my_notes(path)))
        written.append(path.name)
    stubbed = 0
    for path in sorted(folder.glob("*.md")):
        if path.name in written:
            continue
        try:
            head = path.read_text(encoding="utf-8")[:400]
        except OSError:
            continue
        if "generated_by: mostik" not in head or "встреч нет" in head:
            continue
        notes = _my_notes(path)
        name = path.stem
        _write_text(path, "\n".join(["---", f"name: {json.dumps(name, ensure_ascii=False)}", "meetings: 0",
                                     "generated_by: mostik", "---", "", f"# {name}", "",
                                     "Видимых встреч нет (встреч нет в архиве или они чувствительные).", "",
                                     MY_NOTES, "", notes]).rstrip() + "\n")
        stubbed += 1
    return {"written": len(written), "stubbed": stubbed, "folder": str(folder)}


def _write_text(path: Path, text: str) -> None:
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


# --- темы и сводки (W6) -----------------------------------------------------------------

def topics_of(items: list[Meeting], limit: int = 8) -> list[dict[str, Any]]:
    """Темы без модели: основы слов из названий, пунктов сводки и решений, которые повторяются
    на разных встречах (на одной встрече — из названия). Показывается самое частое написание."""
    stems: dict[str, set[str]] = {}
    surface: dict[str, dict[str, int]] = {}
    for meeting in items:
        summary = store.summary(meeting.record) or {}
        texts = [meeting.title] if not default_title(meeting.title) else []
        texts += [_clean(p.get("text") if isinstance(p, dict) else p) for p in summary.get("points") or []]
        texts += list(summary.get("decisions") or [])
        for text in texts:
            for word in tokens(text):
                if len(word) < 4 or word.isdigit():
                    continue
                terms = query_terms(word)
                if not terms or terms[0] != normalize(word):
                    continue
                stem = terms[0]
                stems.setdefault(stem, set()).add(meeting.id)
                surface.setdefault(stem, {})
                surface[stem][word] = surface[stem].get(word, 0) + 1
    floor = 2 if len(items) > 1 else 1
    ranked = sorted(((len(ids), stem) for stem, ids in stems.items() if len(ids) >= floor), key=lambda x: (-x[0], x[1]))
    result = []
    for count, stem in ranked[:limit]:
        word = max(surface[stem].items(), key=lambda item: (item[1], -len(item[0])))[0]
        result.append({"topic": word, "meetings": count})
    return result


def digest(items: list[Meeting], *, kind: str, title: str, since: _dt.datetime | None = None,
           until: _dt.datetime | None = None, today: _dt.date | None = None, language: str = "ru") -> dict[str, Any]:
    today = today or _dt.date.today()
    en = language == "en"
    decisions, open_tasks = [], []
    for meeting in items:
        for text in (store.summary(meeting.record) or {}).get("decisions") or []:
            decisions.append({"text": text, "meeting_id": meeting.id, "meeting_title": meeting.title,
                              "date": meeting.record.date})
        for task in meeting.tasks:
            if task["open"]:
                open_tasks.append(task_view(meeting, task, today))
    open_tasks.sort(key=lambda task: (not task["overdue"], task.get("due_date") or "9999"))
    topics = topics_of(items)
    lines = [f"# {title}", ""]
    if since or until:
        lines += [("Period: " if en else "Период: ")
                  + " — ".join(f"{moment:%d.%m.%Y}" for moment in (since, until) if moment), ""]
    lines += [f"## {'Meetings' if en else 'Встречи'} ({len(items)})", ""]
    lines += [f"- {_date_label(m.record.date, language)} «{m.title}» — `{m.id}`" for m in items] or ["—"]
    if topics:
        lines += ["", f"## {'Topics' if en else 'Темы'}", "",
                  ", ".join(f"{item['topic']} ({item['meetings']})" for item in topics)]
    lines += ["", f"## {'Decisions' if en else 'Решения'}", ""]
    lines += [f"- {item['text']} — «{item['meeting_title']}», {_date_label(item['date'], language)}"
              for item in decisions] or ["—"]
    lines += ["", f"## {'Open action items' if en else 'Открытые поручения'}", ""]
    for task in open_tasks:
        due = f"; {'due' if en else 'срок'}: {task['due_date'] or task['due']}" if task.get("due") else ""
        flag = (" — overdue" if en else " — просрочено") if task["overdue"] else ""
        lines.append(f"- [ ] {task['task']} — {task['assignee'] or ('not set' if en else 'не указан')}{due}{flag} "
                     f"(«{task['meeting_title']}»)")
    if not open_tasks:
        lines.append("—")
    return {"kind": kind, "title": title, "since": since.isoformat(timespec="minutes") if since else None,
            "until": until.isoformat(timespec="minutes") if until else None,
            "meetings": [m.ref() for m in items], "topics": topics, "decisions": decisions,
            "open_tasks": open_tasks, "text": "\n".join(lines).rstrip() + "\n"}


def week_digest(*, root: Path | None = None, now: _dt.datetime | None = None, days: float = 7,
                language: str = "ru") -> dict[str, Any]:
    now = _now(now)
    since = now - _dt.timedelta(days=days)
    items = [m for m in archive(root) if m.started and since <= m.started <= now]
    year, week, _ = now.isocalendar()
    title = f"Week {year}-W{week:02d}" if language == "en" else f"Неделя {year}-W{week:02d}"
    data = digest(items, kind="week", title=title, since=since, until=now, today=now.date(), language=language)
    data["key"] = f"week-{year}-W{week:02d}"
    return data


def series_list(root: Path | None = None) -> list[dict[str, Any]]:
    groups: dict[str, list[Meeting]] = {}
    for meeting in archive(root):
        if meeting.series:
            groups.setdefault(meeting.series, []).append(meeting)
    result = [{"key": key, "title": items[0].title, "meetings": len(items), "last": items[0].ref(),
               "open_tasks": sum(1 for m in items for t in m.tasks if t["open"])}
              for key, items in groups.items()]
    result.sort(key=lambda item: item["last"]["date"] or "", reverse=True)
    return result


def series_digest(key: str, *, root: Path | None = None, now: _dt.datetime | None = None,
                  language: str = "ru") -> dict[str, Any] | None:
    items = [m for m in archive(root) if m.series == key]
    if not items:
        return None
    title = (f"Series: {items[0].title}" if language == "en" else f"Серия: {items[0].title}")
    data = digest(items, kind="series", title=title, today=_now(now).date(), language=language)
    data["key"] = "series-" + hashlib.sha1(key.encode("utf-8")).hexdigest()[:10]
    data["series"] = key
    return data


def write_digest(data: dict[str, Any]) -> Path:
    folder = paths.mostik_home() / "digests"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{data['key']}.md"
    _write_text(path, data["text"])
    return path


# --- темы-триггеры (W12) ------------------------------------------------------------------

def _phrase_match(phrase: list[str], words: list[str]) -> bool:
    if not phrase:
        return False
    size = len(phrase)
    return any(words[i:i + size] == phrase for i in range(len(words) - size + 1))


def track_topics(topics: Iterable[str], *, root: Path | None = None, days: float | None = None,
                 include_sensitive: bool = False, limit: int = 20, now: _dt.datetime | None = None,
                 scope: Scope | None = None) -> dict[str, Any]:
    """Где звучали слова-триггеры: по основам, фраза — подряд. Новые встречи первыми, до `limit` упоминаний на тему."""
    wanted = []
    for topic in topics:
        topic = _clean(topic)
        if topic and topic not in [item[0] for item in wanted]:
            wanted.append((topic, normalize(topic).split()))
    items = archive(root, include_sensitive=include_sensitive)
    if scope is not None:
        items = select(items, scope, now)
    if days:
        since = _now(now) - _dt.timedelta(days=float(days))
        items = [m for m in items if m.started and m.started >= since]
    result = []
    cache: dict[str, tuple[list[dict[str, Any]], dict[int, int]]] = {}
    for topic, phrase in wanted:
        mentions, meetings, total = [], set(), 0
        for meeting in items:
            if meeting.id not in cache:
                cache[meeting.id] = (store.turns(meeting.record), transcript_lines(meeting.record.folder))
            turns, lines = cache[meeting.id]
            for turn in turns:
                if _phrase_match(phrase, normalize(turn["text"]).split()):
                    meetings.add(meeting.id)
                    total += 1
                    if len(mentions) < limit:
                        mentions.append({"meeting_id": meeting.id, "title": meeting.title,
                                         "date": meeting.record.date, "turn": turn["n"], "speaker": turn["speaker"],
                                         "at": turn["start"], "text": _quote(turn["text"], 280),
                                         "ref": turn_ref(meeting.id, turn["n"], lines) or f"{meeting.id}#{turn['n']}"})
        result.append({"topic": topic, "meetings": len(meetings), "mentions": mentions, "count": total})
    return {"items": result, "searched": len(items)}
