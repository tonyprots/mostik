"""Правила извлечения терминов из текста (договор этапа A, «Правила извлечения (S3)»).

Берём: аббревиатуры из 2–6 заглавных, слова с латиницей и цифрами, CamelCase
и snake_case, имена собственные (заглавная не в начале предложения, не меньше
двух раз на источник), кодовые имена после «проект», «клиент», «project»,
«codename», слова из заголовков Markdown, латинские слова в русском тексте.

Выбрасываем: словарные слова, числа и версии, хэши, почту, логины, URL, пути,
слова короче 3 символов (кроме аббревиатур и сочетаний буквы с цифрой: `S3`).

Чистые функции без файлов: на вход текст, на выход
`{термин: [частота, вид, строка, нужен_повтор]}`. Вид — `person`, `project`,
`tech`, `acronym`, `identifier`. `нужен_повтор` = 1 у кандидатов в имена
собственные: термин выживет, только если по всему источнику встретился ≥2 раз.
"""
from __future__ import annotations

import re
from typing import Iterable

from .wordlists import is_common, is_natural_word

KINDS = ("person", "project", "tech", "acronym", "identifier")
MIN_LENGTH = 3

_URL = re.compile(r"^[(<\[«\"']*(?:[a-z][a-z0-9+.-]*://|www\.)", re.IGNORECASE)
_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
_WORD = re.compile(r"[0-9A-Za-zА-Яа-яЁё_][0-9A-Za-zА-Яа-яЁё_+#-]*")
_VERSION = re.compile(r"^v?\d+(?:[._-]\d+)*[a-z]?$", re.IGNORECASE)
_HEX = re.compile(r"^[0-9a-fA-F]+$")
_ACRONYM = re.compile(r"^[A-ZА-ЯЁ]{2,6}$")
_HAS_LETTER = re.compile(r"[A-Za-zА-Яа-яЁё]")
_HAS_DIGIT = re.compile(r"\d")
_LATIN = re.compile(r"[A-Za-z]")
# Без кода (папки документов): `код в обратных кавычках` и имена файлов вроде app.js, main.py.
_LOWER_CAMEL = re.compile(r"^[a-z]{2,}[A-Z][a-z]")
_CODE_SPAN = re.compile(r"`[^`]*`")
_FILE_NAME = re.compile(r"^[\w+-]+(?:\.[\w+-]+)*\.[A-Za-z][A-Za-z0-9]{0,5}$")
_CYRILLIC = re.compile(r"[А-Яа-яЁё]")
_CAMEL = re.compile(r"[a-zа-яё0-9][A-ZА-ЯЁ]|[A-ZА-ЯЁ]{2}[a-zа-яё]")
_HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$")
_LIST_MARK = re.compile(r"^(?:[-*+>|]+|\d+[.)])$")
_SENTENCE_END = ".!?…"
_CODENAME_TRIGGER = re.compile(r"^(?:проект\w*|клиент\w*|project|codename|кодов\w*)$", re.IGNORECASE)
# Пары-исключения из двух букв, которые выглядят аббревиатурой, но ею не служат.
_SHORT_NOISE = frozenset(
    {"OK", "ID", "AM", "PM", "PS", "NB", "OR", "IF", "IS", "IT", "TO", "OF", "ON", "IN", "AT", "BY",
     "КБ", "МБ", "ГБ", "ТБ", "РФ", "ТЗ"}
)

# Вес вхождения: заголовок и кодовое имя весят больше одного слова в тексте.
HEADING_WEIGHT = 2
CODENAME_WEIGHT = 2

Found = dict[str, list[int | str]]


def is_noise_chunk(chunk: str) -> bool:
    """Целый кусок между пробелами — URL, почта, логин или путь: выбрасываем целиком."""
    stripped = chunk.strip("()[]<>«»\"'.,;:!?")
    if not stripped:
        return False
    if _URL.match(chunk) or _EMAIL.search(stripped):
        return True
    if stripped.startswith("@") and len(stripped) > 1:
        return True
    return "/" in stripped or "\\" in stripped or stripped.startswith("~")


def rejected(word: str) -> bool:
    """Числа, версии, хэши, короткие и словарные слова."""
    if not _HAS_LETTER.search(word):
        return True
    if _VERSION.match(word):
        return True
    if len(word) >= 7 and _HEX.match(word) and (_HAS_DIGIT.search(word) or len(word) >= 12):
        return True
    if len(word) < MIN_LENGTH:
        short_ok = (_ACRONYM.match(word) and word not in _SHORT_NOISE) or (
            _HAS_DIGIT.search(word) and len(word) == 2
        )
        if not short_ok:
            return True
    if _ACRONYM.match(word):
        return is_natural_word(word)
    if "_" in word or _HAS_DIGIT.search(word):
        return False
    return is_common(word)


def shape_kind(word: str) -> str | None:
    """Вид по форме слова; None — обычное слово, вид решает контекст."""
    if _ACRONYM.match(word):
        return "acronym"
    if _HAS_DIGIT.search(word) and _HAS_LETTER.search(word):
        return "tech"
    if "_" in word.strip("_") or _CAMEL.search(word):
        return "identifier"
    return None


def proper_kind(word: str) -> str:
    """Имя собственное кириллицей — человек; латиницей — скорее продукт или технология."""
    return "person" if _CYRILLIC.search(word) else "tech"


def _capitalized(word: str) -> bool:
    return word[:1].isupper() and not word.isupper()


def mostly_cyrillic(text: str) -> bool:
    return len(_CYRILLIC.findall(text)) > len(_LATIN.findall(text))


def _add(found: Found, term: str, kind: str, line: int, *, weight: int = 1, repeat: int = 0) -> None:
    current = found.get(term)
    if current is None:
        found[term] = [weight, kind, line, repeat]
        return
    current[0] = int(current[0]) + weight
    # Кодовое имя главнее формы; надёжная находка главнее кандидата в имена.
    if kind == "project" or (current[3] and not repeat):
        current[1] = kind
    # Термин, найденный хоть раз без условия повтора, условия больше не ждёт.
    if not repeat:
        current[3] = 0


def _clean(word: str) -> str:
    return word.strip("-")


def _words(line: str) -> Iterable[tuple[str, bool, bool]]:
    """(слово, начало предложения, закончилось ли предложение после слова)."""
    sentence_start = True
    for chunk in line.split():
        if _LIST_MARK.match(chunk):
            sentence_start = True
            continue
        ends = chunk.rstrip("»\"')]*_").endswith(tuple(_SENTENCE_END))
        if is_noise_chunk(chunk):
            sentence_start = ends
            continue
        quoted = chunk[:1] in "«\"'“„"
        for index, match in enumerate(_WORD.finditer(chunk)):
            word = _clean(match.group(0))
            # Заглавная сразу после открывающей кавычки — начало цитаты
            # («Словарь», «Записать»): это подписи интерфейса, а не имена.
            opens_quote = index == 0 and quoted
            if word:
                yield word, (sentence_start or opens_quote) and index == 0, quoted
            sentence_start = False
        sentence_start = ends


def _without_code(line: str) -> str:
    """Строка без кода: убраны `спаны` и куски, похожие на имя файла (app.js, main.py)."""
    line = _CODE_SPAN.sub(" ", line)
    return " ".join(chunk for chunk in line.split()
                    if not (_LATIN.search(chunk) and _FILE_NAME.match(chunk.strip("()[]<>«»\"'.,;:!?"))))


def terms_from_document(
    text: str, *, markdown: bool = True, cyrillic: bool | None = None, code: bool = True
) -> Found:
    """Документ (Markdown, текст, текст PDF) → найденные термины со строками.

    `code=False` — папки документов: блоки кода, `спаны`, имена файлов и идентификаторы
    (snake_case, camelCase со строчной) не берутся. Из кода — только в режиме разработчика (`repo`).
    """
    found: Found = {}
    if cyrillic is None:
        cyrillic = mostly_cyrillic(text)
    in_fence = False
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if markdown and stripped.startswith(("```", "~~~")):
            in_fence = not in_fence
            continue
        if in_fence and not code:
            continue
        heading = _HEADING.match(line) if markdown and not in_fence else None
        body = heading.group(1) if heading else line
        if not code:
            body = _without_code(body)
        weight = HEADING_WEIGHT if heading else 1
        previous: str | None = None
        for word, at_start, quoted in _words(body):
            trigger = previous is not None and _CODENAME_TRIGGER.match(previous)
            previous = word
            if rejected(word) or (trigger and _CODENAME_TRIGGER.match(word)):
                continue
            kind = shape_kind(word)
            if kind == "identifier" and not code and ("_" in word.strip("_") or _LOWER_CAMEL.match(word)):
                continue  # load_vad, insertText; ClickHouse, gRPC, iPhone, macOS — названия, остаются
            if trigger and (kind or _capitalized(word) or _LATIN.search(word) or quoted):
                _add(found, word, "project", number, weight=CODENAME_WEIGHT)
                continue
            if kind:
                _add(found, word, kind, number, weight=weight)
                continue
            if _LATIN.search(word) and (heading or cyrillic):
                # Латинское слово в русском тексте или в заголовке — термин.
                _add(found, word, "tech", number, weight=weight)
                continue
            if _capitalized(word) and not at_start:
                _add(found, word, proper_kind(word), number, weight=weight, repeat=1)
    return found


def terms_from_title(title: str) -> Found:
    """Название встречи: короткое, поэтому заглавное слово — кодовое имя без условия повтора."""
    found: Found = {}
    previous: str | None = None
    for word, at_start, quoted in _words(title):
        trigger = previous is not None and _CODENAME_TRIGGER.match(previous)
        previous = word
        if rejected(word):
            continue
        kind = shape_kind(word)
        if kind:
            _add(found, word, kind, 1)
        elif trigger or quoted or (_capitalized(word) and not at_start) or _LATIN.search(word):
            _add(found, word, "project", 1)
    return found


def name_terms(name: str) -> list[str]:
    """Имя участника → полное имя и его части (фамилия, имя) длиной от 3 букв."""
    name = " ".join(name.split())
    if not name or "@" in name or not _HAS_LETTER.search(name):
        return []
    parts = [part.strip(".,()") for part in name.split()]
    result = [name]
    if len(parts) > 1:
        for part in parts:
            if len(part) >= MIN_LENGTH and _HAS_LETTER.search(part) and not is_natural_word(part) and part not in result:
                result.append(part)
    return result
