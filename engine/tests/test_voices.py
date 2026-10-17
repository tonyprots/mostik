"""Голосовая память собеседников (M14): хранилище, пороги, подсказки, правка говорящих.

Только синтетика: векторы — из заглушки `StubEmbedder` (sha256 ключа), встречи —
в tmp_path, хранилище — в MOSTIK_HOME теста (conftest).
"""

from __future__ import annotations

import json
import os
import stat
from pathlib import Path

import pytest

from mostik_engine import meeting as m
from mostik_engine import meeting_speakers as ms
from mostik_engine import voices as v


@pytest.fixture(autouse=True)
def diarization_available(monkeypatch):
    """Прогоны встречи здесь поддельные: разделение по голосам считаем доступным при любом fluidaudiocli."""
    monkeypatch.setattr(m, "diarization_problem", lambda **kwargs: None)


def vec(*values):
    return v.normalize(values)


def store(tmp_path) -> v.VoiceStore:
    return v.VoiceStore(tmp_path / "voices")


# --- математика и пороги -----------------------------------------------------


def test_cosine_and_normalize():
    assert v.cosine([1, 0], [1, 0]) == 1.0
    assert abs(v.cosine([1, 0], [0, 1])) < 1e-9
    assert v.cosine([], []) == 0.0 and v.cosine([1, 0], [1, 0, 0]) == 0.0
    assert abs(sum(x * x for x in v.normalize([3, 4])) - 1) < 1e-9


def test_stub_is_deterministic_and_distinct():
    a, b = v.StubEmbedder.vector("Иван"), v.StubEmbedder.vector("Мария")
    assert a == v.StubEmbedder.vector("Иван")
    assert v.cosine(a, b) < v.MATCH_THRESHOLD


def test_match_thresholds_like_heed(tmp_path):
    s = store(tmp_path)
    assert s.match(vec(1, 0, 0), "m") is None  # никого нет
    s.add_sample("Иван", vec(1, 0, 0), model="m", seconds=10, meeting="a")
    found = s.match(vec(0.9, 0.3, 0), "m")
    assert found and found["name"] == "Иван" and found["score"] >= 0.62 and found["second"] == 0
    # Ниже 0,62 — не подсказка.
    assert s.match(vec(0.6, 0.8, 0), "m") is None
    # Зазор до второго меньше 0,08 — не подсказка.
    s.add_sample("Пётр", vec(0.95, 0.31, 0), model="m", seconds=10, meeting="a")
    assert s.match(vec(0.97, 0.24, 0), "m") is None
    # Векторы другой модели несравнимы.
    assert s.match(vec(1, 0, 0), "другая") is None


def test_samples_capped_at_ten_and_same_meeting_replaced(tmp_path):
    s = store(tmp_path)
    for i in range(12):
        s.add_sample("Иван", vec(1, i, 0), model="m", seconds=5, meeting=f"m{i}")
    s.add_sample("Иван", vec(1, 0, 0), model="m", seconds=5, meeting="m11")
    person = s.people()[0]
    assert person["samples"] == v.MAX_SAMPLES
    raw = json.loads(s.people_path.read_text(encoding="utf-8"))["people"][0]["samples"]
    assert [x["meeting"] for x in raw][-1] == "m11" and "m0" not in [x["meeting"] for x in raw]
    assert all("audio" not in x for x in raw) and set(raw[0]) == {"vector", "model", "seconds", "meeting", "added"}


def test_add_sample_to_existing_name_merges(tmp_path):
    s = store(tmp_path)
    first = s.add_sample("Иван Петров", vec(1, 0), model="m", seconds=5, meeting="a")
    second = s.add_sample("  иван   петров ", vec(1, 0.1), model="m", seconds=5, meeting="b")
    assert not first["merged"] and second["merged"] and second["person_id"] == first["person_id"]
    assert len(s.people()) == 1 and s.people()[0]["samples"] == 2
    with pytest.raises(ValueError):
        s.add_sample("Я", vec(1, 0), model="m", seconds=5, meeting="a")


def test_rename_into_existing_person_merges(tmp_path):
    s = store(tmp_path)
    ivan = s.add_sample("Иван", vec(1, 0), model="m", seconds=5, meeting="a")
    stranger = s.add_sample("Собеседник из Zoom", vec(0.9, 0.2), model="m", seconds=5, meeting="b")
    result = s.rename(stranger["person_id"], "иван")
    assert result["merged"] and result["person_id"] == ivan["person_id"]
    assert [p["name"] for p in s.people()] == ["Иван"] and s.people()[0]["samples"] == 2
    plain = s.add_sample("Мария", vec(0, 1), model="m", seconds=5, meeting="c")
    assert s.rename(plain["person_id"], "Мария Ивановна")["merged"] is False


def test_forget_one_and_all(tmp_path):
    s = store(tmp_path)
    ivan = s.add_sample("Иван", vec(1, 0), model="m", seconds=5, meeting="a")
    s.add_sample("Мария", vec(0, 1), model="m", seconds=5, meeting="a")
    s.save_pending("a", "m", {"Собеседник 1": {"vector": vec(1, 0), "seconds": 5}})
    assert s.forget(ivan["person_id"]) and not s.forget("нет такого")
    assert [p["name"] for p in s.people()] == ["Мария"]
    assert s.forget_all() == 1
    assert s.people() == [] and s.load_pending("a") is None and not s.root.exists()


def test_store_files_are_private(tmp_path):
    s = store(tmp_path)
    s.add_sample("Иван", vec(1, 0), model="m", seconds=5, meeting="a")
    assert stat.S_IMODE(os.stat(s.people_path).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(s.root).st_mode) == 0o700


def test_default_store_lives_in_mostik_home(mostik_home):
    assert v.VoiceStore().root == mostik_home / "voices"


# --- векторы меток ------------------------------------------------------------


def test_label_vectors_weight_by_overlap():
    segments = [
        {"startTimeSeconds": 0, "endTimeSeconds": 10, "embedding": [1, 0]},
        {"startTimeSeconds": 10, "endTimeSeconds": 12, "embedding": [0, 1]},
        {"startTimeSeconds": 20, "endTimeSeconds": 30, "embedding": []},
    ]
    result = v.label_vectors(segments, {"A": [(0, 12)], "B": [(20, 30)]})
    assert set(result) == {"A"}
    assert result["A"][0] > 0.95 and result["A"][1] > 0


def test_speech_spans_skip_mic_and_overlaps():
    turns = [
        {"source": "mic", "speaker": "Я", "start": 0, "end": 5},
        {"source": "system", "label": "Собеседник 1", "start": 5, "end": 9},
        {"source": "system", "label": "Собеседник 1 + Собеседник 2", "start": 9, "end": 10},
        {"source": "system", "label": "Собеседник 2", "start": 10, "end": 12},
    ]
    assert v.speech_spans(turns) == {"Собеседник 1": [(5.0, 9.0)], "Собеседник 2": [(10.0, 12.0)]}


def test_fluid_embedder_reports_missing_binary(tmp_path):
    ok, detail = v.FluidAudioEmbedder(binary=tmp_path / "нет").available()
    assert not ok and "нет файла" in detail


# --- встреча целиком ----------------------------------------------------------


def seg(start, end, text, speakers=None):
    return {"start": start, "end": end, "text": text, "speakers": speakers or []}


SEGMENTS = {
    "mic": [seg(0.0, 3.0, "Начнём.")],
    "system": [
        seg(4.0, 10.0, "Про сроки релиза.", ["speaker_0"]),
        seg(12.0, 18.0, "Про бюджет на мониторы.", ["speaker_1"]),
        seg(20.0, 22.0, "Да.", ["speaker_2"]),
    ],
}


def run(tmp_path, monkeypatch, name, keys, *, voice_memory=True, embedder=None):
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: None)
    return run_no_track_patch(tmp_path, monkeypatch, name, keys, voice_memory=voice_memory, embedder=embedder)


def run_no_track_patch(tmp_path, monkeypatch, name, keys, *, voice_memory=True, embedder=None):
    out = tmp_path / name
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 30.0))
    monkeypatch.setattr(m, "load_segments", lambda output: SEGMENTS[output.name.split("-")[0]])
    monkeypatch.setattr(v, "default_embedder", lambda: embedder or v.StubEmbedder(keys))
    result = m.run_meeting({"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "language": "ru",
                            "voice_memory": voice_memory}, lambda event: None)
    return out, json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))


def test_voice_memory_off_by_default_writes_nothing(tmp_path, monkeypatch, mostik_home):
    _, data = run(tmp_path, monkeypatch, "2026-10-11-100000", {}, voice_memory=False)
    assert "voices" not in data and not (mostik_home / "voices").exists()


def test_first_meeting_no_suggestions_then_naming_teaches(tmp_path, monkeypatch, mostik_home):
    keys = {"Собеседник 1": "иван", "Собеседник 2": "мария"}
    out, data = run(tmp_path, monkeypatch, "2026-10-11-100000", keys)
    voices = data["voices"]
    assert voices["suggestions"] == [] and voices["pending"] == ["Собеседник 1", "Собеседник 2"]
    assert voices["short"] == ["Собеседник 3"]  # 2 с речи — меньше 4 с
    assert "vector" not in json.dumps(data)  # векторы — только в voices/
    pending = json.loads((mostik_home / "voices" / "pending" / f"{out.name}.json").read_text(encoding="utf-8"))
    assert set(pending["clusters"]) == {"Собеседник 1", "Собеседник 2"}

    result = ms.rename(out, "Собеседник 1", "Иван Петров", remember=True)
    assert result["person"]["name"] == "Иван Петров" and not result["person"]["merged"]
    data = json.loads((out / "transcript.json").read_text(encoding="utf-8"))
    assert [t["speaker"] for t in data["turns"]] == ["Я", "Иван Петров", "Собеседник 2", "Собеседник 3"]
    assert data["turns"][1]["label"] == "Собеседник 1" and data["speaker_names"] == {"Собеседник 1": "Иван Петров"}
    assert "**Иван Петров** [00:04]" in (out / "transcript.md").read_text(encoding="utf-8")
    assert "Иван Петров" in data["participants"]

    # Вторая встреча: тот же голос под другим номером — подсказка, но не подстановка.
    keys2 = {"Собеседник 1": "мария", "Собеседник 2": "иван"}
    out2, data2 = run(tmp_path, monkeypatch, "2026-10-12-100000", keys2)
    assert [s["label"] for s in data2["voices"]["suggestions"]] == ["Собеседник 2"]
    assert data2["voices"]["suggestions"][0]["name"] == "Иван Петров"
    assert "Иван Петров" not in {t["speaker"] for t in data2["turns"]}

    confirmed = ms.confirm(out2, "Собеседник 2")
    assert confirmed["person"]["merged"] and confirmed["person"]["samples"] == 2
    data2 = json.loads((out2 / "transcript.json").read_text(encoding="utf-8"))
    assert data2["voices"]["suggestions"] == []
    assert {t["speaker"] for t in data2["turns"]} >= {"Иван Петров"}


def test_reject_keeps_name_out(tmp_path, monkeypatch):
    keys = {"Собеседник 1": "иван"}
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", keys)
    ms.rename(out, "Собеседник 1", "Иван", remember=True)
    out2, data2 = run(tmp_path, monkeypatch, "2026-10-12-100000", keys)
    assert data2["voices"]["suggestions"][0]["name"] == "Иван"
    ms.reject(out2, "Собеседник 1")
    data2 = json.loads((out2 / "transcript.json").read_text(encoding="utf-8"))
    assert data2["voices"]["suggestions"] == [] and data2["voices"]["rejected"][0]["label"] == "Собеседник 1"
    assert "Иван" not in {t["speaker"] for t in data2["turns"]}
    with pytest.raises(ms.SpeakerEditError):
        ms.confirm(out2, "Собеседник 1")


def test_rename_without_memory_does_not_store(tmp_path, monkeypatch, mostik_home):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {}, voice_memory=False)
    result = ms.rename(out, "Собеседник 2", "Мария", remember=False)
    assert result["person"] is None and not (mostik_home / "voices" / "people.json").exists()


def test_mic_track_is_never_renamed(tmp_path, monkeypatch):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {})
    with pytest.raises(ms.SpeakerEditError):
        ms.rename(out, "Я", "Антон")
    with pytest.raises(ms.SpeakerEditError):
        ms.rename(out, "Собеседник 1", "Я")
    with pytest.raises(ms.SpeakerEditError):
        ms.rename(out, "Собеседник 9", "Кто-то")


def test_set_turn_moves_one_turn_to_alternative(tmp_path, monkeypatch):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {}, voice_memory=False)
    ms.rename(out, "Собеседник 2", "Мария")
    ms.set_turn(out, 3, "Собеседник 2")
    data = json.loads((out / "transcript.json").read_text(encoding="utf-8"))
    turn = data["turns"][3]
    assert turn["speaker"] == "Мария" and turn["label"] == "Собеседник 2" and turn["reviewed"]
    assert turn["speaker_confidence"] == 1.0 and "review" not in turn
    with pytest.raises(ms.SpeakerEditError):
        ms.set_turn(out, 0, "Собеседник 2")  # реплика микрофона


def test_set_turn_by_name_goes_to_holder_or_new_speaker(tmp_path, monkeypatch):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {}, voice_memory=False)
    ms.rename(out, "Собеседник 2", "Мария")
    ms.set_turn(out, 3, name="мария")                     # имя уже у метки — реплика к ней
    data = json.loads((out / "transcript.json").read_text(encoding="utf-8"))
    assert data["turns"][3]["label"] == "Собеседник 2" and data["turns"][3]["speaker"] == "Мария"
    reply = ms.set_turn(out, 3, name="Пётр")              # нового голоса диаризация не выделила
    data = json.loads((out / "transcript.json").read_text(encoding="utf-8"))
    turn = data["turns"][3]
    assert reply["label"] == turn["label"] not in ("Собеседник 1", "Собеседник 2")
    assert turn["speaker"] == "Пётр" and data["speaker_names"][turn["label"]] == "Пётр" and turn["reviewed"]
    with pytest.raises(ms.SpeakerEditError):
        ms.set_turn(out, 3, name="Я")


def test_forget_drops_suggestions_from_meetings(tmp_path, monkeypatch, mostik_home):
    keys = {"Собеседник 1": "иван"}
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", keys)
    person = ms.rename(out, "Собеседник 1", "Иван", remember=True)["person"]
    out2, _ = run(tmp_path, monkeypatch, "2026-10-12-100000", keys)
    assert v.drop_person_suggestions(tmp_path, person["person_id"]) == 1
    assert json.loads((out2 / "transcript.json").read_text(encoding="utf-8"))["voices"]["suggestions"] == []


def test_unavailable_model_is_reported_not_raised(tmp_path, monkeypatch):
    class Missing(v.StubEmbedder):
        def available(self):
            return False, "нет модели"

    out = tmp_path / "2026-10-11-100000"
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 30.0))
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: None)
    monkeypatch.setattr(m, "load_segments", lambda output: SEGMENTS[output.name.split("-")[0]])
    monkeypatch.setattr(v, "default_embedder", lambda: Missing())
    result = m.run_meeting({"mic": "/m.wav", "system": "/s.wav", "out_dir": str(out), "voice_memory": True},
                           lambda event: None)
    data = json.loads(Path(result["transcript_json"]).read_text(encoding="utf-8"))
    assert data["voices"]["available"] is False and data["voices"]["detail"] == "нет модели"


# --- протокол движка ------------------------------------------------------------


def test_engine_commands(tmp_path, monkeypatch, mostik_home):
    from test_protocol import FakeVerifier, Sink, send
    from conftest import FakePool
    from mostik_engine.personal_glossary import PersonalGlossary
    from mostik_engine.server import Engine

    sink = Sink()
    eng = Engine(sink, pool=FakePool(), verifier=FakeVerifier(),
                 personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False))
    monkeypatch.setattr(v, "default_embedder", lambda: v.StubEmbedder({"Собеседник 1": "иван"}))
    send(eng, cmd="voices_status", id=1)
    status = sink.wait(lambda e: e.get("id") == 1)
    assert status["enabled"] is False and status["available"] is True and status["people"] == []

    send(eng, cmd="voices_config", id=2, enabled=True)
    assert sink.wait(lambda e: e.get("id") == 2)["enabled"] is True
    meetings = mostik_home / "meetings"
    out = meetings / "2026-10-11-100000"
    monkeypatch.setattr(m, "track_usable", lambda path: (bool(path), 30.0))
    monkeypatch.setattr(m, "run_track", lambda command, **kwargs: None)
    monkeypatch.setattr(m, "load_segments", lambda output: SEGMENTS[output.name.split("-")[0]])
    send(eng, cmd="meeting", id=3, mic="/m.wav", system="/s.wav", out_dir=str(out), language="ru")
    sink.wait(lambda e: e.get("id") == 3 and e.get("event") == "meeting_done")
    assert json.loads((out / "transcript.json").read_text(encoding="utf-8"))["voices"]["pending"]

    send(eng, cmd="speaker_rename", id=4, folder=str(out), label="Собеседник 1", name="Иван")
    renamed = sink.wait(lambda e: e.get("id") == 4)
    assert renamed["ok"] and renamed["person"]["name"] == "Иван"
    send(eng, cmd="speaker_rename", id=5, folder=str(out), label="Я", name="Антон")
    assert sink.wait(lambda e: e.get("id") == 5)["code"] == "speaker"
    send(eng, cmd="speaker_turn", id=6, folder=str(out), turn=3, label="")
    assert sink.wait(lambda e: e.get("id") == 6)["ok"]

    person = renamed["person"]["person_id"]
    send(eng, cmd="voices_rename", id=7, person_id=person, name="Иван Петров")
    assert sink.wait(lambda e: e.get("id") == 7)["people"][0]["name"] == "Иван Петров"
    send(eng, cmd="voices_forget", id=8, all=True)
    forgot = sink.wait(lambda e: e.get("id") == 8)
    assert forgot["forgotten"] == 1 and forgot["people"] == [] and not (mostik_home / "voices").exists()


# --- П10 С8: отпечатки не копятся -----------------------------------------------------------

def pending_labels(mostik_home, out):
    path = mostik_home / "voices" / "pending" / f"{out.name}.json"
    return set(json.loads(path.read_text(encoding="utf-8"))["clusters"]) if path.exists() else None


def test_pending_cluster_goes_after_decision(tmp_path, monkeypatch, mostik_home):
    keys = {"Собеседник 1": "иван", "Собеседник 2": "мария"}
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", keys)
    assert pending_labels(mostik_home, out) == {"Собеседник 1", "Собеседник 2"}
    ms.rename(out, "Собеседник 1", "Иван", remember=True)  # «назвал» — вектор ушёл в образцы
    assert pending_labels(mostik_home, out) == {"Собеседник 2"}
    ms.rename(out, "Собеседник 2", "Мария", remember=False)  # назвал без памяти — тоже решение
    assert pending_labels(mostik_home, out) is None, "решено всё — файла нет"

    out2, _ = run(tmp_path, monkeypatch, "2026-10-12-100000", {"Собеседник 1": "иван"})
    assert "Собеседник 1" in pending_labels(mostik_home, out2)
    ms.reject(out2, "Собеседник 1")  # «Не он»
    assert "Собеседник 1" not in (pending_labels(mostik_home, out2) or set())


def test_pending_expires_after_30_days(tmp_path):
    s = store(tmp_path)
    s.save_pending("old", "m", {"Собеседник 1": {"vector": vec(1, 0), "seconds": 5}})
    s.save_pending("new", "m", {"Собеседник 1": {"vector": vec(0, 1), "seconds": 5}})
    old = s.pending_path("old")
    data = json.loads(old.read_text(encoding="utf-8"))
    data["created"] = "2026-08-01T10:00:00+03:00"
    old.write_text(json.dumps(data), encoding="utf-8")
    import datetime as dt
    now = dt.datetime(2026, 10, 11, 12, 0).astimezone()
    assert s.prune_pending(now=now) == 1
    assert s.load_pending("old") is None and s.load_pending("new") is not None
    assert v.PENDING_DAYS == 30


def test_forget_person_drops_their_clusters(tmp_path):
    s = store(tmp_path)
    ivan = s.add_sample("Иван", vec(1, 0, 0), model="m", seconds=5, meeting="a")
    s.add_sample("Мария", vec(0, 1, 0), model="m", seconds=5, meeting="a")
    s.save_pending("b", "m", {"Собеседник 1": {"vector": vec(0.99, 0.05, 0), "seconds": 5},
                              "Собеседник 2": {"vector": vec(0, 0, 1), "seconds": 5}})
    s.save_pending("c", "m", {"Собеседник 3": {"vector": vec(1, 0.01, 0), "seconds": 5}})
    assert s.forget(ivan["person_id"])
    assert set(s.load_pending("b")["clusters"]) == {"Собеседник 2"}
    assert s.load_pending("c") is None


def test_voices_wipe_command_erases_everything(tmp_path, monkeypatch, mostik_home):
    from test_protocol import FakeVerifier, Sink, send
    from conftest import FakePool
    from mostik_engine.personal_glossary import PersonalGlossary
    from mostik_engine.server import Engine

    keys = {"Собеседник 1": "иван"}
    meetings = mostik_home / "meetings"
    out, _ = run(meetings, monkeypatch, "2026-10-11-100000", keys)
    ms.rename(out, "Собеседник 1", "Иван", remember=True)
    out2, _ = run(meetings, monkeypatch, "2026-10-12-100000", keys)
    assert (mostik_home / "voices" / "pending").exists()
    sink = Sink()
    eng = Engine(sink, pool=FakePool(), verifier=FakeVerifier(),
                 personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False))
    eng.voice_memory = True
    send(eng, cmd="voices_wipe", id=1)
    reply = sink.wait(lambda e: e.get("id") == 1)
    assert reply["ok"] and reply["forgotten"] == 1 and reply["people"] == []
    assert not (mostik_home / "voices").exists()
    voices = json.loads((out2 / "transcript.json").read_text(encoding="utf-8"))["voices"]
    assert voices["suggestions"] == [] and voices["pending"] == []


# --- Р2 Н7: «Стереть отпечатки» во время расшифровки встречи --------------------------------------
# Гонка воспроизводится без потоков и таймингов: стирание вызывается изнутри прогона в нужной точке.


def _engine():
    """Движок без потоков и пулов: нужны только обработчики команд голосовой памяти."""
    from mostik_engine.server import Engine

    engine = Engine.__new__(Engine)
    engine.reply = lambda *args, **kwargs: None
    return engine


def _wipe_now(mostik_home):
    """Команда `voices_wipe`, как её шлёт приложение после «Стереть отпечатки»."""
    from mostik_engine.server import Engine

    Engine.cmd_voices_wipe(_engine(), {"cmd": "voices_wipe"})


class _WipingEmbedder(v.StubEmbedder):
    """Стирание приходит, пока считаются векторы (самая долгая часть, ~13 с на живой записи)."""

    def __init__(self, keys, wipe):
        super().__init__(keys)
        self.wipe = wipe

    def embed(self, audio, spans):
        vectors = super().embed(audio, spans)
        self.wipe()
        return vectors


def _assert_no_prints(mostik_home, data):
    assert not (mostik_home / "voices").exists(), "после стирания появились отпечатки"
    voices = data.get("voices") or {}
    assert not voices.get("suggestions") and not voices.get("pending"), voices


@pytest.fixture
def taught(tmp_path, monkeypatch, mostik_home):
    """Иван уже в памяти: следующая встреча с его голосом дала бы подсказку."""
    keys = {"Собеседник 1": "иван"}
    out, _ = run(mostik_home / "meetings", monkeypatch, "2026-10-11-100000", keys)
    ms.rename(out, "Собеседник 1", "Иван", remember=True)
    return keys


def test_wipe_during_transcription_leaves_no_prints(tmp_path, monkeypatch, mostik_home, taught):
    def transcribing(command, **kwargs):
        _wipe_now(mostik_home)

    monkeypatch.setattr(m, "run_track", transcribing)
    _, data = run_no_track_patch(mostik_home / "meetings", monkeypatch, "2026-10-12-100000", taught)
    _assert_no_prints(mostik_home, data)


def test_wipe_during_voice_embedding_leaves_no_prints(tmp_path, monkeypatch, mostik_home, taught):
    embedder = _WipingEmbedder(taught, lambda: _wipe_now(mostik_home))
    _, data = run(mostik_home / "meetings", monkeypatch, "2026-10-12-100000", taught, embedder=embedder)
    _assert_no_prints(mostik_home, data)


def test_wipe_after_voices_before_transcript_written_leaves_no_suggestions(tmp_path, monkeypatch, mostik_home, taught):
    # Отпечатки уже сохранены, transcript.json ещё не записан: стирание приходит между ними.
    real = m.render_markdown

    def rendering(*args, **kwargs):
        _wipe_now(mostik_home)
        return real(*args, **kwargs)

    monkeypatch.setattr(m, "render_markdown", rendering)
    _, data = run(mostik_home / "meetings", monkeypatch, "2026-10-12-100000", taught)
    _assert_no_prints(mostik_home, data)


def test_memory_off_during_transcription_keeps_new_prints_out(tmp_path, monkeypatch, mostik_home, taught):
    """«Выключить» без стирания: старые отпечатки остаются, новых от идущей встречи нет."""
    from mostik_engine.server import Engine

    embedder = _WipingEmbedder(taught, lambda: Engine.cmd_voices_config(_engine(), {"enabled": False}))
    out, data = run(mostik_home / "meetings", monkeypatch, "2026-10-12-100000", taught, embedder=embedder)
    assert v.VoiceStore().people(), "выключение без стирания людей не трогает"
    assert v.VoiceStore().load_pending(out.name) is None
    assert not (data.get("voices") or {}).get("suggestions")


def test_wipe_between_meetings_does_not_block_next_one(tmp_path, monkeypatch, mostik_home, taught):
    _wipe_now(mostik_home)
    out, data = run(mostik_home / "meetings", monkeypatch, "2026-10-12-100000", taught)
    assert "Собеседник 1" in data["voices"]["pending"]
    assert v.VoiceStore().load_pending(out.name) is not None
