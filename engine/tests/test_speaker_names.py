"""Имена говорящих (E1–E3): «Убрать имя», одно имя — один человек, «Объединить с…» и голосовая память.

Данные синтетические: встреча в tmp_path, голоса — StubEmbedder.
"""

from __future__ import annotations

import io
import json

import pytest

from mostik_engine import meeting_speakers as ms
from mostik_engine import voices as v
from mostik_engine.personal_glossary import PersonalGlossary
from mostik_engine.server import Engine
from test_voices import diarization_available, run  # noqa: F401 — фикстура autouse


def doc(folder):
    return json.loads((folder / "transcript.json").read_text(encoding="utf-8"))


def speakers(folder):
    return [t["speaker"] for t in doc(folder)["turns"]]


def pending(mostik_home, folder):
    path = mostik_home / "voices" / "pending" / f"{folder.name}.json"
    return json.loads(path.read_text(encoding="utf-8"))["clusters"] if path.exists() else {}


# --- E1: «Убрать имя» ---------------------------------------------------------------


def test_unname_returns_label_everywhere(tmp_path, monkeypatch):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {}, voice_memory=False)
    ms.rename(out, "Собеседник 2", "Мария")
    assert speakers(out) == ["Я", "Собеседник 1", "Мария", "Собеседник 3"]
    result = ms.unname(out, "Собеседник 2")
    assert result == {"label": "Собеседник 2", "name": "Собеседник 2", "removed": "Мария"}
    data = doc(out)
    assert speakers(out) == ["Я", "Собеседник 1", "Собеседник 2", "Собеседник 3"]
    assert data["speaker_names"] == {} and "Мария" not in data["participants"]
    assert "Мария" not in (out / "transcript.md").read_text(encoding="utf-8")


def test_unname_refuses_me_unknown_and_unnamed(tmp_path, monkeypatch):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {}, voice_memory=False)
    for label in ("Я", "Собеседник 9", "Собеседник 1"):
        with pytest.raises(ms.SpeakerEditError):
            ms.unname(out, label)


def test_unname_takes_voice_sample_back_to_pending(tmp_path, monkeypatch, mostik_home):
    keys = {"Собеседник 1": "иван", "Собеседник 2": "мария"}
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", keys)
    ms.rename(out, "Собеседник 1", "Иван", remember=True)
    assert v.VoiceStore().find("Иван") and "Собеседник 1" not in pending(mostik_home, out)
    ms.unname(out, "Собеседник 1", remember=True)
    assert v.VoiceStore().find("Иван") is None, "единственный образец снят — человека нет"
    assert "Собеседник 1" in pending(mostik_home, out), "вектор снова ждёт решения"
    # Назвали заново — образец вернулся уже под новым именем.
    result = ms.rename(out, "Собеседник 1", "Иван Петров", remember=True)
    assert result["person"]["name"] == "Иван Петров" and result["person"]["samples"] == 1


def test_unname_keeps_other_meetings_samples(tmp_path, monkeypatch, mostik_home):
    keys = {"Собеседник 1": "иван"}
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", keys)
    ms.rename(out, "Собеседник 1", "Иван", remember=True)
    out2, _ = run(tmp_path, monkeypatch, "2026-10-12-100000", keys)
    ms.rename(out2, "Собеседник 1", "Иван", remember=True)
    assert v.VoiceStore().find("Иван")["samples"].__len__() == 2
    ms.unname(out2, "Собеседник 1", remember=True)
    samples = v.VoiceStore().find("Иван")["samples"]
    assert [s["meeting"] for s in samples] == [out.name]


def test_rename_to_other_name_moves_sample_off_wrong_person(tmp_path, monkeypatch, mostik_home):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {"Собеседник 1": "иван"})
    ms.rename(out, "Собеседник 1", "Пётр", remember=True)
    ms.rename(out, "Собеседник 1", "Иван", remember=True)
    store = v.VoiceStore()
    assert store.find("Пётр") is None and len(store.find("Иван")["samples"]) == 1


# --- E2: одно имя — один человек ---------------------------------------------------------


def test_same_name_merges_labels(tmp_path, monkeypatch):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {}, voice_memory=False)
    ms.rename(out, "Собеседник 1", "Катя")
    result = ms.rename(out, "Собеседник 3", "катя")  # регистр не важен
    assert result["label"] == "Собеседник 1" and result["merged_from"] == "Собеседник 3"
    data = doc(out)
    assert [t["label"] for t in data["turns"][1:]] == ["Собеседник 1", "Собеседник 2", "Собеседник 1"]
    assert data["speaker_names"] == {"Собеседник 1": "катя"}
    assert sum(1 for p in data["participants"] if p.casefold() == "катя") == 1


def test_old_transcript_with_duplicate_names_collapses_on_next_edit(tmp_path, monkeypatch):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {}, voice_memory=False)
    data = doc(out)
    # Так писали до E2: две метки с одним именем.
    data["speaker_names"] = {"Собеседник 1": "Катя", "Собеседник 3": "Катя"}
    for turn in data["turns"]:
        if turn.get("label") in data["speaker_names"]:
            turn["speaker"] = "Катя"
    (out / "transcript.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    ms.rename(out, "Собеседник 3", "Катя Тестова")
    data = doc(out)
    assert data["speaker_names"] == {"Собеседник 1": "Катя Тестова"}
    assert speakers(out) == ["Я", "Катя Тестова", "Собеседник 2", "Катя Тестова"]


def test_merge_keeps_source_name_when_target_unnamed(tmp_path, monkeypatch):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {}, voice_memory=False)
    ms.rename(out, "Собеседник 3", "Катя")
    result = ms.merge_label(out, "Собеседник 3", "Собеседник 1")
    assert result["speaker"] == "Катя"
    assert doc(out)["speaker_names"] == {"Собеседник 1": "Катя"}
    assert speakers(out) == ["Я", "Катя", "Собеседник 2", "Катя"]


def test_merge_gives_both_voiceprints_to_one_person(tmp_path, monkeypatch, mostik_home):
    # Один человек, две метки (модель голосов разрезала), обе с вектором.
    keys = {"Собеседник 1": "катя", "Собеседник 2": "катя-2"}
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", keys)
    assert set(pending(mostik_home, out)) == {"Собеседник 1", "Собеседник 2"}
    ms.rename(out, "Собеседник 1", "Катя", remember=True)
    result = ms.rename(out, "Собеседник 2", "Катя", remember=True)
    person = result["person"]
    assert person["name"] == "Катя" and person["samples"] == 1, "один образец встречи — общий вектор"
    assert pending(mostik_home, out) == {}, "оба вектора решены"
    sample = v.VoiceStore().find("Катя")["samples"][0]
    one, two = v.StubEmbedder.vector("катя"), v.StubEmbedder.vector("катя-2")
    # Общий вектор ближе к каждой половине, чем половины друг к другу.
    assert v.cosine(sample["vector"], one) > v.cosine(one, two)
    assert v.cosine(sample["vector"], two) > v.cosine(one, two)
    assert sample["seconds"] == pytest.approx(12.0)


def test_merge_unnamed_labels_keeps_one_pending_vector(tmp_path, monkeypatch, mostik_home):
    keys = {"Собеседник 1": "катя", "Собеседник 2": "катя-2"}
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", keys)
    ms.merge_label(out, "Собеседник 2", "Собеседник 1", remember=True)
    clusters = pending(mostik_home, out)
    assert set(clusters) == {"Собеседник 1"} and clusters["Собеседник 1"]["seconds"] == pytest.approx(12.0)
    result = ms.rename(out, "Собеседник 1", "Катя", remember=True)
    assert result["person"]["samples"] == 1


def test_merge_into_differently_named_moves_sample(tmp_path, monkeypatch, mostik_home):
    keys = {"Собеседник 1": "катя", "Собеседник 2": "катя-2"}
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", keys)
    ms.rename(out, "Собеседник 1", "Катя", remember=True)
    ms.rename(out, "Собеседник 2", "Ошибка", remember=True)
    ms.merge_label(out, "Собеседник 2", "Собеседник 1", remember=True)
    store = v.VoiceStore()
    assert store.find("Ошибка") is None, "образец с неверным именем снят"
    assert len(store.find("Катя")["samples"]) == 1


def test_merge_without_memory_writes_no_voiceprints(tmp_path, monkeypatch, mostik_home):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {}, voice_memory=False)
    ms.rename(out, "Собеседник 1", "Катя")
    ms.merge_label(out, "Собеседник 2", "Собеседник 1")
    ms.unname(out, "Собеседник 1")
    assert not (mostik_home / "voices").exists()


def test_unname_and_merge_commands(tmp_path, monkeypatch):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {}, voice_memory=False)
    ms.rename(out, "Собеседник 1", "Анна")
    sink = io.StringIO()
    engine = Engine(sink, pool=object(), verifier=type("V", (), {"stop": lambda self: None})(), polishers={},
                    personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False))
    engine.handle_line(json.dumps({"cmd": "speaker_unname", "id": 1, "folder": str(out), "label": "Собеседник 1"}))
    engine.handle_line(json.dumps({"cmd": "speaker_unname", "id": 2, "folder": str(out), "label": "Собеседник 1"}))
    engine.handle_line(json.dumps({"cmd": "speaker_merge", "id": 3, "folder": str(out),
                                   "source": "Собеседник 3", "target": "Собеседник 2"}))
    replies = {r["id"]: r for r in map(json.loads, sink.getvalue().splitlines()) if "id" in r}
    assert replies[1]["ok"] and replies[1]["removed"] == "Анна"
    assert replies[2]["ok"] is False and replies[2]["code"] == "speaker"
    assert replies[3]["ok"] and replies[3]["moved"] == 1


def test_merge_on_old_duplicate_names_merges_the_whole_person(tmp_path, monkeypatch):
    out, _ = run(tmp_path, monkeypatch, "2026-10-11-100000", {}, voice_memory=False)
    data = doc(out)
    data["speaker_names"] = {"Собеседник 1": "Катя", "Собеседник 3": "Катя"}
    for turn in data["turns"]:
        if turn.get("label") in data["speaker_names"]:
            turn["speaker"] = "Катя"
    (out / "transcript.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    # Уже один человек — объединение просто сворачивает дубль.
    assert ms.merge_label(out, "Собеседник 3", "Собеседник 1")["moved"] == 0
    assert doc(out)["speaker_names"] == {"Собеседник 1": "Катя"}
    # Вторая метка Кати в другого — переезжает весь человек, не половина.
    ms.merge_label(out, "Собеседник 1", "Собеседник 2")
    assert speakers(out) == ["Я", "Катя", "Катя", "Катя"]
    assert doc(out)["speaker_names"] == {"Собеседник 2": "Катя"}
