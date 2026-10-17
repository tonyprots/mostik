"""Нарезка окон из потока: чистая функция и сессия на синтетическом звуке."""
from __future__ import annotations

import wave

import numpy as np
import pytest

from conftest import HANDY_RECORDINGS, SR, FakePool, FakeVerifier, pcm16, silence, tone
from mostik_engine.session import Session, plan_windows


def test_unfinished_span_is_not_cut():
    # Речь до самого конца хвоста: пауза ещё не набрала 300 мс.
    windows, cut = plan_windows([(1000, 30000)], 31000, final=False)
    assert windows == [] and cut == 0


def test_finished_span_cut_in_silence():
    windows, cut = plan_windows([(8000, 40000)], 50000, final=False)
    assert len(windows) == 1
    start, end = windows[0]
    assert start == 8000 - int(0.2 * SR)
    assert 40000 <= end <= 40000 + int(0.2 * SR)
    assert cut == end


def test_span_followed_by_another_is_finished_even_without_long_pause():
    spans = [(0, 20 * SR), (20 * SR, 24 * SR)]
    windows, cut = plan_windows(spans, 24 * SR + 100, final=False)
    assert windows == [(0, 20 * SR)]
    assert cut == 20 * SR


def test_neighbour_spans_pack_up_to_20_seconds():
    spans = [(0, 5 * SR), (6 * SR, 11 * SR), (12 * SR, 19 * SR), (20 * SR, 23 * SR)]
    windows, _ = plan_windows(spans, 25 * SR, final=False)
    assert len(windows) == 2
    assert all(end - start <= 20 * SR for start, end in windows)
    # Окна не перекрываются и идут подряд.
    assert windows[0][1] <= windows[1][0]


def test_long_silence_moves_cut_forward():
    windows, cut = plan_windows([], 5 * SR, final=False)
    assert windows == [] and cut == 4 * SR


def test_final_takes_open_span():
    windows, cut = plan_windows([(1000, 30000)], 30000, final=True)
    assert windows == [(0, 30000)] and cut == 30000


def _feed(session: Session, waveform: np.ndarray) -> None:
    pcm = pcm16(waveform)
    frame = int(0.1 * SR) * 2
    for at in range(0, len(pcm), frame):
        session.append(pcm[at : at + frame])
        if session.due():
            session.step()


def test_session_streams_windows_and_final():
    pool = FakePool()
    events: list[dict] = []
    verifier = FakeVerifier()
    session = Session("s", "ru", pool=pool, verifier=verifier, emit=events.append)
    verifier.sink = session.on_verifier
    audio = np.concatenate([silence(0.5), tone(3), silence(1.0), tone(2), silence(1.0), tone(1.5)])
    _feed(session, audio)
    partials = [event for event in events if event["event"] == "partial"]
    assert len(partials) == 2, "два законченных окна до stop"
    result = session.finish(wait_verifier_ms=1000)
    assert result["event"] == "final"
    assert len(session.windows) == 3
    assert result["text"].startswith("Слово") or result["text"].startswith("слово")
    assert result["verifier"] == "done"
    assert result["timings"]["audio_s"] == pytest.approx(len(audio) / SR, abs=0.01)
    # VAD смотрел только хвосты: суммарно не больше звука плюс шаги.
    assert all(seconds <= 20.5 for seconds in pool.recognized)


def test_session_vad_cost_bounded_by_tail():
    """Длинная диктовка: каждое окно ≤ 20 с, хвост VAD не растёт."""
    pool = FakePool()
    seen: list[int] = []
    original = pool.speech_spans

    def spy(waveform, **kwargs):
        seen.append(len(waveform))
        return original(waveform, **kwargs)

    pool.speech_spans = spy
    session = Session("long", "ru", pool=pool, verify=False)
    pieces = []
    for _ in range(12):
        pieces += [tone(6), silence(0.6)]
    _feed(session, np.concatenate(pieces))
    assert max(seen) <= 25 * SR
    session.finish()
    assert all(window.end - window.start <= 20 * SR for window in session.windows)


def test_empty_audio_gives_empty_final():
    session = Session("e", "ru", pool=FakePool(), verify=False)
    result = session.finish()
    assert result["text"] == "" and result["doubts"] == [] and result["verifier"] == "off"
    session = Session("q", "ru", pool=FakePool(), verify=False)
    _feed(session, silence(2.0))
    result = session.finish()
    assert result["timings"]["audio_s"] == pytest.approx(2.0)


def test_late_verifier_reports_late():
    class Silent(FakeVerifier):
        def submit(self, *args, **kwargs):
            return True  # отправили, но ответа не будет

    verifier = Silent()
    session = Session("l", "ru", pool=FakePool(), verifier=verifier)
    _feed(session, np.concatenate([tone(2), silence(1)]))
    result = session.finish(wait_verifier_ms=100)
    assert result["verifier"] == "late"
    assert verifier.cancelled == ["l"]
    assert result["text"]


def _short_recording():
    if not HANDY_RECORDINGS.is_dir():
        return None
    for path in sorted(HANDY_RECORDINGS.glob("handy-*.wav")):
        with wave.open(str(path), "rb") as handle:
            if 20 <= handle.getnframes() / handle.getframerate() <= 90:
                return path
    return None


@pytest.mark.slow
def test_real_silero_windows_on_real_speech():
    path = _short_recording()
    if path is None:
        pytest.skip("нет записей Handy")
    from mostik_engine.models import ModelPool

    pool = ModelPool()
    with wave.open(str(path), "rb") as handle:
        audio = np.frombuffer(handle.readframes(handle.getnframes()), dtype="<i2").astype(np.float32) / 32768

    class VadOnly:
        def speech_spans(self, waveform, **kwargs):
            return pool.speech_spans(waveform, **kwargs)

        def recognize(self, waveform, language, **kwargs):
            return "x"

    session = Session("real", "ru", pool=VadOnly(), verify=False)
    _feed(session, audio)
    session.finish()
    assert len(session.windows) >= 2
    assert all(w.end - w.start <= 20 * SR + 1 for w in session.windows)
    starts = [w.start for w in session.windows]
    assert starts == sorted(starts)
    assert all(a.end <= b.start for a, b in zip(session.windows, session.windows[1:]))


def test_verifier_packs_reach_8s_and_flush_on_stop():
    sent: list[tuple[str, float]] = []

    class Recording(FakeVerifier):
        def submit(self, window_id, session, pcm16, language, hotwords=None):
            sent.append((window_id, len(pcm16) / 2 / SR))
            return super().submit(window_id, session, pcm16, language, hotwords)

    verifier = Recording()
    session = Session("p", "ru", pool=FakePool(), verifier=verifier)
    verifier.sink = session.on_verifier
    pieces = []
    for _ in range(7):
        pieces += [tone(3), silence(0.6)]
    _feed(session, np.concatenate(pieces))
    during = list(sent)
    assert during, "пачка ушла ещё во время речи"
    assert all(8.0 <= seconds <= 24.0 for _, seconds in during)
    result = session.finish(wait_verifier_ms=1000)
    assert len(sent) == len(session.packs) and len(sent) > len(during)
    assert result["verifier"] == "done"
    assert sum(len(pack.windows) for pack in session.packs) == len(session.windows) == 7
    assert result["stats"]["packs"] == len(session.packs)
