"""Уверенность меток говорящих (M15): формула, альтернативы, прогон встречи. Только синтетика."""

from __future__ import annotations

import json
from pathlib import Path

from mostik_engine import meeting as m
from mostik_engine import speaker_confidence as sc

LABELS = {"speaker_0": "Собеседник 1", "speaker_1": "Собеседник 2", "speaker_2": "Собеседник 3"}


def d(start, end, *speakers):
    return {"start": start, "end": end, "speakers": list(speakers)}


def turn(start, end, label, source="system"):
    return {"speaker": label, "label": label, "source": source, "start": start, "end": end, "text": "…"}


def test_full_coverage_by_one_voice_is_certain():
    diar = [d(0, 10, "speaker_0"), d(10, 20, "speaker_1")]
    conf, others = sc.score(0, 10, {"speaker_0"}, diar)
    assert conf == 1.0 and others == {}


def test_half_in_silence_without_rival_is_not_flagged():
    conf, _ = sc.score(0, 10, {"speaker_0"}, [d(0, 5, "speaker_0"), d(30, 40, "speaker_1")])
    assert conf == 0.75 and conf >= sc.REVIEW_BELOW


def test_even_split_with_rival_is_low():
    conf, others = sc.score(0, 10, {"speaker_0"}, [d(0, 4, "speaker_0"), d(4, 8, "speaker_1")])
    assert conf == 0.2 and others == {"speaker_1": 4.0}


def test_mostly_one_voice_passes_and_sixty_forty_does_not():
    assert sc.score(0, 10, {"speaker_0"}, [d(0, 8, "speaker_0"), d(8, 10, "speaker_1")])[0] == 0.7
    assert sc.score(0, 10, {"speaker_0"}, [d(0, 6, "speaker_0"), d(6, 10, "speaker_1")])[0] == 0.4


def test_uncovered_turn_scores_zero():
    """transcriber приписал реплику ближайшему говорящему — диаризация её не покрывала."""
    assert sc.score(10, 12, {"speaker_0"}, [d(0, 5, "speaker_0"), d(20, 25, "speaker_1")])[0] == 0.0


def test_overlap_label_uses_union():
    diar = [d(0, 10, "speaker_0"), d(5, 10, "speaker_1")]
    assert sc.score(0, 10, {"speaker_0", "speaker_1"}, diar)[0] == 1.0


def test_annotate_flags_and_lists_alternatives_by_share():
    diar = [d(0, 4, "speaker_0"), d(4, 7, "speaker_1"), d(7, 8, "speaker_2"), d(20, 30, "speaker_1")]
    turns = [turn(0, 10, "Собеседник 1"), turn(20, 30, "Собеседник 2"), turn(0, 3, "Я", source="mic")]
    flagged = sc.annotate(turns, diar, LABELS)
    assert flagged == 1
    low, sure, mine = turns
    assert low["review"] is True and low["speaker_confidence"] < 0.6
    assert low["speaker_alternatives"] == [{"label": "Собеседник 2", "share": 0.3},
                                           {"label": "Собеседник 3", "share": 0.1}]
    assert sure["speaker_confidence"] == 1.0 and "review" not in sure
    assert "speaker_confidence" not in mine  # «Я» не оценивается


def test_annotate_uses_neighbours_when_window_is_empty():
    diar = [d(0, 5, "speaker_1"), d(20, 25, "speaker_2"), d(30, 40, "speaker_0")]
    turns = [turn(10, 12, "Собеседник 1")]
    sc.annotate(turns, diar, LABELS)
    assert [alt["label"] for alt in turns[0]["speaker_alternatives"]] == ["Собеседник 2", "Собеседник 3"]
    assert all(alt["share"] == 0 for alt in turns[0]["speaker_alternatives"])


def test_single_voice_is_certain_and_no_diarization_is_untouched():
    turns = [turn(10, 12, "Собеседник 1")]
    sc.annotate(turns, [d(0, 5, "speaker_0")], {"speaker_0": "Собеседник 1"})
    assert turns[0]["speaker_confidence"] == 1.0
    bare = [turn(0, 1, "Собеседник 1")]
    assert sc.annotate(bare, None, LABELS) == 0 and "speaker_confidence" not in bare[0]


def test_load_diarization_reads_speakers_json(tmp_path):
    (tmp_path / "speakers.json").write_text(json.dumps({"turns": [
        {"start": 0, "end": 1, "speakers": ["speaker_0"]}, {"start": 2, "end": 1, "speakers": ["x"]},
        {"start": 3, "end": 4, "speakers": []}]}), encoding="utf-8")
    assert sc.load_diarization(tmp_path) == [d(0.0, 1.0, "speaker_0")]
    assert sc.load_diarization(tmp_path / "нет") is None


def test_run_meeting_writes_confidence_to_transcript(tmp_path, monkeypatch):
    monkeypatch.setattr(m, "diarization_problem", lambda **kwargs: None)  # прогон поддельный, fluidaudiocli не нужен
    out = tmp_path / "2026-10-11-120000"
    segments = {
        "mic": [{"start": 0.0, "end": 2.0, "text": "Начнём.", "speakers": []}],
        "system": [
            {"start": 3.0, "end": 9.0, "text": "Сначала про сроки.", "speakers": ["speaker_0"]},
            {"start": 12.0, "end": 16.0, "text": "А я про деньги.", "speakers": ["speaker_1"]},
            {"start": 20.0, "end": 22.0, "text": "Согласен.", "speakers": ["speaker_0"]},
        ],
    }
    system_out = out / "system-transcript"
    system_out.mkdir(parents=True)
    (system_out / "speakers.json").write_text(json.dumps({"turns": [
        d(3, 9, "speaker_0"), d(12, 16, "speaker_1"), d(20, 20.8, "speaker_0"), d(20.8, 22, "speaker_1")]}),
        encoding="utf-8")
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 30.0))
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: None)
    monkeypatch.setattr(m, "load_segments", lambda output: segments[output.name.split("-")[0]])
    result = m.run_meeting({"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru"},
                           lambda event: None)
    data = json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))
    by_text = {t["text"]: t for t in data["turns"]}
    assert data["speaker_review"] == 1
    assert by_text["Согласен."]["review"] is True
    assert by_text["Согласен."]["speaker_alternatives"][0]["label"] == "Собеседник 2"
    assert by_text["Сначала про сроки."]["speaker_confidence"] == 1.0
    assert by_text["Сначала про сроки."]["label"] == "Собеседник 1"
    assert "label" not in by_text["Начнём."] and "voices" not in data
