"""Имена по времени из окна ВКС → метки диаризации (прототип для Zoom)."""

from __future__ import annotations

import json
from pathlib import Path

from mostik_engine import meeting as m
from mostik_engine import speaker_timeline as st


def write_timeline(folder: Path, rows: list[dict]) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    lines = [json.dumps(row, ensure_ascii=False) for row in rows] + ["не json", '{"at": -1, "active": ["X"]}']
    (folder / st.TIMELINE_FILE).write_text("\n".join(lines) + "\n", encoding="utf-8")


def turn(label: str, start: float, end: float, source: str = "system") -> dict:
    return {"speaker": label, "label": label if source == "system" else None, "source": source,
            "start": start, "end": end, "text": "…"}


def test_intervals_skip_self_overlap_and_silence():
    events = [
        {"at": 0.0, "active": ["Пётр"], "self": [], "source": "zoom"},
        {"at": 5.0, "active": ["Игорь"], "self": ["Игорь"], "source": "zoom"},
        {"at": 8.0, "active": ["Пётр", "Мария"], "self": [], "source": "zoom"},
        {"at": 9.0, "active": [], "self": [], "source": "zoom"},
        {"at": 10.0, "active": ["Мария"], "self": [], "source": "zoom"},
    ]
    spans = st.intervals(events, end=14.0)
    assert [(s.name, s.start, s.end) for s in spans] == [("Пётр", 0.0, 5.0), ("Мария", 10.0 - st.LEAD_S, 14.0)]


def test_last_snapshot_does_not_run_forever():
    spans = st.intervals([{"at": 0.0, "active": ["Пётр"], "self": [], "source": ""}], end=600.0)
    assert spans[0].end == st.MAX_TAIL_S


def test_match_names_dominant_label_and_leaves_ambiguous():
    spans = [st.Interval(0, 20, "Пётр"), st.Interval(20, 30, "Мария"), st.Interval(30, 40, "Олег")]
    turns = [
        turn("Собеседник 1", 1, 9), turn("Собеседник 1", 11, 19),     # 16 с под Петром
        turn("Собеседник 2", 21, 26),                                  # 5 с под Марией
        turn("Собеседник 3", 27, 34),                                  # 3 с Мария, 4 с Олег — перевес меньше 2×
        turn("Собеседник 1 + Собеседник 2", 2, 8),                      # перекрытие не в счёт
        turn("Я", 0, 40, source="mic"),
    ]
    named = st.match(turns, spans, source="zoom")
    assert {label: n.name for label, n in named.items()} == {"Собеседник 1": "Пётр", "Собеседник 2": "Мария"}
    assert named["Собеседник 1"].share == 1.0 and named["Собеседник 1"].source == "zoom"


def test_match_needs_enough_speech_and_share():
    spans = [st.Interval(0, 3, "Пётр")]
    assert st.match([turn("Собеседник 1", 0, 3)], spans) == {}            # меньше MIN_SECONDS
    spans = [st.Interval(0, 5, "Пётр")]
    assert st.match([turn("Собеседник 1", 0, 20)], spans) == {}           # 5 из 20 с — меньше половины


def test_names_case_and_spaces_merge():
    spans = [st.Interval(0, 3, "Пётр  Иванов"), st.Interval(3, 6, "пётр иванов")]
    named = st.match([turn("Собеседник 1", 0, 6)], spans)
    assert named["Собеседник 1"].name == "Пётр Иванов" and named["Собеседник 1"].seconds == 6


def test_run_meeting_names_labels_from_timeline(tmp_path, monkeypatch):
    out = tmp_path / "meet"
    write_timeline(out, [
        {"at": 0.0, "active": ["Пётр Иванов"], "source": "zoom"},
        {"at": 10.0, "active": ["Игорь (Я)"], "self": ["Игорь (Я)"], "source": "zoom"},
        {"at": 12.0, "active": ["Мария"], "source": "zoom"},
    ])
    segments = {
        "mic": [{"start": 10.0, "end": 12.0, "text": "Моя реплика."}],
        "system": [
            {"start": 0.5, "end": 9.5, "text": "Раз.", "speakers": ["speaker_1"]},
            {"start": 12.5, "end": 19.0, "text": "Два.", "speakers": ["speaker_2"]},
        ],
    }
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 20.0))
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: None)
    monkeypatch.setattr(m, "load_segments", lambda output: segments[output.name.split("-")[0]])
    result = m.run_meeting({"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru",
                            "attendees": ["Пётр Иванов", "Мария"]}, lambda event: None)
    data = json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))
    assert [t["speaker"] for t in data["turns"]] == ["Пётр Иванов", "Я", "Мария"]
    assert [t.get("label") for t in data["turns"]] == ["Собеседник 1", None, "Собеседник 2"]
    assert data["speaker_names"] == {"Собеседник 1": "Пётр Иванов", "Собеседник 2": "Мария"}
    assert data["speaker_timeline"]["Собеседник 1"]["source"] == "zoom"
    assert "Пётр Иванов" in (out / "transcript.md").read_text(encoding="utf-8")


def test_run_meeting_without_timeline_unchanged(tmp_path, monkeypatch):
    out = tmp_path / "meet"
    segments = {"mic": [], "system": [{"start": 0.0, "end": 9.0, "text": "Раз.", "speakers": ["speaker_1"]}]}
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 10.0))
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: None)
    monkeypatch.setattr(m, "load_segments", lambda output: segments[output.name.split("-")[0]])
    result = m.run_meeting({"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru"},
                           lambda event: None)
    data = json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))
    assert data["speaker_names"] == {} and "speaker_timeline" not in data


def test_unmuted_is_fallback_when_no_active_marker():
    events = [
        {"at": 0.0, "active": [], "unmuted": [], "self": [], "source": "zoom"},
        {"at": 40.0, "active": [], "unmuted": ["Alex Morgan"], "self": [], "source": "zoom"},
        {"at": 70.0, "active": [], "unmuted": ["Пётр", "Мария"], "self": [], "source": "zoom"},
        {"at": 80.0, "active": ["Мария"], "unmuted": ["Пётр", "Мария"], "self": [], "source": "zoom"},
    ]
    spans = st.intervals(events, end=90.0)
    assert [(s.name, s.start, s.end) for s in spans] == [("Alex Morgan", 40.0, 70.0), ("Мария", 80.0 - st.LEAD_S, 90.0)]
    named = st.match([turn("Собеседник 1", 50.2, 60.0)], spans)
    assert named["Собеседник 1"].name == "Alex Morgan"


def test_roster_names_single_interlocutor_one_on_one(tmp_path):
    # Звонок один на один: собеседница сказала пару фраз, а её плитка всё это время «muted».
    rows = [
        {"at": 0.0, "active": [], "unmuted": [], "present": ["Игорь"], "self": [], "source": "zoom"},
        {"at": 10.0, "active": [], "unmuted": [], "present": ["Игорь"], "self": ["Игорь"], "source": "zoom"},
        {"at": 20.0, "active": [], "unmuted": [], "present": ["Игорь", "Ольга"], "self": ["Игорь"], "source": "zoom"},
        {"at": 40.0, "active": [], "unmuted": ["Ольга"], "present": ["Игорь", "Ольга"], "self": ["Игорь"], "source": "zoom"},
    ]
    write_timeline(tmp_path, rows)
    turns = [turn("Собеседник 1", 19.5, 22.0), turn("Собеседник 1", 25.0, 26.0), turn("Я", 22.5, 38.0, "mic")]
    named = st.names_for(tmp_path, turns, duration=50.0)
    assert {k: (v.name, v.source) for k, v in named.items()} == {"Собеседник 1": ("Ольга", "zoom:roster")}


def test_roster_needs_known_self_one_voice_and_one_other(tmp_path):
    turns = [turn("Собеседник 1", 10.0, 12.0)]
    base = {"at": 0.0, "active": [], "unmuted": [], "source": "zoom"}
    events = [{**base, "present": ["Игорь", "Ольга"], "self": []}]
    assert st.roster_name(turns, events) == {}                                   # кто из двоих я — неизвестно
    assert st.roster_name(turns, events, own=["игорь"])["Собеседник 1"].name == "Ольга"  # своё имя из календаря
    three = [{**base, "present": ["Игорь", "Ольга", "Пётр"], "self": ["Игорь"]}]
    assert st.roster_name(turns, three) == {}                                    # собеседников двое
    two_voices = turns + [turn("Собеседник 2", 13.0, 15.0)]
    assert st.roster_name(two_voices, [{**base, "present": ["Игорь", "Ольга"], "self": ["Игорь"]}]) == {}


def test_roster_folds_short_fragments_into_the_one_interlocutor(tmp_path):
    # Звонок один на один: Ольга — «Собеседник 2», обрывки на стыках — «Собеседник 1».
    rows = [
        {"at": 5.0, "active": [], "unmuted": [], "present": ["Игорь"], "self": ["Игорь"], "source": "zoom"},
        {"at": 15.0, "active": [], "unmuted": [], "present": ["Игорь", "Ольга"], "self": ["Игорь"], "source": "zoom"},
        {"at": 20.0, "active": [], "unmuted": ["Ольга"], "present": ["Игорь", "Ольга"], "self": ["Игорь"], "source": "zoom"},
        {"at": 41.0, "active": [], "unmuted": [], "present": ["Игорь", "Ольга"], "self": ["Игорь"], "source": "zoom"},
        {"at": 45.0, "active": [], "unmuted": ["Ольга"], "present": ["Игорь", "Ольга"], "self": ["Игорь"], "source": "zoom"},
    ]
    write_timeline(tmp_path, rows)
    turns = [turn("Собеседник 1", 18.0, 20.0), turn("Собеседник 2", 20.0, 34.0), turn("Собеседник 1", 34.0, 35.0),
             turn("Собеседник 1", 40.5, 41.5), turn("Собеседник 2", 42.0, 66.0), turn("Собеседник 1", 66.0, 67.0)]
    named = st.names_for(tmp_path, turns, duration=75.0)
    assert {k: v.name for k, v in named.items()} == {"Собеседник 1": "Ольга", "Собеседник 2": "Ольга"}
    assert named["Собеседник 2"].source == "zoom"          # по ленте — сильнее состава
    assert named["Собеседник 1"].source == "zoom:roster"


def test_roster_keeps_quiet_when_second_voice_is_substantial():
    base = {"at": 0.0, "active": [], "unmuted": [], "source": "zoom", "present": ["Игорь", "Ольга"], "self": ["Игорь"]}
    turns = [turn("Собеседник 1", 0.0, 20.0), turn("Собеседник 2", 20.0, 30.0)]   # треть речи — второй человек?
    assert st.roster_name(turns, [base]) == {}
