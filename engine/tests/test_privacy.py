"""Приватность движка: облако только с consent, бэкенд по умолчанию off, «чувствительные» встречи не уходят.

Сети нет: облачный бэкенд — подделка под именем `claude`.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from test_ask import FakeBackend as AskBackend
from test_meeting_ai import FakeBackend, Sink, echo_answer, turns_of, write_meeting
from test_protocol import FakePool, send
from mostik_engine import ask as ask_mod
from mostik_engine import index as ix
from mostik_engine import meeting_ai as mai
from mostik_engine import meeting_folder, meeting_recipes, privacy
from mostik_engine.personal_glossary import PersonalGlossary
from mostik_engine.server import Engine


@pytest.fixture
def cloud_engine(tmp_path):
    sink = Sink()
    backend = FakeBackend(echo_answer)
    eng = Engine(sink, pool=FakePool(), personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False),
                 polishers={"claude": backend})
    return eng, sink, backend


# --- consent ------------------------------------------------------------------------

def test_refusal_rules():
    assert privacy.refusal({"cmd": "meeting_ai", "backend": "claude"})
    assert privacy.refusal({"cmd": "meeting_ai", "backend": "claude", "consent": "yes"}), "только настоящий true"
    assert privacy.refusal({"cmd": "meeting_ai", "backend": "claude", "consent": True}) is None
    assert privacy.refusal({"cmd": "start", "polish": {"backend": "claude"}})
    assert privacy.refusal({"cmd": "start", "polish": {"backend": "claude"}, "consent": True}) is None
    assert privacy.refusal({"cmd": "meeting_ai", "backend": "mlx"}) is None, "локальная модель не облако"
    assert privacy.refusal({"cmd": "start", "polish": {"backend": "off"}}) is None
    assert privacy.refusal({"cmd": "ask", "backend": "claude", "consent": False}), "исключений по имени команды нет"


@pytest.mark.parametrize("command", [
    {"cmd": "meeting_ai", "mode": "brief", "backend": "claude"},
    {"cmd": "meeting_recipe", "recipe": "followup-email", "backend": "claude"},
    {"cmd": "edit", "session": "e1", "selection": "Текст.", "edit_text": "короче", "backend": "claude"},
    {"cmd": "intent", "text": "создай встречу завтра в три", "backend": "claude"},
    {"cmd": "polish_text", "text": "текст", "polish": {"backend": "claude", "style": "plain"}},
    {"cmd": "start", "session": "s1", "language": "ru", "polish": {"backend": "claude", "style": "plain"}},
])
def test_cloud_command_without_consent_is_refused(cloud_engine, tmp_path, command):
    eng, sink, backend = cloud_engine
    folder = write_meeting(tmp_path / "m", turns_of(4))
    fields = dict(command, folder=str(folder)) if command["cmd"].startswith("meeting_") else dict(command)
    send(eng, id=9, **fields)
    error = sink.wait(lambda e: e.get("id") == 9)
    assert error["event"] == "error" and error["code"] == "consent_required"
    assert "consent" in error["message"] and "не отправлен" in error["message"]
    assert backend.calls == [], "до облака не дошло"
    assert "s1" not in eng.sessions


# --- бэкенд по умолчанию — off -----------------------------------------------------------

def test_default_backend_is_off_not_cloud(tmp_path):
    folder = write_meeting(tmp_path / "m", turns_of(4))
    backend = FakeBackend(echo_answer)
    with pytest.raises(ValueError, match="'off'"):
        mai.run_meeting_ai({"folder": str(folder)}, {"claude": backend}, None)
    with pytest.raises(ValueError, match="'off'"):
        meeting_recipes.run_recipe({"folder": str(folder), "recipe": "followup-email"}, {"claude": backend})
    assert backend.calls == []


def test_voice_edit_without_backend_does_not_go_to_cloud(cloud_engine):
    eng, sink, backend = cloud_engine
    send(eng, cmd="edit", id=5, session="e1", selection="Текст.", edit_text="короче", consent=True)
    reply = sink.wait(lambda e: e.get("id") == 5)
    assert reply["event"] == "error" and "'off'" in reply["message"]
    assert backend.calls == []


# --- «чувствительная» встреча ----------------------------------------------------------------

def test_sensitive_meeting_never_goes_to_cloud(tmp_path):
    folder = write_meeting(tmp_path / "m", turns_of(4))
    meeting_folder.update_manifest(folder, {"sensitive": True})
    cloud = FakeBackend(echo_answer)
    with pytest.raises(privacy.SensitiveMeeting, match="никуда, кроме этого Mac"):
        mai.run_meeting_ai({"folder": str(folder), "backend": "claude", "consent": True}, {"claude": cloud}, None)
    refused = meeting_recipes.run_recipe({"folder": str(folder), "recipe": "followup-email", "backend": "claude"},
                                         {"claude": cloud})
    assert refused["status"] == "refused"
    assert cloud.calls == []
    # На этом Mac — можно: локальная модель сводку делает.
    local = FakeBackend(echo_answer)
    done = mai.run_meeting_ai({"folder": str(folder), "backend": "mlx"}, {"mlx": local}, None)
    assert done["status"] != "failed" and local.calls


def test_sensitive_meeting_protocol_error(cloud_engine, tmp_path):
    eng, sink, backend = cloud_engine
    folder = write_meeting(tmp_path / "m", turns_of(4))
    (folder / "meeting.md").write_text("---\nsensitive: true\n---\n# Синк\n", encoding="utf-8")
    send(eng, cmd="meeting_ai", id=3, folder=str(folder), mode="brief", backend="claude", consent=True)
    error = sink.wait(lambda e: e.get("id") == 3, timeout=10)
    assert error["event"] == "error" and error["code"] == "sensitive"
    assert backend.calls == []


class _Fixed:
    name = "fixed"

    def __init__(self, hits):
        self.hits = hits

    def search(self, query, *, scope="all", k=8):
        return list(self.hits)


def _hit(folder, text, n):
    return ix.Hit(chunk_id=n, kind=ix.KIND_MEETING, ref=f"{folder.name}#{n}", title="Синк", text=text, context="",
                  path=str(folder / "transcript.json"), root=str(folder.parent), file_title="Синк", date=None,
                  line=None, turn=n, speaker="Пётр", at=1.0)


def test_ask_cloud_answer_skips_sensitive_passages(tmp_path):
    open_ = write_meeting(tmp_path / "open", turns_of(2))
    secret = write_meeting(tmp_path / "secret", turns_of(2))
    meeting_folder.update_manifest(secret, {"sensitive": True})
    (secret / "frames").mkdir()
    frame = ix.Hit(chunk_id=9, kind=ix.KIND_MEETING, ref="secret#f", title="кадр", text="слайд с зарплатами",
                   context="", path=str(secret / "frames" / "0001.ocr.txt"), root=str(tmp_path), file_title="Синк",
                   date=None, line=None, turn=None, speaker=None, at=2.0)
    hits = [_hit(secret, "увольнение Ивана", 1), _hit(open_, "релиз 14 октября", 2), frame]
    cloud = AskBackend("<answer>Релиз 14 октября [1].</answer>")
    result = ask_mod.answer("Когда релиз?", retriever=_Fixed(hits), backend=cloud, consent=True, cloud=True)
    sent = cloud.calls[0][1]
    assert "релиз 14 октября" in sent
    assert "увольнение" not in sent and "зарплатами" not in sent
    assert [c["meeting"] for c in result["citations"]] == ["open"]
    # Локальная модель видит всё: отрывки не уходят с этого Mac.
    local = AskBackend("<answer>Релиз 14 октября [2].</answer>")
    result = ask_mod.answer("Когда релиз?", retriever=_Fixed(hits), backend=local, consent=True, cloud=False)
    assert "увольнение" in local.calls[0][1] and len(result["citations"]) == 3


def _frames_corpus(meetings):
    """Настоящий индекс: открытая и «чувствительная» встречи, у второй — кадр экрана с OCR."""
    write_meeting(meetings / "2026-10-01-1000", [{"speaker": "Я", "start": 0, "end": 5,
                                                  "text": "Бюджет отдела утвердили на квартал."}])
    secret = write_meeting(meetings / "2026-10-02-1000", [{"speaker": "Я", "start": 0, "end": 5,
                                                           "text": "Обсудили увольнения в отделе."}])
    (secret / "frames").mkdir()
    (secret / "frames" / "000130.ocr.txt").write_text(
        "Бюджет отдела: зарплаты сотрудников, премии и сокращения на квартал.\n", encoding="utf-8")
    index = ix.AskIndex(meetings.parent / "index.sqlite")
    index.refresh([], meetings=meetings)
    # Пометку поставили после записи и индексации: кадр уже в индексе, фильтр выдачи обязан его отсечь.
    meeting_folder.update_manifest(secret, {"sensitive": True})
    return index


def test_ask_cloud_skips_frames_of_sensitive_meeting_in_real_index(tmp_path):
    index = _frames_corpus(tmp_path / "meetings")
    hits = index.retriever().search("бюджет отдела квартал", scope="all", k=8)
    assert any("зарплаты" in hit.text for hit in hits), "кадр есть в индексе — иначе тест ничего не проверяет"
    cloud = AskBackend("<answer>Бюджет утвердили [1].</answer>")
    result = ask_mod.answer("Какой бюджет отдела на квартал?", retriever=index.retriever(), backend=cloud,
                            consent=True, cloud=True)
    sent = cloud.calls[0][1]
    assert "утвердили" in sent
    assert "зарплаты" not in sent and "увольнения" not in sent
    assert all("2026-10-02-1000" not in (c.get("path") or "") for c in result["citations"])


def test_local_ask_sees_frames_of_sensitive_meeting(tmp_path):
    """Кадры встречи «только на этом Mac» снимаются и индексируются, как её расшифровка (2026-10-16):
    пометка до индексации их не прячет от локальной модели."""
    meetings = tmp_path / "meetings"
    secret = write_meeting(meetings / "2026-10-02-1000", [{"speaker": "Я", "start": 0, "end": 5, "text": "Отдел."}])
    meeting_folder.update_manifest(secret, {"sensitive": True})
    (secret / "frames").mkdir()
    (secret / "frames" / "000130.ocr.txt").write_text("Слайд: премии отдела за квартал.\n", encoding="utf-8")
    index = ix.AskIndex(tmp_path / "index.sqlite")
    index.refresh([], meetings=meetings)
    assert any("премии" in hit.text for hit in index.retriever().search("премии отдела квартал", k=8))
    local = AskBackend("<answer>Премии [1].</answer>")
    ask_mod.answer("Что с премиями?", retriever=index.retriever(), backend=local, consent=True, cloud=False)
    assert "премии" in local.calls[0][1]
    cloud = AskBackend("<answer>Не знаю.</answer>")
    ask_mod.answer("Что с премиями?", retriever=index.retriever(), backend=cloud, consent=True, cloud=True)
    assert all("премии" not in call[1] for call in cloud.calls)


def test_agent_search_hides_frames_of_sensitive_meeting(mostik_home):
    from mostik_engine import agent_api

    _frames_corpus(mostik_home / "meetings")  # index.sqlite лежит в MOSTIK_HOME — его и читает агент
    assert ix.index_path() == mostik_home / "index.sqlite"
    for scope in ("all", "sources", "meetings"):
        texts = " ".join(item["text"] for item in agent_api.search("бюджет отдела квартал", scope=scope)["items"])
        assert "зарплаты" not in texts and "увольнения" not in texts, scope
    texts = " ".join(item["text"] for item in agent_api.search("бюджет отдела квартал", scope="all")["items"])
    assert "утвердили" in texts


# --- офлайн-окружение (п. 5) и адрес моделей (п. 8) ------------------------------------------

def test_meeting_transcriber_runs_offline_without_update_check(monkeypatch, tmp_path):
    from mostik_engine import meeting

    seen = {}

    class FakeProcess:
        def __init__(self, command, env=None, **kwargs):
            seen["env"] = env
            self.stderr = iter(())
            self.stdout = None

        def wait(self):
            return 0

        def communicate(self, *args, **kwargs):
            return "", ""

        returncode = 0

    monkeypatch.delenv("HF_HUB_OFFLINE", raising=False)
    monkeypatch.setattr(meeting.subprocess, "Popen", FakeProcess)
    try:
        meeting.run_track(["true"], track="mic", index=0, count=1, emit=lambda event: None)
    except Exception:  # noqa: BLE001 — исход подделки не важен, важна среда запуска
        pass
    env = seen["env"]
    assert env["HF_HUB_OFFLINE"] == "1" and env["HF_HUB_DISABLE_TELEMETRY"] == "1"
    assert env["TRANSCRIBER_NO_UPDATE_CHECK"] == "1"


def test_engine_entry_sets_offline_env_before_server_import():
    from pathlib import Path

    from mostik_engine import privacy as p

    source = (Path(p.__file__).parent / "__main__.py").read_text(encoding="utf-8")
    assert source.index("os.environ.update(OFFLINE_ENV)") < source.index("from .server import main"), \
        "huggingface_hub читает HF_HUB_OFFLINE при импорте — окружение до сервера"
    assert p.OFFLINE_ENV == {"HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TRANSCRIBER_NO_UPDATE_CHECK": "1"}


def test_models_base_url_comes_only_from_the_app(monkeypatch):
    from mostik_engine import model_store as ms

    monkeypatch.setenv("MOSTIK_MODELS_BASE_URL", "https://mirror.example.net")
    assert ms.Downloader(specs=[]).base_url == ms.DEFAULT_BASE_URL, "окружение процесса не уводит загрузку"
    assert ms.Downloader(specs=[], base_url="http://127.0.0.1:8000").base_url == "http://127.0.0.1:8000"


def test_models_download_rejects_non_http_base_url(cloud_engine):
    eng, sink, _ = cloud_engine
    send(eng, cmd="models_download", id=4, keys=["vad"], base_url="file:///etc")
    reply = sink.wait(lambda e: e.get("id") == 4)
    assert reply["event"] == "error" and "base_url" in reply["message"]


# --- хук SessionStart: участники встречи только по явной опции (п. 3) ----------------------------

def test_session_hook_sends_meeting_title_without_attendees_by_default(mostik_home, tmp_path, monkeypatch):
    import datetime as _dt
    import io
    import json

    from mostik_engine import agent_api, cli
    from test_agent_cli import write_calendar

    mostik_home.mkdir(parents=True, exist_ok=True)
    now = _dt.datetime(2026, 10, 12, 11, 0).astimezone()  # понедельник, рабочие часы
    write_calendar(mostik_home, now + _dt.timedelta(minutes=30))
    assert agent_api.HOOK_DEFAULTS["includeAttendees"] is False
    assert agent_api.HOOK_DEFAULTS["hookEnabled"] is False, "подсказка агенту по умолчанию выключена"
    on = {"hookEnabled": True, "hookExplicit": True}
    (mostik_home / "settings.json").write_text(json.dumps({"agentContext": on}))

    context = agent_api.session_context(str(tmp_path), now)
    assert "Планирование Q4" in context["text"]
    assert "Пётр Тестов" not in context["text"] and "участники" not in context["text"]
    assert "attendees" not in context["meeting"], "и в данных ответа участников нет"

    # Вывод самого хука — то, что агент отправит в облако.
    monkeypatch.setattr(agent_api, "_now", lambda: now)
    out = io.StringIO()
    cli.hook_session_start(io.StringIO(json.dumps({"cwd": str(tmp_path), "source": "startup"})), out)
    assert "Планирование Q4" in out.getvalue() and "Пётр" not in out.getvalue()

    # Явная опция в Настройках — участники идут.
    (mostik_home / "settings.json").write_text(json.dumps({"agentContext": {**on, "includeAttendees": True}}))
    context = agent_api.session_context(str(tmp_path), now)
    assert "участники: Пётр Тестов, Анна Пример" in context["text"]
    (mostik_home / "settings.json").write_text(json.dumps({"agentContext": {**on, "includeAttendees": "yes"}}))
    assert "Пётр" not in agent_api.session_context(str(tmp_path), now)["text"], "только настоящий true"


# --- Р2, низкие: папка встреч как источник ---------------------------------------------------------

def test_meetings_folder_as_source_skips_sensitive_meeting(tmp_path):
    """Папку встреч добавили в источники «Спросить»: файлы чувствительной встречи как источники
    не индексируются; её расшифровка и кадры — только как встреча (их режет `drop_sensitive`)."""
    meetings = tmp_path / "meetings"
    index = _frames_corpus(meetings)
    secret = meetings / "2026-10-02-1000"
    (secret / "notes.md").write_text("# Заметки\n\nСписок на сокращение.\n", encoding="utf-8")
    open_meeting = meetings / "2026-10-01-1000"
    (open_meeting / "notes.md").write_text("# Заметки\n\nБюджет на квартал.\n", encoding="utf-8")
    index.refresh([str(meetings)], meetings=meetings)
    with index.connect() as db:
        paths = [row[0] for row in db.execute("SELECT path FROM files")]
    assert not [p for p in paths if "/2026-10-02-1000/" in p and not p.endswith("transcript.json")
                and "/frames/" not in p], paths
    assert any(p.endswith("2026-10-01-1000/notes.md") for p in paths), "открытая встреча как источник — индексируется"
