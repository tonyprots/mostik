"""Срок поручения из речи (W4): «до пятницы» → дата. Детерминированно, без модели.

`parse_due(text, base)` разбирает срок, как он прозвучал (поле `due` задач M7 и
шапки `meeting.md`), относительно дня встречи `base`. Русский и английский.
Не понял — `None`: даты не выдумываем.

Правила (одинаковые для обоих языков):

- «сегодня», «до конца дня», EOD — день встречи; «завтра» — +1, «послезавтра» — +2;
- день недели («до пятницы», «в пятницу», «к пт», by Friday) — ближайший такой
  день ПОСЛЕ дня встречи: сказано в пятницу «до пятницы» — следующая пятница;
- «в следующую пятницу», next Friday — пятница следующей календарной недели
  (неделя с понедельника);
- «к концу недели», «на этой неделе», EOW — пятница этой недели; если встреча
  в субботу или воскресенье — это воскресенье; «на следующей неделе», next week —
  пятница следующей недели;
- «до конца месяца», EOM — последний день месяца; «в следующем месяце» —
  последний день следующего; «до конца квартала» — последний день квартала;
- «через 3 дня / две недели / месяц», in 3 days / two weeks / a month;
- дата: «до 15 ноября», «к 3.11», «15.11.2026», by Nov 15, 15 November,
  2026-11-15, 11/15 (по-английски месяц первым). Без года — ближайшая такая
  дата не раньше дня встречи.
"""
from __future__ import annotations

import calendar
import datetime as _dt
import re
from typing import Any

# --- словари ----------------------------------------------------------------------

_RU_WEEKDAYS = [
    ("понедельник", "пн"), ("вторник", "вт"), ("сред", "ср"), ("четверг", "чт"),
    ("пятниц", "пт"), ("суббот", "сб"), ("воскресень", "вс"),
]
_EN_WEEKDAYS = [
    ("monday", "mon"), ("tuesday", "tue"), ("wednesday", "wed"), ("thursday", "thu"),
    ("friday", "fri"), ("saturday", "sat"), ("sunday", "sun"),
]
_RU_MONTHS = ["январ", "феврал", "март", "апрел", "ма", "июн", "июл", "август", "сентябр", "октябр", "ноябр", "декабр"]
_EN_MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
_NUMBERS = {
    "один": 1, "одну": 1, "одна": 1, "одного": 1, "два": 2, "две": 2, "двух": 2, "пару": 2, "пара": 2,
    "три": 3, "трёх": 3, "трех": 3, "четыре": 4, "четырёх": 4, "четырех": 4, "пять": 5, "пяти": 5,
    "шесть": 6, "семь": 7, "восемь": 8, "девять": 9, "десять": 10, "десяти": 10,
    "a": 1, "an": 1, "one": 1, "two": 2, "couple": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10,
}
_NUMBER = r"(\d{1,3}|" + "|".join(sorted(_NUMBERS, key=len, reverse=True)) + r")"


def _number(word: str) -> int | None:
    word = word.lower()
    if word.isdigit():
        return int(word)
    return _NUMBERS.get(word)


# --- даты -------------------------------------------------------------------------

def _add_months(day: _dt.date, months: int) -> _dt.date:
    month0 = day.month - 1 + months
    year, month = day.year + month0 // 12, month0 % 12 + 1
    return _dt.date(year, month, min(day.day, calendar.monthrange(year, month)[1]))


def _month_end(day: _dt.date) -> _dt.date:
    return day.replace(day=calendar.monthrange(day.year, day.month)[1])


def _week_start(day: _dt.date) -> _dt.date:
    return day - _dt.timedelta(days=day.weekday())


def _next_weekday(base: _dt.date, weekday: int) -> _dt.date:
    """Ближайший `weekday` строго после `base`."""
    delta = (weekday - base.weekday()) % 7
    return base + _dt.timedelta(days=delta or 7)


def _end_of_week(base: _dt.date) -> _dt.date:
    friday = _week_start(base) + _dt.timedelta(days=4)
    return friday if base <= friday else _week_start(base) + _dt.timedelta(days=6)


def _calendar_date(base: _dt.date, day: int, month: int, year: int | None) -> _dt.date | None:
    if year is not None and year < 100:
        year += 2000
    try:
        result = _dt.date(year or base.year, month, day)
    except ValueError:
        return None
    if year is None and result < base:
        try:
            result = _dt.date(base.year + 1, month, day)
        except ValueError:
            return None
    return result


def _weekday_index(word: str, table: list[tuple[str, str]]) -> int | None:
    word = word.lower().rstrip(".")
    for index, (stem, short) in enumerate(table):
        if word.startswith(stem) or word == short:
            return index
    return None


def _ru_month(word: str) -> int | None:
    word = word.lower().rstrip(".")
    if word.startswith("мая") or word == "май":
        return 5
    for index, stem in enumerate(_RU_MONTHS):
        if index == 4:
            continue
        if word.startswith(stem) or (len(word) >= 3 and stem.startswith(word)):
            return index + 1
    return None


def _en_month(word: str) -> int | None:
    word = word.lower().rstrip(".")
    for index, stem in enumerate(_EN_MONTHS):
        if word.startswith(stem):
            return index + 1
    return None


# --- разбор -----------------------------------------------------------------------

_RU_WD = r"(понедельник\w*|вторник\w*|сред\w*|четверг\w*|пятниц\w*|суббот\w*|воскресень\w*|пн|вт|ср|чт|пт|сб|вс)\.?"
_EN_WD = (r"(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|"
          r"sat|sun)\.?")
_RU_MONTH = r"(январ\w*|феврал\w*|март\w*|апрел\w*|ма[йяе]|июн\w*|июл\w*|август\w*|сентябр\w*|октябр\w*|ноябр\w*|декабр\w*)"
_EN_MONTH = r"(jan\w*|feb\w*|mar\w*|apr\w*|may|jun\w*|jul\w*|aug\w*|sep\w*|oct\w*|nov\w*|dec\w*)\.?"
_B = r"(?<![\w])"
_E = r"(?![\w])"


def _result(day: _dt.date, kind: str, phrase: str) -> dict[str, Any]:
    return {"date": day.isoformat(), "kind": kind, "phrase": " ".join(phrase.split())}


def parse_due(text: Any, base: _dt.date | _dt.datetime | str | None = None) -> dict[str, Any] | None:
    """Срок словами → `{date: 'YYYY-MM-DD', kind, phrase}` или None.

    `kind`: `day` (сегодня/завтра), `weekday`, `period` (конец недели/месяца),
    `relative` (через N), `date` (календарная дата).
    """
    if not isinstance(text, str) or not text.strip():
        return None
    if isinstance(base, str):
        try:
            base = _dt.datetime.fromisoformat(base.replace("Z", "+00:00"))
        except ValueError:
            base = None
    if isinstance(base, _dt.datetime):
        base = base.date()
    base = base or _dt.date.today()
    source = " ".join(text.replace("ё", "е").replace("Ё", "Е").split())
    low = source.lower()

    # ISO и числовые даты — раньше слов: «15.11» не должно стать «через 15».
    match = re.search(_B + r"(\d{4})-(\d{2})-(\d{2})" + _E, low)
    if match:
        day = _calendar_date(base, int(match.group(3)), int(match.group(2)), int(match.group(1)))
        if day:
            return _result(day, "date", match.group(0))
    english = not re.search(r"[а-я]", low)
    match = re.search(_B + r"(\d{1,2})[./](\d{1,2})(?:[./](\d{2,4}))?" + _E, low)
    if match:
        first, second = int(match.group(1)), int(match.group(2))
        day_n, month_n = (second, first) if english else (first, second)
        day = _calendar_date(base, day_n, month_n, int(match.group(3)) if match.group(3) else None)
        if day:
            return _result(day, "date", match.group(0))

    # «15 ноября», «15-го ноября», 15 November, Nov 15(th).
    match = re.search(_B + r"(\d{1,2})(?:-?го)?\s+" + _RU_MONTH + r"(?:\s+(\d{4}))?" + _E, low)
    if match and _ru_month(match.group(2)):
        day = _calendar_date(base, int(match.group(1)), _ru_month(match.group(2)) or 0,
                             int(match.group(3)) if match.group(3) else None)
        if day:
            return _result(day, "date", match.group(0))
    match = re.search(_B + r"(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?" + _EN_MONTH + r"(?:,?\s+(\d{4}))?", low)
    if match and _en_month(match.group(2)):
        day = _calendar_date(base, int(match.group(1)), _en_month(match.group(2)) or 0,
                             int(match.group(3)) if match.group(3) else None)
        if day:
            return _result(day, "date", match.group(0))
    match = re.search(_B + _EN_MONTH + r"\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?" + _E, low)
    if match and _en_month(match.group(1)):
        day = _calendar_date(base, int(match.group(2)), _en_month(match.group(1)) or 0,
                             int(match.group(3)) if match.group(3) else None)
        if day:
            return _result(day, "date", match.group(0))

    # Через N дней / недель / месяцев.
    match = re.search(_B + r"через\s+(?:" + _NUMBER + r"\s+)?(дн\w*|день|недел\w*|месяц\w*)" + _E, low)
    if match:
        count = _number(match.group(1)) if match.group(1) else 1
        if count is not None:
            unit = match.group(2)
            if unit.startswith("недел"):
                day = base + _dt.timedelta(weeks=count)
            elif unit.startswith("месяц"):
                day = _add_months(base, count)
            else:
                day = base + _dt.timedelta(days=count)
            return _result(day, "relative", match.group(0))
    match = re.search(_B + r"(?:in|within)\s+(?:" + _NUMBER + r"\s+)?(?:of\s+)?(days?|weeks?|months?)" + _E, low)
    if match:
        count = _number(match.group(1)) if match.group(1) else 1
        if count is not None:
            unit = match.group(2)
            if unit.startswith("week"):
                day = base + _dt.timedelta(weeks=count)
            elif unit.startswith("month"):
                day = _add_months(base, count)
            else:
                day = base + _dt.timedelta(days=count)
            return _result(day, "relative", match.group(0))

    # Конец периода.
    periods: list[tuple[str, Any]] = [
        (r"(?:до|к)\s+конц\w*\s+(?:этого\s+|текущего\s+)?квартал\w*|end of (?:the )?quarter|eoq",
         lambda: _month_end(_dt.date(base.year, ((base.month - 1) // 3) * 3 + 3, 1))),
        (r"(?:до|к)\s+конц\w*\s+следующ\w*\s+месяц\w*|end of next month",
         lambda: _month_end(_add_months(base.replace(day=1), 1))),
        (r"(?:до|к)\s+конц\w*\s+(?:этого\s+|текущего\s+)?месяц\w*|end of (?:the |this )?month|eom",
         lambda: _month_end(base)),
        (r"в\s+следующем\s+месяце|next month", lambda: _month_end(_add_months(base.replace(day=1), 1))),
        (r"(?:до|к)\s+конц\w*\s+следующ\w*\s+недел\w*|end of next week",
         lambda: _end_of_week(_week_start(base) + _dt.timedelta(days=7))),
        (r"на\s+следующей\s+неделе|следующ\w*\s+недел\w*|next week",
         lambda: _week_start(base) + _dt.timedelta(days=11)),
        (r"(?:до|к)\s+конц\w*\s+(?:этой\s+|текущей\s+)?недел\w*|на\s+этой\s+неделе|end of (?:the |this )?week|"
         r"this week|eow", lambda: _end_of_week(base)),
        (r"(?:до|к)\s+конц\w*\s+(?:рабочего\s+)?дня|end of (?:the )?day|eod|сегодня|today|tonight",
         lambda: base),
        (r"послезавтра|day after tomorrow", lambda: base + _dt.timedelta(days=2)),
        (r"завтра|tomorrow", lambda: base + _dt.timedelta(days=1)),
    ]
    for pattern, compute in periods:
        match = re.search(_B + r"(?:" + pattern + r")" + _E, low)
        if match:
            kind = "day" if re.search(r"сегодня|today|tonight|завтра|tomorrow|дня|day", match.group(0)) else "period"
            return _result(compute(), kind, match.group(0))

    # Дни недели: «в следующую пятницу», next Friday, «до пятницы», by Fri.
    match = re.search(_B + r"(?:в|во|на|к|до)?\s*следующ\w*\s+" + _RU_WD + _E, low)
    if match:
        index = _weekday_index(match.group(1), _RU_WEEKDAYS)
        if index is not None:
            return _result(_week_start(base) + _dt.timedelta(days=7 + index), "weekday", match.group(0))
    match = re.search(_B + r"next\s+" + _EN_WD + _E, low)
    if match:
        index = _weekday_index(match.group(1), _EN_WEEKDAYS)
        if index is not None:
            return _result(_week_start(base) + _dt.timedelta(days=7 + index), "weekday", match.group(0))
    match = re.search(_B + r"(?:(?:до|к|ко|в|во|на|по)\s+)?(?:эт\w+\s+)?" + _RU_WD + _E, low)
    if match:
        index = _weekday_index(match.group(1), _RU_WEEKDAYS)
        if index is not None:
            return _result(_next_weekday(base, index), "weekday", match.group(0))
    match = re.search(_B + r"(?:(?:by|on|until|till|before|this)\s+)?" + _EN_WD + _E, low)
    if match:
        index = _weekday_index(match.group(1), _EN_WEEKDAYS)
        if index is not None:
            return _result(_next_weekday(base, index), "weekday", match.group(0))
    return None


def due_date(text: Any, base: Any = None) -> str | None:
    """Только дата ISO или None."""
    parsed = parse_due(text, base)
    return parsed["date"] if parsed else None
