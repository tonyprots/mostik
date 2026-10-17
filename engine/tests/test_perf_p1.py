"""Пакет «Плавность и быстродействие» (2026-10-12): раскладка хвоста, прогноз проверяющей."""
from __future__ import annotations

import base64
import json
import threading
import time
import types

import numpy as np

from conftest import SR, FakePool, FakeVerifier, pcm16, silence, tone
from mostik_engine.personal_glossary import PersonalGlossary
from mostik_engine.server import Engine
from mostik_engine.session import Session
from mostik_engine.verifier_worker import VerifierClient
from test_protocol import Sink, send


def _feed(session: Session, waveform: np.ndarray) -> None:
    pcm = pcm16(waveform)
    frame = int(0.1 * SR) * 2
    for at in range(0, len(pcm), frame):
        session.append(pcm[at : at + frame])
        if session.due():
            session.step()


class Silent(FakeVerifier):
    """Пачку приняла, ответ не придёт: как Whisper, которому до конца ещё 1,7 с."""

    def __init__(self, ema: float | None) -> None:
        super().__init__()
        self.call_ema_s = ema

    def submit(self, *args, **kwargs):
        return True


def test_final_timings_break_down_the_tail():
    """Шаг 0: в `final.timings` — очередь, остаток, ожидание проверяющей, подготовка и загрузка модели."""
    session = Session("t", "ru", pool=FakePool(), verifier=FakeVerifier())
    session.verifier.sink = session.on_verifier
    session.prepare_ms, session.model_load_ms = 12.5, 0.0
    _feed(session, np.concatenate([tone(2), silence(1)]))
    timings = session.finish(wait_verifier_ms=500)["timings"]
    assert {"queued_ms", "remainder_ms", "verifier_wait_ms", "prepare_ms", "model_load_ms"} <= set(timings)
    assert timings["prepare_ms"] == 12.5 and timings["model_load_ms"] == 0.0
    assert timings["verifier_wait_ms"] >= 0


def test_hopeless_verifier_is_not_awaited():
    """Шаг 1, п. 4: вызов стоит 1,69 с, срок 1,2 с — не ждём впустую, сразу `late`."""
    verifier = Silent(ema=1.69)
    session = Session("h", "ru", pool=FakePool(), verifier=verifier)
    _feed(session, np.concatenate([tone(2), silence(1)]))
    started = time.monotonic()
    result = session.finish(wait_verifier_ms=1200)
    elapsed = time.monotonic() - started
    assert result["verifier"] == "late"
    assert elapsed < 0.4, f"ждали {elapsed:.2f} с"
    assert verifier.cancelled == ["h"]
    assert result["timings"]["verifier_wait_ms"] < 100
    assert result["timings"]["verifier_forecast_ms"] >= 1200


def test_verifier_that_can_make_it_is_awaited():
    """Прогноз укладывается в срок — ждём, как раньше, и получаем `done`."""

    class Quick(FakeVerifier):
        call_ema_s = 0.05

        def submit(self, window_id, session, pcm16, language, hotwords=None):
            def answer() -> None:
                time.sleep(0.15)
                self.sink({"window_id": window_id, "text": "слово.", "seconds": 0.05})

            threading.Thread(target=answer, daemon=True).start()
            return True

    verifier = Quick()
    session = Session("q", "ru", pool=FakePool(), verifier=verifier)
    verifier.sink = session.on_verifier
    _feed(session, np.concatenate([tone(2), silence(1)]))
    result = session.finish(wait_verifier_ms=1200)
    assert result["verifier"] == "done"


def test_unknown_cost_waits_as_before():
    """Цены вызова ещё нет (первая диктовка) — ждём до срока, как раньше."""
    verifier = Silent(ema=None)
    session = Session("u", "ru", pool=FakePool(), verifier=verifier)
    _feed(session, np.concatenate([tone(2), silence(1)]))
    started = time.monotonic()
    result = session.finish(wait_verifier_ms=300)
    assert result["verifier"] == "late"
    assert time.monotonic() - started >= 0.25


def test_verifier_client_learns_call_cost():
    """Цена вызова — скользящее среднее по `seconds` ответов; ответы определения языка не в счёт."""
    client = VerifierClient()
    lines = [
        json.dumps({"window_id": "s:0", "text": "a", "seconds": 1.0}) + "\n",
        json.dumps({"window_id": "s:detect", "probs": {"ru": 1.0}, "seconds": 0.2}) + "\n",
        json.dumps({"window_id": "s:1", "text": "b", "seconds": 2.0}) + "\n",
    ]
    process = types.SimpleNamespace(stdout=iter(lines))
    client._read(process)
    assert client.call_ema_s is not None
    assert 1.0 < client.call_ema_s < 2.0


def test_engine_reports_prepare_and_model_load(tmp_path):
    """`prepare_ms` и `model_load_ms` из `_prepare` доходят до `final.timings`."""

    class ColdPool(FakePool):
        def __init__(self) -> None:
            super().__init__()
            self.loaded: set[str] = set()

        def has_primary(self, language):
            return language in self.loaded

        def primary(self, language):
            if language not in self.loaded:
                time.sleep(0.05)
                self.loaded.add(language)
            return self

    sink = Sink()
    verifier = FakeVerifier()
    eng = Engine(sink, pool=ColdPool(), verifier=verifier,
                 personal=PersonalGlossary(tmp_path / "g.yaml", import_transcriber=False))
    verifier.sink = eng._on_verifier
    send(eng, cmd="start", id=1, session="c", language="ru", verify=False)
    pcm = pcm16(np.concatenate([tone(1.5), silence(0.5)]))
    frame = int(0.1 * SR) * 2
    for at in range(0, len(pcm), frame):
        send(eng, cmd="audio", session="c", pcm=base64.b64encode(pcm[at : at + frame]).decode())
    send(eng, cmd="stop", id=2, session="c", wait_verifier_ms=0)
    final = sink.wait(lambda e: e.get("event") == "final")
    assert final["timings"]["model_load_ms"] >= 40
    assert final["timings"]["prepare_ms"] >= final["timings"]["model_load_ms"]


# --- шаг 1, п. 6: `claude -p` поднимается на старте, текст — на отпускании --------------------

def _fake_claude(tmp_path, startup_s: float):
    """Поддельный CLI: пишет время старта, читает stdin до EOF (время первого байта), «грузится»
    `startup_s` от старта и отвечает. Как настоящий: запуск ~1 с, запрос — после EOF."""
    import stat
    import sys

    log = tmp_path / "claude.log"
    script = tmp_path / "bin" / "claude"
    script.parent.mkdir(exist_ok=True)
    script.write_text(f"""#!{sys.executable}
import sys, time, json
t0 = time.time()
open({str(log)!r}, "a").write(json.dumps({{"started": t0, "argv": sys.argv[1:]}}) + "\\n")
first = sys.stdin.buffer.read(1)
t_first = time.time()
rest = sys.stdin.buffer.read()
open({str(log)!r}, "a").write(json.dumps({{"first_byte": t_first, "stdin": (first + rest).decode()}}) + "\\n")
time.sleep(max(0.0, {startup_s} - (time.time() - t0)))
print("<polished>Привет, мир.</polished>")
""", encoding="utf-8")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return script, log


def _log_entries(log):
    return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()] if log.exists() else []


def _wait_started(log, then_s: float) -> None:
    """Ждать, пока поддельный CLI запишет старт (на нагруженной машине запуск python дольше секунды),
    и ещё `then_s` — «человек говорит», пока CLI грузится."""
    deadline = time.monotonic() + 15
    while not _log_entries(log) and time.monotonic() < deadline:
        time.sleep(0.02)
    time.sleep(then_s)


def test_claude_prespawn_sends_no_text_before_release(tmp_path):
    """Процесс стоит с пустым stdin, пока человек говорит; текста и терминов нет ни в аргументах,
    ни в stdin до `finish`. На отпускании ответ приходит без второго запуска CLI."""
    from mostik_engine import polish as P

    exe, log = _fake_claude(tmp_path, startup_s=1.0)
    backend = P.ClaudeCliBackend(str(exe))
    assert getattr(backend, "prespawn", False)
    request = P.PolishRequest("", terms=["Zyxwab"])
    stream = backend.open_stream(request)
    _wait_started(log, 1.2)  # человек говорит
    entries = _log_entries(log)
    assert len(entries) == 1 and "started" in entries[0], "процесс поднят, stdin ещё пуст"
    argv = " ".join(entries[0]["argv"])
    assert "Zyxwab" not in argv and "кракозябра" not in argv, "в аргументах нет ни текста, ни терминов"
    released = time.time()
    stream.request = P.PolishRequest("ну кракозябра э мир", terms=["Zyxwab"])
    started = time.monotonic()
    outcome = stream.finish("ну кракозябра э мир", timeout=10)
    tail = time.monotonic() - started
    assert outcome.polished and outcome.text == "Привет, мир."
    data = _log_entries(log)[1]
    assert data["first_byte"] >= released, "первый байт stdin — только после отпускания"
    assert "ну кракозябра э мир" in data["stdin"] and "Zyxwab" in data["stdin"], "термины — в сообщении"
    assert sum("started" in e for e in _log_entries(log)) == 1, "CLI не запускался второй раз"
    assert tail < 0.6, f"хвост {tail:.2f} с: запуск CLI уже прошёл, пока говорили"


def test_claude_prespawn_cancel_and_fallback(tmp_path):
    """Отмена убивает процесс; умерший процесс — обычный вызов целиком."""
    from mostik_engine import polish as P

    exe, log = _fake_claude(tmp_path, startup_s=0.0)
    backend = P.ClaudeCliBackend(str(exe))
    stream = backend.open_stream(P.PolishRequest(""))
    stream._spawned.wait(5)
    process = stream._process
    stream.cancel()
    assert process is not None and process.poll() is not None, "после отмены процесса нет"

    dead = backend.open_stream(P.PolishRequest(""))
    dead._spawned.wait(5)
    dead._process.kill()
    dead._process.wait()
    outcome = dead.finish("ну привет э мир", timeout=10)
    assert outcome.polished, "откат на обычный вызов"


def test_claude_prespawn_is_slower_without_it(tmp_path):
    """Замер для docs/bench.md: тот же поддельный CLI с запуском 1 с — без заранее поднятого
    процесса хвост ≥ 1 с, с ним — доли секунды."""
    from mostik_engine import polish as P

    exe, log = _fake_claude(tmp_path, startup_s=1.0)
    backend = P.ClaudeCliBackend(str(exe))
    started = time.monotonic()
    assert P.polish(backend, P.PolishRequest("ну привет э мир"), timeout=10).polished
    cold = time.monotonic() - started
    log.unlink()
    stream = backend.open_stream(P.PolishRequest(""))
    _wait_started(log, 1.1)
    started = time.monotonic()
    assert stream.finish("ну привет э мир", timeout=10).polished
    warm = time.monotonic() - started
    assert cold >= 0.95 and warm < cold - 0.5, (cold, warm)
