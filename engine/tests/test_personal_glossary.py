"""Личный словарь: remember/forget/list и импорт из transcriber."""
from __future__ import annotations

import yaml

from mostik_engine import personal_glossary as pgm
from mostik_engine.personal_glossary import PersonalGlossary


def test_remember_list_forget(tmp_path):
    store = PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False)
    assert store.list() == []
    store.remember("пара кит", "Parakeet")
    store.remember("паракит", "Parakeet")
    store.remember("пара кит", "Parakeet")  # повтор не дублирует
    listed = store.list()
    assert listed == [
        {"canonical": "Parakeet", "aliases": ["пара кит", "паракит"], "source": "personal",
         "auto_apply": True, "language": None}
    ]
    entries = store.entries("ru")
    assert entries[0].auto_apply and entries[0].aliases == ("пара кит", "паракит")
    # Формат файла — словарь transcriber.
    raw = yaml.safe_load((tmp_path / "glossary.yaml").read_text(encoding="utf-8"))
    assert raw["entries"][0]["canonical"] == "Parakeet"
    assert store.forget("Parakeet") is True
    assert store.forget("Parakeet") is False
    assert store.list() == []


def test_remember_moves_alias_from_other_entry(tmp_path):
    store = PersonalGlossary(tmp_path / "g.yaml", import_transcriber=False)
    store.remember("клод", "Cloud")
    store.remember("клод", "Claude")
    by_name = {item["canonical"]: item for item in store.list()}
    assert by_name["Claude"]["aliases"] == ["клод"]
    assert by_name["Cloud"]["aliases"] == []


def test_import_from_transcriber_on_first_run(tmp_path, monkeypatch):
    curated = tmp_path / "curated.yaml"
    curated.write_text(yaml.safe_dump({"entries": [
        {"canonical": "Obsidian", "aliases": ["обсидиан"], "auto_apply": True},
    ]}, allow_unicode=True), encoding="utf-8")
    learned_ru = tmp_path / "learned.yaml"
    learned_ru.write_text(yaml.safe_dump({"version": 1, "entries": [
        {"canonical": "Obsidian", "aliases": ["абсидиан"], "auto_apply": True},
        {"canonical": "Threads", "aliases": ["трэдс"], "auto_apply": True},
        {"canonical": "Мусор", "aliases": ["мест"], "auto_apply": False},
    ], "pending": [{"aliases": ["x"]}]}, allow_unicode=True), encoding="utf-8")
    learned_en = tmp_path / "learned.en.yaml"
    learned_en.write_text(yaml.safe_dump({"entries": [
        {"canonical": "Mostik", "aliases": ["talk"], "auto_apply": True},
    ]}), encoding="utf-8")
    monkeypatch.setattr(pgm, "CURATED_SOURCE", curated)
    monkeypatch.setattr(pgm, "_learned_store", lambda language: learned_ru if language == "ru" else learned_en)
    store = PersonalGlossary(tmp_path / "home" / "glossary.yaml", import_transcriber=True)
    listed = store.list()
    names = [(item["canonical"], item["source"], item["language"]) for item in listed]
    assert ("Obsidian", "transcriber", "ru") in names
    assert ("Threads", "transcriber-learned", "ru") in names
    assert ("Mostik", "transcriber-learned", "en") in names
    # Выученный «Obsidian» не спорит с выверенным.
    assert sum(1 for item in listed if item["canonical"] == "Obsidian") == 1
    assert [e.canonical for e in store.entries("en")] == ["Mostik"]
    trusted = {e.canonical for e in store.trusted("ru")}
    assert trusted == {"Obsidian", "Threads"}
    assert store.hotwords("ru") == ["Obsidian"]
    # Повторный запуск не импортирует заново.
    store.forget("Threads")
    again = PersonalGlossary(tmp_path / "home" / "glossary.yaml", import_transcriber=True)
    assert "Threads" not in {item["canonical"] for item in again.list()}
