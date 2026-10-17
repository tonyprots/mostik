"""Тесты расшифровки встречи: чистые функции и один медленный сквозной прогон.

Сквозной прогон синтезирует разговор голосами macOS (`say`), кладёт его в
две дорожки, как это делает MeetingRecorder, и гоняет настоящий transcriber.
Запуск: PYTHONPATH=engine pytest engine/tests/test_meeting.py [-m slow].
"""

from __future__ import annotations

import datetime as dt
import json
import os
import shutil
import struct
import subprocess
import wave
from pathlib import Path

import numpy as np
import pytest

from mostik_engine import meeting as m


def seg(start, end, text, speakers=None):
    return {"start": start, "end": end, "text": text, "speakers": speakers or []}


# --- похожесть и эхо -------------------------------------------------------


def test_similarity_ignores_case_and_punctuation():
    assert m.text_similarity("Привет, как дела?", "привет как дела") == 1.0


def test_similarity_partial_echo_counts_coverage():
    # Микрофон поймал только хвост фразы собеседника.
    assert m.text_similarity("давайте обсудим бюджет", "итак коллеги давайте обсудим бюджет на квартал") >= 0.6


def test_similarity_short_word_is_not_echo():
    assert m.text_similarity("да", "да конечно давайте начнём встречу") < 0.6


def test_drop_echo_removes_overlapping_similar_segment():
    system = [seg(10.0, 14.0, "мы выпускаем релиз в пятницу", ["speaker_1"])]
    mic = [
        seg(10.5, 13.5, "мы выпускаем релиз в пятницу"),  # эхо
        seg(20.0, 22.0, "мы выпускаем релиз в пятницу"),  # не пересекается — сказал сам
        seg(11.0, 12.0, "а тесты готовы"),  # пересекается, но не похож
    ]
    kept, dropped = m.drop_echo(mic, system)
    assert dropped == 1
    assert [item["start"] for item in kept] == [20.0, 11.0]


def test_drop_echo_matches_against_several_system_segments():
    system = [seg(0, 2, "первая часть фразы"), seg(2, 4, "и вторая часть")]
    mic = [seg(0.5, 3.5, "первая часть фразы и вторая часть")]
    kept, dropped = m.drop_echo(mic, system)
    assert (kept, dropped) == ([], 1)


def test_drop_echo_without_system_keeps_everything():
    mic = [seg(0, 1, "раз"), seg(1, 2, "два")]
    assert m.drop_echo(mic, []) == (mic, 0)


# --- имена и слияние ------------------------------------------------------


def test_speaker_labels_by_first_appearance():
    system = [seg(5, 6, "b", ["speaker_0"]), seg(1, 2, "a", ["speaker_3"]), seg(7, 8, "c", ["speaker_3"])]
    assert m.speaker_labels(system) == {"speaker_3": "Собеседник 1", "speaker_0": "Собеседник 2"}


def test_unlabeled_system_segment_is_one_interlocutor():
    labels = m.speaker_labels([seg(0, 1, "x")])
    assert m.label_system_segment(seg(0, 1, "x"), labels) == "Собеседник 1"


def test_overlap_label():
    labels = m.speaker_labels([seg(0, 1, "x", ["speaker_1"]), seg(1, 2, "y", ["speaker_2"])])
    assert m.label_system_segment(seg(2, 3, "z", ["speaker_1", "speaker_2"]), labels) == "Собеседник 1 + Собеседник 2"


def test_merge_orders_by_start_and_joins_same_speaker():
    mic = [seg(0.0, 2.0, "Привет."), seg(2.5, 4.0, "Начнём?"), seg(20.0, 21.0, "Согласен.")]
    system = [
        seg(5.0, 7.0, "Да, давай.", ["speaker_1"]),
        seg(7.5, 9.0, "Я тоже здесь.", ["speaker_2"]),
        seg(9.2, 10.0, "Слышно?", ["speaker_2"]),
    ]
    turns = m.merge_tracks(mic, system)
    assert [(t["speaker"], t["text"]) for t in turns] == [
        ("Я", "Привет. Начнём?"),
        ("Собеседник 1", "Да, давай."),
        ("Собеседник 2", "Я тоже здесь. Слышно?"),
        ("Я", "Согласен."),
    ]
    assert turns[0]["end"] == 4.0


def test_merge_does_not_join_across_long_pause():
    turns = m.merge_tracks([seg(0, 1, "раз"), seg(10, 11, "два")], [])
    assert len(turns) == 2


def test_merge_does_not_join_across_other_speaker():
    turns = m.merge_tracks([seg(0, 1, "раз"), seg(1.6, 2, "три")], [seg(1.1, 1.5, "два", ["speaker_1"])])
    assert [t["speaker"] for t in turns] == ["Я", "Собеседник 1", "Я"]


# --- разметка ---------------------------------------------------------------


def test_format_clock():
    assert m.format_clock(0) == "00:00"
    assert m.format_clock(65.9) == "01:05"
    assert m.format_clock(3725) == "1:02:05"


def test_render_markdown_header_and_lines():
    turns = [
        {"speaker": "Я", "start": 3.0, "end": 4.0, "text": "Привет"},
        {"speaker": "Собеседник 1", "start": 65.0, "end": 66.0, "text": "Здравствуй"},
    ]
    text = m.render_markdown(turns, date=dt.datetime(2026, 10, 10, 15, 30), duration_seconds=125)
    assert text.startswith("# Встреча 2026-10-10 15:30\n")
    assert "- Длительность: 02:05" in text
    assert "- Участники: Я, Собеседник 1" in text
    assert "**Я** [00:03] Привет" in text
    assert "**Собеседник 1** [01:05] Здравствуй" in text


def test_render_markdown_empty():
    text = m.render_markdown([], date=dt.datetime(2026, 1, 1), duration_seconds=0)
    assert "нет речи" in text


def test_parse_progress_line():
    assert m.parse_progress_line("") is None
    assert m.parse_progress_line("  warnings.warn(") is None
    assert m.parse_progress_line("[12:00:01] Речевых окон: 4") == {"stage": "Речевых окон: 4"}
    assert m.parse_progress_line("[12:00:05] GigaAM: окно 3/17\n") == {
        "stage": "GigaAM: окно 3/17",
        "done": 3,
        "total": 17,
    }


def test_meeting_date_from_folder_name(tmp_path):
    assert m._meeting_date(tmp_path / "2026-10-10-1530") == dt.datetime(2026, 10, 10, 15, 30)


# --- команда --------------------------------------------------------------


def test_build_command_flags(tmp_path):
    system = m.build_command(tmp_path / "s.wav", tmp_path / "o", language="ru", diarize=True, speakers=3)
    assert system[system.index("--mode") + 1] == "max"
    assert system[system.index("--language") + 1] == "ru"
    assert "--diarize" in system and system[system.index("--diarization-backend") + 1] == "auto"
    assert system[system.index("--expected-speakers") + 1] == "3"
    assert "--offline" in system and "--no-learn" in system
    # Р2 Н6: текст встречи не остаётся в общем кэше transcriber (~/.cache/transcriber, 90 дней).
    assert "--no-cache" in system
    if shutil.which("nice"):
        assert system[:3] == ["nice", "-n", "10"]
    if shutil.which("taskpolicy"):
        assert "taskpolicy" in system and system[system.index("taskpolicy") + 1: system.index("taskpolicy") + 3] == ["-c", "utility"]
    mic = m.build_command(tmp_path / "m.wav", tmp_path / "o", language="ru", diarize=False, speakers=3)
    assert "--diarize" not in mic and "--expected-speakers" not in mic
    assert "--no-cache" in mic


# --- WAV --------------------------------------------------------------------


def write_wav(path: Path, samples: np.ndarray, rate: int = 16000) -> None:
    with wave.open(str(path), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(rate)
        writer.writeframes(samples.astype("<i2").tobytes())


def test_track_usable_silent_and_absent(tmp_path):
    silent = tmp_path / "silent.wav"
    write_wav(silent, np.zeros(16000 * 2, dtype=np.int16))
    assert m.track_usable(silent) == (False, 2.0)
    assert m.track_usable(tmp_path / "missing.wav") == (False, 0.0)
    assert m.track_usable(None) == (False, 0.0)


def test_track_usable_tone(tmp_path):
    tone = tmp_path / "tone.wav"
    t = np.arange(16000) / 16000
    write_wav(tone, (np.sin(2 * np.pi * 440 * t) * 8000).astype(np.int16))
    ok, duration = m.track_usable(tone)
    assert ok and duration == pytest.approx(1.0)


def test_repair_wav_header_after_crash(tmp_path):
    path = tmp_path / "crashed.wav"
    write_wav(path, np.ones(16000, dtype=np.int16) * 1000)
    raw = bytearray(path.read_bytes())
    # Так выглядит файл, если приложение упало до финального патча: заглушки.
    raw[4:8] = struct.pack("<I", 0xFFFFFFFF)
    raw[40:44] = struct.pack("<I", 0xFFFFFFFF - 36)
    raw += b"\x01"  # и неполный кадр в хвосте
    path.write_bytes(bytes(raw))
    assert m.repair_wav_header(path) is True
    with wave.open(str(path), "rb") as reader:
        assert reader.getnframes() == 16000
    assert m.repair_wav_header(path) is False


# --- метки, название, участники (M1, M2) ------------------------------------


def test_normalize_marks_sorts_and_drops_bad():
    marks = m.normalize_marks([{"at": 30, "text": " вторая "}, {"at": "x", "text": "битая"},
                               {"at": 5.5, "text": "первая"}, {"at": 9, "text": "  "}, "мусор"])
    assert marks == [{"at": 5.5, "text": "первая"}, {"at": 30.0, "text": "вторая"}]


def test_marks_go_before_first_turn_not_earlier_than_mark():
    turns = [
        {"speaker": "Я", "start": 3.0, "end": 4.0, "text": "Привет"},
        {"speaker": "Собеседник 1", "start": 65.0, "end": 66.0, "text": "Здравствуй"},
    ]
    marks = [{"at": 3.0, "text": "старт"}, {"at": 10.0, "text": "бюджет"}, {"at": 200.0, "text": "итог"}]
    text = m.render_markdown(turns, date=dt.datetime(2026, 10, 10, 15, 30), duration_seconds=210, marks=marks)
    lines = [line for line in text.splitlines() if line]
    me = lines.index("**Я** [00:03] Привет")
    other = lines.index("**Собеседник 1** [01:05] Здравствуй")
    assert lines[me - 1] == "> 📌 00:03 — старт"
    assert lines[other - 1] == "> 📌 00:10 — бюджет"
    assert lines[-1] == "> 📌 03:20 — итог"  # после всех реплик — в конец


def test_title_goes_to_header():
    text = m.render_markdown([], date=dt.datetime(2026, 10, 10, 15, 30), duration_seconds=0, title="Синк Mostik")
    assert text.startswith("# Синк Mostik\n") and "- Дата: 2026-10-10 15:30" in text


def test_calendar_name_only_without_ambiguity():
    one_voice = [seg(0, 1, "x", ["speaker_1"]), seg(2, 3, "y", ["speaker_1"])]
    two_voices = [seg(0, 1, "x", ["speaker_1"]), seg(2, 3, "y", ["speaker_2"])]
    pair = m.normalize_attendees([{"name": "Антон", "self": True}, "Иван Петров"])
    assert m.calendar_name(one_voice, pair) == "Иван Петров"
    assert m.calendar_name(two_voices, pair) is None  # два голоса — номера, не имена
    trio = m.normalize_attendees([{"name": "Антон", "self": True}, "Иван", "Злата"])
    assert m.calendar_name(one_voice, trio) is None  # два кандидата — не угадываем
    # Владелец не помечен: без поля owner двое — двусмысленно, с owner — нет.
    plain = m.normalize_attendees(["Антон", "Иван"])
    assert m.calendar_name(one_voice, plain) is None
    assert m.calendar_name(one_voice, plain, owner="Антон") == "Иван"
    assert m.calendar_name([], pair) is None
    assert m.calendar_name(one_voice, m.normalize_attendees([{"name": "A", "self": True}, "Система"])) is None


def test_channel_words_never_become_speakers():
    turns = [
        {"speaker": "Микрофон", "source": "mic", "start": 0, "end": 1, "text": "a"},
        {"speaker": "system", "source": "system", "start": 1, "end": 2, "text": "b"},
        {"speaker": "Собеседник 1", "source": "system", "start": 2, "end": 3, "text": "c"},
    ]
    fixed = m.apply_speaker_names(turns, {"Собеседник 1": "Иван"})
    assert [turn["speaker"] for turn in fixed] == ["Я", "Собеседник 1", "Иван"]


def test_run_meeting_with_fake_transcriber(tmp_path, monkeypatch):
    """Весь `run_meeting` без моделей: дорожки подменены готовыми сегментами."""
    out = tmp_path / "2026-10-10-1530"
    segments = {
        "mic": [seg(0.0, 2.0, "Привет, начнём."), seg(40.0, 42.0, "Договорились.")],
        # Имя в речи («Я Пётр») не должно стать меткой говорящего.
        "system": [seg(5.0, 8.0, "Я Пётр, слышно хорошо.", ["speaker_0"]),
                   seg(20.0, 25.0, "Бюджет утвердили.", ["speaker_0"])],
    }
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 60.0))
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: None)
    monkeypatch.setattr(m, "load_segments", lambda output: segments[output.name.split("-")[0]])
    events: list[dict] = []
    payload = {
        "mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru", "speakers": None,
        "title": "Синк по бюджету",
        "attendees": [{"name": "Антон Тестов", "self": True}, "Иван Петров"],
        "marks": [{"at": 18, "text": "бюджет"}, {"at": 1, "text": "начало"}],
    }
    result = m.run_meeting(payload, events.append)
    text = Path(result["transcript_md"]).read_text(encoding="utf-8")
    assert text.startswith("# Синк по бюджету\n")
    assert "**Иван Петров** [00:05]" in text and "Пётр**" not in text
    assert "**Я** [00:00] Привет, начнём." in text
    assert "Микрофон" not in text and "Система" not in text
    lines = [line for line in text.splitlines() if line]
    assert lines[lines.index("**Иван Петров** [00:20] Бюджет утвердили.") - 1] == "> 📌 00:18 — бюджет"
    assert lines[lines.index("**Иван Петров** [00:05] Я Пётр, слышно хорошо.") - 1] == "> 📌 00:01 — начало"
    data = json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))
    assert data["marks"] == [{"at": 1.0, "text": "начало"}, {"at": 18.0, "text": "бюджет"}]
    assert data["title"] == "Синк по бюджету"
    assert data["attendees"] == ["Антон Тестов", "Иван Петров"]
    assert data["participants"] == ["Я", "Иван Петров"]
    assert {turn["speaker"] for turn in data["turns"]} == {"Я", "Иван Петров"}
    assert result["speakers"] == 1


def test_run_meeting_two_voices_keeps_numbers(tmp_path, monkeypatch):
    out = tmp_path / "meet"
    segments = {
        "mic": [],
        "system": [seg(0.0, 2.0, "Раз.", ["speaker_1"]), seg(5.0, 6.0, "Два.", ["speaker_2"])],
    }
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 10.0))
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: None)
    monkeypatch.setattr(m, "load_segments", lambda output: segments[output.name.split("-")[0]])
    result = m.run_meeting(
        {"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru",
         "attendees": [{"name": "Я Сам", "self": True}, "Иван"]},
        lambda event: None,
    )
    data = json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))
    assert [turn["speaker"] for turn in data["turns"]] == ["Собеседник 1", "Собеседник 2"]
    assert data["marks"] == [] and data["title"] is None



def test_run_meeting_without_diarization_runs_system_track_plain(tmp_path, monkeypatch):
    """Повтор после нехватки памяти: `diarize: false` — без модели голосов, один собеседник."""
    out = tmp_path / "meet"
    stale = out / "system-transcript"
    stale.mkdir(parents=True)
    (stale / "speakers.json").write_text('{"turns": [{"start": 0, "end": 9, "speakers": ["speaker_7"]}]}')
    segments = {"mic": [seg(0.0, 2.0, "Начнём.")],
                "system": [seg(3.0, 5.0, "Раз."), seg(9.0, 11.0, "Два.")]}
    calls: list[tuple[list[str], dict]] = []
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 20.0))
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: calls.append((command, kwargs)))
    monkeypatch.setattr(m, "load_segments", lambda output: segments[output.name.split("-")[0]])
    result = m.run_meeting(
        {"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru", "speakers": 3,
         "diarize": False, "voice_memory": True},
        lambda event: None,
    )
    assert [kwargs["track"] for _, kwargs in calls] == ["mic", "system"]
    assert all("--diarize" not in command and "--expected-speakers" not in command for command, _ in calls)
    assert all(kwargs["diarize"] is False for _, kwargs in calls)
    assert not (stale / "speakers.json").exists()
    data = json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))
    assert {turn["speaker"] for turn in data["turns"]} == {"Я", "Собеседник 1"}
    assert "voices" not in data


def _fluidaudio(monkeypatch, tmp_path, *, present: bool) -> None:
    """fluidaudiocli для поиска transcriber'а: есть (с моделями) или нет нигде."""
    from audio_transcription import catalog, fluid_models

    binary = tmp_path / "fluidaudiocli"
    if present:
        binary.write_text("#!/bin/sh\n")
        binary.chmod(0o755)
    monkeypatch.setattr(catalog, "fluidaudio_binary_path", lambda *a, **k: binary if present else None)
    monkeypatch.setattr(catalog, "bundled_binary_problem", lambda *a, **k: None)
    monkeypatch.setattr(fluid_models, "ready", lambda *a, **k: present)
    from mostik_engine import fluid_offline

    monkeypatch.setattr(fluid_offline, "models_problem", lambda *a, **k: None if present else "нет моделей FluidAudio")


def _transcriber_without_fluidaudio(command: list[str], **kwargs) -> None:
    """Как настоящий transcriber без fluidaudiocli: прогон с --diarize падает с кодом 2."""
    if "--diarize" in command:
        raise RuntimeError("transcriber (system) завершился с кодом 2: Ошибка: fluidaudio недоступен на этой машине")


def test_run_meeting_without_fluidaudio_transcribes_system_as_one_interlocutor(tmp_path, monkeypatch):
    """Нет fluidaudiocli (ни в PATH, ни в бандле) — встреча расшифрована без разделения по голосам, не ошибка."""
    _fluidaudio(monkeypatch, tmp_path, present=False)
    out = tmp_path / "meet"
    segments = {"mic": [seg(0.0, 2.0, "Начнём.")],
                "system": [seg(3.0, 5.0, "Раз."), seg(9.0, 11.0, "Два.")]}
    calls: list[tuple[list[str], dict]] = []

    def run_track(command, **kwargs):
        calls.append((command, kwargs))
        _transcriber_without_fluidaudio(command, **kwargs)

    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 20.0))
    monkeypatch.setattr(m, "run_track", run_track)
    monkeypatch.setattr(m, "load_segments", lambda output: segments[output.name.split("-")[0]])
    result = m.run_meeting(
        {"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru", "speakers": 3,
         "voice_memory": True},
        lambda event: None,
    )
    assert result["event"] == "meeting_done"
    assert all("--diarize" not in command for command, _ in calls)
    data = json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))
    assert {turn["speaker"] for turn in data["turns"]} == {"Я", "Собеседник 1"}
    assert {turn["source"] for turn in data["turns"]} == {"mic", "system"}
    assert data["diarization"] == {"available": False, "code": m.DIARIZATION_UNAVAILABLE}
    assert "voices" not in data
    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["transcript"]["status"] == "done"
    assert manifest["transcript"]["code"] == "diarization_unavailable"


def test_run_meeting_with_fluidaudio_clears_unavailable_code(tmp_path, monkeypatch):
    """Повтор, когда бинарник появился: голоса разделены, старый код из манифеста снят."""
    out = tmp_path / "meet"
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 20.0))
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: None)
    monkeypatch.setattr(m, "load_segments", lambda output: [seg(3.0, 5.0, "Раз.", ["speaker_1"])])
    _fluidaudio(monkeypatch, tmp_path, present=False)
    m.run_meeting({"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru"}, lambda event: None)
    _fluidaudio(monkeypatch, tmp_path, present=True)
    result = m.run_meeting({"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru"},
                           lambda event: None)
    data = json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))
    assert "diarization" not in data
    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["transcript"]["status"] == "done" and manifest["transcript"]["code"] is None


def test_diarization_problem_names_missing_binary_and_models(tmp_path, monkeypatch):
    _fluidaudio(monkeypatch, tmp_path, present=False)
    assert "fluidaudiocli" in m.diarization_problem()
    _fluidaudio(monkeypatch, tmp_path, present=True)
    assert m.diarization_problem() is None
    from audio_transcription import fluid_models

    monkeypatch.setattr(fluid_models, "ready", lambda *a, **k: False)
    assert "FluidAudio" in m.diarization_problem(offline=True)
    assert m.diarization_problem(offline=False) is None


def test_run_meeting_diarizes_system_track_by_default(tmp_path, monkeypatch):
    _fluidaudio(monkeypatch, tmp_path, present=True)
    calls: list[tuple[list[str], dict]] = []
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 20.0))
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: calls.append((command, kwargs)))
    monkeypatch.setattr(m, "load_segments", lambda output: [])
    m.run_meeting({"mic": "/m.wav", "system": "/s.wav", "out_dir": str(tmp_path / "x"), "language": "ru"},
                  lambda event: None)
    system = [(command, kwargs) for command, kwargs in calls if kwargs["track"] == "system"]
    assert "--diarize" in system[0][0] and system[0][1]["diarize"] is True


@pytest.mark.parametrize("code, tail, expected", [
    (-9, ["loading pyannote"], True),
    (137, [], True),
    (1, ["RuntimeError: MPS backend out of memory (MPS allocated: 5.2 GB)"], True),
    (1, ["MemoryError"], True),
    (1, ["FileNotFoundError: model.bin"], False),
    (2, ["usage: transcribe.py"], False),
])
def test_memory_failure_signs(code, tail, expected):
    assert m.memory_failure(code, tail) is expected


class _FakeProcess:
    def __init__(self, code: int, stderr: str) -> None:
        import io

        self.stderr = io.StringIO(stderr)
        self.stdout = io.StringIO("")
        self._code = code

    def wait(self) -> int:
        return self._code


def test_run_track_reports_diarization_memory_with_code(monkeypatch):
    monkeypatch.setattr(m.subprocess, "Popen", lambda *args, **kwargs: _FakeProcess(1, "torch.OutOfMemoryError: CUDA out of memory\n"))
    with pytest.raises(m.MeetingTrackError) as caught:
        m.run_track(["x"], track="system", index=1, count=2, emit=lambda event: None, diarize=True)
    assert caught.value.code == "diarization_memory"


def test_run_track_memory_without_diarization_is_plain_error(monkeypatch):
    """Без диаризации повторять «без голосов» бессмысленно: обычная ошибка."""
    monkeypatch.setattr(m.subprocess, "Popen", lambda *args, **kwargs: _FakeProcess(-9, ""))
    with pytest.raises(RuntimeError) as caught:
        m.run_track(["x"], track="mic", index=0, count=2, emit=lambda event: None, diarize=False)
    assert not isinstance(caught.value, m.MeetingTrackError)


# --- сквозной прогон -------------------------------------------------------

VOICES = ("Samantha", "Daniel", "Karen")
LINES = [
    # (кто, голос, фраза): «me» — микрофон, остальные — системная дорожка.
    ("me", "Samantha", "Good morning everyone. Let us review the release plan for this week."),
    ("a", "Daniel", "Thanks. The backend is ready, and the database migration finished yesterday."),
    ("b", "Karen", "On the mobile side we still need two more days for testing on older phones."),
    ("me", "Samantha", "Okay. Then we ship the web version on Thursday and mobile next Monday."),
    ("a", "Daniel", "Sounds good to me. I will update the deployment checklist today."),
    ("b", "Karen", "Agreed. I will send the test report tomorrow morning."),
]


def _synth(text: str, voice: str, work: Path, name: str) -> np.ndarray:
    aiff = work / f"{name}.aiff"
    wav = work / f"{name}.wav"
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-i", str(aiff), "-ac", "1", "-ar", "16000", "-sample_fmt", "s16", str(wav)],
        check=True,
    )
    with wave.open(str(wav), "rb") as reader:
        return np.frombuffer(reader.readframes(reader.getnframes()), dtype="<i2")


def _have_tools() -> bool:
    if not (shutil.which("say") and shutil.which("ffmpeg")):
        return False
    voices = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    return all(voice in voices for voice in VOICES) and (m.transcriber_scripts_dir() / "transcribe.py").is_file()


@pytest.mark.slow
@pytest.mark.skipif(not _have_tools(), reason="нет say/ffmpeg/голосов или transcriber")
def test_run_meeting_end_to_end(tmp_path, monkeypatch):
    # Р2 Н6: прогон во временном HOME — после него кэша transcriber там нет. Модели — из настоящего кэша HF.
    real_hf = Path(os.environ.get("HF_HOME") or Path.home() / ".cache" / "huggingface")
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setenv("HF_HOME", str(real_hf))
    # Диаризация — FluidAudio: бинарник через переменную (разработка), модели — ссылкой из настоящего дома.
    fluid_bin = Path(__file__).resolve().parents[3] / "transcriber" / "skills" / "transcriber" / "bin" / "macos-arm64" / "fluidaudiocli"
    fluid_models = Path.home() / "Library" / "Application Support" / "FluidAudio"
    if not (fluid_bin.is_file() and fluid_models.is_dir()):
        pytest.skip("нет fluidaudiocli или моделей FluidAudio")
    monkeypatch.setenv("TRANSCRIBER_FLUIDAUDIO_BIN", str(fluid_bin))
    (fake_home / "Library" / "Application Support").mkdir(parents=True)
    (fake_home / "Library" / "Application Support" / "FluidAudio").symlink_to(fluid_models)
    monkeypatch.setenv("HOME", str(fake_home))
    work = tmp_path / "synth"
    work.mkdir()
    rate = 16000
    pause = np.zeros(int(rate * 0.8), dtype=np.int16)
    mic_parts: list[np.ndarray] = []
    system_parts: list[np.ndarray] = []
    for index, (who, voice, text) in enumerate(LINES):
        audio = _synth(text, voice, work, f"line{index}")
        silence = np.zeros_like(audio)
        # Дорожки синхронны: пока говорит одна сторона, у другой тишина.
        mic_parts += [audio if who == "me" else silence, pause]
        system_parts += [silence if who == "me" else audio, pause]
    meeting_dir = tmp_path / "2026-10-10-1530"
    meeting_dir.mkdir()
    write_wav(meeting_dir / "mic.wav", np.concatenate(mic_parts))
    write_wav(meeting_dir / "system.wav", np.concatenate(system_parts))

    events: list[dict] = []

    def emit(event: dict) -> None:
        events.append(event)
        print("progress:", event.get("stage"), event.get("done"), event.get("total"), flush=True)

    result = m.run_meeting(
        {
            "mic": str(meeting_dir / "mic.wav"),
            "system": str(meeting_dir / "system.wav"),
            "out_dir": str(meeting_dir),
            "language": "en",
            "speakers": 2,
        },
        emit,
    )
    assert result["event"] == "meeting_done"
    text = Path(result["transcript_md"]).read_text(encoding="utf-8")
    assert "**Я**" in text
    assert "**Собеседник" in text
    data = json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))
    assert data["tracks"]["mic"]["used"] and data["tracks"]["system"]["used"]
    assert any(event.get("event") == "progress" for event in events)
    assert not (fake_home / ".cache" / "transcriber").exists(), "текст встречи остался в кэше transcriber"
    # Агрегаты для отчёта — без текста.
    print(
        "meeting e2e:",
        {
            "turns": len(data["turns"]),
            "speakers": result["speakers"],
            "echo_dropped": data["echo_dropped"],
            "seconds": result["seconds"],
            "progress_events": len(events),
        },
    )


# --- сбой модели голосов и повтор -----------------------------

_COREML = ("transcriber (system) завершился с кодом 2: ERROR: Failed to process audio file (offline mode): "
           "Error Domain=com.apple.CoreML Code=0 «Unable to compute the asynchronous prediction»")


def _meeting_with_crashes(tmp_path, monkeypatch, crashes: int, message: str = _COREML):
    _fluidaudio(monkeypatch, tmp_path, present=True)
    out = tmp_path / "meet"
    segments = {"mic": [seg(0.0, 2.0, "Начнём.")],
                "system": [seg(3.0, 5.0, "Раз.", ["speaker_1"]), seg(9.0, 11.0, "Два.", ["speaker_2"])]}
    calls: list[tuple[str, bool]] = []
    left = {"n": crashes}

    def run_track(command, **kwargs):
        calls.append((kwargs["track"], kwargs["diarize"]))
        if kwargs["diarize"] and left["n"] > 0:
            left["n"] -= 1
            raise RuntimeError(message)

    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 20.0))
    monkeypatch.setattr(m, "run_track", run_track)
    monkeypatch.setattr(m, "load_segments", lambda output: segments[output.name.split("-")[0]])
    result = m.run_meeting({"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru"},
                           lambda event: None)
    return out, result, calls


def test_diarization_crash_once_is_retried_with_voices(tmp_path, monkeypatch):
    out, result, calls = _meeting_with_crashes(tmp_path, monkeypatch, crashes=1)
    assert calls == [("mic", False), ("system", True), ("system", True)]
    data = json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))
    assert "diarization" not in data


def test_diarization_crash_twice_falls_back_to_one_interlocutor(tmp_path, monkeypatch):
    """Сбой CoreML на модели голосов не оставляет встречу без расшифровки."""
    out, result, calls = _meeting_with_crashes(tmp_path, monkeypatch, crashes=2)
    assert calls == [("mic", False), ("system", True), ("system", True), ("system", False)]
    assert result["event"] == "meeting_done"
    data = json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))
    assert data["diarization"] == {"available": False, "code": m.DIARIZATION_FAILED}
    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["transcript"]["status"] == "done"
    assert manifest["transcript"]["code"] == "diarization_failed"


def test_recognition_failure_is_not_retried_without_voices(tmp_path, monkeypatch):
    with pytest.raises(RuntimeError):
        _meeting_with_crashes(tmp_path, monkeypatch, crashes=1,
                              message="transcriber (system) завершился с кодом 1: GigaAM: окно 3 не распознано")
    manifest = json.loads((tmp_path / "meet" / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["transcript"]["status"] == "failed"


def _finished(output: Path, audio: Path, *, diarized: bool) -> None:
    output.mkdir(parents=True)
    (output / "segments.json").write_text('{"readable": []}', encoding="utf-8")
    (output / "manifest.json").write_text(json.dumps({
        "mode": "max", "source": {"size_bytes": audio.stat().st_size},
        "diarization_model": "FluidAudio Community-1 offline" if diarized else None,
    }), encoding="utf-8")


def test_finished_track_is_reused_on_retry(tmp_path, monkeypatch):
    """Повтор после сбоя на системной дорожке не гонит заново готовый микрофон (35 минут на полчаса записи)."""
    _fluidaudio(monkeypatch, tmp_path, present=True)
    out = tmp_path / "meet"
    mic = tmp_path / "mic.wav"
    mic.write_bytes(b"x" * 100)
    system = tmp_path / "system.wav"
    system.write_bytes(b"y" * 100)
    _finished(out / "mic-transcript", mic, diarized=False)
    calls: list[str] = []
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 20.0))
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: calls.append(kwargs["track"]))
    monkeypatch.setattr(m, "load_segments", lambda output: [])
    m.run_meeting({"mic": str(mic), "system": str(system), "out_dir": str(out), "language": "ru"}, lambda event: None)
    assert calls == ["system"]


def test_finished_track_mismatch_is_not_reused(tmp_path):
    audio = tmp_path / "a.wav"
    audio.write_bytes(b"z" * 10)
    _finished(tmp_path / "o", audio, diarized=False)
    assert m.finished_track(tmp_path / "o", audio, diarize=False)
    assert not m.finished_track(tmp_path / "o", audio, diarize=True)
    audio.write_bytes(b"z" * 11)
    assert not m.finished_track(tmp_path / "o", audio, diarize=False)
    assert not m.finished_track(tmp_path / "missing", audio, diarize=False)


def test_diarization_crash_signs():
    assert m.diarization_crash(_COREML)
    assert m.diarization_crash("ошибка: fluidaudio недоступен")
    assert not m.diarization_crash("GigaAM: окно 3 не распознано")


def test_progress_phase_hides_raw_transcriber_labels():
    assert m.progress_phase("Whisper mlx-community/whisper-large-v3-turbo-asr-fp16: окно 0/6") == ("transcribe", "Whisper")
    assert m.progress_phase("faster-whisper medium: окно 2/9") == ("transcribe", "Whisper")
    assert m.progress_phase("GigaAM v3_e2e_rnnt: окно 3/17") == ("transcribe", "GigaAM")
    assert m.progress_phase("Диаризация: окно 1/4") == ("voices", None)
    assert m.progress_phase("Определение языка: окно 1/3") == ("prepare", None)
    assert m.progress_phase("Речевых окон: 4") == ("prepare", None)


def test_overall_progress_grows_across_tracks():
    # Две дорожки, вторая с голосами: полоса идёт от 0 к 950, потом сборка добирает до 1000.
    mic_half = m.track_fraction("transcribe", {"done": 3, "total": 6}, diarize=False)
    assert m.overall_progress(0, 2, mic_half) == round(1000 * 0.95 * (0.05 + 0.95 * 0.5) / 2)
    voices = m.track_fraction("voices", {"done": 4, "total": 4}, diarize=True)
    assert voices == 0.3
    assert m.overall_progress(1, 2, voices) < m.overall_progress(1, 2, 1.0) == 950
    assert m.track_fraction("prepare", {"stage": "Речевых окон: 4"}, diarize=True) == 0.0


def test_run_track_emits_phase_model_and_share(monkeypatch):
    lines = ["[12:00:01] Речевых окон: 6\n",
             "[12:00:02] Whisper mlx-community/whisper-large-v3-turbo-asr-fp16: окно 3/6\n",
             "  warnings.warn(\n"]

    class Process:
        stderr = iter(lines)
        stdout = None

        def wait(self):
            return 0

    monkeypatch.setattr(m.subprocess, "Popen", lambda *a, **k: Process())
    monkeypatch.setattr(m, "check_media_tools", lambda env, audio=None: None)
    events = []
    m.run_track(["/py", "x"], track="mic", index=0, count=1, emit=events.append)
    assert [e["stage"] for e in events] == ["prepare", "prepare", "transcribe"]
    assert events[-1]["model"] == "Whisper" and events[-1]["total"] == 1000
    assert events[-1]["done"] == round(1000 * 0.95 * (0.05 + 0.95 * 0.5))
    assert all("окно" not in e["stage"] and "mic" not in e["stage"] for e in events)
