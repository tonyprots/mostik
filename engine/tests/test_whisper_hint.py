"""L4: подсказка Whisper «фраза + термины» и пиковая нормализация."""
from __future__ import annotations

import numpy as np

from mostik_engine import verifier_worker
from mostik_engine.whisper_hint import PROMPT_CHARS, SAMPLE_PHRASES, build_prompt, peak_gain, peak_normalize


def test_prompt_is_terms_then_phrase():
    prompt = build_prompt("ru", ["Mostik", "GigaAM", "Mostik", " ", "Claude Code"])
    assert prompt == "Mostik, GigaAM, Claude Code. " + SAMPLE_PHRASES["ru"]


def test_prompt_language_and_empty_cases():
    assert build_prompt("en", []).startswith("Okay,")
    assert build_prompt(None, ["Mostik"]) == "Mostik."
    assert build_prompt("de", None) is None


def test_prompt_fits_budget_and_keeps_phrase():
    prompt = build_prompt("ru", [f"Термин{i}" for i in range(200)])
    assert len(prompt) <= PROMPT_CHARS
    assert prompt.endswith(SAMPLE_PHRASES["ru"])


def test_peak_normalize_to_minus_0_1_dbfs():
    quiet = (0.05 * np.sin(np.linspace(0, 200, 16000))).astype(np.float32)
    louder = peak_normalize(quiet)
    assert abs(20 * np.log10(np.max(np.abs(louder))) - (-0.1)) < 0.01
    assert louder.dtype == np.float32


def test_peak_normalize_limits_and_silence():
    assert peak_gain(0.0) == 1.0
    assert peak_gain(5e-5) == 1.0
    assert abs(peak_gain(1e-3) - 10 ** 1.5) < 1e-6  # не больше +30 дБ
    loud = np.array([0.0, 1.0, -1.0], dtype=np.float32)
    assert np.max(np.abs(peak_normalize(loud))) <= 10 ** (-0.1 / 20) + 1e-6


class _Model:
    def __init__(self):
        self.calls = []

    def generate(self, audio, **kwargs):
        self.calls.append((np.max(np.abs(audio)), kwargs))

        class Answer:
            text = "ok"

        return Answer()


def _request(amplitude=0.05):
    pcm = (amplitude * np.sin(np.linspace(0, 400, 16000)) * 32767).astype("<i2").tobytes()
    import base64

    return {"window_id": "s:0", "pcm": base64.b64encode(pcm).decode(), "language": "ru", "hotwords": ["Mostik"]}


def test_worker_uses_phrase_prompt_and_normalizes():
    model = _Model()
    verifier_worker._transcribe(model, _request())
    peak, kwargs = model.calls[0]
    assert peak > 0.98
    assert kwargs["initial_prompt"] == "Mostik. " + SAMPLE_PHRASES["ru"]
    assert "hotwords" not in kwargs


def test_worker_legacy_hint_for_bench():
    model = _Model()
    verifier_worker._transcribe(model, _request(), hint="legacy")
    peak, kwargs = model.calls[0]
    assert peak < 0.06
    assert kwargs["hotwords"] == ["Mostik"]
