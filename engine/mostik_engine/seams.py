"""Склейка окон распознавания без ложных точек на стыках.

Основная модель видит каждое окно речи отдельно и закрывает его точкой, а
следующее начинает с заглавной: «Только у Acme. И у Globex. Его есть
достаточно». На стыке окон точка снимается, если фраза явно продолжается:
следующее окно начинается с союза или местоимения или предыдущий обрывок —
одно слово, а следующее — обычное словарное. Предлоги в список служебных слов не
входят: с них новое предложение начинается часто. Знаки «?» и «!» и точки
внутри окна не трогаются.

Окна режутся по паузам, а пауза — чаще всего и есть конец фразы. Поэтому слов, с которых
предложения начинаются часто («если», «как», «когда», «то», «такой»), в списке нет, а
законченный ответ из одного слова («Хорошо.», «Okay.») обрывком не считается.

С местоимения («его», «их», «ему») новое предложение начинается не реже, чем продолжается
старое: «Я отправил отчёт. Его посмотрит Маша.» Точку перед ним снимаем, только если слева
нет сказуемого — «Только у Acme. И у Globex. Его есть достаточно»: там фраза ещё не закончена.
Сказуемое узнаём по окончанию слова, без морфологии; ошибка в сторону «сказуемое есть» лишь
оставляет точку модели на месте.
"""
from __future__ import annotations

import re
from collections.abc import Iterable

from .wordlists import is_natural_word

# Слова, с которых новое предложение начинается редко, а продолжение фразы — часто.
CONTINUE_RU = frozenset("""
и а но или либо что чтобы который которая которое которые которого которой которых котором которым
потому поэтому тоже также его ее её их ему ей им него нее неё них ли же бы чем
""".split())
CONTINUE_EN = frozenset("""
and or but that which who whom than because
""".split())
CONTINUE = CONTINUE_RU | CONTINUE_EN
# Местоимения: продолжают фразу, только если слева ещё нет сказуемого (`_has_predicate`).
PRONOUNS = frozenset("его ее её их ему ей им него нее неё них".split())
# Перед этими союзами вместо снятой точки нужна запятая: «Я думаю, что это правильно».
COMMA_BEFORE = frozenset("""
а но что чтобы который которая которое которые которого которой которых котором которым потому чем
""".split())
# Одно слово, но законченная реплика: точка после него настоящая.
COMPLETE = frozenset("""
да нет хорошо ладно ок окей понятно ясно спасибо привет отлично конечно согласен согласна точно верно
okay ok yes no yeah sure right thanks hello hi fine great
""".split())

_FIRST_WORD = re.compile(r"[A-Za-zА-Яа-яЁё]+")
_WORD = re.compile(r"[0-9A-Za-zА-Яа-яЁё]+")
# Начало последнего предложения левой части: после «.», «?», «!» или «…» с пробелом.
_SENTENCE_START = re.compile(r".*[.?!…]\s+", re.S)
# Сказуемое без глагольного окончания: связки, модальные и краткие прилагательные.
_PREDICATIVES = frozenset("""
есть нет надо нужно можно нельзя пора жаль был дал шёл шел ждёт ждет идёт идет
готов готова готово готовы должен должна должно должны нужен нужна нужны рад рада рады
могу хочу буду знаю думаю вижу прошу жду
""".split())
# Личные формы, прошедшее время и инфинитив. Сюда попадают и существительные («бюджет», «канал») —
# это только оставляет точку.
_VERB_END = re.compile(
    r"(?:л|ла|ло|ли|лся|лась|лось|лись|ет|ёт|ит|ют|ут|ат|ят|ем|ём|им|ешь|ёшь|ишь|ете|ёте|ите|тся|ть|ться|ти|чь)$"
)
# Обрывок из стольких слов и короче — не предложение, а кусок, отрезанный паузой.
SHORT_FRAGMENT_WORDS = 1


def _last_sentence(text: str) -> str:
    match = _SENTENCE_START.match(text[:-1])
    return text[match.end():-1] if match else text[:-1]


def _has_predicate(words: list[str]) -> bool:
    """В предложении слева есть сказуемое — оно закончено, и точка после него настоящая."""
    for word in words:
        word = word.casefold()
        if word in _PREDICATIVES or (len(word) >= 4 and word not in CONTINUE and _VERB_END.search(word)):
            return True
    return False


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
    last = _WORD.findall(_last_sentence(left))
    if connector and word.casefold() in PRONOUNS and _has_predicate(last):
        connector = False
    fragment = len(last) <= SHORT_FRAGMENT_WORDS and not (last and last[0].casefold() in COMPLETE)
    # После обрывка строчной пишем только словарное слово: имя или аббревиатура оставляют точку.
    if not (connector or (fragment and is_natural_word(word))):
        return f"{left} {right}"
    # Аббревиатуру и английское «I» строчной не пишем.
    if not ((len(word) > 1 and word.isupper()) or word == "I"):
        right = word[0].lower() + right[1:]
    comma = "," if connector and word.casefold() in COMMA_BEFORE else ""
    return f"{left[:-1]}{comma} {right}"


def join_windows(texts: Iterable[str]) -> str:
    joined = ""
    for text in texts:
        if text and text.strip():
            joined = join_seam(joined, text)
    return joined.strip()
