"""Имена по разговору (speaker_context): зацепки кодом, проверка ответа модели, применение и подсказки."""
from __future__ import annotations

import json

from test_meeting_ai import FakeBackend, wrap
from test_meeting_templates import topic_answer
from mostik_engine import meeting_ai as mai
from mostik_engine import speaker_context as sc


def turn(i, label, text):
    source = "mic" if label == "Я" else "system"
    item = {"id": i, "speaker": label, "source": source, "start": i * 5.0, "end": i * 5.0 + 4, "text": text}
    if source == "system":
        item["label"] = label
    return item


GROUP = [
    turn(0, "Я", "Всем привет, начинаем."),
    turn(1, "Собеседник 1", "Привет, меня зовут Тимур, я из платформы."),
    turn(2, "Я", "Ксюш, а у тебя что по срокам?"),
    turn(3, "Собеседник 2", "Я сделала оценку, две недели."),
    turn(4, "Собеседник 3", "Тимур говорил, что можно быстрее."),
    turn(5, "Я", "Ли, ты согласна?"),
    turn(6, "Собеседник 3", "Да, вполне."),
]


def meeting(tmp_path, turns, attendees=(), manifest_attendees=None):
    folder = tmp_path / "2026-11-10-120000"
    folder.mkdir()
    (folder / "transcript.json").write_text(json.dumps({
        "id": folder.name, "title": "Синк", "language": "ru", "attendees": list(attendees),
        "duration_seconds": 60, "turns": turns, "speaker_names": {},
    }, ensure_ascii=False), encoding="utf-8")
    (folder / "transcript.md").write_text("# Синк\n", encoding="utf-8")
    if manifest_attendees is not None:
        (folder / "manifest.json").write_text(json.dumps({"attendees": manifest_attendees}, ensure_ascii=False))
    return folder


def load(folder):
    return json.loads((folder / "transcript.json").read_text(encoding="utf-8"))


def test_stems_cover_diminutives_and_latin():
    assert {"ксени", "ксюш"} <= sc.stems("Ксения Орлова")
    assert sc.mentions("Ксюш, а ты?", sc.stems("Ксения Орлова"))
    assert not sc.mentions("Ксерокс сломался", sc.stems("Ксения Орлова"))
    assert sc.mentions("Борис, привет", sc.stems("Boris K. Smith"))
    assert sc.self_intro("Привет, меня зовут Тимур, я из платформы.") == "Тимур"


def test_no_hits_no_model_call(tmp_path):
    folder = meeting(tmp_path, [turn(0, "Я", "Начнём"), turn(1, "Собеседник 1", "Давайте по задачам")],
                     attendees=["Ксения Орлова"])
    backend = FakeBackend([])
    assert sc.identify(folder, mai.Caller(backend, "ru")) is None
    assert backend.calls == []


def test_identify_applies_high_and_suggests_medium(tmp_path):
    folder = meeting(tmp_path, GROUP, attendees=["Тимур Белов", "Ксения Орлова", "Лилия Смирнова"])
    answer = {"speakers": [
        {"label": "Собеседник 1", "name": "Тимур Белов", "confidence": "high",
         "evidence": "меня зовут Тимур, я из платформы"},
        {"label": "Собеседник 2", "name": "Ксюша", "confidence": "high", "evidence": "Ксюш, а у тебя что по срокам?"},
        {"label": "Собеседник 3", "name": "Лилия Смирнова", "confidence": "medium", "evidence": "Ли, ты согласна"},
    ]}
    backend = FakeBackend([wrap(answer)])
    block = sc.identify(folder, mai.Caller(backend, "ru"), model="sonnet")
    system, user = backend.calls[0]
    assert "Без имени: Собеседник 1, Собеседник 2, Собеседник 3" in user and "<transcript>" in user
    document = load(folder)
    assert document["speaker_names"] == {"Собеседник 1": "Тимур Белов", "Собеседник 2": "Ксения Орлова"}
    assert [t["speaker"] for t in document["turns"][1:4]] == ["Тимур Белов", "Я", "Ксения Орлова"]
    # «Ли» — две буквы, имя в цитате не узнаётся: подсказкой не становится, а уходит в отброшенные.
    assert {d["label"] for d in block["dropped"]} == {"Собеседник 3"}
    assert document["speaker_context"]["model"] == "sonnet"
    # Повторный вызов не зовёт модель: шаг уже сделан.
    assert sc.identify(folder, mai.Caller(FakeBackend([]), "ru")) is None


def test_validate_rejects_hallucinations(tmp_path):
    folder = meeting(tmp_path, GROUP, attendees=["Тимур Белов", "Ксения Орлова"])
    document = load(folder)
    proposals = sc.parse({"speakers": [
        {"label": "Собеседник 9", "name": "Тимур Белов", "confidence": "high", "evidence": "меня зовут Тимур"},
        {"label": "Собеседник 1", "name": "Пётр Сидоров", "confidence": "high", "evidence": "меня зовут Тимур"},
        {"label": "Собеседник 2", "name": "Ксения Орлова", "confidence": "high", "evidence": "Ксюша всё сделала"},
        {"label": "Собеседник 3", "name": "Тимур Белов", "confidence": "high", "evidence": "Тимур говорил, что можно быстрее"},
        {"label": "Собеседник 1", "name": "Тимур Белов", "confidence": "medium", "evidence": "меня зовут Тимур"},
    ]})
    apply, suggest, dropped = sc.validate(proposals, document, ["Тимур Белов", "Ксения Орлова"], set())
    reasons = [d["reason"] for d in dropped]
    assert "метка уже названа или её нет" in reasons
    assert "имени нет среди приглашённых" in reasons
    assert "цитаты нет в расшифровке" in reasons
    # Метка 3 говорит о Тимуре в третьем лице — себя по имени не зовут, отброшено.
    assert "имя звучит в речи самой метки" in reasons
    assert apply == [] and [s["label"] for s in suggest] == ["Собеседник 1"]


def test_medium_goes_to_suggestions_and_confirm_names(tmp_path):
    from mostik_engine import meeting_speakers

    folder = meeting(tmp_path, GROUP, attendees=["Ксения Орлова"])
    answer = {"speakers": [{"label": "Собеседник 2", "name": "Ксения Орлова", "confidence": "medium",
                            "evidence": "Ксюш, а у тебя что по срокам"}]}
    sc.identify(folder, mai.Caller(FakeBackend([wrap(answer)]), "ru"))
    suggestion = load(folder)["voices"]["suggestions"][0]
    assert suggestion["label"] == "Собеседник 2" and suggestion["person_id"] == "context:Ксения Орлова"
    assert 0 < suggestion["score"] < 1
    meeting_speakers.reject(folder, "Собеседник 2")
    # Отклонённая подсказка не возвращается при повторном прогоне.
    sc.identify(folder, mai.Caller(FakeBackend([wrap(answer)]), "ru"), force=True)
    assert load(folder)["voices"]["suggestions"] == []


def test_self_attendee_is_not_a_candidate(tmp_path):
    folder = meeting(tmp_path, GROUP, manifest_attendees=[{"name": "Олег Петров", "self": True},
                                                          {"name": "Тимур Белов", "self": False}])
    invited, _ = sc._people(load(folder), json.loads((folder / "manifest.json").read_text()))
    assert invited == ["Тимур Белов"]


def test_run_meeting_ai_names_before_summary(tmp_path):
    folder = meeting(tmp_path, GROUP, attendees=["Тимур Белов"])
    names = {"speakers": [{"label": "Собеседник 1", "name": "Тимур Белов", "confidence": "high",
                           "evidence": "меня зовут Тимур"}]}

    def answer(system, user):
        if system == sc.SYSTEM:
            return wrap(names)
        return topic_answer(["Сроки"])(system, user)

    backend = FakeBackend(answer)
    result = mai.run_meeting_ai({"folder": str(folder), "backend": "claude"}, {"claude": backend}, None)
    assert result["names"]["applied"] == 1
    # Сводка уже видит имя, а не метку.
    assert "Тимур Белов" in backend.calls[1][1]


def test_run_meeting_ai_survives_names_failure(tmp_path):
    folder = meeting(tmp_path, GROUP, attendees=["Тимур Белов"])

    def answer(system, user):
        if system == sc.SYSTEM:
            return wrap({"nope": 1})
        return topic_answer(["Сроки"])(system, user)

    result = mai.run_meeting_ai({"folder": str(folder), "backend": "claude"}, {"claude": FakeBackend(answer)}, None)
    assert result["status"] != "failed" and result["names"]["error"] == "Unparsed"
