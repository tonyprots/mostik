"""Длинная диктовка ждёт проверяющую до конца; «Вставить быструю версию» прерывает ожидание; стыки окон."""
from __future__ import annotations

import threading
import time

import numpy as np

from conftest import FakePool, FakeVerifier, pcm16, silence, tone
from mostik_engine import session as session_mod
from mostik_engine.seams import join_seam, join_windows
from mostik_engine.session import Session
from test_perf_p1 import Silent, _feed


def _long(monkeypatch, cap_s: float = 2.0) -> None:
    # Порог и потолок уменьшены, чтобы не гнать минуты звука: проверяется ветка, а не числа.
    monkeypatch.setattr(session_mod, "LONG_DICTATION_S", 1.0)
    monkeypatch.setattr(session_mod, "LONG_WAIT_CAP_S", cap_s)


def test_long_dictation_waits_past_hopeless_forecast(monkeypatch):
    """Прогноз «не успеет» длинную диктовку не обрывает: ждём до ответа и сообщаем ход."""
    _long(monkeypatch)

    class Slow(Silent):
        def submit(self, window_id, session, pcm16, language, hotwords=None):
            def answer() -> None:
                time.sleep(0.4)
                self.sink({"window_id": window_id, "text": "слово.", "seconds": 0.4})

            threading.Thread(target=answer, daemon=True).start()
            return True

    verifier = Slow(ema=5.0)
    session = Session("long", "ru", pool=FakePool(), verifier=verifier)
    verifier.sink = session.on_verifier
    _feed(session, np.concatenate([tone(2), silence(1)]))
    progress: list[tuple[int, int]] = []
    result = session.finish(wait_verifier_ms=0, on_wait=lambda done, total: progress.append((done, total)))
    assert result["verifier"] == "done"
    assert progress and progress[0][0] == 0 and progress[0][1] >= 1


def test_skip_wait_inserts_fast_version(monkeypatch):
    """«Вставить быструю версию»: ожидание обрывается сразу, текст основной модели, `late`."""
    _long(monkeypatch, cap_s=30.0)
    verifier = Silent(ema=None)
    session = Session("skip", "ru", pool=FakePool(), verifier=verifier)
    _feed(session, np.concatenate([tone(2), silence(1)]))
    threading.Timer(0.2, session.skip_wait).start()
    started = time.monotonic()
    result = session.finish(wait_verifier_ms=0)
    assert result["verifier"] == "late"
    assert time.monotonic() - started < 2.0
    assert verifier.cancelled == ["skip"]


def test_short_dictation_keeps_old_deadline(monkeypatch):
    """Короткая диктовка ждёт только свой срок, без потолка длинной."""
    monkeypatch.setattr(session_mod, "LONG_WAIT_CAP_S", 30.0)
    session = Session("short", "ru", pool=FakePool(), verifier=Silent(ema=None))
    _feed(session, np.concatenate([tone(2), silence(1)]))
    started = time.monotonic()
    assert session.finish(wait_verifier_ms=200)["verifier"] == "late"
    assert time.monotonic() - started < 1.5


class LaggingPool(FakePool):
    """Основная модель медленнее речи: пока распознаёт окно, приходит ещё секунда звука."""

    session: Session | None = None

    def recognize(self, waveform, language, **kwargs):
        if self.session is not None:
            self.session.append(pcm16(silence(1.0)))
        return super().recognize(waveform, language, **kwargs)


class Counting(FakeVerifier):
    def __init__(self) -> None:
        super().__init__()
        self.submitted: list[str] = []

    def submit(self, window_id, session, pcm16, language, hotwords=None):
        self.submitted.append(window_id)
        return True  # ответа не будет: ждать его — значит висеть до потолка


def test_lagging_primary_sheds_verifier(monkeypatch):
    """Основная модель отстала больше порога: проверяющую до конца записи не зовём и не ждём."""
    _long(monkeypatch, cap_s=30.0)
    monkeypatch.setattr(session_mod, "LAG_SHED_S", 0.5)
    monkeypatch.setattr(session_mod, "PACK_MIN_S", 0.5)  # первая пачка уходит до отставания
    pool, verifier = LaggingPool(), Counting()
    session = Session("lag", "ru", pool=pool, verifier=verifier)
    pool.session = session
    _feed(session, np.concatenate([tone(1), silence(1)]))  # первое окно: пачка ушла, затем отставание
    assert session.verifier_shed and verifier.cancelled == ["lag"]
    sent = list(verifier.submitted)
    assert sent  # до отставания проверяющая работала
    pool.session = None
    _feed(session, np.concatenate([tone(1), silence(1), tone(1), silence(1)]))
    started = time.monotonic()
    result = session.finish(wait_verifier_ms=0)
    assert time.monotonic() - started < 2.0  # не ждём ответа на старые пачки до потолка 30 с
    assert verifier.submitted == sent  # новые пачки не ушли
    assert result["timings"]["verifier_shed"] is True
    assert "слово" in result["text"]


def test_keeping_up_keeps_verifier(monkeypatch):
    """Успевает за речью — проверяющая работает как раньше."""
    monkeypatch.setattr(session_mod, "LAG_SHED_S", 0.5)
    verifier = FakeVerifier()
    session = Session("ok", "ru", pool=FakePool(), verifier=verifier)
    verifier.sink = session.on_verifier
    _feed(session, np.concatenate([tone(1), silence(1), tone(1), silence(1)]))
    result = session.finish(wait_verifier_ms=500)
    assert not session.verifier_shed and "verifier_shed" not in result["timings"]
    assert result["verifier"] == "done"


def test_catch_up_progress_after_stop():
    """После отпускания распознавание догоняет: плашка получает ход в десятых секунды."""
    events: list[dict] = []
    session = Session("p", "ru", pool=FakePool(), verifier=None, emit=events.append)
    for chunk in (tone(1), silence(1), tone(1), silence(1), tone(1), silence(0.3)):
        session.append(pcm16(chunk))  # звук пришёл, шаги не успели: всё распознаётся на finish
    session.stopping = True
    session.finish()
    asr = [e for e in events if e.get("stage") == "asr"]
    assert asr and all(e["task"] == "dictation" and e["session"] == "p" for e in asr)
    assert [e["done"] for e in asr] == sorted(e["done"] for e in asr)
    assert all(0 < e["done"] <= e["total"] == 53 for e in asr)  # 5,3 с звука в десятых
    assert asr[-1]["done"] >= 50  # к концу распознано почти всё


def test_no_catch_up_progress_while_recording():
    events: list[dict] = []
    session = Session("r", "ru", pool=FakePool(), verifier=None, emit=events.append)
    _feed(session, np.concatenate([tone(1), silence(1), tone(1), silence(1)]))
    assert not [e for e in events if e.get("stage") == "asr"]


def test_window_seams_drop_false_periods():
    windows = ["Место есть.", "Только у Acme.", "И у Globex.", "Его есть достаточно.", "Globex.", "То есть.",
               "Я там цифру, не помню.", "100.", "При скидке нам на год.", "За терабайт.", "Тоже подходит."]
    assert join_windows(windows) == (
        "Место есть. Только у Acme и у Globex его есть достаточно. Globex то есть. Я там цифру, не помню. "
        "100 при скидке нам на год. За терабайт тоже подходит."
    )


def test_window_seams_keep_real_sentence_ends():
    assert join_windows(["Привет.", "Москва большая.", "Ок.", "Globex молодцы."]) == (
        "Привет. Москва большая. Ок. Globex молодцы."
    )
    assert join_seam("Готов?", "И это всё.") == "Готов? И это всё."
    assert join_seam("Ну и вот...", "И это всё.") == "Ну и вот... И это всё."
    assert join_seam("Это API.", "И SDK.") == "Это API и SDK."
    assert join_seam("Я спросил.", "IBM ответил.") == "Я спросил. IBM ответил."
