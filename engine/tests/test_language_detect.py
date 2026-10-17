"""L5: автоопределение языка только из списка пользователя."""
from __future__ import annotations

import base64

import numpy as np

from conftest import SR, FakePool, FakeVerifier, pcm16, silence, tone
from mostik_engine.language_detect import allowed_languages, pick_language
from mostik_engine.personal_glossary import PersonalGlossary
from mostik_engine.server import Engine
from mostik_engine.session import Session
from test_protocol import Sink, send


def test_allowed_languages_from_mac_list():
    assert allowed_languages(["ru-RU", "en-US", "de-DE", "en-GB", "uk"]) == ["ru", "en"]
    assert allowed_languages(["en_US"]) == ["en"]
    assert allowed_languages(None) == []


def test_pick_only_from_allowed():
    probs = {"ru": 0.2, "en": 0.7, "uk": 0.1}
    assert pick_language(probs, ["ru", "en"], "ru") == ("en", round(0.7 / 0.9, 3))
    # Украинский вероятнее всех, но его нет в списке — выбор между ru и en.
    assert pick_language({"uk": 0.9, "ru": 0.08, "en": 0.02}, ["ru", "en"], "en")[0] == "ru"


def test_pick_unsure_or_empty_keeps_default():
    assert pick_language({"ru": 0.5, "en": 0.45}, ["ru", "en"], "en")[0] == "en"
    assert pick_language(None, ["ru", "en"], "ru") == ("ru", 0.0)
    assert pick_language({}, [], "en") == ("en", 0.0)


class DetectingVerifier(FakeVerifier):
    def __init__(self, probs):
        super().__init__()
        self.probs = probs
        self.detects: list[list[str]] = []

    def submit_detect(self, window_id, session, pcm, languages):
        self.detects.append(list(languages))
        if self.sink and self.probs is not None:
            self.sink({"window_id": window_id, "probs": self.probs, "seconds": 0.01})
        return True


def _session(probs, languages=("ru", "en")):
    verifier = DetectingVerifier(probs)
    session = Session("s", "ru", pool=FakePool(), verifier=verifier)
    verifier.sink = session.on_verifier
    session.languages = list(languages)
    session.detector = verifier.submit_detect
    changed: list[str] = []
    session.on_language = lambda current: changed.append(current.language)
    return session, verifier, changed


def test_session_switches_language_once():
    session, verifier, changed = _session({"ru": 0.1, "en": 0.9})
    session.append(pcm16(np.concatenate([tone(1.5), silence(0.6), tone(1.5), silence(0.6)])))
    result = session.finish()
    assert result["language"] == "en" and changed == ["en"]
    assert verifier.detects == [["ru", "en"]]
    assert result["language_detect"]["detected"] == "en" and not result["language_detect"]["fallback"]


def test_session_timeout_falls_back_to_default(monkeypatch):
    import mostik_engine.language_detect as ld

    monkeypatch.setattr(ld, "TIMEOUT_S", 0.05)
    session, _, changed = _session(None)
    session.append(pcm16(np.concatenate([tone(1.5), silence(0.6)])))
    result = session.finish()
    assert result["language"] == "ru" and changed == []
    assert result["language_detect"]["fallback"] is True


def test_engine_detects_only_with_two_languages(tmp_path):
    sink = Sink()
    verifier = DetectingVerifier({"ru": 0.05, "en": 0.95})
    eng = Engine(sink, pool=FakePool(), verifier=verifier,
                 personal=PersonalGlossary(tmp_path / "g.yaml", import_transcriber=False))
    verifier.sink = eng._on_verifier
    pcm = pcm16(np.concatenate([tone(1.5), silence(0.6)]))
    frame = int(0.1 * SR) * 2
    for number, languages in ((1, ["ru-RU", "en-US"]), (2, ["ru-RU"])):
        session = f"s{number}"
        send(eng, cmd="start", id=number * 10, session=session, language="ru", languages=languages)
        sink.wait(lambda e, n=number: e.get("id") == n * 10)
        for index, at in enumerate(range(0, len(pcm), frame)):
            send(eng, cmd="audio", id=1000 * number + index, session=session,
                 pcm=base64.b64encode(pcm[at : at + frame]).decode())
        send(eng, cmd="stop", id=number * 10 + 1, session=session, wait_verifier_ms=500)
        final = sink.wait(lambda e, s=session: e.get("event") == "final" and e.get("session") == s)
        if number == 1:
            assert final["language"] == "en" and final["language_detect"]["from"] == ["ru", "en"]
        else:
            assert final["language"] == "ru" and "language_detect" not in final
    assert verifier.detects == [["ru", "en"]]
