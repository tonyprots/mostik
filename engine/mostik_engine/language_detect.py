"""Автоопределение языка диктовки только из списка пользователя (L5).

Список приходит от приложения (`start.languages`): по умолчанию это языки Mac из
`Locale.preferredLanguages`, пересечённые с поддерживаемыми `ru` и `en`. Если в нём
один язык — определять нечего. Иначе первое окно речи уходит Whisper (тот же процесс,
что проверяет русский): он даёт вероятности языков, и из них берётся лучший
среди разрешённых. Не ответил вовремя или не уверен — язык по умолчанию из Настроек.
"""
from __future__ import annotations

from typing import Iterable, Mapping

SUPPORTED = ("ru", "en")
DETECT_SECONDS = 8.0
TIMEOUT_S = 3.0
# Ниже этой доли среди разрешённых языков — не уверен, остаётся язык по умолчанию.
MIN_SHARE = 0.6


def allowed_languages(raw: Iterable[object] | None) -> list[str]:
    """Коды из списка приложения: «ru-RU» → «ru», только поддерживаемые, без повторов."""
    picked: list[str] = []
    for item in raw or []:
        code = str(item or "").strip().lower().replace("_", "-").split("-")[0]
        if code in SUPPORTED and code not in picked:
            picked.append(code)
    return picked


def pick_language(probs: Mapping[str, float] | None, allowed: list[str], default: str) -> tuple[str, float]:
    """Лучший язык среди разрешённых и его доля; при неуверенности — `default`."""
    if not allowed:
        return default, 0.0
    scores = {code: max(0.0, float((probs or {}).get(code, 0.0))) for code in allowed}
    total = sum(scores.values())
    if total <= 0:
        return (default if default in allowed else allowed[0]), 0.0
    best = max(allowed, key=lambda code: scores[code])
    share = scores[best] / total
    if share < MIN_SHARE and default in allowed:
        return default, round(share, 3)
    return best, round(share, 3)
