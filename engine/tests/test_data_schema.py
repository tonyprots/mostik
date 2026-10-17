"""Данные между версиями (2026-10-17): манифест встречи прошлой версии читается, миграции только вперёд,
откат на старую версию Mostik не теряет полей новой. Фикстуры в `fixtures/` заморожены: их не правят,
к новой версии схемы добавляют новую папку."""
from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest

from mostik_engine import meeting_folder as mf
from mostik_engine import meeting_store as store

FIXTURES = Path(__file__).resolve().parent / "fixtures"
SCHEMAS = Path(__file__).resolve().parents[2] / "docs" / "schemas"


def _copy(tmp_path: Path, name: str) -> Path:
    shutil.copytree(FIXTURES / name, tmp_path / name)
    return tmp_path / name


def test_meeting_of_v1_reads(tmp_path):
    """Манифест версии 1 (выпуск 0.1.0) читается текущей сборкой."""
    root = _copy(tmp_path, "meeting-v1")
    [record] = store.list_meetings(root)
    assert record.id == "2026-10-17-101500"
    assert record.title == "Планёрка по выпуску"
    assert record.status == "transcribed" and record.format == "m10"
    assert record.attendees == ["Алекс Пример", "Сэм Образец"]
    assert not record.sensitive
    full = store.get(record.id, root)
    assert [turn["speaker"] for turn in store.turns(full)][:2] == ["Алекс Пример", "Сэм Образец"]
    manifest = mf.read_manifest(root / record.id)
    assert manifest["version"] == mf.VERSION == 1
    required = json.loads((SCHEMAS / "meeting-manifest.schema.json").read_text())["required"]
    assert set(required) <= set(manifest)


def test_update_keeps_fields_and_version_of_newer_build(tmp_path):
    """Откат: старая сборка пишет в манифест новой — её ключи и версия остаются."""
    folder = _copy(tmp_path, "meeting-v1") / "2026-10-17-101500"
    raw = json.loads((folder / "manifest.json").read_text())
    raw.update(version=5, future_block={"kept": True})
    raw["transcript"]["future_flag"] = "x"
    (folder / "manifest.json").write_text(json.dumps(raw, ensure_ascii=False))
    assert mf.read_manifest(folder)["version"] == 5, "версия новее — без «миграции назад»"
    mf.update_manifest(folder, {"title": "Новое название", "transcript": {"attempts": 2}})
    after = json.loads((folder / "manifest.json").read_text())
    assert after["version"] == 5 and after["future_block"] == {"kept": True}
    assert after["transcript"]["future_flag"] == "x" and after["transcript"]["attempts"] == 2
    assert after["title"] == "Новое название"


def test_migrations_go_forward_step_by_step(tmp_path, monkeypatch):
    """Механизм миграций: версия 1 → 3 двумя шагами, старое поле не удаляется в той же версии."""
    calls = []

    def one_to_two(data):
        calls.append(1)
        return {**data, "new_title": data.get("title")}  # старое `title` остаётся

    def two_to_three(data):
        calls.append(2)
        return {**data, "extra": True}

    monkeypatch.setattr(mf, "VERSION", 3)
    monkeypatch.setattr(mf, "MIGRATIONS", {1: one_to_two, 2: two_to_three})
    folder = _copy(tmp_path, "meeting-v1") / "2026-10-17-101500"
    manifest = mf.read_manifest(folder)
    assert calls == [1, 2] and manifest["version"] == 3
    assert manifest["title"] == manifest["new_title"] == "Планёрка по выпуску" and manifest["extra"]
    record = store.load(folder)
    assert record.manifest["version"] == 3, "чтение для агентов и MCP — тоже через миграции"
    mf.update_manifest(folder, {})
    assert json.loads((folder / "manifest.json").read_text())["version"] == 3


def test_missing_migration_step_is_loud(monkeypatch):
    monkeypatch.setattr(mf, "VERSION", 2)
    monkeypatch.setattr(mf, "MIGRATIONS", {})
    with pytest.raises(RuntimeError, match="1 → 2"):
        mf.upgrade_manifest({"version": 1})


def test_fixture_is_synthetic():
    """Фикстура не из реальной встречи: только вымышленные имена."""
    text = "".join(p.read_text(encoding="utf-8") for p in (FIXTURES / "meeting-v1").rglob("*.json"))
    assert "Пример" in text and "Образец" in text
