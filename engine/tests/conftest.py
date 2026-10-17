"""Общее для тестов движка: путь к пакету и поддельный пул моделей."""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

ENGINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ENGINE))

SR = 16_000
HANDY_RECORDINGS = Path.home() / "Library" / "Application Support" / "com.pais.handy" / "recordings"


@pytest.fixture(autouse=True)
def mostik_home(tmp_path, monkeypatch):
    """Каждый тест — в своём MOSTIK_HOME, без импорта словарей transcriber."""
    home = tmp_path / "mostik-home"
    monkeypatch.setenv("MOSTIK_HOME", str(home))
    monkeypatch.setenv("MOSTIK_IMPORT_TRANSCRIBER", "0")
    return home


def tone(seconds: float, freq: float = 220.0, amp: float = 0.3) -> np.ndarray:
    t = np.arange(int(seconds * SR)) / SR
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def silence(seconds: float) -> np.ndarray:
    return np.zeros(int(seconds * SR), dtype=np.float32)


def pcm16(waveform: np.ndarray) -> bytes:
    return (np.clip(waveform, -1, 1) * 32767).astype("<i2").tobytes()


class FakePool:
    """VAD по энергии и «распознавание» по длине: детерминированно и мгновенно."""

    def __init__(self) -> None:
        self.recognized: list[float] = []

    def speech_spans(self, waveform, *, max_seconds=20.0, min_silence_ms=300):
        hop = SR * 30 // 1000
        frames = len(waveform) // hop
        if not frames:
            return []
        rms = np.sqrt((waveform[: frames * hop].reshape(frames, hop) ** 2).mean(axis=1))
        voiced = rms > 0.01
        spans, start, quiet = [], None, 0
        gap = max(1, min_silence_ms // 30)
        for index, flag in enumerate(voiced):
            if flag:
                if start is None:
                    start = index
                quiet = 0
                if (index + 1 - start) * hop >= max_seconds * SR:
                    spans.append((start * hop, (index + 1) * hop))
                    start = None
            elif start is not None:
                quiet += 1
                if quiet >= gap:
                    spans.append((start * hop, (index - quiet + 1) * hop))
                    start, quiet = None, 0
        if start is not None:
            spans.append((start * hop, (frames - quiet) * hop))
        return spans

    def recognize(self, waveform, language, **kwargs):
        seconds = len(waveform) / SR
        self.recognized.append(seconds)
        words = max(1, int(round(seconds)))
        return " ".join(["слово"] * words) + "."

    def primary(self, language):
        return self

    def vad(self):
        return self

    def warmup(self, language):
        return ["fake"]

    def sweep(self, now=None):
        return []


class FakeVerifier:
    """Проверяющая, отвечающая сразу и тем же текстом, что задан функцией."""

    def __init__(self, answer=lambda window_id: "слово.") -> None:
        self.answer = answer
        self.sink = None
        self.available = True
        self.cancelled: list[str] = []

    def submit(self, window_id, session, pcm16, language, hotwords=None):
        if self.sink:
            self.sink({"window_id": window_id, "text": self.answer(window_id), "seconds": 0.01})
        return True

    def ensure(self):
        return True

    def running(self):
        return True

    def cancel(self, session):
        self.cancelled.append(session)

    def stop(self):
        pass

    def sweep(self, now=None):
        return False


def pytest_configure(config):
    config.addinivalue_line("markers", "slow: настоящие модели или процесс движка")
