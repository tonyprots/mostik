"""Длинная диктовка ждёт проверяющую до конца; «Вставить быструю версию» прерывает ожидание; стыки окон."""
from __future__ import annotations

import threading
import time

import numpy as np

from conftest import FakePool, silence, tone
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
