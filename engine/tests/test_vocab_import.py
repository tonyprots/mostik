"""L6: импорт словаря из Handy, Wispr Flow (синтетическая база), CSV и строк; команды движка."""
from __future__ import annotations

import json
import sqlite3

import pytest

from mostik_engine import vocab_import
from mostik_engine.personal_glossary import PersonalGlossary
from mostik_engine.vocab_import import ImportEntry, parse_csv, parse_lines, read_handy, read_wispr, split_new
from test_protocol import Sink, send  # noqa: F401
from test_protocol import engine  # noqa: F401 — фикстура


def test_handy_custom_words_only(tmp_path):
    path = tmp_path / "settings_store.json"
    path.write_text(json.dumps({"settings": {
        "custom_words": ["Mostik", " GigaAM ", "", "Mostik", 42],
        "post_process_api_keys": {"openai": "sk-test"},
    }}), encoding="utf-8")
    assert read_handy(path) == [ImportEntry("Mostik"), ImportEntry("GigaAM")]


def test_handy_without_words(tmp_path):
    path = tmp_path / "settings_store.json"
    path.write_text(json.dumps({"settings": {"custom_words": None}}), encoding="utf-8")
    assert read_handy(path) == []
    path.write_text("not json", encoding="utf-8")
    with pytest.raises(vocab_import.VocabImportError):
        read_handy(path)


def _wispr_db(path):
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute(
        "CREATE TABLE Dictionary (id INTEGER PRIMARY KEY, phrase TEXT, replacement TEXT, isDeleted INTEGER, isSnippet INTEGER)")
    connection.executemany("INSERT INTO Dictionary (phrase, replacement, isDeleted, isSnippet) VALUES (?, ?, ?, ?)", [
        ("Kubernetes", None, 0, 0),
        ("клод", "Claude", 0, 0),
        ("старое", None, 1, 0),
        ("сниппет", "длинный текст", 0, 1),
        ("гигам", "", 0, 0),
    ])
    connection.commit()
    return connection


def test_wispr_reads_a_copy_and_skips_deleted_and_snippets(tmp_path):
    db = tmp_path / "flow.sqlite"
    connection = _wispr_db(db)  # открыта: данные в WAL, как у работающего приложения
    try:
        before = db.read_bytes()
        entries = read_wispr(db)
        assert db.read_bytes() == before
    finally:
        connection.close()
    assert entries == [ImportEntry("Kubernetes"), ImportEntry("Claude", "клод"), ImportEntry("гигам")]


def test_wispr_wrong_schema(tmp_path):
    db = tmp_path / "flow.sqlite"
    sqlite3.connect(db).execute("CREATE TABLE Other (x)").connection.commit()
    with pytest.raises(vocab_import.VocabImportError):
        read_wispr(db)


def test_csv_one_and_two_columns_with_header():
    text = "﻿phrase,replacement\nклод,Claude\n\"пара, кит\",Parakeet\nMostik\n"
    assert parse_csv(text) == [ImportEntry("Claude", "клод"), ImportEntry("Parakeet", "пара, кит"),
                               ImportEntry("Mostik")]


def test_lines_from_clipboard():
    text = "Mostik\n\n- GigaAM\nклод → Claude\nпара кит -> Parakeet\n" + "x" * 200 + "\n"
    assert parse_lines(text) == [ImportEntry("Mostik"), ImportEntry("GigaAM"), ImportEntry("Claude", "клод"),
                                 ImportEntry("Parakeet", "пара кит")]


def test_split_new_counts_duplicates():
    existing = [{"canonical": "Claude", "aliases": ["клод"]}, {"canonical": "Mostik", "aliases": []}]
    fresh, duplicates = split_new(
        [ImportEntry("Claude", "клод"), ImportEntry("Claude", "клауд"), ImportEntry("Mostik"), ImportEntry("X")],
        existing)
    assert fresh == [ImportEntry("Claude", "клауд"), ImportEntry("X")]
    assert duplicates == 2


def test_detect_reads_metadata_only(tmp_path, monkeypatch):
    monkeypatch.setattr(vocab_import, "DEFAULT_PATHS", {"handy": tmp_path / "h.json", "wispr": tmp_path / "w.sqlite"})
    (tmp_path / "h.json").write_text("{}", encoding="utf-8")
    assert vocab_import.detect() == {"handy": True, "wispr": False}


def test_engine_import_preview_then_apply(engine):  # noqa: F811
    eng, sink = engine
    text = "Mostik\nклод → Claude\n"
    send(eng, cmd="glossary_import", id=1, source="lines", text=text)
    preview = sink.wait(lambda line: line.get("id") == 1)
    assert preview["new_count"] == 2 and preview["added"] == 0
    assert eng.personal.list() == []
    send(eng, cmd="glossary_import", id=2, source="lines", text=text, apply=True)
    assert sink.wait(lambda line: line.get("id") == 2)["added"] == 2
    listed = {item["canonical"]: item["aliases"] for item in eng.personal.list()}
    assert listed == {"Mostik": [], "Claude": ["клод"]}
    send(eng, cmd="glossary_import", id=3, source="lines", text=text)
    again = sink.wait(lambda line: line.get("id") == 3)
    assert again["new_count"] == 0 and again["duplicates"] == 2


def test_engine_import_error(engine, tmp_path):  # noqa: F811
    eng, sink = engine
    send(eng, cmd="glossary_import", id=1, source="handy", path=str(tmp_path / "missing.json"))
    error = sink.wait(lambda line: line.get("id") == 1)
    assert error["ok"] is False and error["code"] == "import_failed"


def test_engine_learn_edit_flow(engine):  # noqa: F811
    eng, sink = engine
    for number in (1, 2):
        send(eng, cmd="learn_edit", id=number, inserted="спроси клод про тесты", edited="спроси Claude про тесты",
             language="ru")
    second = sink.wait(lambda line: line.get("id") == 2)
    assert [(s["heard"], s["canonical"], s["count"]) for s in second["suggestions"]] == [("клод", "Claude", 2)]
    send(eng, cmd="learn_decide", id=3, heard="клод", canonical="Claude", language="ru", accept=True)
    assert sink.wait(lambda line: line.get("id") == 3)["suggestions"] == []
    assert {item["canonical"]: item["aliases"] for item in eng.personal.list()} == {"Claude": ["клод"]}
    # Уже в словаре — больше не копится.
    send(eng, cmd="learn_edit", id=4, inserted="спроси клод", edited="спроси Claude", language="ru")
    send(eng, cmd="learn_edit", id=5, inserted="спроси клод", edited="спроси Claude", language="ru")
    assert sink.wait(lambda line: line.get("id") == 5)["suggestions"] == []


def test_engine_learn_reject(engine):  # noqa: F811
    eng, sink = engine
    for number in (1, 2):
        send(eng, cmd="learn_edit", id=number, inserted="открой гигам", edited="открой GigaAM")
    send(eng, cmd="learn_decide", id=3, heard="гигам", canonical="GigaAM", accept=False)
    assert sink.wait(lambda line: line.get("id") == 3)["suggestions"] == []
    assert eng.personal.list() == []
    send(eng, cmd="learn_edit", id=4, inserted="открой гигам", edited="открой GigaAM")
    send(eng, cmd="learn_edit", id=5, inserted="открой гигам", edited="открой GigaAM")
    assert sink.wait(lambda line: line.get("id") == 5)["suggestions"] == []
    send(eng, cmd="learn_suggestions", id=6)
    assert sink.wait(lambda line: line.get("id") == 6)["suggestions"] == []


def test_engine_doubt_reject(engine):  # noqa: F811
    eng, sink = engine
    send(eng, cmd="doubt_reject", id=1, heard="дабт блок", suggestion="DoubtBlock")
    assert sink.wait(lambda line: line.get("id") == 1)["ok"] is True
    assert eng._learning_store().rejected_doubts() == [("дабт блок", "DoubtBlock")]
    send(eng, cmd="doubt_reject", id=2, heard="", suggestion="x")
    assert sink.wait(lambda line: line.get("id") == 2)["ok"] is False


def test_personal_remember_many(tmp_path):
    glossary = PersonalGlossary(tmp_path / "g.yaml", import_transcriber=False)
    assert glossary.remember_many([("", "Mostik"), ("клод", "Claude"), ("x", " ")]) == 2
    assert [item["canonical"] for item in glossary.list()] == ["Mostik", "Claude"]
