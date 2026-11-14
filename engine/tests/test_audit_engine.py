"""Находки ревью движка (2026-11-14), оставленные до живой проверки: E11, E12, E13, E18.

Номер в имени теста — номер находки реестра `drafts/2026-11-14-audit/findings-ledger.md`.
Живой прогон на настоящих моделях — `bench/audit_live.py`.
"""
from __future__ import annotations

import base64
import threading
import time
import wave

import numpy as np

from conftest import SR, FakePool, FakeVerifier, pcm16, silence, tone
from mostik_engine import llm_mlx as L
from mostik_engine import meeting_folder
from mostik_engine import polish as P
from mostik_engine import server as server_mod
from mostik_engine.personal_glossary import PersonalGlossary
from mostik_engine.server import Engine
from test_language_detect import DetectingVerifier
from test_llm_mlx import fake  # noqa: F401 — фикстура поддельного процесса модели
from test_perf_p1 import _fake_claude, _log_entries
from test_protocol import Sink, send


def make_engine(tmp_path, **kwargs):
    sink = Sink()
    verifier = kwargs.pop("verifier", None) or FakeVerifier()
    eng = Engine(sink, pool=FakePool(), verifier=verifier,
                 personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False), **kwargs)
    verifier.sink = eng._on_verifier
    return eng, sink


def dictate(eng, session: str, cid: int, **start) -> None:
    send(eng, cmd="start", id=cid, session=session, verify=False, **{"language": "ru", **start})
    pcm = pcm16(np.concatenate([tone(1.5), silence(0.5)]))
    frame = int(0.1 * SR) * 2
    for at in range(0, len(pcm), frame):
        send(eng, cmd="audio", session=session, pcm=base64.b64encode(pcm[at:at + frame]).decode())
    send(eng, cmd="stop", id=cid + 1, session=session, wait_verifier_ms=0)


# --- E11: миграция встреч не занимает очередь моделей ---------------------------------------------------

def test_e11_dictation_does_not_wait_for_meetings_migration(tmp_path, monkeypatch):
    eng, sink = make_engine(tmp_path)
    gate, entered = threading.Event(), threading.Event()

    def slow_migration(root):
        entered.set()
        gate.wait(10)
        return {"scanned": 3, "migrated": 1, "errors": 0}

    monkeypatch.setattr(meeting_folder, "migrate_all", slow_migration)
    send(eng, cmd="meetings_migrate", id=1, root=str(tmp_path / "meetings"))
    assert entered.wait(5)
    dictate(eng, "d", 10)
    final = sink.wait(lambda e: e.get("event") == "final" and e.get("session") == "d", timeout=5)
    assert final["text"], "диктовка прошла, пока миграция ещё идёт"
    assert not [e for e in sink.lines if e.get("id") == 1]
    gate.set()
    assert sink.wait(lambda e: e.get("id") == 1) == {"id": 1, "ok": True, "scanned": 3, "migrated": 1, "errors": 0}


def test_e11_migration_failure_still_answers(tmp_path, monkeypatch):
    eng, sink = make_engine(tmp_path)
    monkeypatch.setattr(meeting_folder, "migrate_all", lambda root: 1 / 0)
    send(eng, cmd="meetings_migrate", id=2, root=str(tmp_path))
    error = sink.wait(lambda e: e.get("id") == 2)
    assert error["event"] == "error" and error["code"] == "internal"


# --- E12: цикл stdin не ждёт ни статусов, ни чтения файла -------------------------------------------------

def test_e12_hello_does_not_block_the_command_loop(tmp_path):
    gate, entered = threading.Event(), threading.Event()

    class SlowStatus(P.PolishBackend):
        name = "claude"

        def status(self):  # как `claude auth status`: секунды
            entered.set()
            gate.wait(10)
            return {"available": True}

    eng, sink = make_engine(tmp_path, polishers={"claude": SlowStatus()})
    started = time.monotonic()
    send(eng, cmd="hello", id=1)
    assert time.monotonic() - started < 0.5, "handle_line вернулся, не дожидаясь статуса"
    assert entered.wait(5)
    send(eng, cmd="glossary_list", id=2)
    assert sink.wait(lambda e: e.get("id") == 2)["ok"] is True
    assert not [e for e in sink.lines if e.get("id") == 1]
    gate.set()
    hello = sink.wait(lambda e: e.get("id") == 1)
    assert hello["ok"] is True and hello["polish"] == {"claude": {"available": True}} and hello["version"]


def test_e12_wav_is_read_outside_the_command_loop_and_the_model_queue(tmp_path, monkeypatch):
    eng, sink = make_engine(tmp_path)
    path = tmp_path / "long.wav"
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SR)
        handle.writeframes(pcm16(np.concatenate([tone(1.5), silence(0.5)])))
    gate, entered = threading.Event(), threading.Event()
    real_read = server_mod.read_wav_pcm16

    def slow_read(target):
        entered.set()
        gate.wait(10)
        return real_read(target)

    monkeypatch.setattr(server_mod, "read_wav_pcm16", slow_read)
    started = time.monotonic()
    send(eng, cmd="transcribe_file", id=5, session="f", path=str(path), verify=False)
    assert time.monotonic() - started < 0.5 and entered.wait(5)
    dictate(eng, "d", 10)  # и цикл команд, и рабочий поток свободны
    assert sink.wait(lambda e: e.get("event") == "final" and e.get("session") == "d", timeout=5)["text"]
    assert not [e for e in sink.lines if e.get("id") == 5]
    gate.set()
    final = sink.wait(lambda e: e.get("id") == 5)
    assert final["event"] == "final" and final["text"]


def test_e12_unreadable_wav_reports_bad_audio_and_frees_the_session(tmp_path):
    released = []

    class Holding(P.PolishBackend):
        name = "mlx"

        def status(self):
            return {"available": True}

        def hold(self, key):
            return lambda: released.append(key)

    eng, sink = make_engine(tmp_path, polishers={"mlx": Holding()})
    send(eng, cmd="transcribe_file", id=6, session="bad", path=str(tmp_path / "missing.wav"))
    error = sink.wait(lambda e: e.get("id") == 6)
    assert error["event"] == "error" and error["code"] == "bad_audio" and error["session"] == "bad"
    assert released == ["bad"] and "bad" not in eng._live


# --- E13: поток причёсывания под язык, который определился, а не под стартовый ---------------------------

class RecordingStream(P.PolishStream):
    cancelled = False

    def cancel(self):
        self.cancelled = True
        super().cancel()


class PrespawnBackend(P.PolishBackend):
    """Как `claude -p` заранее: поток открывается на `start` под запрос этого момента."""

    name = "claude"
    prespawn = True

    def __init__(self):
        self.streams: list[RecordingStream] = []
        self.calls: list[tuple[str, str]] = []

    def status(self):
        return {"available": True}

    def complete(self, system, user, timeout):
        self.calls.append((system, user))
        return "<polished>Clean text.</polished>"

    def open_stream(self, request):
        self.streams.append(RecordingStream(self, request))
        return self.streams[-1]


def test_e13_stream_is_reopened_for_the_detected_language(tmp_path):
    """Старт на en с переводом на en (перевода нет), а человек говорит по-русски: нужен перевод."""
    backend = PrespawnBackend()
    eng, sink = make_engine(tmp_path, verifier=DetectingVerifier({"ru": 0.95, "en": 0.03}),
                            polishers={"claude": backend})
    dictate(eng, "t", 10, language="en", languages=["ru-RU", "en-US"], consent=True,
            polish={"backend": "claude", "style": "plain", "translate": {"to": "en"}})
    final = sink.wait(lambda e: e.get("event") == "final" and e.get("session") == "t")
    assert final["language"] == "ru" and final["polished"] is True
    first, second = backend.streams
    assert first.request.language == "en" and first.request.translate_to is None and first.cancelled
    assert second.request.language == "ru" and second.request.translate_to == "en" and not second.cancelled
    assert backend.calls and backend.calls[-1][0] == P.system_for(second.request)
    assert final["polish"]["translate"] == "en"


def test_e13_prespawned_claude_with_another_prompt_is_not_used(tmp_path):
    """Запрос сменил язык после запуска процесса: его системный промпт не тот — обычный вызов."""
    exe, log = _fake_claude(tmp_path, startup_s=0.0)
    backend = P.ClaudeCliBackend(str(exe))
    stream = backend.open_stream(P.PolishRequest("", language="en"))
    stream._spawned.wait(5)
    prespawned = stream._process
    stream.request = P.PolishRequest("ну привет э мир", language="ru", translate_to="en", tone="plain")
    outcome = stream.finish("ну привет э мир", timeout=10)
    assert outcome.polished
    assert prespawned.poll() is not None, "предзапущенный процесс убран"
    plain = [entry["argv"] for entry in _log_entries(log) if "started" in entry and "stream-json" not in entry["argv"]]
    assert len(plain) == 1, "текст ушёл обычным вызовом, а не предзапущенному процессу"
    system = plain[0][plain[0].index("--system-prompt") + 1]
    assert system == P.system_for(stream.request) and system != stream.system


def test_e13_mlx_stream_with_another_prompt_falls_back_to_plain_complete(fake):  # noqa: F811
    from test_llm_mlx import ops

    backend, log = fake()
    stream = backend.open_stream(P.PolishRequest("", language="en"))
    stream.feed("ну привет")
    stream.request = P.PolishRequest("ну привет", language="ru", translate_to="en", tone="plain")
    assert stream.finish("ну привет", timeout=10).polished
    sent = ops(log)
    assert [item["op"] for item in sent] == ["open", "feed", "cancel", "complete"]
    assert sent[-1]["system"] == P.stream_system_for(stream.request) != sent[0]["system"]


# --- E18: срок фонового запроса не идёт под паузой диктовки ------------------------------------------------

SLOW_BACKGROUND = r"""
import json, sys, threading, time
print(json.dumps({"ready": True, "seconds": 0.01}), flush=True)
held, pending, lock = set(), [], threading.Lock()

def work():
    while True:
        time.sleep(0.02)
        with lock:
            if held or not pending:
                continue
            request = pending.pop(0)
        time.sleep(0.2)
        print(json.dumps({"id": request["id"], "text": "<summary>ok</summary>"}), flush=True)

threading.Thread(target=work, daemon=True).start()
for line in sys.stdin:
    request = json.loads(line)
    with lock:
        if request["op"] == "hold":
            held.add(request["key"])
        elif request["op"] == "release":
            held.discard(request["key"])
        elif request["op"] == "complete":
            pending.append(request)
"""


def paused_backend(tmp_path):
    import sys

    script = tmp_path / "paused_llm.py"
    script.write_text(SLOW_BACKGROUND)
    client = L.LlmClient(L.MODELS[L.DEFAULT_MODEL], command=[sys.executable, str(script)])
    backend = L.MlxBackend(client=client)
    assert client.ensure() and client.wait_ready(10)
    return backend


def test_e18_background_timeout_does_not_run_during_dictation_hold(tmp_path):
    backend = paused_backend(tmp_path)
    try:
        release = backend.hold("dictation")  # идёт диктовка: фон процесса стоит
        assert backend.client.held()
        threading.Timer(1.2, release).start()
        started = time.monotonic()
        # Срок куска — 0,8 с, диктовка держит паузу 1,2 с: раньше кусок падал по таймауту, не начавшись.
        text = backend.complete("сводка встречи", "<transcript>…</transcript>", 0.8)
        assert text == "<summary>ok</summary>" and time.monotonic() - started >= 1.2
        assert not backend.client.held()
    finally:
        backend.stop()


def test_e18_timeout_still_works_without_hold_and_for_foreground(tmp_path):
    backend = paused_backend(tmp_path)
    try:
        backend.client.hold("d")
        started = time.monotonic()
        try:  # передний план (голосовая правка) под паузой не стоит и срок не продлевает
            backend.client.request({"op": "noop"}, 0.3)
            raise AssertionError("ожидался таймаут")
        except P.PolishTimeout:
            pass
        assert time.monotonic() - started < 1.0
        backend.client.release("d")
        # Пауза истекла по ttl — срок фонового запроса снова идёт.
        backend.client.hold("short", ttl=0.2)
        started = time.monotonic()
        try:
            backend.client.request({"op": "noop", "priority": "background"}, 0.3)
            raise AssertionError("ожидался таймаут")
        except P.PolishTimeout:
            pass
        assert 0.4 < time.monotonic() - started < 1.5
    finally:
        backend.stop()
