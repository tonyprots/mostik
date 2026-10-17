"""Локальная LLM (MLX): клиент процесса, потоковая полировка, откаты, подача окон из сессии.

Быстрые тесты гоняют фейковый процесс с тем же протоколом строк JSON. Живой
тест (`-m slow`) поднимает настоящую модель из кэша HF, если она скачана.
"""
from __future__ import annotations

import json
import threading
import sys
import textwrap
import time

import pytest

from conftest import FakePool, FakeVerifier
from test_polish import dictate
from test_protocol import Sink, send
from mostik_engine import llm_mlx as L
from mostik_engine import polish as P
from mostik_engine.personal_glossary import PersonalGlossary
from mostik_engine.server import Engine

FAKE = textwrap.dedent(r'''
    import json, sys, time, os
    mode = os.environ.get("MOSTIK_TEST_FAKE_MODE", "ok")
    if mode == "broken":
        print(json.dumps({"ready": False, "error": "нет весов"}), flush=True)
        sys.exit(0)
    print(json.dumps({"ready": True, "seconds": 0.01}), flush=True)
    ops = []
    log = os.environ.get("MOSTIK_TEST_FAKE_LOG")
    for line in sys.stdin:
        req = json.loads(line)
        ops.append(req.get("op"))
        if log:
            with open(log, "a") as fh:
                fh.write(json.dumps(req, ensure_ascii=False) + "\n")
        if req["op"] in ("complete", "finish"):
            if mode == "slow":
                time.sleep(3)
            if mode == "crash":
                sys.exit(3)
            lines = req["user"].split("\n"); body = lines[1] if len(lines) > 1 else lines[0]
            answer = "<polished>" + body.replace("ну ", "").capitalize() + ".</polished>"
            if mode == "garbage":
                answer = "Конечно! Вот ответ."
            print(json.dumps({"id": req["id"], "text": answer, "ops": ops[:-1]}, ensure_ascii=False), flush=True)
''')


@pytest.fixture
def fake(tmp_path, monkeypatch):
    script = tmp_path / "fake_llm.py"
    script.write_text(FAKE)
    log = tmp_path / "ops.jsonl"
    monkeypatch.setenv("MOSTIK_TEST_FAKE_LOG", str(log))

    def make(mode="ok", idle_s=300.0):
        monkeypatch.setenv("MOSTIK_TEST_FAKE_MODE", mode)
        client = L.LlmClient(L.MODELS[L.DEFAULT_MODEL], command=[sys.executable, str(script)], idle_s=idle_s)
        return L.MlxBackend(client=client), log

    yield make


def ops(log):
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def make_hub(tmp_path, repo, files=("model.safetensors",), index=None):
    # Ревизия — из манифеста: другие снапшоты в общем кэше движок не грузит (П10).
    revision = L.pinned_revision(repo) or "abc"
    snap = tmp_path / "hub" / ("models--" + repo.replace("/", "--")) / "snapshots" / revision
    snap.mkdir(parents=True)
    (snap / "config.json").write_text("{}")
    for name in files:
        (snap / name).write_bytes(b"x")
    if index is not None:
        (snap / "model.safetensors.index.json").write_text(json.dumps({"weight_map": index}))
    refs = snap.parent.parent / "refs"
    refs.mkdir()
    (refs / "main").write_text(revision)
    return tmp_path / "hub", snap


def test_model_path_and_status_missing(tmp_path):
    repo = L.MODELS[L.DEFAULT_MODEL].repo
    hub, snap = make_hub(tmp_path, repo)
    assert L.model_path(repo, hub) == snap
    assert L.model_path("mlx-community/нет-такой", hub) is None
    shard_hub, _ = make_hub(tmp_path / "s", repo, files=("a.safetensors",),
                            index={"w1": "a.safetensors", "w2": "b.safetensors"})
    assert L.model_path(repo, shard_hub) is None  # второго шарда нет — модель не докачана
    backend = L.MlxBackend(hub=tmp_path / "пусто")
    status = backend.status()
    assert status["available"] is False and status["reason"] == "model_missing"
    assert "не установлена" in status["message"] and "ГБ" in status["message"]
    assert status["size_gb"] == L.MODELS[L.DEFAULT_MODEL].size_gb
    outcome = P.polish(backend, P.PolishRequest("ну привет"))
    assert outcome.status == "unavailable" and outcome.text == "ну привет"
    # Потока у недоступной модели нет: базовый копит куски, финиш — честный откат.
    stream = backend.open_stream(P.PolishRequest("", "ru", "plain"))
    assert not isinstance(stream, L.MlxStream)
    stream.feed("ну привет")
    assert stream.finish().status == "unavailable"


def test_registered_as_default_backend():
    assert isinstance(P.default_backends()["mlx"], L.MlxBackend)


def test_complete_through_process(fake):
    backend, _ = fake()
    assert backend.status()["available"] is True
    outcome = P.polish(backend, P.PolishRequest("ну привет мир"), timeout=10)
    assert outcome.polished and outcome.text == "Привет мир."
    assert backend.status()["loaded"] is True
    backend.stop()
    assert not backend.client.running()


def test_stream_feeds_then_finishes_with_terms_after_text(fake):
    backend, log = fake()
    stream = backend.open_stream(P.PolishRequest("", "ru", "plain"))
    assert isinstance(stream, L.MlxStream) and stream.opened
    stream.feed("ну запусти parakeet")
    stream.feed("  ")
    stream.feed("и проверь кэш")
    stream.request.terms = ["Parakeet"]
    stream.request.keep = ["кэш"]
    outcome = stream.finish("ну запусти parakeet и проверь кэш", timeout=10)
    assert outcome.polished and outcome.text == "Запусти Parakeet и проверь кэш."
    sent = ops(log)
    assert [o["op"] for o in sent] == ["open", "feed", "feed", "finish"]
    assert sent[0]["system"] == L.stream_system("ru", "plain") and "Parakeet" not in sent[0]["system"]
    assert sent[0]["user_head"] == "<transcript>\n"
    finish = sent[-1]
    assert finish["system"] == sent[0]["system"]
    assert finish["user"].startswith("<transcript>\nну запусти parakeet и проверь кэш\n</transcript>\n")
    assert "«Parakeet»" in finish["user"] and "«кэш»" in finish["user"]
    backend.stop()


def test_dev_stream_sends_project_vocabulary_after_text(fake):
    backend, log = fake()
    stream = backend.open_stream(P.PolishRequest("", "ru", "dev"))
    stream.request.vocabulary = ["FastAPI", "Redis"]
    assert stream.finish("добавь эндпоинт в фаст апи", timeout=10).polished
    sent = ops(log)
    assert "разработчик" in sent[0]["system"] and "Словарь проекта" not in sent[0]["system"]
    assert "Словарь проекта" in sent[-1]["user"] and "«FastAPI», «Redis»" in sent[-1]["user"]
    backend.stop()


def test_polish_and_meeting_share_transcript_tag_but_not_priority(fake):
    backend, log = fake()
    backend.complete(P.system_prompt("ru", "plain"), P.user_message("ну привет"), 10)
    backend.complete("Ты разбираешь расшифровку встречи", "<transcript>\n[0] 00:01 Я: привет\n</transcript>", 10)
    sent = ops(log)
    assert sent[0]["prefill"] == L.POLISH_PREFILL and "priority" not in sent[0]
    assert sent[1]["priority"] == "background" and "prefill" not in sent[1]
    backend.stop()


def test_stream_cancel_and_second_finish_is_plain_complete(fake):
    backend, log = fake()
    stream = backend.open_stream(P.PolishRequest("", "en", "brief"))
    stream.feed("hello")
    stream.cancel()
    assert stream.chunks == [] and not stream.opened
    outcome = stream.finish("ну hello there", timeout=10)
    assert outcome.polished
    assert [o["op"] for o in ops(log)] == ["open", "feed", "cancel", "complete"]
    backend.stop()


@pytest.mark.parametrize("mode,status", [("slow", "timeout"), ("crash", "failed"), ("garbage", "bad_output"),
                                         ("broken", "unavailable")])
def test_failures_fall_back_to_raw_text(fake, mode, status):
    backend, _ = fake(mode)
    # Процесс поднимаем заранее: под нагрузкой запуск Python дольше секунды, и бюджет 1 с
    # уходил на загрузку — `crash` давал `timeout` вместо `failed`. Меряем только вызов.
    backend.warm()
    backend.client.wait_ready(30)
    started = time.monotonic()
    outcome = P.polish(backend, P.PolishRequest("ну привет мир"), timeout=1.0)
    assert (outcome.text, outcome.polished, outcome.status) == ("ну привет мир", False, status)
    assert time.monotonic() - started < 2.5
    stream = backend.open_stream(P.PolishRequest("", "ru", "plain"))
    stream.feed("ну привет мир")
    streamed = stream.finish(timeout=1.0)
    assert (streamed.text, streamed.polished) == ("ну привет мир", False)
    backend.stop()


def test_sweep_unloads_after_idle(fake):
    backend, _ = fake(idle_s=0.2)
    assert P.polish(backend, P.PolishRequest("ну раз"), timeout=10).polished
    assert backend.client.running()
    assert backend.sweep(time.monotonic()) is False
    assert backend.sweep(time.monotonic() + 1) is True
    assert not backend.client.running()
    assert P.polish(backend, P.PolishRequest("ну два"), timeout=10).polished  # поднимается снова
    backend.stop()


def test_warm_starts_process(fake):
    backend, _ = fake()
    assert backend.warm() is True and backend.client.running()
    backend.stop()


def test_stream_notes_layout():
    assert L.stream_notes("ru", [], []) == ""
    user = L.stream_user("текст", "en", ["Mostik", "Mostik"], [])
    assert user.startswith("<transcript>\nтекст\n</transcript>\nTerms") and user.count("Mostik") == 1
    dev = L.stream_user("текст", "ru", ["Mostik"], [], ["FastAPI", "Mostik"])
    assert "Словарь проекта" in dev and "«FastAPI»" in dev and dev.count("Mostik") == 1


# --- сессия и протокол --------------------------------------------------------------------

class StreamingBackend(P.PolishBackend):
    """Поток без процесса: запоминает поданные куски, полирует по итоговому тексту."""

    name = "mlx"
    streaming = True

    def __init__(self):
        self.streams = []

    def status(self):
        return {"available": True}

    def complete(self, system, user, timeout):
        return "<polished>" + user.split("\n")[1].upper() + "</polished>"

    def open_stream(self, request):
        stream = RecordingStream(self, request)
        self.streams.append(stream)
        return stream


class RecordingStream(P.PolishStream):
    cancelled = False

    def cancel(self):
        self.cancelled = True
        super().cancel()


def test_session_feeds_windows_to_stream_and_claude_unchanged(tmp_path):
    sink = Sink()
    verifier = FakeVerifier()
    streaming = StreamingBackend()

    class Claude(P.PolishBackend):
        name = "claude"
        calls = []

        def status(self):
            return {"available": True}

        def complete(self, system, user, timeout):
            self.calls.append(user)
            return "<polished>Облако.</polished>"

        def open_stream(self, request):
            raise AssertionError("claude не потоковый: окна ему не подаются")

    claude = Claude()
    eng = Engine(sink, pool=FakePool(), verifier=verifier,
                 personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False),
                 polishers={"claude": claude, "mlx": streaming})
    verifier.sink = eng._on_verifier
    dictate(eng, "m1", 10, polish={"backend": "mlx", "style": "plain"})
    final = sink.wait(lambda e: e.get("event") == "final" and e.get("session") == "m1")
    assert final["polished"] is True and final["text"] == final["unpolished_text"].upper()
    assert len(streaming.streams) == 1 and streaming.streams[0].chunks  # окна пришли по ходу речи
    dictate(eng, "c1", 20, polish={"backend": "claude", "style": "plain"})
    cloud = sink.wait(lambda e: e.get("event") == "final" and e.get("session") == "c1")
    assert cloud["polished"] is True and cloud["text"] == "Облако." and len(claude.calls) == 1
    assert len(streaming.streams) == 1


def test_cancel_cancels_stream(tmp_path):
    sink = Sink()
    streaming = StreamingBackend()
    eng = Engine(sink, pool=FakePool(), verifier=FakeVerifier(),
                 personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False),
                 polishers={"mlx": streaming})
    send(eng, cmd="start", id=1, session="x", language="ru", project=None, verify=False,
         polish={"backend": "mlx", "style": "plain"})
    sink.wait(lambda e: e.get("id") == 1)
    send(eng, cmd="cancel", id=2, session="x")
    sink.wait(lambda e: e.get("id") == 2)
    assert streaming.streams and streaming.streams[0].cancelled


# --- живой тест -------------------------------------------------------------------------

@pytest.mark.slow
def test_live_model_stream_matches_plain():
    """Механика потока на живой модели. Под нагрузкой (load ~50) тест падал по таймауту:
    60 с первого `finish` включали холодную загрузку модели в процесс (≈29 с при load ~20,
    растёт с нагрузкой и давлением на память), а вывод при жадном декодировании от нагрузки
    не зависит. Поэтому загрузка ждётся отдельно, вызовам — запас, а «модель уже загружена»
    проверяется по тому же процессу, а не по секундомеру."""
    backend = L.MlxBackend()
    if not backend.status()["available"]:
        pytest.skip(backend.status().get("message"))
    try:
        assert backend.warm()
        assert backend.client.wait_ready(LIVE_LOAD_TIMEOUT_S), backend.client.failure or "модель не загрузилась"
        pid = backend.client.pid
        text = ("ну значит э надо перезапустить cron задачу во вторник нет в среду "
                "и как бы проверить что постгрес поднимается")
        stream = backend.open_stream(P.PolishRequest("", "ru", "plain"))
        for chunk in ("ну значит э надо перезапустить cron задачу", "во вторник нет в среду",
                      "и как бы проверить что постгрес поднимается"):
            stream.feed(chunk)
        stream.request.terms = ["Postgres", "cron"]
        streamed = stream.finish(text, timeout=LIVE_CALL_TIMEOUT_S)
        assert streamed.polished, streamed.detail
        # Качество (самоисправления) — дело стенда `bench/llm_bench.py`; здесь — механика потока.
        assert "Postgres" in streamed.text and "сред" in streamed.text
        plain = P.polish(backend, P.PolishRequest(text, "ru", "plain", terms=["Postgres", "cron"]),
                         timeout=LIVE_CALL_TIMEOUT_S)
        assert plain.polished, plain.detail
        assert "Parakeet" in plain.text
        again = backend.open_stream(P.PolishRequest("", "ru", "plain"))
        again.feed("ну проверка")
        assert again.finish("ну проверка связи", timeout=LIVE_CALL_TIMEOUT_S).polished
        assert backend.client.pid == pid, "модель не перезагружалась между вызовами"
    finally:
        backend.stop()


# Холодная загрузка Gemma 4 E2B: ≈29 с при load ~20; запас на загруженную машину.
LIVE_LOAD_TIMEOUT_S = 300
# Сам вызов — 0,5–4 с на тихой машине; запас, чтобы мерить механику, а не нагрузку.
LIVE_CALL_TIMEOUT_S = 120


# --- планировщик процесса модели: одна модель на все роли ----------------------------------

class StepWorker:
    """Фейковая модель для `Scheduler`: фон — генератор из `n` шагов, передний план — сразу."""

    def __init__(self, log):
        self.log = log
        self.aborted = set()
        self.streams = {}

    def handle(self, request):
        self.log.append(("front", request.get("op"), request.get("id")))
        if request.get("op") in ("complete", "finish"):
            return {"id": request.get("id"), "text": "front"}
        return None

    def steps(self, request):
        for step in range(request.get("n", 3)):
            if request.get("id") in self.aborted:
                raise RuntimeError("aborted")
            self.log.append(("back", request.get("id"), step))
            yield
        return {"text": "back"}


def scheduler(now=None):
    log, sent, prio = [], [], []
    clock = now or [0.0]
    sched = L.Scheduler(StepWorker(log), sent.append, background=prio.append, clock=lambda: clock[0])
    return sched, log, sent, prio, clock


def test_scheduler_front_preempts_background_between_steps():
    sched, log, sent, prio, _ = scheduler()
    sched.put({"op": "complete", "id": 1, "priority": "background", "n": 3})
    sched.run_once()  # фон: первый шаг, приоритет процесса — фоновый
    sched.put({"op": "open", "stream": "s"})
    sched.put({"op": "finish", "id": 2, "stream": "s"})
    while sched.run_once(wait=0.01) and len(sent) < 2:
        pass
    assert log == [("back", 1, 0), ("front", "open", None), ("front", "finish", 2), ("back", 1, 1), ("back", 1, 2)]
    assert [m["id"] for m in sent] == [2, 1] and sent[1]["text"] == "back"
    assert prio == [True, False, True]  # передний план — с обычным приоритетом


def test_scheduler_hold_pauses_background_until_release_or_ttl():
    sched, log, sent, prio, clock = scheduler()
    sched.put({"op": "hold", "key": "d1", "ttl": 60})
    sched.put({"op": "complete", "id": 1, "priority": "background", "n": 1})
    done = threading.Event()

    def loop():
        while not done.is_set():
            sched.run_once(wait=0.01)

    thread = threading.Thread(target=loop, daemon=True)
    thread.start()
    time.sleep(0.1)
    assert log == []  # идёт диктовка — фон стоит
    sched.put({"op": "complete", "id": 2})  # передний план во время диктовки проходит
    time.sleep(0.1)
    assert log == [("front", "complete", 2)]
    sched.put({"op": "release", "key": "d1"})
    time.sleep(0.1)
    assert ("back", 1, 0) in log and sent[-1] == {"id": 1, "text": "back"}
    # Брошенная диктовка не держит фон вечно: hold истекает.
    sched.put({"op": "hold", "key": "d2", "ttl": 5})
    sched.put({"op": "complete", "id": 3, "priority": "background", "n": 1})
    time.sleep(0.1)
    assert ("back", 3, 0) not in log
    clock[0] = 10.0
    time.sleep(0.1)
    assert ("back", 3, 0) in log
    done.set()
    sched.close()
    thread.join(1)


def test_scheduler_abort_and_close():
    sched, log, sent, _, _ = scheduler()
    sched.put({"op": "complete", "id": 1, "priority": "background", "n": 5})
    sched.run_once()
    sched.put({"op": "abort", "id": 1})
    sched.put({"op": "complete", "id": 2, "priority": "background"})
    sched.put({"op": "abort", "id": 2})  # ещё в очереди — просто выбрасывается
    sched.run_once()
    assert sent and sent[0]["id"] == 1 and "aborted" in sent[0]["error"]
    sched.close()
    assert sched.run_once() is False
    assert not [m for m in sent if m.get("id") == 2]


def test_background_roles_and_holds_through_process(fake):
    backend, log = fake()
    assert backend.complete("встреча", "<transcript>…</transcript>", 10)
    backend.complete("правка", "<instruction>короче</instruction>\n<selection>\nтекст\n</selection>", 10)
    release = backend.hold("d1")
    release()
    deadline = time.monotonic() + 5
    while len(ops(log)) < 4 and time.monotonic() < deadline:
        time.sleep(0.02)
    sent = ops(log)
    assert sent[0]["priority"] == "background"
    assert "priority" not in sent[1] and sent[1]["closers"] == ["</edited>", "<cannot_edit/>"]
    assert [o["op"] for o in sent[2:]] == ["hold", "release"]
    backend.stop()
    backend.hold("d2")  # процесс не запущен — ради паузы его не поднимаем
    assert not backend.client.running()


def test_engine_holds_llm_during_dictation(tmp_path):
    class Holding(StreamingBackend):
        def __init__(self):
            super().__init__()
            self.events = []

        def hold(self, key):
            self.events.append(("hold", key))
            return lambda: self.events.append(("release", key))

    sink = Sink()
    backend = Holding()
    eng = Engine(sink, pool=FakePool(), verifier=FakeVerifier(),
                 personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False),
                 polishers={"mlx": backend})
    dictate(eng, "h1", 10)
    sink.wait(lambda e: e.get("event") == "final" and e.get("session") == "h1")
    assert backend.events == [("hold", "h1"), ("release", "h1")]
