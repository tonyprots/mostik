"""Папка встречи как контракт (M10): манифест, meeting.md с YAML, notes.md, миграция, флаг «чувствительная».

Все встречи синтетические, в tmp_path. Схемы из `docs/schemas/` проверяются
маленьким валидатором (jsonschema в окружении нет): type, required, enum,
const, properties, items.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml

from mostik_engine import meeting as m
from mostik_engine import meeting_folder as mf

SCHEMAS = Path(__file__).resolve().parents[2] / "docs" / "schemas"

TYPES = {
    "object": dict, "array": list, "string": str, "boolean": bool,
    "integer": int, "number": (int, float), "null": type(None),
}


def validate(value, schema, path="$"):
    errors = []
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: ожидалось {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} не из {schema['enum']}")
    if "type" in schema:
        kinds = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        ok = any(isinstance(value, TYPES[kind]) and not (kind in ("integer", "number") and isinstance(value, bool))
                 for kind in kinds)
        if not ok:
            return errors + [f"{path}: тип {type(value).__name__}, ожидался {kinds}"]
    if "minimum" in schema and value < schema["minimum"]:
        errors.append(f"{path}: {value!r} < {schema['minimum']}")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: нет {key}")
        for key, sub in schema.get("properties", {}).items():
            if key in value:
                errors += validate(value[key], sub, f"{path}.{key}")
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            errors += validate(item, schema["items"], f"{path}[{index}]")
    return errors


def schema(name):
    return json.loads((SCHEMAS / name).read_text(encoding="utf-8"))


def wav(path: Path, seconds: float = 1.0) -> None:
    path.write_bytes(b"RIFF" + b"\0" * 40 + b"\0" * int(seconds * 32_000))


LEGACY_TRANSCRIPT = {
    "date": "2026-10-09T10:00",
    "title": "Планёрка: \"бюджет\" и сроки",
    "attendees": ["Анна Смирнова"],
    "marks": [{"at": 12.0, "text": "про бюджет"}],
    "duration_seconds": 95.5,
    "language": "ru",
    "participants": ["Я", "Анна Смирнова"],
    "turns": [
        {"speaker": "Я", "source": "mic", "start": 0.0, "end": 4.0, "text": "Начнём?"},
        {"speaker": "Анна Смирнова", "source": "system", "start": 5.0, "end": 9.0, "text": "Да."},
    ],
}

LEGACY_NOTES = {
    "version": 1,
    "last_mode": "detailed",
    "modes": {
        "detailed": {
            "status": "done", "language": "ru", "overview": "Обсудили бюджет.",
            "points": [{"text": "Решили перенести релиз на ноябрь", "refs": [1]},
                       {"text": "Цифры квартала растут", "refs": [0]}],
            "tasks": [
                {"text": "Подготовить смету", "owner": "Я", "assignee": "Анна Смирнова",
                 "assignee_kind": "speaker", "due": "до пятницы", "refs": [1]},
                {"text": "Собрать отзывы", "owner": None, "assignee": None, "assignee_kind": "group",
                 "due": None, "refs": []},
            ],
        }
    },
}


def legacy_folder(root: Path, name: str = "2026-10-09-100000", *, notes: bool = True) -> Path:
    folder = root / name
    folder.mkdir(parents=True)
    wav(folder / "mic.wav")
    wav(folder / "system.wav")
    (folder / "transcript.json").write_text(json.dumps(LEGACY_TRANSCRIPT, ensure_ascii=False), encoding="utf-8")
    (folder / "transcript.md").write_text("# старая расшифровка\n", encoding="utf-8")
    if notes:
        (folder / "notes.json").write_text(json.dumps(LEGACY_NOTES, ensure_ascii=False), encoding="utf-8")
        (folder / "summary.md").write_text("# Сводка\n", encoding="utf-8")
    return folder


def snapshot(folder: Path) -> dict[str, bytes]:
    return {item.name: item.read_bytes() for item in folder.iterdir() if item.is_file()}


def header(folder: Path) -> dict:
    text = (folder / "meeting.md").read_text(encoding="utf-8")
    assert text.startswith("---\n")
    return yaml.safe_load(text.split("---\n")[1])


# --- миграция -------------------------------------------------------------------


def test_migration_adds_contract_without_touching_old_files(tmp_path):
    folder = legacy_folder(tmp_path)
    before = snapshot(folder)
    assert mf.migrate_folder(folder)
    after = snapshot(folder)
    for name, data in before.items():
        assert after[name] == data, f"{name} переписан"
    assert {"manifest.json", "meeting.md", "notes.md"} <= set(after)
    manifest = mf.read_manifest(folder)
    assert validate(manifest, schema("meeting-manifest.schema.json")) == []
    assert manifest["transcript"]["status"] == "done"
    assert manifest["summary"]["status"] == "done"
    assert manifest["title"] == LEGACY_TRANSCRIPT["title"]
    assert manifest["started"].startswith("2026-10-09T10:00:00")
    assert manifest["files"]["meeting_md"] == "meeting.md"
    assert manifest["audio"]["files"] == ["mic.wav", "system.wav"]
    assert not manifest["sensitive"]
    # Второй прогон ничего не меняет.
    assert not mf.migrate_folder(folder)


def test_migrated_meeting_md_header(tmp_path):
    folder = legacy_folder(tmp_path)
    mf.migrate_folder(folder)
    data = header(folder)
    assert validate(data, schema("meeting-frontmatter.schema.json")) == []
    assert data["title"] == 'Планёрка: "бюджет" и сроки'
    assert data["attendees"] == ["Анна Смирнова"]
    assert data["action_items"] == [
        {"assignee": "Анна Смирнова", "task": "Подготовить смету", "due": "до пятницы"},
        {"assignee": "группа", "task": "Собрать отзывы", "due": None},
    ]
    assert data["decisions"] == ["Решили перенести релиз на ноябрь"]
    assert data["sensitive"] is False
    body = (folder / "meeting.md").read_text(encoding="utf-8")
    assert "## Поручения" in body and "- [ ] Подготовить смету — Анна Смирнова; срок: до пятницы" in body
    assert "[расшифровка](transcript.md)" in body
    notes = (folder / "notes.md").read_text(encoding="utf-8")
    assert "## Пометки" in notes and "- 00:12 — про бюджет" in notes


def test_untranscribed_legacy_meeting_is_missing_not_pending(tmp_path):
    folder = tmp_path / "2026-10-08-0930"
    folder.mkdir()
    wav(folder / "mic.wav", 2.0)
    assert mf.migrate_folder(folder)
    manifest = mf.read_manifest(folder)
    assert manifest["transcript"]["status"] == "missing"
    assert manifest["duration_seconds"] == pytest.approx(2.0, abs=0.01)
    assert manifest["started"].startswith("2026-10-08T09:30")
    assert "Расшифровки пока нет." in (folder / "meeting.md").read_text(encoding="utf-8")
    assert header(folder)["action_items"] == []


def test_migrate_all_skips_non_meetings(tmp_path):
    legacy_folder(tmp_path, "2026-10-09-100000")
    legacy_folder(tmp_path, "2026-10-09-110000", notes=False)
    (tmp_path / "clips").mkdir()
    (tmp_path / ".hidden").mkdir()
    stats = mf.migrate_all(tmp_path)
    assert stats == {"scanned": 2, "migrated": 2, "errors": 0}
    assert mf.migrate_all(tmp_path)["migrated"] == 0


# --- чувствительность ----------------------------------------------------------------


def test_sensitive_from_manifest_or_front_matter(tmp_path):
    folder = legacy_folder(tmp_path)
    mf.migrate_folder(folder)
    assert not mf.is_sensitive(folder)
    mf.update_manifest(folder, {"sensitive": True})
    assert mf.is_sensitive(folder)
    mf.update_manifest(folder, {"sensitive": False})
    # Человек поставил флаг в шапке руками — встреча чувствительная и без манифеста.
    path = folder / "meeting.md"
    path.write_text(path.read_text(encoding="utf-8").replace("sensitive: false", "sensitive: true"), encoding="utf-8")
    assert mf.is_sensitive(folder)


def test_regeneration_keeps_human_edit_and_its_sensitive_flag(tmp_path):
    folder = legacy_folder(tmp_path)
    mf.migrate_folder(folder)
    path = folder / "meeting.md"
    edited = path.read_text(encoding="utf-8").replace("sensitive: false", "sensitive: true") + "\nмоя приписка\n"
    path.write_text(edited, encoding="utf-8")
    mf.write_meeting_md(folder)
    backups = list(folder.glob("meeting.edited-*.md"))
    assert len(backups) == 1 and backups[0].read_text(encoding="utf-8") == edited
    assert mf.read_manifest(folder)["sensitive"] is True
    assert header(folder)["sensitive"] is True
    assert "чувствительная" in path.read_text(encoding="utf-8")


def test_app_toggling_sensitive_line_is_not_a_human_edit(tmp_path):
    folder = legacy_folder(tmp_path)
    mf.migrate_folder(folder)
    path = folder / "meeting.md"
    # Так флаг ставит приложение: манифест + строка шапки.
    mf.update_manifest(folder, {"sensitive": True})
    path.write_text(path.read_text(encoding="utf-8").replace("sensitive: false", "sensitive: true"), encoding="utf-8")
    mf.update_manifest(folder, {"sensitive": False})
    path.write_text(path.read_text(encoding="utf-8").replace("sensitive: true", "sensitive: false"), encoding="utf-8")
    mf.write_meeting_md(folder)
    assert not list(folder.glob("meeting.edited-*.md"))
    assert not mf.is_sensitive(folder)


def test_list_meetings_hides_sensitive(tmp_path):
    first = legacy_folder(tmp_path, "2026-10-09-100000")
    second = legacy_folder(tmp_path, "2026-10-09-110000")
    mf.migrate_all(tmp_path)
    mf.update_manifest(first, {"sensitive": True})
    assert [item["id"] for item in mf.list_meetings(tmp_path)] == [second.name]
    assert len(mf.list_meetings(tmp_path, include_sensitive=True)) == 2


# --- YAML и notes.md -------------------------------------------------------------------


def test_yaml_dump_round_trips_awkward_strings():
    data = {"title": 'a: "b" # c\nd', "attendees": ["- x", "yes", "null", "Ёж"], "action_items": [], "n": None,
            "items": [{"assignee": None, "task": "t: 1", "due": "2026-10-12"}], "sensitive": True}
    assert yaml.safe_load(mf.dump_yaml(data)) == data


def test_front_matter_parser_without_yaml(monkeypatch):
    import builtins

    real_import = builtins.__import__

    def no_yaml(name, *args, **kwargs):
        if name == "yaml":
            raise ImportError("нет")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", no_yaml)
    parsed = mf.front_matter('---\ntitle: "Х: у"\nsensitive: true\n---\n# Тело\n')
    assert parsed == {"title": "Х: у", "sensitive": True}


def test_notes_md_keeps_human_text_and_appends_marks_once(tmp_path):
    folder = tmp_path / "meet"
    folder.mkdir()
    mf.ensure_notes_md(folder, "Синк", agenda=["Бюджет", "Найм"], prep="Спросить про сроки")
    text = (folder / "notes.md").read_text(encoding="utf-8")
    assert "## Повестка" in text and "- [ ] Бюджет" in text and "Спросить про сроки" in text
    (folder / "notes.md").write_text(text + "\nмоя строка\n", encoding="utf-8")
    marks = [{"at": 75, "text": "Бюджет"}]
    mf.ensure_notes_md(folder, "Синк", marks=marks)
    mf.ensure_notes_md(folder, "Синк", marks=marks)
    final = (folder / "notes.md").read_text(encoding="utf-8")
    assert "моя строка" in final
    assert final.count("## Пометки") == 1 and "- 01:15 — Бюджет" in final


# --- новая встреча целиком -----------------------------------------------------------


def seg(start, end, text, speakers=None):
    return {"start": start, "end": end, "text": text, "speakers": speakers or []}


def test_run_meeting_writes_whole_contract(tmp_path, monkeypatch):
    out = tmp_path / "2026-10-11-153000"
    segments = {
        "mic": [seg(0.0, 2.0, "Привет, начнём.")],
        "system": [seg(5.0, 8.0, "Слышно хорошо.", ["speaker_0"])],
    }
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 60.0))
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: None)
    monkeypatch.setattr(m, "load_segments", lambda output: segments[output.name.split("-")[0]])
    result = m.run_meeting({
        "mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru",
        "title": "Синк", "attendees": [{"name": "Антон", "self": True}, "Иван"],
        "marks": [{"at": 4, "text": "Бюджет"}], "agenda": ["Бюджет", "Найм"],
        "calendar": {"event_id": "e1@1", "title": "Синк", "start": "2026-10-11T15:30:00+03:00",
                     "end": "2026-10-11T16:00:00+03:00", "link": "https://telemost.yandex.ru/j/123"},
    }, lambda event: None)
    assert result["manifest"].endswith("manifest.json")
    manifest = mf.read_manifest(out)
    assert validate(manifest, schema("meeting-manifest.schema.json")) == []
    assert manifest["transcript"] == {**manifest["transcript"], "status": "done", "attempts": 1}
    assert manifest["title"] == "Синк" and manifest["title_source"] == "calendar"
    assert manifest["attendees"] == [{"name": "Антон", "self": True}, {"name": "Иван", "self": False}]
    assert manifest["calendar"]["link"].startswith("https://telemost")
    transcript = json.loads((out / "transcript.json").read_text(encoding="utf-8"))
    assert validate(transcript, schema("meeting-transcript.schema.json")) == []
    assert [turn["id"] for turn in transcript["turns"]] == [0, 1]
    data = header(out)
    assert data["attendees"] == ["Антон", "Иван"]
    notes = (out / "notes.md").read_text(encoding="utf-8")
    assert "- [ ] Найм" in notes and "- 00:04 — Бюджет" in notes
    assert "Ссылка на звонок: https://telemost.yandex.ru/j/123" in (out / "meeting.md").read_text(encoding="utf-8")


def test_run_meeting_failure_marks_manifest(tmp_path, monkeypatch):
    out = tmp_path / "2026-10-11-160000"

    def boom(command, **kwargs):
        raise RuntimeError("transcriber упал")

    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 10.0))
    monkeypatch.setattr(m, "run_track", boom)
    with pytest.raises(RuntimeError):
        m.run_meeting({"mic": "/m.wav", "system": None, "out_dir": str(out), "language": "ru"}, lambda e: None)
    manifest = mf.read_manifest(out)
    assert manifest["transcript"]["status"] == "failed"
    assert "transcriber упал" in manifest["transcript"]["error"]
    assert manifest["transcript"]["attempts"] == 1
    assert manifest["transcript"]["code"] is None


def test_memory_failure_code_in_manifest_and_cleared_on_retry(tmp_path, monkeypatch):
    """Код `diarization_memory` переживает перезапуск приложения и сбрасывается новым прогоном."""
    out = tmp_path / "2026-10-11-170000"

    def oom(command, **kwargs):
        raise m.MeetingTrackError("diarization_memory", "Не хватило памяти для модели голосов.")

    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 10.0))
    monkeypatch.setattr(m, "run_track", oom)
    with pytest.raises(m.MeetingTrackError):
        m.run_meeting({"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru"}, lambda e: None)
    assert mf.read_manifest(out)["transcript"]["code"] == "diarization_memory"

    def other(command, **kwargs):
        raise RuntimeError("диск полон")

    monkeypatch.setattr(m, "run_track", other)
    with pytest.raises(RuntimeError):
        m.run_meeting({"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru",
                       "diarize": False}, lambda e: None)
    transcript = mf.read_manifest(out)["transcript"]
    assert transcript["code"] is None and transcript["attempts"] == 2


def test_after_ai_updates_summary_and_header(tmp_path):
    folder = legacy_folder(tmp_path, notes=False)
    mf.migrate_folder(folder)
    assert header(folder)["action_items"] == []
    (folder / "notes.json").write_text(json.dumps(LEGACY_NOTES, ensure_ascii=False), encoding="utf-8")
    mf.after_ai(folder)
    assert mf.read_manifest(folder)["summary"]["status"] == "done"
    assert len(header(folder)["action_items"]) == 2


# --- M12: сегменты дорожек ------------------------------------------------------------


def pcm_wav(path: Path, samples: list[int], rate: int = 16_000) -> None:
    import wave as wave_mod

    with wave_mod.open(str(path), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(rate)
        writer.writeframes(b"".join(int(value).to_bytes(2, "little", signed=True) for value in samples))


def read_samples(path: Path) -> list[int]:
    import wave as wave_mod

    with wave_mod.open(str(path), "rb") as reader:
        data = reader.readframes(reader.getnframes())
    return [int.from_bytes(data[i:i + 2], "little", signed=True) for i in range(0, len(data), 2)]


def test_join_segments_places_by_offset_and_trims_overlap(tmp_path):
    pcm_wav(tmp_path / "mic.wav", [1] * 10, rate=10)
    pcm_wav(tmp_path / "mic.2.wav", [2] * 5, rate=10)
    pcm_wav(tmp_path / "mic.3.wav", [3] * 4, rate=10)
    joined = m.join_segments([(tmp_path / "mic.wav", 0.0), (tmp_path / "mic.2.wav", 1.5),
                              (tmp_path / "mic.3.wav", 1.8)], tmp_path / "out.wav")
    # 0–1 с — первый, 1–1.5 — тишина, 1.5–1.8 — второй (хвост обрезан третьим), дальше третий.
    assert read_samples(joined) == [1] * 10 + [0] * 5 + [2] * 3 + [3] * 4


def test_track_segments_from_manifest_and_payload(tmp_path):
    folder = tmp_path / "2026-10-11-170000"
    folder.mkdir()
    pcm_wav(folder / "mic.wav", [5] * 16)
    mf.update_manifest(folder, {"recording": {"segments": [
        {"track": "mic", "file": "mic.2.wav", "offset_seconds": 3.0},
        {"track": "mic", "file": "mic.wav", "offset_seconds": 0},
        {"track": "system", "file": "system.wav", "offset_seconds": 0},
    ]}})
    parts = m.track_segments({}, folder)
    assert parts["mic"] == [(folder / "mic.wav", 0.0), (folder / "mic.2.wav", 3.0)]
    explicit = m.track_segments({"segments": {"system": [{"file": "/abs/system.wav", "offset_seconds": 0}]}}, folder)
    assert explicit == {"system": [(Path("/abs/system.wav"), 0.0)]}
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    paths = m.assemble_tracks({}, folder, scratch)
    # Второго сегмента микрофона на диске нет — склейка из одного, системной дорожки нет вовсе.
    assert paths == {"mic": str(scratch / "mic.joined.wav")}
    assert len(read_samples(Path(paths["mic"]))) == 16


def test_run_meeting_uses_joined_track(tmp_path, monkeypatch):
    out = tmp_path / "2026-10-11-180000"
    out.mkdir()
    pcm_wav(out / "mic.wav", [100] * 16_000)
    pcm_wav(out / "mic.2.wav", [100] * 16_000)
    seen = {}

    def fake_track(command, **kwargs):
        audio = Path(command[command.index("--mode") - 1])
        seen[kwargs["track"]] = len(read_samples(audio))

    monkeypatch.setattr(m, "run_track", fake_track)
    monkeypatch.setattr(m, "load_segments", lambda output: [])
    monkeypatch.setattr(m, "wav_stats", lambda path: (5.0, -20.0))
    m.run_meeting({"mic": str(out / "mic.wav"), "system": None, "out_dir": str(out), "language": "ru",
                   "segments": {"mic": [{"file": "mic.wav", "offset_seconds": 0},
                                        {"file": "mic.2.wav", "offset_seconds": 3}]}}, lambda event: None)
    assert seen["mic"] == 4 * 16_000
    assert not any(item.name.endswith(".joined.wav") for item in out.iterdir())


def test_notes_md_waits_for_agent_lock(tmp_path):
    """`notes.md` пишется под тем же flock, что и заметки MCP-агента (`meeting_store.append_note`)."""
    import fcntl
    import threading
    import time

    path = tmp_path / mf.NOTES_MD
    with open(path, "a+", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        worker = threading.Thread(target=mf.ensure_notes_md, args=(tmp_path, "Синк"),
                                  kwargs={"marks": [{"time": 5, "text": "решили"}]})
        worker.start()
        time.sleep(0.2)
        assert path.read_text(encoding="utf-8") == ""
        handle.write("# Заметки: Синк\n\n## агент\n\nтекст агента\n")
        handle.flush()
        fcntl.flock(handle, fcntl.LOCK_UN)
    worker.join(5)
    text = path.read_text(encoding="utf-8")
    assert text.startswith("# Заметки: Синк\n\n## агент\n\nтекст агента\n")
    assert "решили" in text


def test_schemas_know_every_value_the_engine_writes():
    """Коды без разделения по голосам и тема из сводки — в схемах, а не только в коде."""
    transcript = schema("meeting-transcript.schema.json")["properties"]["diarization"]["properties"]["code"]
    for code in (m.DIARIZATION_UNAVAILABLE, m.DIARIZATION_FAILED):
        assert validate(code, transcript) == []
    manifest = schema("meeting-manifest.schema.json")["properties"]
    assert validate("summary", manifest["title_source"]) == []
    assert validate(m.DIARIZATION_FAILED, manifest["transcript"]["properties"]["code"]) == []
