"""Подсказка и громкость для Whisper (L4).

Подсказка — `initial_prompt`: термины и фраза-образец на языке диктовки. Только
термины (как раньше через `hotwords`) Whisper читает как список и теряет пунктуацию;
только фраза — теряет термины. Идея — vadic (MIT), фразы свои.

Громкость — пиковая нормализация окна до −0,1 dBFS перед Whisper: тихие слова
он выбрасывает. Усиление ограничено, а почти тишина не трогается, чтобы не
раздувать шум до «речи».
"""
from __future__ import annotations

from typing import Any, Iterable

# Фраза задаёт язык, регистр и пунктуацию; в ней нет терминов и имён.
SAMPLE_PHRASES = {
    "ru": "Так, давай посмотрим задачу: проверим код, поправим тесты и выложим релиз.",
    "en": "Okay, let's look at the task: check the code, fix the tests, and ship the release.",
}
# Whisper держит из подсказки только последние 223 токена, и лишнее срезается с начала —
# вместе с фразой. 400 знаков кириллицы и терминов укладываются с запасом (замер в стенде L4).
PROMPT_CHARS = 400
TERMS_LIMIT = 60
TARGET_DBFS = -0.1
MAX_GAIN_DB = 30.0
SILENCE_PEAK = 1e-4


def pick_terms(words: Iterable[Any] | None, *, limit: int = TERMS_LIMIT, chars: int = PROMPT_CHARS) -> list[str]:
    """Термины без повторов и пустых, в пределах числа и длины."""
    picked: list[str] = []
    length = 0
    for word in words or []:
        word = str(word).strip()
        if not word or word in picked:
            continue
        if len(picked) >= limit or length + len(word) + 2 > chars:
            break
        picked.append(word)
        length += len(word) + 2
    return picked


def build_prompt(language: str | None, hotwords: Iterable[Any] | None, *, chars: int = PROMPT_CHARS) -> str | None:
    """«Термин, Термин, Термин. Фраза-образец.» — или None, если сказать нечего.

    Термины идут первыми, фраза — последней, прямо перед звуком. Так замерено на стенде
    (`docs/bench.md`, L4): с фразой в конце русские диктовки не теряют латиницу терминов
    (42 из 56 против 38 у порядка «фраза, термины»), а пунктуация у английского — 100 %."""
    phrase = SAMPLE_PHRASES.get(language or "", "")
    terms = pick_terms(hotwords, chars=max(0, chars - len(phrase) - 2))
    head = ", ".join(terms)
    if head and not head.endswith((".", "!", "?")):
        head += "."
    prompt = " ".join(part for part in (head, phrase) if part)
    return prompt or None


def peak_gain(peak: float, *, target_dbfs: float = TARGET_DBFS, max_gain_db: float = MAX_GAIN_DB) -> float:
    """Во сколько раз усилить окно с таким пиком; 1.0 — не трогать."""
    if peak <= SILENCE_PEAK:
        return 1.0
    target = 10 ** (target_dbfs / 20)
    return min(target / peak, 10 ** (max_gain_db / 20))


def peak_normalize(audio: Any, *, target_dbfs: float = TARGET_DBFS, max_gain_db: float = MAX_GAIN_DB) -> Any:
    """float32 моно → то же с пиком −0,1 dBFS (и ослабляет перегруженное)."""
    import numpy as np

    samples = np.asarray(audio, dtype=np.float32)
    if not samples.size:
        return samples
    gain = peak_gain(float(np.max(np.abs(samples))), target_dbfs=target_dbfs, max_gain_db=max_gain_db)
    if gain == 1.0:
        return samples
    return np.clip(samples * gain, -1.0, 1.0).astype(np.float32)
