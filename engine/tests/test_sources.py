"""Несколько источников словаря (S2, S5), календарь (S1) и их команды протокола."""
from __future__ import annotations

import json
import os
import threading
import time

import pytest

from test_protocol import Sink, send  # noqa: F401 — общий приёмник событий
from conftest import FakePool, FakeVerifier
from mostik_engine import calendar_terms as cal
from mostik_engine import project_glossary as pg
from mostik_engine.personal_glossary import PersonalGlossary
from mostik_engine.server import Engine


def make_docs(root):
    (root / "notes").mkdir(parents=True)
    (root / ".obsidian").mkdir()
    (root / ".hidden").mkdir()
    (root / "notes" / "meeting.md").write_text(
        "# Запуск Vega\n\nОбсудили с клиентом проект «Альфа» и миграцию на ClickHouse.\n"
        "Отвечает Злата, а Злата ещё пишет в TODO_LIST.\n",
        encoding="utf-8",
    )
    (root / "plan.txt").write_text("Берём SDK и S3.\nСроки — до v2, коммит 3fa9c1e2b.\n", encoding="utf-8")
    (root / "single.md").write_text("Решили, что Тимофей поможет.\n", encoding="utf-8")
    (root / ".obsidian" / "workspace.md").write_text("# HiddenPlugin\n", encoding="utf-8")
    (root / ".hidden" / "x.md").write_text("# SecretThing\n", encoding="utf-8")
    (root / "image.png").write_bytes(b"\x89PNG")


def entry(result, term):
    return next(item for item in result["entries"] if item["term"] == term)


# --- папка документов -------------------------------------------------------


def test_docs_folder_terms_kinds_and_origins(tmp_path):
    docs = tmp_path / "docs"
    make_docs(docs)
    result = pg.build(docs, kind="docs")
    terms = set(result["terms"])
    assert {"Vega", "Альфа", "ClickHouse", "Злата", "SDK", "S3"} <= terms
    assert "TODO_LIST" not in terms  # идентификатор из кода — только в режиме разработчика
    assert entry(result, "Альфа")["kind"] == "project"
    assert entry(result, "Злата")["kind"] == "person"
    assert entry(result, "SDK")["kind"] == "acronym"
    assert entry(result, "ClickHouse")["origins"] == ["notes/meeting.md:3"]
    assert entry(result, "S3")["origins"] == ["plan.txt:1"]
    # Скрытое, .obsidian, картинки, версии и хэши — мимо; имя без повтора — мимо.
    assert not terms & {"HiddenPlugin", "SecretThing", "v2", "3fa9c1e2b", "Тимофей"}
    assert result["counts"]["person"] >= 1 and sum(result["counts"].values()) == result["count"]


def test_cache_file_format(tmp_path):
    docs = tmp_path / "docs"
    make_docs(docs)
    pg.build(docs, kind="docs")
    payload = json.loads(pg.cache_path(docs.resolve()).read_text(encoding="utf-8"))
    assert payload["root"] == str(docs.resolve()) and payload["kind"] == "docs"
    assert payload["scanned_at"] and isinstance(payload["scanned_ts"], float)
    first = payload["terms"][0]
    assert set(first) >= {"term", "kind", "origins"}


def test_ten_minute_rule_and_rescan(tmp_path):
    docs = tmp_path / "docs"
    make_docs(docs)
    first = pg.build(docs, kind="docs", max_age_s=600)
    assert first["cached"] is False
    (docs / "new.md").write_text("Подключаем Kubernetes и Kubernetes.\n", encoding="utf-8")
    # Моложе 10 минут — дерево не обходим, новый файл не виден.
    second = pg.build(docs, kind="docs", max_age_s=600)
    assert second["cached"] is True and "Kubernetes" not in second["terms"]
    # rescan — обход заново.
    third = pg.build(docs, kind="docs", force=True)
    assert third["cached"] is False and third["reused"] == 0 and "Kubernetes" in third["terms"]
    # Кэш старше 10 минут — обход с повторным использованием неизменённых файлов.
    store = pg.cache_path(docs.resolve())
    payload = json.loads(store.read_text(encoding="utf-8"))
    payload["scanned_ts"] = time.time() - 601
    store.write_text(json.dumps(payload), encoding="utf-8")
    fourth = pg.build(docs, kind="docs", max_age_s=600)
    assert fourth["cached"] is False and fourth["reused"] == fourth["files"]


def test_glossaries_memory_respects_rescan(tmp_path):
    docs = tmp_path / "docs"
    make_docs(docs)
    memory = pg.ProjectGlossaries()
    assert "Vega" in memory.terms(str(docs), "docs")
    (docs / "new.md").write_text("Сегодня подключаем кластер Kubernetes.\n", encoding="utf-8")
    assert "Kubernetes" not in memory.terms(str(docs), "docs")
    assert "Kubernetes" in memory.scan(str(docs), "docs", force=True)["terms"]
    assert memory.scan(str(tmp_path / "missing"), "docs") is None


def test_limits_files_and_text(tmp_path, monkeypatch):
    docs = tmp_path / "docs"
    docs.mkdir()
    for index in range(5):
        (docs / f"n{index}.md").write_text(f"Термин Alpha{index}x.\n", encoding="utf-8")
    monkeypatch.setattr(pg, "MAX_FILES", 2)
    result = pg.build(docs, kind="docs", force=True)
    assert result["files"] == 2 and result["truncated"] is True
    monkeypatch.setattr(pg, "MAX_FILES", 2000)
    monkeypatch.setattr(pg, "MAX_TEXT_BYTES", 30)
    result = pg.build(docs, kind="docs", force=True)
    assert result["files"] < 5 and result["truncated"] is True


def test_pdf_through_pdftotext_or_skipped(tmp_path, monkeypatch):
    docs = tmp_path / "docs"
    docs.mkdir()
    (docs / "spec.pdf").write_bytes(b"%PDF-1.4 fake")
    monkeypatch.setattr(pg, "pdftotext_available", lambda: False)
    assert pg.build(docs, kind="docs", force=True)["files"] == 0
    monkeypatch.setattr(pg, "pdftotext_available", lambda: True)
    monkeypatch.setattr(pg, "_pdf_text", lambda path: "Страница\nСистема Kafka2 и gRPC.\n")
    result = pg.build(docs, kind="docs", force=True)
    assert entry(result, "Kafka2")["origins"] == ["spec.pdf:2"]
    assert "gRPC" in result["terms"]


def test_repo_takes_markdown_by_document_rules(tmp_path):
    repo = tmp_path / "repo"
    (repo / "docs").mkdir(parents=True)
    (repo / "engine.py").write_text("class TermIndex:\n    pass\n", encoding="utf-8")
    (repo / "docs" / "notes.md").write_text("Модуль работает с Silero и GigaAM.\n", encoding="utf-8")
    result = pg.build(repo)
    assert entry(result, "TermIndex")["origins"] == ["engine.py:1"]
    assert entry(result, "TermIndex")["kind"] == "identifier"
    assert entry(result, "GigaAM")["origins"] == ["docs/notes.md:1"]


# --- календарь ----------------------------------------------------------------

EVENTS = [
    {"id": "1", "title": "Синк Mostik с командой ОТК", "start": "2026-10-10T10:00:00+03:00",
     "end": "2026-10-10T11:00:00+03:00", "attendees": ["Иван Петров", "Злата Тестова"], "notes": ""},
    {"id": "2", "title": "Фокус-время", "start": "2026-10-10T12:00:00+03:00",
     "end": "2026-10-10T13:00:00+03:00", "attendees": ["Иван Петров"], "notes": ""},
    {"id": "3", "title": "Ревью Vega", "start": "2026-10-14T10:00:00+03:00",
     "end": "2026-10-14T11:00:00+03:00", "attendees": ["Иван Петров", "Олег", "Мария"],
     "notes": "Обсудить ClickHouse и S3."},
]


def test_calendar_keeps_events_with_two_attendees_and_replaces_set():
    kept = cal.store(EVENTS)
    assert [event["id"] for event in kept] == ["1", "3"]
    assert [event["id"] for event in cal.load()] == ["1", "3"]
    cal.store(EVENTS[2:])
    assert [event["id"] for event in cal.load()] == ["3"]


def test_calendar_terms_kinds_origins_and_order():
    kept = cal.store(EVENTS)
    now = cal._parse_time("2026-10-10T10:30:00+03:00")
    terms = cal.terms(kept, now=now)
    by_term = {item["term"]: item for item in terms}
    assert by_term["Иван Петров"]["kind"] == "person"
    assert by_term["Петров"]["origins"] == ["календарь: Синк Mostik с командой ОТК", "календарь: Ревью Vega"]
    assert by_term["Олег"]["origins"] == ["календарь: Ревью Vega"]
    assert by_term["Mostik"]["kind"] == "project" and by_term["ОТК"]["kind"] == "acronym"
    assert by_term["ClickHouse"]["origins"] == ["календарь: Ревью Vega"]
    assert "Фокус-время" not in by_term
    # Идущая сейчас встреча — первой.
    assert terms[0]["origins"][0] == "календарь: Синк Mostik с командой ОТК"


def test_calendar_rejects_bad_payload():
    with pytest.raises(ValueError):
        cal.normalize_events({"not": "a list"})
    assert cal.normalize_events([None, {"attendees": ["", "A"]}]) == []


# --- протокол -------------------------------------------------------------------


@pytest.fixture
def engine(tmp_path):
    sink = Sink()
    verifier = FakeVerifier()
    eng = Engine(
        sink,
        pool=FakePool(),
        verifier=verifier,
        personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False),
    )
    verifier.sink = eng._on_verifier
    return eng, sink


def test_calendar_command(engine):
    eng, sink = engine
    send(eng, cmd="calendar", id=1, events=EVENTS)
    reply = sink.lines[-1]
    assert reply["id"] == 1 and reply["ok"] is True and reply["events"] == 2
    assert any(item["term"] == "Злата Тестова" and item["kind"] == "person" for item in reply["terms"])
    send(eng, cmd="calendar", id=2, events="bad")
    assert sink.lines[-1]["event"] == "error" and sink.lines[-1]["id"] == 2


def test_sources_and_rescan_commands(engine, tmp_path):
    eng, sink = engine
    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / "engine.py").write_text("class TermIndex:\n    pass\n", encoding="utf-8")
    docs = tmp_path / "docs"
    make_docs(docs)
    send(eng, cmd="calendar", id=1, events=EVENTS)
    send(eng, cmd="remember", id=2, heard="пара кит", canonical="Parakeet")
    send(eng, cmd="sources", id=3, project=str(repo), sources=[str(docs), str(tmp_path / "missing")])
    reply = sink.wait(lambda e: e.get("id") == 3)
    kinds = [item["kind"] for item in reply["sources"]]
    assert kinds == ["repo", "docs", "docs", "calendar", "personal"]
    repo_card, docs_card, missing, calendar_card, personal_card = reply["sources"]
    assert repo_card["label"] == "repo" and repo_card["total"] >= 1 and repo_card["scanned_at"]
    assert set(docs_card["counts"]) == {"person", "project", "tech", "acronym", "identifier"}
    assert docs_card["total"] == sum(docs_card["counts"].values())
    assert missing["total"] == 0 and missing["error"]
    assert calendar_card["total"] >= 4 and personal_card["total"] == 1
    by_term = {item["term"]: item for item in reply["terms"]}
    assert by_term["TermIndex"]["origins"] == ["engine.py:1"]
    assert by_term["Альфа"]["origins"][0].startswith("notes/meeting.md:")
    assert by_term["Parakeet"]["origins"] == ["личный словарь"]
    assert by_term["Петров"]["origins"][0].startswith("календарь: ")
    assert len(reply["terms"]) <= 5000
    # `in` — значения path источников: интерфейс фильтрует по ним.
    assert [card["path"] for card in reply["sources"]] == [
        str(repo), str(docs), str(tmp_path / "missing"), "calendar", "personal"]
    assert by_term["TermIndex"]["in"] == [str(repo)]
    assert by_term["Альфа"]["in"] == [str(docs)]
    assert by_term["Parakeet"]["in"] == ["personal"]
    assert by_term["Петров"]["in"] == ["calendar"]
    paths = {card["path"] for card in reply["sources"]}
    assert all(set(item["in"]) <= paths for item in reply["terms"])
    # Новый файл: sources берёт кэш (моложе 10 минут), rescan — видит.
    (docs / "fresh.md").write_text("Сегодня добавили кластер Kubernetes.\n", encoding="utf-8")
    send(eng, cmd="sources", id=4, project=None, sources=[str(docs)])
    reply = sink.wait(lambda e: e.get("id") == 4)
    assert "Kubernetes" not in {item["term"] for item in reply["terms"]}
    assert [item["kind"] for item in reply["sources"]] == ["docs", "calendar", "personal"]
    send(eng, cmd="rescan", id=5, project=None, sources=[str(docs)])
    reply = sink.wait(lambda e: e.get("id") == 5)
    assert "Kubernetes" in {item["term"] for item in reply["terms"]}


def test_term_in_several_sources_lists_all(engine, tmp_path):
    eng, sink = engine
    docs = tmp_path / "docs"
    make_docs(docs)
    other = tmp_path / "other"
    other.mkdir()
    (other / "x.md").write_text("Сегодня снова обсуждали кластер ClickHouse.\n", encoding="utf-8")
    send(eng, cmd="sources", id=1, project=None, sources=[str(docs), str(other)])
    reply = sink.wait(lambda e: e.get("id") == 1)
    clickhouse = next(item for item in reply["terms"] if item["term"] == "ClickHouse")
    assert sorted(clickhouse["in"]) == sorted([str(docs), str(other)])
    assert sorted(clickhouse["origins"]) == ["notes/meeting.md:3", "x.md:1"]


def test_sources_terms_capped(engine, monkeypatch, tmp_path):
    eng, sink = engine
    from mostik_engine import sources as src

    monkeypatch.setattr(src, "MAX_TERMS", 3)
    docs = tmp_path / "docs"
    make_docs(docs)
    send(eng, cmd="sources", id=1, project=None, sources=[str(docs)])
    reply = sink.wait(lambda e: e.get("id") == 1)
    assert len(reply["terms"]) == 3


def test_session_dictionary_includes_sources_and_calendar(engine, tmp_path):
    eng, sink = engine
    docs = tmp_path / "docs"
    make_docs(docs)
    send(eng, cmd="calendar", id=1, events=EVENTS)
    # Обход заранее: на медленном диске он дольше 200 мс, и старт взял бы прошлое (пустое).
    eng.projects.scan(str(docs), "docs")
    send(eng, cmd="start", id=2, session="s1", language="ru", project=None, sources=[str(docs)], verify=True)
    session = eng.sessions["s1"]
    deadline = time.monotonic() + 5
    while not session.hotwords and time.monotonic() < deadline:
        time.sleep(0.01)
    assert "Vega" in session.hotwords and "Иван Петров" in session.hotwords
    assert session.terms.exact  # словарь сомнений не пуст
    assert any(hit.canonical == "ClickHouse" for hit in session.terms.exact.values())
    send(eng, cmd="cancel", id=3, session="s1")


def test_terms_cache_key_follows_sources_and_calendar(engine, tmp_path):
    eng, _ = engine
    docs = tmp_path / "docs"
    make_docs(docs)
    eng.projects.scan(str(docs), "docs")
    _, empty = eng._terms_for(None, "ru", [])
    _, with_docs = eng._terms_for(None, "ru", [str(docs)])
    assert "Vega" not in empty and "Vega" in with_docs
    cal.store(EVENTS)
    later = time.time() + 5
    os.utime(cal.calendar_path(), (later, later))
    _, with_calendar = eng._terms_for(None, "ru", [str(docs)])
    assert "Иван Петров" in with_calendar


def test_bad_sources_field_is_error(engine):
    eng, sink = engine
    send(eng, cmd="start", id=7, session="s2", language="ru", sources=42)
    assert sink.lines[-1]["event"] == "error" and sink.lines[-1]["id"] == 7


def test_transcribe_file_passes_sources(engine, tmp_path):
    import wave

    eng, sink = engine
    path = tmp_path / "a.wav"
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16000)
        handle.writeframes(b"\x00\x00" * 1600)
    seen = {}
    original = eng._prepare

    def spy(session, project, folders=None):
        seen["folders"] = folders
        original(session, project, folders)

    eng._prepare = spy
    send(eng, cmd="transcribe_file", id=8, path=str(path), language="ru", project=None,
         sources=[str(tmp_path / "docs")], session="file-x")
    sink.wait(lambda e: e.get("id") == 8)
    assert seen["folders"] == [str(tmp_path / "docs")]


# --- большой корень: рабочая папка агента, а не репозиторий ------------------


def make_workspace(root):
    """Общая рабочая папка вроде ~/Work: проекты, архив, черновики, данные, глубина."""
    root.mkdir()
    (root / "AGENTS.md").write_text("# Правила RootRule\n", encoding="utf-8")
    for index in range(12):
        project = root / "01_work" / f"p{index:02d}"
        project.mkdir(parents=True)
        (project / "PROJECT.md").write_text(f"# Проект Shallow{index:02d}x\n", encoding="utf-8")
    deep = root / "code" / "a" / "b" / "c" / "d"
    deep.mkdir(parents=True)
    (deep / "deep.md").write_text("# DeepThing\n", encoding="utf-8")
    for name, term in (("06_archive/old", "ArchivedThing"), ("01_work/p00/drafts", "DraftThing"),
                       (".claude/skills", "ClaudeThing"), (".worktrees/x", "WorktreeThing")):
        (root / name).mkdir(parents=True)
        (root / name / "n.md").write_text(f"# {term}\n", encoding="utf-8")
    data = root / "02_research" / "dump"
    data.mkdir(parents=True)
    for index in range(30):
        (data / f"row{index}.json").write_text("{}", encoding="utf-8")
    (data / "readme.md").write_text("# DataThing\n", encoding="utf-8")


def test_big_root_skips_archive_drafts_hidden_and_data(tmp_path):
    root = tmp_path / "Agentic"
    make_workspace(root)
    terms = set(pg.build(root)["terms"])
    assert {"RootRule", "Shallow00x", "Shallow11x", "DeepThing"} <= terms
    assert not terms & {"ArchivedThing", "DraftThing", "ClaudeThing", "WorktreeThing", "DataThing"}


def test_big_root_breadth_first_under_file_limit(tmp_path, monkeypatch):
    root = tmp_path / "Agentic"
    make_workspace(root)
    monkeypatch.setattr(pg, "MAX_FILES", 6)
    result = pg.build(root, force=True)
    assert result["truncated"] is True and result["files"] == 6
    # Ближние к корню файлы первыми, глубокий — за лимитом.
    assert "RootRule" in result["terms"] and "DeepThing" not in result["terms"]


def test_fresher_folder_goes_first_on_same_level(tmp_path, monkeypatch):
    root = tmp_path / "ws"
    for name in ("aaa_old", "zzz_new"):
        (root / name).mkdir(parents=True)
        (root / name / "n.md").write_text(f"# Term{name.split('_')[0].upper()}x\n", encoding="utf-8")
    past = time.time() - 3600
    os.utime(root / "aaa_old", (past, past))
    monkeypatch.setattr(pg, "MAX_FILES", 1)
    result = pg.build(root, force=True)
    assert result["terms"] == ["TermZZZx"]


def test_looks_like_data():
    assert pg.looks_like_data([f"{i}.png" for i in range(25)])
    assert not pg.looks_like_data([f"{i}.png" for i in range(5)])
    assert not pg.looks_like_data([f"{i}.md" for i in range(25)])


def test_slow_scan_does_not_block_session_start(tmp_path, monkeypatch):
    """Обход дольше 200 мс уходит в фон: старт берёт прошлый результат и не ждёт."""
    root = tmp_path / "Agentic"
    make_workspace(root)
    assert "RootRule" in pg.ProjectGlossaries().terms(str(root))  # без wait_s — блокирующий обход
    real_build = pg.build
    gate = threading.Event()

    def slow_build(*args, **kwargs):
        gate.wait(5)
        return real_build(*args, **kwargs)

    monkeypatch.setattr(pg, "build", slow_build)
    (root / "fresh.md").write_text("# FreshThing\n", encoding="utf-8")
    # Новый движок (пустая память), кэш на диске есть: прошлый результат без ожидания.
    cold = pg.ProjectGlossaries()
    started = time.monotonic()
    terms = cold.terms(str(root), wait_s=pg.BACKGROUND_WAIT_S)
    assert time.monotonic() - started < 1.0
    assert "RootRule" in terms and "FreshThing" not in terms
    # Кэша нет вовсе: пусто, но тоже без ожидания.
    empty_root = tmp_path / "other"
    make_workspace(empty_root)
    started = time.monotonic()
    assert cold.terms(str(empty_root), wait_s=pg.BACKGROUND_WAIT_S) == []
    assert time.monotonic() - started < 1.0
    # Кэш старше 10 минут, фон доработал — следующая сессия видит свежий результат.
    store = pg.cache_path(root.resolve())
    payload = json.loads(store.read_text(encoding="utf-8"))
    payload["scanned_ts"] = time.time() - 601
    store.write_text(json.dumps(payload), encoding="utf-8")
    gate.set()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and "FreshThing" not in cold.terms(str(root), wait_s=0.05):
        time.sleep(0.05)
    assert "FreshThing" in cold.terms(str(root), wait_s=0.05)


def test_start_with_slow_project_scan_is_prepared_quickly(engine, tmp_path, monkeypatch):
    eng, sink = engine
    root = tmp_path / "Agentic"
    make_workspace(root)
    gate = threading.Event()
    real_build = pg.build
    monkeypatch.setattr(pg, "build", lambda *a, **k: (gate.wait(5), real_build(*a, **k))[1])
    prepared = threading.Event()
    original = eng._prepare

    def spy(session, project, folders=None):
        original(session, project, folders)
        prepared.set()

    eng._prepare = spy
    started = time.monotonic()
    send(eng, cmd="start", id=1, session="s9", language="ru", project=str(root), verify=False)
    assert prepared.wait(3)
    # Подготовка сессии (словарь, модель, VAD) не ждала пятисекундный обход.
    assert time.monotonic() - started < 1.5
    gate.set()
    send(eng, cmd="cancel", id=2, session="s9")
    # Фоновый обход пишет кэш в MOSTIK_HOME: дождаться его, пока подменённый каталог ещё действует,
    # иначе после теста он допишет кэш в настоящую папку данных.
    for thread in threading.enumerate():
        if thread.name.startswith(("mostik-scan-", "mostik-project-glossary")):
            thread.join(10)


def test_hidden_terms_leave_session_glossary(engine, tmp_path):
    """«Скрыть термин»: скрытый термин проекта не попадает в подсказку и в индекс сомнений."""
    eng, sink = engine
    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / "engine.py").write_text("class TermIndex:\n    pass\n\nclass NoisyThing:\n    pass\n", encoding="utf-8")
    index, hotwords = eng._terms_for(str(repo), "ru")
    assert "NoisyThing" in hotwords
    assert any(hit.canonical == "NoisyThing" for hit in index.exact.values())
    send(eng, cmd="hidden_terms", id=1, terms=["NoisyThing", "  "])
    assert sink.lines[-1]["id"] == 1 and sink.lines[-1]["count"] == 1
    index, hotwords = eng._terms_for(str(repo), "ru")
    assert "NoisyThing" not in hotwords and "TermIndex" in hotwords
    assert not any(hit.canonical == "NoisyThing" for hit in index.exact.values())
    send(eng, cmd="hidden_terms", id=2, terms=[])
    assert "NoisyThing" in eng._terms_for(str(repo), "ru")[1]
    send(eng, cmd="hidden_terms", id=3, terms="bad")
    assert sink.lines[-1]["event"] == "error" and sink.lines[-1]["id"] == 3
