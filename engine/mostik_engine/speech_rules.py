"""Правила речи (P3) и числа цифрами (V4): детерминированно, до модели.

То, что однозначно по словам, не стоит отдавать модели: малая локальная модель путает,
облачная — стоит секунд. Правила работают и без причёсывания. Каждое включается отдельно
(`start.rules`), без поля правил нет вовсе — старое поведение.

- `commands` — «новый абзац», «новая строка» (`new paragraph`, `new line`) → перенос;
- `scratch` — «зачеркни», «удали последнюю фразу» (`scratch that`) → предыдущее предложение
  снимается вместе с командой. «Нет, на самом деле…» сюда не входит: после вопроса или чужого
  мнения это обычная речь («Сложно? Нет, на самом деле просто»). Её разбирает модель по правилу
  в промпте, а однозначную замену того же рода — `polish.resolve_self_corrections`;
- `lists` — «во-первых …, во-вторых …» (`first …, second …`) → список «- », только от двух
  пунктов: один «во-первых» без продолжения остаётся текстом (V4);
- `numbers` — числительные цифрами с учётом падежей («двумстам» → 200, «три запятая пять» → 3,5).
  Однозначные числа без единицы остаются словами («два варианта»): так пишут в прозе.

Продиктованный вопрос не отвечать — это правило модели (промпт) и проверка `answered_question`.
"""
from __future__ import annotations

import re
from typing import Iterable

RULES = ("commands", "scratch", "lists", "numbers")
DEFAULT_RULES = {"commands": True, "scratch": True, "lists": True, "numbers": False}


def parse_rules(raw: object) -> dict[str, bool] | None:
    """`start.rules`: объект `{commands, scratch, lists, numbers}` или список имён; иное — None."""
    if raw is None:
        return None
    if isinstance(raw, (list, tuple)):
        return {name: name in raw for name in RULES}
    if isinstance(raw, dict):
        return {name: bool(raw.get(name, False)) for name in RULES}
    return None


# --- команды «новый абзац» ------------------------------------------------------------------

_BREAKS = {
    "ru": [(r"(?:новый|с\s+нового)\s+абзац(?:а)?", "\n\n"), (r"(?:новая|с\s+новой)\s+строк[аи]", "\n")],
    "en": [(r"new\s+paragraph", "\n\n"), (r"new\s+line", "\n")],
}
_END = ".!?…:;"


def _capitalize_from(text: str, index: int) -> str:
    for i in range(index, len(text)):
        if text[i].isalpha():
            return text[:i] + text[i].upper() + text[i + 1:]
        if not text[i].isspace() and text[i] not in "\"«“'(-–—":
            break
    return text


def _standalone(text: str, start: int, end: int) -> bool:
    """Команда стоит отдельно: перед ней начало или знак, или после неё знак или конец.
    «Открой новый абзац в документе» — просьба, а не команда."""
    before = text[:start].rstrip(" \t")
    after = text[end:].lstrip(" \t")
    return (not before or before[-1] in ".!?…,;:\n") or (not after or after[0] in ".!?…,;:\n")


def apply_commands(text: str, language: str = "ru") -> str:
    lang = "en" if language == "en" else "ru"
    for phrase, mark in _BREAKS[lang]:
        pattern = re.compile(rf"(?<![\w-]){phrase}(?![\w-])", re.I)
        position = 0
        while True:
            match = pattern.search(text, position)
            if match is None:
                break
            if not _standalone(text, match.start(), match.end()):
                position = match.end()
                continue
            head = text[: match.start()].rstrip(" \t,;")
            tail = re.sub(r"^[ \t]*[.,;:!]?[ \t]*", "", text[match.end():])
            if head and head[-1] not in _END and head[-1] != "\n" and tail:
                head += "."
            joint = mark if head else ""
            text = head + joint + tail
            text = _capitalize_from(text, len(head) + len(joint))
            position = len(head) + len(joint)
    return re.sub(r"\n{3,}", "\n\n", text).strip(" \t")


# --- «зачеркни» --------------------------------------------------------------------------------

_SCRATCH = {
    "ru": r"(?:зачеркни(?:\s+(?:это|последнее|последнюю\s+фразу))?|удали\s+последн(?:ее|юю\s+фразу))",
    "en": r"(?:scratch\s+that|delete\s+(?:that|the\s+last\s+sentence))",
}


def apply_scratch(text: str, language: str = "ru") -> str:
    """Команда — только отдельной фразой: за ней знак препинания или конец текста
    («зачеркни вторую строку в таблице» — просьба агенту, её не трогаем)."""
    lang = "en" if language == "en" else "ru"
    pattern = re.compile(rf"(?<![\w-]){_SCRATCH[lang]}(?![\w-])[ \t]*(?:[.,;:!]+|$)[ \t]*", re.I)
    while True:
        match = pattern.search(text)
        if match is None:
            return text.strip()
        head = text[: match.start()].rstrip(" \t,;")
        # Предыдущее предложение: от последнего конца предложения (или переноса) до команды.
        cut = max((head.rfind(mark, 0, len(head) - 1) for mark in ".!?…\n"), default=-1)
        kept = head[: cut + 1] if cut >= 0 else ""
        tail = text[match.end():]
        joined = kept.rstrip(" \t") + (" " if kept and not kept.endswith("\n") and tail else "") + tail
        text = _capitalize_from(joined, len(kept))


# --- списки «во-первых, во-вторых» ---------------------------------------------------------------

_ORDINAL_MARKERS = {
    "ru": [r"во[\s-]?первых", r"во[\s-]?вторых", r"в[\s-]?третьих", r"в[\s-]?четв[её]ртых", r"в[\s-]?пятых",
           r"в[\s-]?шестых", r"в[\s-]?седьмых", r"в[\s-]?восьмых", r"в[\s-]?девятых", r"в[\s-]?десятых"],
    "en": [r"first(?:ly)?", r"second(?:ly)?", r"third(?:ly)?", r"fourth(?:ly)?", r"fifth(?:ly)?",
           r"sixth(?:ly)?", r"seventh(?:ly)?", r"eighth(?:ly)?", r"ninth(?:ly)?", r"tenth(?:ly)?"],
}


def _marker_re(marker: str, language: str) -> "re.Pattern[str]":
    # Английские «first», «second» — обычные слова; маркер — только в начале фразы или после знака.
    lead = r"(?:(?<=^)|(?<=[.,;:!?\n])|(?<=[.,;:!?\n] ))(?:and\s+)?" if language == "en" else r"(?<![\w-])"
    return re.compile(rf"{lead}{marker}(?![\w-])\s*[,:—–-]?\s*", re.I)


def _item(text: str) -> str:
    item = text.strip().strip(",;").strip()
    item = re.sub(r"\s+(?:и|а|and)$", "", item, flags=re.I).rstrip(",; ")
    if item.endswith("."):
        item = item[:-1]
    return item[:1].upper() + item[1:]


def apply_lists(text: str, language: str = "ru", min_items: int = 2) -> str:
    """Порядковые маркеры по порядку, начиная с первого → пункты «- »; меньше `min_items` — текст."""
    lang = "en" if language == "en" else "ru"
    positions: list[tuple[int, int]] = []
    cursor = 0
    for marker in _ORDINAL_MARKERS[lang]:
        match = _marker_re(marker, lang).search(text, cursor)
        if match is None:
            break
        positions.append((match.start(), match.end()))
        cursor = match.end()
    if len(positions) < max(2, min_items):
        return text
    lead = text[: positions[0][0]].rstrip(" \t,")
    items = []
    for index, (_, end) in enumerate(positions):
        stop = positions[index + 1][0] if index + 1 < len(positions) else len(text)
        items.append(text[end:stop])
    # Хвост после последнего пункта: первое предложение — пункт, остальное — абзац после списка.
    last = items[-1]
    split = re.search(r"[.!?…](?:\s+|\n)(?=\S)", last)
    rest = ""
    if split:
        rest = last[split.end():].strip()
        items[-1] = last[: split.start() + 1]
    items = [_item(item) for item in items]
    if any(not item for item in items):
        return text
    body = "\n".join(f"- {item}" for item in items)
    if lead.endswith("\n"):  # список с нового абзаца: вводная уже отделена
        result = lead + body
    else:
        if lead and lead[-1] in ".!?…":
            lead = lead[:-1] + ":" if lead[-1] == "." else lead
        elif lead and lead[-1] != ":":
            lead += ":"
        result = (lead + "\n" if lead else "") + body
    return result + ("\n\n" + rest if rest else "")


def single_item_list(text: str) -> str:
    """Список из одного пункта — обычный текст (V4): «- Купить хлеб» → «Купить хлеб»."""
    lines = [line for line in text.split("\n") if line.strip()]
    bullets = [line for line in lines if re.match(r"\s*[-•*]\s+", line)]
    if len(bullets) != 1:
        return text
    return re.sub(r"(?m)^\s*[-•*]\s+", "", text, count=1)


# --- числа (V4) -------------------------------------------------------------------------------------

def _forms(nom: str, gen: str, dat: str, ins: str, prep: str, *extra: str) -> list[str]:
    return [nom, gen, dat, ins, prep, *extra]


def _teen(nom: str) -> list[str]:  # «пять» → пяти, пятью; «одиннадцать» → одиннадцати, одиннадцатью
    stem = nom[:-1]
    return [nom, stem + "и", stem + "ью"]


_RU_UNITS: dict[int, list[str]] = {
    0: ["ноль", "нуля", "нулю", "нулём", "нулем", "нуле", "нуль"],
    1: ["один", "одна", "одно", "одного", "одной", "одному", "одним", "одном", "одну", "одною"],
    2: _forms("два", "двух", "двум", "двумя", "двух", "две"),
    3: _forms("три", "трёх", "трём", "тремя", "трёх", "трех", "трем"),
    4: _forms("четыре", "четырёх", "четырём", "четырьмя", "четырёх", "четырех", "четырем"),
    5: _teen("пять"), 6: _teen("шесть"), 7: _teen("семь"),
    8: ["восемь", "восьми", "восемью", "восьмью"], 9: _teen("девять"),
}
_RU_TEENS: dict[int, list[str]] = {
    10: _teen("десять"), 11: _teen("одиннадцать"), 12: _teen("двенадцать"), 13: _teen("тринадцать"),
    14: _teen("четырнадцать"), 15: _teen("пятнадцать"), 16: _teen("шестнадцать"), 17: _teen("семнадцать"),
    18: _teen("восемнадцать"), 19: _teen("девятнадцать"),
}
_RU_TENS: dict[int, list[str]] = {
    20: _teen("двадцать"), 30: _teen("тридцать"), 40: ["сорок", "сорока"],
    50: ["пятьдесят", "пятидесяти", "пятьюдесятью"], 60: ["шестьдесят", "шестидесяти", "шестьюдесятью"],
    70: ["семьдесят", "семидесяти", "семьюдесятью"],
    80: ["восемьдесят", "восьмидесяти", "восемьюдесятью", "восьмьюдесятью"],
    90: ["девяносто", "девяноста"],
}
_RU_HUNDREDS: dict[int, list[str]] = {
    100: ["сто", "ста"],
    200: ["двести", "двухсот", "двумстам", "двумястами", "двухстах"],
    300: ["триста", "трёхсот", "трехсот", "трёмстам", "тремстам", "тремястами", "трёхстах", "трехстах"],
    400: ["четыреста", "четырёхсот", "четырехсот", "четырёмстам", "четыремстам", "четырьмястами",
          "четырёхстах", "четырехстах"],
}
for _value, _name in ((500, "пят"), (600, "шест"), (700, "сем"), (800, "восем"), (900, "девят")):
    _gen = "восьм" if _name == "восем" else _name
    _RU_HUNDREDS[_value] = [_name + "ьсот", _gen + "исот", _gen + "истам", _name + "ьюстами", _gen + "истах"]
    if _name == "восем":
        _RU_HUNDREDS[_value] += ["восьмьюстами"]

_RU_SCALES: dict[int, list[str]] = {
    1000: ["тысяча", "тысячи", "тысяч", "тысячу", "тысячей", "тысячею", "тысячам", "тысячами", "тысячах", "тыщ",
           "тыщи", "тыща"],
    1_000_000: ["миллион", "миллиона", "миллионов", "миллиону", "миллионом", "миллионам", "миллионами",
                "миллионах", "миллионе", "миллионы"],
    1_000_000_000: ["миллиард", "миллиарда", "миллиардов", "миллиарду", "миллиардом", "миллиардам",
                    "миллиардами", "миллиардах", "миллиарде", "миллиарды"],
}

_EN_SMALL = {name: value for value, name in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen "
    "seventeen eighteen nineteen".split())}
_EN_TENS = {"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
            "ninety": 90}
_EN_SCALES = {"thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000}


def _index(groups: Iterable[dict[int, list[str]]]) -> dict[str, int]:
    table: dict[str, int] = {}
    for group in groups:
        for value, names in group.items():
            for name in names:
                table[name] = value
    return table


_RU_WORDS = _index([_RU_UNITS, _RU_TEENS, _RU_TENS, _RU_HUNDREDS])
_RU_SCALE = _index([_RU_SCALES])
_EN_WORDS = {**_EN_SMALL, **_EN_TENS, "hundred": 100}

# Порядковые («двадцать пятого марта», «второй раз»): последовательность перед ними не трогаем,
# иначе вышло бы «20 пятого марта».
_RU_ORDINAL = re.compile(
    r"^(?:перв|втор|трет|четв[её]рт|пят|шест|седьм|восьм|девят|десят|одиннадцат|двенадцат|тринадцат|"
    r"четырнадцат|пятнадцат|шестнадцат|семнадцат|восемнадцат|девятнадцат|двадцат|тридцат|сороков|"
    r"пятидесят|шестидесят|семидесят|восьмидесят|девяност|сот|двухсот|трёхсот|трехсот|тысячн|миллионн)"
    r"(?:ый|ой|ий|ая|ое|ые|ого|ому|ым|ом|ую|ых|ыми|ей|ья|ье|ьего|ьему|ьим|ьем|ью|ьи|ьих|ьими)$", re.I)
_EN_ORDINAL = re.compile(r"^(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|\w+(?:th|ieth))$",
                         re.I)

# Значение порядкового по основе: длинные основы раньше коротких («пятнадцат» раньше «пят»).
_RU_ORDINAL_STEMS = (
    ("одиннадцат", 11), ("двенадцат", 12), ("тринадцат", 13), ("четырнадцат", 14), ("пятнадцат", 15),
    ("шестнадцат", 16), ("семнадцат", 17), ("восемнадцат", 18), ("девятнадцат", 19), ("двадцат", 20),
    ("тридцат", 30), ("сороков", 40), ("пятидесят", 50), ("шестидесят", 60), ("семидесят", 70),
    ("восьмидесят", 80), ("девяност", 90), ("двухсот", 200), ("трёхсот", 300), ("трехсот", 300),
    ("четырёхсот", 400), ("четырехсот", 400), ("пятисот", 500), ("шестисот", 600), ("семисот", 700),
    ("восьмисот", 800), ("девятисот", 900), ("сот", 100), ("тысячн", 1000), ("перв", 1), ("втор", 2),
    ("трет", 3), ("четвёрт", 4), ("четверт", 4), ("пят", 5), ("шест", 6), ("седьм", 7), ("восьм", 8),
    ("девят", 9), ("десят", 10),
)
# Окончание порядкового → наращение после цифр: «двадцать первого» → «21-го».
_RU_ORDINAL_SUFFIX = {
    "ый": "й", "ий": "й", "ой": "й", "ей": "й", "ая": "я", "ья": "я", "ое": "е", "ье": "е", "ые": "е", "ьи": "е",
    "ого": "го", "ьего": "го", "ому": "му", "ьему": "му", "ым": "м", "ьим": "м", "ом": "м", "ьем": "м",
    "ую": "ю", "ью": "ю", "ых": "х", "ьих": "х", "ыми": "ми", "ьими": "ми",
}
# Перед месяцем и «годом» наращение не пишут: «24 октября», «в 2026 году».
_RU_BARE_AFTER = re.compile(
    r"^(?:январ|феврал|март|апрел|ма[яйюе]|июн|июл|август|сентябр|октябр|ноябр|декабр|год)\w*$", re.I)


def _ru_ordinal(word: str) -> tuple[int, str] | None:
    """«двадцатого» → (20, "го"); не порядковое — None."""
    low = word.lower()
    for stem, value in _RU_ORDINAL_STEMS:
        if low.startswith(stem) and low[len(stem):] in _RU_ORDINAL_SUFFIX:
            return value, _RU_ORDINAL_SUFFIX[low[len(stem):]]
    return None


def is_number_word(word: str) -> bool:
    """Числительное словом: количественное, порядковое или «тысяча» — «восемнадцать», «двадцатого»."""
    return _ru_value(word) is not None or _ru_ordinal(word) is not None or _en_value(word) is not None


def _joins(total: int, part: int) -> bool:
    """«двадцать» + «первый», «две тысячи» + «шестом»: младший разряд у `total` свободен."""
    unit = 10 if part < 10 else 100 if part < 100 else 1000
    return total % unit == 0 and total > part


_UNITS_RU = re.compile(
    r"^(?:%|процент\w*|рубл\w*|руб|долл\w*|евро|доллар\w*|копе\w*|цент\w*|минут\w*|мин|секунд\w*|сек|"
    r"час\w*|дн[еяи]\w*|день|сут\w*|недел\w*|месяц\w*|лет|год\w*|гб|мб|кб|тб|гигабайт\w*|мегабайт\w*|"
    r"килобайт\w*|терабайт\w*|км|километр\w*|метр\w*|см|мм|кг|килограмм\w*|грамм\w*|литр\w*|штук\w*|шт|"
    r"градус\w*|пиксел\w*|px)$", re.I)
_UNITS_EN = re.compile(
    r"^(?:%|percent|dollars?|euros?|cents?|minutes?|seconds?|hours?|days?|weeks?|months?|years?|gb|mb|kb|tb|"
    r"gigabytes?|megabytes?|km|kilometers?|meters?|kg|pounds?|degrees?|pixels?|px)$",
    re.I)

_TOKEN = re.compile(r"\d+(?:[.,]\d+)?|[^\W\d_]+(?:-[^\W\d_]+)*|\S", re.U)


def _ru_value(word: str) -> tuple[str, int] | None:
    low = word.lower().replace("ё", "ё")
    if low in _RU_SCALE:
        return "scale", _RU_SCALE[low]
    if low in _RU_WORDS:
        return "word", _RU_WORDS[low]
    alt = low.replace("е", "ё")
    if alt in _RU_WORDS:
        return "word", _RU_WORDS[alt]
    return None


def _en_value(word: str) -> tuple[str, int] | None:
    low = word.lower()
    if low in _EN_SCALES:
        return "scale", _EN_SCALES[low]
    if low == "hundred":
        return "hundred", 100
    if low in _EN_WORDS:
        return "word", _EN_WORDS[low]
    if "-" in low:  # twenty-five
        parts = low.split("-")
        if len(parts) == 2 and parts[0] in _EN_TENS and parts[1] in _EN_SMALL and 0 < _EN_SMALL[parts[1]] < 10:
            return "word", _EN_TENS[parts[0]] + _EN_SMALL[parts[1]]
    return None


def _place(value: int) -> int:
    """Разряд слова: 1 — единицы и «-надцать», 10 — десятки, 100 — сотни."""
    if value >= 100:
        return 100
    if value >= 20:
        return 10
    return 1


def _digits(value: float | int, language: str) -> str:
    if isinstance(value, float) and not value.is_integer():
        text = f"{value:.6f}".rstrip("0").rstrip(".")
        return text.replace(".", ",") if language == "ru" else text
    return str(int(value))


def _parse_number(tokens: list[str], start: int, language: str) -> tuple[int, int, bool] | None:
    """Целое с позиции `start`: (значение, позиция после, были ли слова). None — числа нет."""
    lookup = _en_value if language == "en" else _ru_value
    total, group, last_place, i, used_words = 0, 0, 1000, start, False
    seen = False
    while i < len(tokens):
        token = tokens[i]
        if re.fullmatch(r"\d+", token) and not seen:
            group, last_place, seen = int(token), 1, True
            i += 1
            continue
        hit = lookup(token)
        if hit is None:
            if language == "en" and token.lower() == "and" and seen and i + 1 < len(tokens) and lookup(tokens[i + 1]):
                i += 1
                continue
            break
        kind, value = hit
        if kind == "scale":
            if not seen and group == 0:
                group = 1
            if total and value >= _largest_scale(total):
                break
            total += group * value
            group, last_place, seen, used_words = 0, 1000, True, True
            i += 1
            continue
        if kind == "hundred":  # английское «five hundred»
            if not seen or group == 0 or group >= 10:
                break
            group *= 100
            last_place, used_words = 100, True
            i += 1
            continue
        place = _place(value)
        if seen and (place >= last_place or (last_place == 10 and value >= 10)):
            break  # «два три», «двадцать тридцать», «двадцать одиннадцать» — не одно число
        if seen and group and last_place == 1:
            break
        group += value
        last_place, seen, used_words = place, True, True
        i += 1
    if not seen:
        return None
    return total + group, i, used_words


def _largest_scale(total: int) -> int:
    for scale in (1_000_000_000, 1_000_000, 1000):
        if total >= scale:
            return scale
    return 1


def _digit_run(tokens: list[str], start: int) -> tuple[str, int]:
    """«ноль пять» после «запятая» — цифры подряд, а не число: 3,05."""
    digits, j = "", start
    while j < len(tokens):
        hit = _ru_value(tokens[j])
        if hit is None or hit[0] != "word" or hit[1] > 9:
            break
        digits += str(hit[1])
        j += 1
    return digits, j


_CLOCK_PREPS = {"в", "к", "до", "с", "со", "после", "около", "на"}


def _clock(tokens: list[str], start: int, end: int, hours: int) -> tuple[int, int] | None:
    """«в двенадцать ноль ноль» → 12:00, «к десяти тридцати» нет, «в девять сорок пять» → 9:45.
    Только после предлога времени и только часы 0–23 с минутами 00–59."""
    if hours > 23 or start == 0 or tokens[start - 1].lower() not in _CLOCK_PREPS or end >= len(tokens):
        return None
    if tokens[end].lower() in ("ноль", "нуль"):
        digits, j = _digit_run(tokens, end)
        if len(digits) == 2:
            return int(digits), j
        return None
    minute = _parse_number(tokens, end, "ru")
    if minute is None or not minute[2] or not 10 <= minute[0] <= 59:
        return None
    if minute[1] < len(tokens) and _ru_ordinal(tokens[minute[1]]) is not None:
        return None  # «в десять двадцать пятого» — это дата, а не 10:20
    return minute[0], minute[1]


_FRACTIONS_RU = {"десятых": 10, "десятая": 10, "десятую": 10, "сотых": 100, "сотая": 100, "сотую": 100,
                 "тысячных": 1000, "тысячная": 1000}


def _ordinal_number(tokens: list[str], start: int,
                    parsed: tuple[int, int, bool] | None) -> tuple[int, int, str] | None:
    """Порядковое с позиции `start`: «восемнадцатый», «двадцать первого», «две тысячи двадцать шестом»,
    разговорный год «двадцать двадцать шестом». (значение, позиция после, наращение) или None."""
    alone = _ru_ordinal(tokens[start])
    if alone is not None and (parsed is None or not parsed[2]):
        return alone[0], start + 1, alone[1]
    if parsed is None or not parsed[2]:
        return None
    value, end, _ = parsed
    if end >= len(tokens):
        return None
    tail = _ru_ordinal(tokens[end])
    if tail is not None and _joins(value, tail[0]):
        return value + tail[0], end + 1, tail[1]
    # «в двадцать двадцать шестом году» → 2026: век и год двумя числами.
    if value in (19, 20):
        inner = _parse_number(tokens, end, "ru")
        inner_end = inner[1] if inner is not None and inner[2] else end
        inner_value = inner[0] if inner is not None and inner[2] else 0
        last = _ru_ordinal(tokens[inner_end]) if inner_end < len(tokens) else None
        if last is not None and (inner_value == 0 or _joins(inner_value, last[0])):
            year = inner_value + last[0]
            after = tokens[inner_end + 1] if inner_end + 1 < len(tokens) else ""
            if year < 100 and re.match(r"^год", after, re.I):
                return value * 100 + year, inner_end + 1, last[1]
    return None


def apply_numbers(text: str, language: str = "ru") -> str:
    """Числительные → цифры. Без единицы рядом однозначные (0–9) остаются словами."""
    lang = "en" if language == "en" else "ru"
    ordinal = _EN_ORDINAL if lang == "en" else _RU_ORDINAL
    units = _UNITS_EN if lang == "en" else _UNITS_RU
    spans = [(m.start(), m.end(), m.group(0)) for m in _TOKEN.finditer(text)]
    tokens = [s[2] for s in spans]
    out: list[str] = []
    cursor = 0
    i = 0
    while i < len(tokens):
        parsed = _parse_number(tokens, i, lang)
        if lang == "ru":
            ordinal_end = _ordinal_number(tokens, i, parsed)
            if ordinal_end is not None:
                value, end, suffix = ordinal_end
                following = tokens[end] if end < len(tokens) else ""
                bare = bool(following) and bool(_RU_BARE_AFTER.match(following))
                if value >= 10 or bare:
                    out.append(text[cursor:spans[i][0]])
                    out.append(str(value) if bare else f"{value}-{suffix}")
                    cursor = spans[end - 1][1]
                i = end
                continue
        if parsed is None or not parsed[2]:
            i += 1
            continue
        value, end, _ = parsed
        number: float | int = value
        # Дробь: «три запятая пять», «три целых пять десятых», «три с половиной», «three point five».
        if lang == "ru" and end + 1 < len(tokens) and tokens[end].lower() in ("запятая", "точка"):
            digits, j = _digit_run(tokens, end + 1)
            if len(digits) < 2:
                frac = _parse_number(tokens, end + 1, lang)
                digits, j = (tokens[end + 1] if re.fullmatch(r"\d+", tokens[end + 1]) else str(frac[0]),
                             frac[1]) if frac is not None else ("", end)
            if digits:
                number, end = float(f"{value}.{digits}"), j
        elif lang == "ru" and end < len(tokens) and tokens[end].lower() in ("целых", "целая", "целую"):
            frac = _parse_number(tokens, end + 1, lang)
            if frac is not None and frac[1] < len(tokens) and tokens[frac[1]].lower() in _FRACTIONS_RU:
                scale = _FRACTIONS_RU[tokens[frac[1]].lower()]
                number, end = value + frac[0] / scale, frac[1] + 1
        elif lang == "ru" and end + 1 < len(tokens) and tokens[end].lower() == "с" \
                and tokens[end + 1].lower() in ("половиной", "половинкой"):
            number, end = value + 0.5, end + 2
        elif lang == "en" and end + 1 < len(tokens) and tokens[end].lower() == "point":
            digits = []
            j = end + 1
            while j < len(tokens) and tokens[j].lower() in _EN_SMALL and _EN_SMALL[tokens[j].lower()] < 10:
                digits.append(str(_EN_SMALL[tokens[j].lower()]))
                j += 1
            if digits:
                number, end = float(f"{value}.{''.join(digits)}"), j
        clock = _clock(tokens, i, end, value) if lang == "ru" and not isinstance(number, float) else None
        if clock is not None:
            minutes, end = clock
            start_char, end_char = spans[i][0], spans[end - 1][1]
            out.append(text[cursor:start_char])
            out.append(f"{value}:{minutes:02d}")
            cursor, i = end_char, end
            continue
        following = tokens[end] if end < len(tokens) else ""
        if following and ordinal.match(following):
            i = end + 1
            continue
        has_unit = bool(following) and bool(units.match(following))
        is_fraction = isinstance(number, float)
        if not (number >= 10 or has_unit or is_fraction):
            i = end
            continue
        start_char, end_char = spans[i][0], spans[end - 1][1]
        out.append(text[cursor:start_char])
        out.append(_digits(number, lang))
        cursor = end_char
        i = end
    out.append(text[cursor:])
    return "".join(out)


# --- всё вместе --------------------------------------------------------------------------------------

def apply(text: str, language: str, rules: dict[str, bool] | None) -> tuple[str, list[str]]:
    """Правила по порядку: команды, «зачеркни», списки, числа. Возвращает текст и что сработало."""
    if not rules or not text:
        return text, []
    applied: list[str] = []
    steps = (("commands", apply_commands), ("scratch", apply_scratch), ("lists", apply_lists),
             ("numbers", apply_numbers))
    for name, step in steps:
        if rules.get(name):
            changed = step(text, language)
            if changed != text:
                applied.append(name)
                text = changed
    return text, applied


_QUESTION_RU = re.compile(r"^(?:как|что|почему|зачем|когда|где|куда|откуда|кто|чей|сколько|какой|какая|какое|"
                          r"какие|ли|можно ли|можешь|не мог бы|не могла бы|скажи|подскажи|объясни)\b", re.I)
_QUESTION_EN = re.compile(r"^(?:how|what|why|when|where|who|whose|which|can|could|would|will|is|are|do|does|"
                          r"did|should|tell me|explain)\b", re.I)


def is_question(text: str, language: str = "ru") -> bool:
    stripped = text.strip()
    if not stripped:
        return False
    if stripped.endswith("?"):
        return True
    pattern = _QUESTION_EN if language == "en" else _QUESTION_RU
    return bool(pattern.match(stripped)) and len(stripped.split()) <= 25 and "\n" not in stripped


def answered_question(raw: str, polished: str, language: str = "ru") -> bool:
    """Модель ответила на продиктованный вопрос вместо правки: вопрос был, а в итоге вопроса нет
    и текст заметно вырос. Тогда это не причёсывание — откат на исходный текст."""
    if not is_question(raw, language) or "?" in polished:
        return False
    return len(polished.strip()) > len(raw.strip()) * 1.2 + 20
