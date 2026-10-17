"""Архив встреч (M18, W1, W3–W6, W12): карточки, бриф, люди, серии, сводки, темы, чат-агент.

Встречи синтетические, в tmp MOSTIK_HOME; модель — заглушка со сценарием.
"""
from __future__ import annotations

import datetime as dt
import json
from pathlib import Path

import pytest

from mostik_engine import archive, task_state
from mostik_engine import meeting_folder as mf
from mostik_engine import meeting_store as store
from mostik_engine.meeting import render_markdown

TZ = dt.timezone(dt.timedelta(hours=3))
NOW = dt.datetime(2026, 10, 21, 9, 0, tzinfo=TZ)  # среда


def make(home: Path, meeting_id: str, *, title: str, people=("Иван Петров",), turns=None, tasks=None,
         points=None, overview="", event: str | None = None, sensitive=False) -> Path:
    folder = home / "meetings" / meeting_id
    folder.mkdir(parents=True)
    started = dt.datetime.strptime(meeting_id, "%Y-%m-%d-%H%M%S").replace(tzinfo=TZ)
    turns = turns or [
        {"speaker": "Я", "start": 0.0, "text": "Начнём с бюджета на ноябрь."},
        {"speaker": people[0] if people else "Собеседник 1", "start": 5.0, "text": "Смету подготовлю до пятницы."},
        {"speaker": "Я", "start": 9.0, "text": "Договорились, релиз переносим на ноябрь."},
    ]
    turns = [{"id": index, **turn} for index, turn in enumerate(turns)]
    (folder / "transcript.json").write_text(json.dumps({
        "schema": "mostik.transcript", "id": meeting_id, "title": title, "language": "ru",
        "participants": ["Я", *people], "turns": turns}, ensure_ascii=False), encoding="utf-8")
    (folder / "transcript.md").write_text(render_markdown(turns, date=started.replace(tzinfo=None), duration_seconds=12,
                                                          title=title), encoding="utf-8")
    mode = {"status": "done", "language": "ru", "overview": overview,
            "points": [{"text": text, "refs": [2]} for text in (points or ["Договорились перенести релиз на ноябрь"])],
            "tasks": tasks if tasks is not None else [
                {"text": "Подготовить смету", "assignee": people[0] if people else None, "due": "до пятницы",
                 "refs": [1]}]}
    (folder / "notes.json").write_text(json.dumps({"last_mode": "detailed", "modes": {"detailed": mode}},
                                                  ensure_ascii=False), encoding="utf-8")
    mf.update_manifest(folder, {
        "title": title, "title_source": "calendar", "started": started.isoformat(), "language": "ru",
        "attendees": [{"name": "Антон", "self": True}, *({"name": name, "self": False} for name in people)],
        "calendar": {"event_id": event, "title": title} if event else None,
        "sensitive": sensitive, "transcript": {"status": "done"}})
    mf.write_meeting_md(folder)
    return folder


@pytest.fixture
def home(mostik_home):
    mostik_home.mkdir(parents=True, exist_ok=True)
    return mostik_home


# --- серии и поручения (W4) --------------------------------------------------------------

def test_series_by_calendar_and_by_title(home):
    make(home, "2026-10-07-100000", title="Синк по бюджету", event="ABC@1759820400")
    make(home, "2026-10-14-100000", title="Синк по бюджету", event="ABC@1760425200")
    make(home, "2026-10-15-100000", title="Синк по бюджету")  # без календаря, то же название
    make(home, "2026-10-16-120000", title="Ретро", people=("Анна",))
    make(home, "2026-10-17-120000", title="Ретро", people=("Анна",))
    make(home, "2026-10-18-120000", title="Разовая", people=("Олег",))
    series = {m.id: m.series for m in archive.archive()}
    assert series["2026-10-07-100000"] == series["2026-10-14-100000"] == series["2026-10-15-100000"] == "cal:ABC"
    assert series["2026-10-16-120000"] == series["2026-10-17-120000"] == "title:ретро"
    assert series["2026-10-18-120000"] is None


def test_actions_have_due_date_and_status(home):
    folder = make(home, "2026-10-14-100000", title="Синк")
    record = store.load(folder)
    [task] = store.actions(record)
    assert task["due_date"] == "2026-10-16" and task["status"] == "open" and task["key"]
    task_state.set_status(record.id, task["key"], "done")
    [task] = store.actions(record)
    assert task["open"] is False and task["status"] == "done"
    task_state.set_status(record.id, task["key"], "open")
    assert store.actions(record)[0]["open"] is True
    with pytest.raises(ValueError):
        task_state.set_status(record.id, task["key"], "maybe")


# --- бриф (W1) -----------------------------------------------------------------------------

def test_brief_series_followup_and_last_time(home):
    make(home, "2026-10-14-100000", title="Синк по бюджету", event="ABC@1760425200",
         overview="Обсудили бюджет на ноябрь и перенос релиза.")
    make(home, "2026-10-15-120000", title="Секрет", event="ABC@1760518800", sensitive=True,
         overview="Тайное", tasks=[{"text": "Секретная задача", "assignee": "Иван Петров", "due": None}])
    event = {"id": "ABC@1761030000", "title": "Синк по бюджету", "start": "2026-10-21T10:00:00+03:00",
             "attendees": ["Антон", "Иван Петров"]}
    data = archive.brief(event, now=NOW)
    assert data["event"]["attendees"] == ["Иван Петров"]
    assert [m["id"] for m in data["related"]] == ["2026-10-14-100000"]  # чувствительной нет
    kinds = [point["kind"] for point in data["points"]]
    assert kinds == ["last", "promises", "decisions"] and len(data["points"]) <= 3
    assert "Обсудили бюджет" in data["points"][0]["text"]
    promise = data["points"][1]["text"]
    assert "В прошлый раз Иван Петров обещал(а): «Подготовить смету»" in promise
    assert "срок 16.10, просрочено" in promise and "сделано?" in promise
    assert "Секрет" not in data["text"] and "Тайное" not in data["text"]
    assert data["text"].startswith("Бриф: Синк по бюджету")


def test_brief_by_people_without_series_and_done_task_disappears(home):
    folder = make(home, "2026-10-14-100000", title="Разговор", people=("Мария",))
    event = {"id": "XYZ@1", "title": "Другое", "start": "2026-10-21T10:00:00+03:00", "attendees": ["Антон", "Мария"]}
    data = archive.brief(event, now=NOW)
    assert data["series"] is None and data["related"][0]["id"] == folder.name
    key = data["followups"][0]["key"]
    task_state.set_status(folder.name, key, "done")
    assert archive.brief(event, now=NOW)["followups"] == []


def test_brief_empty_without_history(home):
    data = archive.brief({"id": "N@1", "title": "Новая", "start": "2026-10-21T10:00:00+03:00",
                          "attendees": ["Антон", "Незнакомец"]}, now=NOW)
    assert data["points"] == [] and data["text"] == ""
    assert archive.write_brief(data) is None


def test_brief_english_followup(home):
    make(home, "2026-10-14-100000", title="Budget sync", event="E@1",
         tasks=[{"text": "Prepare the estimate", "assignee": "Я", "due": "by Friday"}])
    data = archive.brief({"id": "E@2", "title": "Budget sync", "start": "2026-10-21T10:00:00+03:00",
                          "attendees": ["Антон", "Иван Петров"]}, now=NOW, language="en")
    assert "Last time you promised: «Prepare the estimate» (due Oct 16, overdue) — done?" in data["text"]


# --- карточка встречи (M18) -------------------------------------------------------------------

def test_card_refs_point_to_transcript_lines(home):
    folder = make(home, "2026-10-14-100000", title="Синк")
    path = archive.write_card(folder)
    text = path.read_text(encoding="utf-8")
    header = mf.front_matter(text)
    assert header["prompt_version"] == archive.CARD_PROMPT_VERSION and header["card_version"] == 1
    card = archive.meeting_card(store.load(folder, with_transcript=True))
    lines = (folder / "transcript.md").read_text(encoding="utf-8").splitlines()
    [task] = card["tasks"]
    file, line = task["ref"].rsplit(":", 1)
    assert file == "2026-10-14-100000/transcript.md" and "Смету подготовлю" in lines[int(line) - 1]
    [decision] = card["decisions"]
    assert "релиз переносим" in lines[int(decision["ref"].rsplit(":", 1)[1]) - 1]
    assert {q["text"] for q in card["quotes"]} >= {"Смету подготовлю до пятницы."}
    assert [p["name"] for p in card["people"] if not p["self"]] == ["Иван Петров"]
    assert not archive.card_stale(folder)


def test_card_stale_on_version_and_skip_sensitive(home, monkeypatch):
    folder = make(home, "2026-10-14-100000", title="Синк")
    archive.write_card(folder)
    monkeypatch.setattr(archive, "CARD_PROMPT_VERSION", "rules-2")
    assert archive.card_stale(folder)
    secret = make(home, "2026-10-15-100000", title="Секрет", sensitive=True)
    assert archive.write_card(secret) is None and not (secret / "card.md").exists()


def test_open_questions_rules(home):
    turns = [
        {"speaker": "Иван Петров", "start": 0.0, "text": "А кто будет вести миграцию базы?"},
        {"speaker": "Я", "start": 3.0, "text": "Не знаю, уточню у команды."},
        {"speaker": "Я", "start": 6.0, "text": "Всё, спасибо."},
    ]
    folder = make(home, "2026-10-14-100000", title="Синк", turns=turns, tasks=[])
    card = archive.meeting_card(store.load(folder, with_transcript=True))
    assert [q["text"] for q in card["open_questions"]] == ["А кто будет вести миграцию базы?"]
    lines = (folder / "transcript.md").read_text(encoding="utf-8").splitlines()
    line = int(card["open_questions"][0]["ref"].rsplit(":", 1)[1])
    assert "кто будет вести миграцию" in lines[line - 1]


# --- люди (W3) -------------------------------------------------------------------------------------

def test_person_card_and_file(home):
    make(home, "2026-10-07-100000", title="Первая", overview="Познакомились.")
    make(home, "2026-10-14-100000", title="Вторая", overview="Обсудили смету.",
         tasks=[{"text": "Подготовить смету", "assignee": "Иван Петров", "due": "до пятницы"},
                {"text": "Прислать договор", "assignee": "Я", "due": None}])
    card = archive.person("иван петров", now=NOW)
    assert card["name"] == "Иван Петров" and [m["id"] for m in card["meetings"]] == [
        "2026-10-14-100000", "2026-10-07-100000"]
    assert {t["task"] for t in card["promises"]} == {"Подготовить смету"}
    assert [t["task"] for t in card["my_promises"]] == ["Прислать договор"]
    assert card["last"]["overview"] == "Обсудили смету."
    stats = archive.write_people(now=NOW)
    path = archive.people_dir() / "Иван Петров.md"
    assert stats["written"] == 1 and path.is_file()
    text = path.read_text(encoding="utf-8")
    assert "## О чём говорили в последний раз" in text and "Подготовить смету" in text
    path.write_text(text + "Любит короткие встречи.\n", encoding="utf-8")
    archive.write_people(now=NOW)
    assert "Любит короткие встречи." in path.read_text(encoding="utf-8")


def test_people_file_stubbed_when_meetings_become_sensitive(home):
    folder = make(home, "2026-10-14-100000", title="Вторая", overview="Обсудили смету.", people=("Ольга",))
    archive.write_people(now=NOW)
    path = archive.people_dir() / "Ольга.md"
    assert "Обсудили смету" in path.read_text(encoding="utf-8")
    mf.update_manifest(folder, {"sensitive": True})
    stats = archive.write_people(now=NOW)
    assert stats["stubbed"] == 1
    text = path.read_text(encoding="utf-8")
    assert "Обсудили смету" not in text and "Видимых встреч нет" in text


def test_person_links_voice_memory(home):
    from mostik_engine.voices import VoiceStore

    make(home, "2026-10-14-100000", title="Синк")
    VoiceStore().add_sample("Иван Петров", [1.0, 0.0], model="stub", seconds=10, meeting="2026-10-14-100000")
    assert archive.person("Иван Петров", now=NOW)["voice"]["samples"] == 1
    assert archive.people()[0]["voice"] is True


# --- область (W5) ---------------------------------------------------------------------------------

def test_scope_who_series_period(home):
    make(home, "2026-06-01-100000", title="Клиент Ромашка: старт", people=("Пётр",))
    make(home, "2026-10-14-100000", title="Синк", event="S@1")
    make(home, "2026-10-20-100000", title="Синк", event="S@2", people=("Ольга",))
    items = archive.archive()
    assert [m.id for m in archive.select(items, archive.Scope(who="ромашка"), NOW)] == ["2026-06-01-100000"]
    assert [m.id for m in archive.select(items, archive.Scope.from_payload({"period": "week"}), NOW)] == [
        "2026-10-20-100000", "2026-10-14-100000"]
    assert len(archive.select(items, archive.Scope(series="cal:S"), NOW)) == 2
    assert [m.id for m in archive.select(items, archive.Scope(who="ольга"), NOW)] == ["2026-10-20-100000"]
    with pytest.raises(ValueError):
        archive.Scope.from_payload({"days": "много"})


# --- сводки (W6) -----------------------------------------------------------------------------------

def test_week_digest_excludes_old_and_sensitive(home):
    make(home, "2026-10-01-100000", title="Старая", points=["Договорились о старом"])
    make(home, "2026-10-19-100000", title="Бюджет", points=["Договорились о бюджете на ноябрь"])
    make(home, "2026-10-20-100000", title="Бюджет", points=["Решили урезать бюджет"], people=("Ольга",))
    make(home, "2026-10-20-150000", title="Тайна", sensitive=True, points=["Договорились о тайном"])
    data = archive.week_digest(now=NOW)
    assert [m["id"] for m in data["meetings"]] == ["2026-10-20-100000", "2026-10-19-100000"]
    assert {d["text"] for d in data["decisions"]} == {"Договорились о бюджете на ноябрь", "Решили урезать бюджет"}
    assert "тайн" not in data["text"].lower() and "старом" not in data["text"]
    assert any(item["topic"].lower().startswith("бюджет") for item in data["topics"])
    # «до пятницы», сказанное в понедельник и вторник, — 23.10: ещё не просрочено.
    assert {task["due_date"] for task in data["open_tasks"]} == {"2026-10-23"}
    assert not any(task["overdue"] for task in data["open_tasks"])
    path = archive.write_digest(data)
    assert path.name == "week-2026-W43.md" and path.read_text(encoding="utf-8").startswith("# Неделя 2026-W43")


def test_series_digest(home):
    make(home, "2026-10-07-100000", title="Синк", event="S@1", points=["Договорились о первом"])
    make(home, "2026-10-14-100000", title="Синк", event="S@2", points=["Договорились о втором"])
    [series] = archive.series_list()
    assert series["key"] == "cal:S" and series["meetings"] == 2
    data = archive.series_digest("cal:S", now=NOW)
    assert data["title"] == "Серия: Синк" and len(data["decisions"]) == 2
    assert archive.series_digest("cal:нет", now=NOW) is None


# --- темы (W12) -------------------------------------------------------------------------------------

def test_track_topics_by_stems_and_sensitive_flag(home):
    turns = [{"speaker": "Иван Петров", "start": 1.0, "text": "Цена у конкурента ниже, платёжного шлюза у них нет."},
             {"speaker": "Я", "start": 4.0, "text": "Следующие шаги обсудим завтра."}]
    make(home, "2026-10-14-100000", title="Синк", turns=turns, tasks=[])
    make(home, "2026-10-15-100000", title="Тайна", sensitive=True, tasks=[],
         turns=[{"speaker": "Я", "start": 1.0, "text": "Конкуренты снова снизили цены."}])
    data = archive.track_topics(["конкурент", "платёжный шлюз", "следующие шаги", "слон"])
    by_topic = {item["topic"]: item for item in data["items"]}
    assert by_topic["конкурент"]["count"] == 1 and by_topic["платёжный шлюз"]["count"] == 1
    assert by_topic["следующие шаги"]["mentions"][0]["ref"].startswith("2026-10-14-100000/transcript.md:")
    assert by_topic["слон"]["count"] == 0
    assert archive.track_topics(["конкурент"], include_sensitive=True)["items"][0]["meetings"] == 2
