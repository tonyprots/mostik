"""Ремонт говорящих (W17): вся метка — другому говорящему. Данные синтетические, папка — tmp_path."""

from __future__ import annotations

import io
import json

import pytest

from mostik_engine import meeting_speakers as ms
from mostik_engine.personal_glossary import PersonalGlossary
from mostik_engine.server import Engine


def write_meeting(folder):
    folder.mkdir(parents=True, exist_ok=True)
    turns = [
        {"speaker": "Я", "source": "mic", "start": 0.0, "end": 2.0, "text": "Начнём"},
        {"speaker": "Анна", "label": "Собеседник 1", "source": "system", "start": 2.5, "end": 5.0, "text": "Да"},
        {"speaker": "Собеседник 2", "label": "Собеседник 2", "source": "system", "start": 5.5, "end": 8.0,
         "text": "Это я, Анна", "review": True, "speaker_alternatives": [{"label": "Собеседник 1", "share": 0.4}]},
        {"speaker": "Анна + Собеседник 2", "label": "Собеседник 1 + Собеседник 2", "source": "system",
         "start": 8.0, "end": 9.0, "text": "Угу"},
        {"speaker": "Собеседник 3", "label": "Собеседник 3", "source": "system", "start": 9.5, "end": 11.0, "text": "Борис"},
    ]
    document = {
        "id": folder.name, "date": "2026-10-12T15:30", "duration_seconds": 11.0, "marks": [],
        "speaker_names": {"Собеседник 1": "Анна", "Собеседник 2": "Ошибка"},
        "voices": {"suggestions": [{"label": "Собеседник 2", "name": "Вера", "person_id": "p1"}]},
        "turns": [{"id": i, **t} for i, t in enumerate(turns)],
    }
    (folder / "transcript.json").write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
    return folder


def test_merge_moves_every_turn_and_collapses_overlap(tmp_path):
    folder = write_meeting(tmp_path / "2026-10-12-153000")
    result = ms.merge_label(folder, "Собеседник 2", "Собеседник 1")
    assert result["moved"] == 2 and result["speaker"] == "Анна"
    document = json.loads((folder / "transcript.json").read_text(encoding="utf-8"))
    turns = document["turns"]
    assert [t["speaker"] for t in turns] == ["Я", "Анна", "Анна", "Анна", "Собеседник 3"]
    assert turns[3]["label"] == "Собеседник 1", "перекрытие «А + А» схлопнулось"
    assert "review" not in turns[2] and "speaker_alternatives" not in turns[2]
    assert "Собеседник 2" not in document["speaker_names"]
    assert document["voices"]["suggestions"] == []
    assert "Собеседник 2" not in document["participants"]
    markdown = (folder / "transcript.md").read_text(encoding="utf-8")
    assert "**Анна** [00:05] Это я, Анна" in markdown


def test_merge_into_unnamed_label_keeps_label_as_name(tmp_path):
    folder = write_meeting(tmp_path / "m")
    ms.merge_label(folder, "Собеседник 3", "Собеседник 2")
    turns = json.loads((folder / "transcript.json").read_text(encoding="utf-8"))["turns"]
    assert turns[4]["label"] == "Собеседник 2" and turns[4]["speaker"] == "Ошибка"


@pytest.mark.parametrize("source,target", [("Я", "Собеседник 1"), ("Собеседник 1", "Я"),
                                           ("Собеседник 9", "Собеседник 1"), ("Собеседник 1", "Собеседник 1")])
def test_merge_refuses_me_unknown_and_same(tmp_path, source, target):
    folder = write_meeting(tmp_path / "m")
    before = (folder / "transcript.json").read_bytes()
    with pytest.raises(ms.SpeakerEditError):
        ms.merge_label(folder, source, target)
    assert (folder / "transcript.json").read_bytes() == before


def test_speaker_merge_command(tmp_path):
    folder = write_meeting(tmp_path / "m")
    out = io.StringIO()
    engine = Engine(out, pool=object(), verifier=type("V", (), {"stop": lambda self: None})(), polishers={},
                    personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False))
    engine.handle_line(json.dumps({"cmd": "speaker_merge", "id": 7, "folder": str(folder),
                                   "source": "Собеседник 3", "target": "Собеседник 1"}))
    engine.handle_line(json.dumps({"cmd": "speaker_merge", "id": 8, "folder": str(folder),
                                   "source": "Я", "target": "Собеседник 1"}))
    replies = [json.loads(line) for line in out.getvalue().splitlines()]
    ok = next(r for r in replies if r.get("id") == 7)
    assert ok["ok"] and ok["moved"] == 1 and ok["speaker"] == "Анна"
    failed = next(r for r in replies if r.get("id") == 8)
    assert failed["ok"] is False and failed["code"] == "speaker"
