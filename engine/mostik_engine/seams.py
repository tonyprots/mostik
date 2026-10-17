"""Склейка окон распознавания без ложных точек на стыках.

Основная модель видит каждое окно речи отдельно и закрывает его точкой, а
следующее начинает с заглавной: «Только у Acme. И у Globex. Его есть
достаточно». На стыке окон точка снимается, если фраза явно продолжается:
следующее окно начинается с союза или местоимения или предыдущий обрывок —
одно слово, а следующее — обычное словарное. Предлоги в список служебных слов не
входят: с них новое предложение начинается часто. Знаки «?» и «!» и точки
внутри окна не трогаются.
"""
from __future__ import annotations

import re
from collections.abc import Iterable

from .wordlists import is_natural_word

# Слова, с которых новое предложение начинается редко, а продолжение фразы — часто.
CONTINUE_RU = frozenset("""
и а но или либо что чтобы который которая которое которые которого которой которых котором которым
потому поэтому то тоже также его ее её их ему ей им него нее неё них как когда если ли же бы чем
такой такая такое такие
""".split())
CONTINUE_EN = frozenset("""
and or but that which who whom than so because if when
""".split())
CONTINUE = CONTINUE_RU | CONTINUE_EN

_FIRST_WORD = re.compile(r"[A-Za-zА-Яа-яЁё]+")
_WORD = re.compile(r"[0-9A-Za-zА-Яа-яЁё]+")
# Начало последнего предложения левой части: после «.», «?», «!» или «…» с пробелом.
_SENTENCE_START = re.compile(r".*[.?!…]\s+", re.S)
# Обрывок из стольких слов и короче — не предложение, а кусок, отрезанный паузой.
SHORT_FRAGMENT_WORDS = 1


def _last_sentence(text: str) -> str:
    match = _SENTENCE_START.match(text[:-1])
    return text[match.end():-1] if match else text[:-1]


def join_seam(left: str, right: str) -> str:
    """Соединить два соседних окна; точку на стыке снять, если фраза продолжается."""
    left, right = left.rstrip(), right.lstrip()
    if not left:
        return right
    if not right:
        return left
    first = _FIRST_WORD.match(right)
    if not left.endswith(".") or left.endswith("..") or first is None:
        return f"{left} {right}"
    word = first.group(0)
    connector = word.casefold() in CONTINUE
    fragment = len(_WORD.findall(_last_sentence(left))) <= SHORT_FRAGMENT_WORDS
    # После обрывка строчной пишем только словарное слово: имя или аббревиатура оставляют точку.
    if not (connector or (fragment and is_natural_word(word))):
        return f"{left} {right}"
    if not (len(word) > 1 and word.isupper()):
        right = word[0].lower() + right[1:]
    return f"{left[:-1]} {right}"


def join_windows(texts: Iterable[str]) -> str:
    joined = ""
    for text in texts:
        if text and text.strip():
            joined = join_seam(joined, text)
    return joined.strip()
