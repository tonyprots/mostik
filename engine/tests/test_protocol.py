"""Протокол движка: разбор команд и цикл с поддельными моделями."""
from __future__ import annotations

import base64
import json
import sys
import threading
import time
import types
import wave

import numpy as np
import pytest

from conftest import SR, FakePool, FakeVerifier, pcm16, silence, tone
from mostik_engine.personal_glossary import PersonalGlossary
from mostik_engine.server import Engine, EngineError, decode_pcm, parse_command, read_wav_pcm16


class Sink:
    def __init__(self) -> None:
        self.lines: list[dict] = []
        self.lock = threading.Lock()

    def write(self, text: str) -> None:
        for line in text.splitlines():
            if line.strip():
                with self.lock:
                    self.lines.append(json.loads(line))

    def flush(self) -> None:
        pass

    def wait(self, predicate, timeout: float = 10.0) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                for line in self.lines:
                    if predicate(line):
                        return line
            time.sleep(0.01)
        raise AssertionError(f"не дождались события; есть: {self.lines}")


@pytest.fixture
def engine(tmp_path):
    sink = Sink()
    verifier = FakeVerifier()
    eng = Engine(
        sink,
        pool=FakePool(),
        verifier=verifier,
        personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False),
    )
    verifier.sink = eng._on_verifier
    return eng, sink


def send(eng: Engine, **command) -> bool:
    return eng.handle_line(json.dumps(command, ensure_ascii=False))


def test_parse_command_errors():
    with pytest.raises(EngineError):
        parse_command("{не json")
    with pytest.raises(EngineError):
        parse_command("[1, 2]")
    with pytest.raises(EngineError):
        parse_command('{"id": 1}')
    assert parse_command('{"cmd": "hello", "id": 3}')["id"] == 3


def test_decode_pcm_errors():
    assert decode_pcm(base64.b64encode(b"\x01\x00\x02\x00").decode()) == b"\x01\x00\x02\x00"
    for bad in (None, "!!!", base64.b64encode(b"\x01").decode()):
        with pytest.raises(EngineError) as error:
            decode_pcm(bad)
        assert error.value.code == "bad_audio"


def test_bad_lines_produce_errors_not_crash(engine):
    eng, sink = engine
    assert eng.handle_line("мусор") is True
    assert sink.lines[-1]["event"] == "error" and sink.lines[-1]["code"] == "internal"
    send(eng, cmd="nope", id=7)
    assert sink.lines[-1]["id"] == 7 and sink.lines[-1]["event"] == "error"
    send(eng, cmd="start", id=8, session="a", language="ru")
    send(eng, cmd="audio", id=9, session="a", pcm="%%%")
    error = sink.wait(lambda e: e.get("event") == "error" and e.get("id") == 9)
    assert error["code"] == "bad_audio" and error["session"] == "a"


def test_hello_and_power(engine):
    eng, sink = engine
    send(eng, cmd="hello", id=1)
    hello = sink.lines[-1]
    assert hello["id"] == 1 and hello["ok"] is True and "models" in hello and hello["version"]
    # «Проверка» показывает, разделит ли этот Mac встречу по голосам (fluidaudiocli).
    assert isinstance(hello["diarization"]["available"], bool)
    send(eng, cmd="power", id=2, thermal="serious", on_battery=False, low_power=False, battery=None)
    assert sink.lines[-1] == {"id": 2, "ok": True, "verifier_enabled": False}
    send(eng, cmd="power", id=3, thermal="nominal", on_battery=True, low_power=False, battery=15)
    assert sink.lines[-1]["verifier_enabled"] is False
    send(eng, cmd="power", id=4, thermal="fair", on_battery=True, low_power=False, battery=80)
    assert sink.lines[-1]["verifier_enabled"] is True


def test_dictation_roundtrip(engine):
    eng, sink = engine
    send(eng, cmd="warmup", id=1, language="ru")
    sink.wait(lambda e: e.get("id") == 1 and e.get("ok"))
    send(eng, cmd="start", id=2, session="s1", language="ru", project=None, verify=True, agent=True)
    assert sink.wait(lambda e: e.get("id") == 2)["ok"] is True
    pcm = pcm16(np.concatenate([tone(2), silence(1), tone(2), silence(0.5)]))
    frame = int(0.1 * SR) * 2
    for index, at in enumerate(range(0, len(pcm), frame)):
        send(eng, cmd="audio", id=100 + index, session="s1",
             pcm=base64.b64encode(pcm[at : at + frame]).decode())
    sink.wait(lambda e: e.get("event") == "partial" and e.get("session") == "s1")
    send(eng, cmd="stop", id=3, session="s1", wait_verifier_ms=1200)
    final = sink.wait(lambda e: e.get("event") == "final")
    assert final["id"] == 3 and final["session"] == "s1"
    assert final["text"] and final["verifier"] == "done"
    assert set(final["timings"]) >= {"audio_s", "tail_ms", "primary_ms", "verifier_ms", "total_ms"}
    assert len(final["doubts"]) <= 5
    # На `audio` ответа нет: только partial/final/ответы на прочие id.
    assert not [e for e in sink.lines if 100 <= (e.get("id") or 0) < 1000]


def test_stop_unknown_session_and_cancel(engine):
    eng, sink = engine
    send(eng, cmd="stop", id=1, session="ghost")
    assert sink.lines[-1]["event"] == "error" and sink.lines[-1]["id"] == 1
    send(eng, cmd="start", id=2, session="c", language="ru")
    send(eng, cmd="cancel", id=3, session="c")
    sink.wait(lambda e: e.get("id") == 3 and e.get("ok"))
    send(eng, cmd="audio", id=4, session="c", pcm=base64.b64encode(b"\0\0").decode())
    assert not [e for e in sink.lines if e.get("event") == "error" and e.get("id") == 4]


def test_new_start_drops_unfinished_session(engine):
    eng, sink = engine
    send(eng, cmd="start", id=1, session="old", language="ru")
    send(eng, cmd="start", id=2, session="new", language="ru")
    assert "old" not in eng.sessions and "new" in eng.sessions


def test_transcribe_file(engine, tmp_path):
    eng, sink = engine
    path = tmp_path / "x.wav"
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SR)
        handle.writeframes(pcm16(np.concatenate([tone(3), silence(1), tone(1)])))
    send(eng, cmd="transcribe_file", id=5, path=str(path), language="ru", project=None, session="file-1")
    final = sink.wait(lambda e: e.get("event") == "final" and e.get("id") == 5)
    assert final["session"] == "file-1" and final["text"]
    send(eng, cmd="transcribe_file", id=6, path=str(tmp_path / "missing.wav"), language="ru")
    assert sink.wait(lambda e: e.get("id") == 6)["code"] == "bad_audio"


def test_read_wav_converts_stereo_and_rate(tmp_path):
    path = tmp_path / "s.wav"
    stereo = np.stack([tone(1.0), tone(1.0)], axis=1)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(8000)
        handle.writeframes((stereo[: 8000] * 32767).astype("<i2").tobytes())
    pcm = read_wav_pcm16(path)
    assert len(pcm) == 2 * SR


def test_glossary_commands(engine):
    eng, sink = engine
    send(eng, cmd="remember", id=1, heard="пара кит", canonical="Parakeet")
    assert sink.lines[-1] == {"id": 1, "ok": True}
    send(eng, cmd="glossary_list", id=2)
    entries = sink.lines[-1]["entries"]
    assert entries[0]["canonical"] == "Parakeet" and entries[0]["aliases"] == ["пара кит"]
    send(eng, cmd="forget", id=3, canonical="Parakeet")
    assert sink.lines[-1]["ok"] is True
    send(eng, cmd="glossary_list", id=4)
    assert sink.lines[-1]["entries"] == []


def test_project_glossary_command(engine, tmp_path):
    eng, sink = engine
    (tmp_path / "repo").mkdir()
    (tmp_path / "repo" / "mostik_core.py").write_text("class DoubtBlock:\n    pass\n", encoding="utf-8")
    send(eng, cmd="project_glossary", id=9, path=str(tmp_path / "repo"))
    reply = sink.wait(lambda e: e.get("id") == 9)
    assert reply["ok"] and "DoubtBlock" in reply["terms"] and reply["count"] >= 1


def test_meeting_dispatch_unloads_verifier_and_emits_done(engine, monkeypatch):
    eng, sink = engine
    stopped = []
    eng.verifier.stop = lambda: stopped.append(True)
    seen = {}

    def fake_run(payload, emit):
        seen.update(payload)
        assert eng.meeting_running.is_set()
        emit({"event": "progress", "task": "meeting", "stage": "mic", "done": 1, "total": 2})
        return {"transcript_md": "/x/t.md", "transcript_json": "/x/t.json", "speakers": 2, "seconds": 1.5}

    monkeypatch.setitem(sys.modules, "mostik_engine.meeting", types.SimpleNamespace(run_meeting=fake_run))
    send(eng, cmd="meeting", id=11, mic="/m.wav", system="/s.wav", out_dir="/x", language="ru", speakers=None)
    done = sink.wait(lambda e: e.get("event") == "meeting_done")
    assert done["id"] == 11 and done["speakers"] == 2
    assert seen["mic"] == "/m.wav" and stopped
    assert any(e.get("event") == "progress" for e in sink.lines)


def test_meeting_import_failure_is_internal_error(engine, monkeypatch):
    eng, sink = engine
    monkeypatch.setitem(sys.modules, "mostik_engine.meeting", None)
    send(eng, cmd="meeting", id=12, mic="/m.wav", system="/s.wav", out_dir="/x", language="ru")
    error = sink.wait(lambda e: e.get("id") == 12)
    assert error["event"] == "error" and error["code"] == "internal"


def test_shutdown(engine):
    eng, sink = engine
    assert send(eng, cmd="shutdown", id=99) is False
    assert sink.lines[-1] == {"id": 99, "ok": True}
