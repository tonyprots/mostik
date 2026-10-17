"""Сквозной прогон: настоящий процесс движка, настоящие модели, запись Handy."""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import threading
import time
import wave
from pathlib import Path

import pytest

from conftest import ENGINE, HANDY_RECORDINGS

pytestmark = pytest.mark.slow


def pick_recording() -> Path | None:
    if not HANDY_RECORDINGS.is_dir():
        return None
    best = None
    for path in sorted(HANDY_RECORDINGS.glob("handy-*.wav")):
        with wave.open(str(path), "rb") as handle:
            seconds = handle.getnframes() / handle.getframerate()
        if 20 <= seconds <= 90 and (best is None or seconds < best[1]):
            best = (path, seconds)
    return best[0] if best else None


class Engine:
    def __init__(self, home: Path) -> None:
        env = dict(os.environ, MOSTIK_HOME=str(home), MOSTIK_IMPORT_TRANSCRIBER="0", PYTHONPATH=str(ENGINE))
        self.process = subprocess.Popen(
            [sys.executable, "-m", "mostik_engine"],
            cwd=str(ENGINE),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            env=env,
        )
        self.events: list[dict] = []
        self.bad_lines: list[str] = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        for line in self.process.stdout:
            try:
                self.events.append(json.loads(line))
            except ValueError:
                self.bad_lines.append(line)

    def send(self, **command) -> None:
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()

    def wait(self, predicate, timeout: float) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for event in list(self.events):
                if predicate(event):
                    return event
            if self.process.poll() is not None:
                break
            time.sleep(0.05)
        raise AssertionError(f"нет события; последние: {self.events[-5:]}")

    def close(self) -> None:
        try:
            self.send(cmd="shutdown", id=999)
            self.process.wait(timeout=20)
        except Exception:  # noqa: BLE001
            self.process.kill()


def test_engine_end_to_end(tmp_path):
    recording = pick_recording()
    if recording is None:
        pytest.skip("нет коротких записей Handy")
    engine = Engine(tmp_path / "home")
    try:
        engine.send(cmd="hello", id=1)
        hello = engine.wait(lambda e: e.get("id") == 1, 60)
        assert hello["ok"] and hello["models"]
        engine.send(cmd="warmup", id=2, language="ru")
        assert engine.wait(lambda e: e.get("id") == 2, 300)["ok"]
        engine.send(cmd="start", id=3, session="it", language="ru", project=str(ENGINE),
                    verify=True, agent=True)
        assert engine.wait(lambda e: e.get("id") == 3, 60)["ok"]
        with wave.open(str(recording), "rb") as handle:
            pcm = handle.readframes(handle.getnframes())
        frame = 3200  # 100 мс
        for index, at in enumerate(range(0, len(pcm), frame)):
            engine.send(cmd="audio", id=1000 + index, session="it",
                        pcm=base64.b64encode(pcm[at : at + frame]).decode())
        engine.send(cmd="stop", id=4, session="it", wait_verifier_ms=1200)
        final = engine.wait(lambda e: e.get("event") == "final", 600)
        assert final["session"] == "it" and final["id"] == 4
        assert final["text"].strip()
        assert len(final["doubts"]) <= 5
        assert final["verifier"] in ("done", "late", "off")
        assert final["timings"]["audio_s"] > 15
        assert any(e.get("event") == "partial" for e in engine.events)
        assert not engine.bad_lines, "в stdout попало не-JSON"
        assert not [e for e in engine.events if e.get("event") == "error"]
    finally:
        engine.close()
