"""Срок поручения из речи (W4): детерминированный разбор русских и английских сроков."""
from __future__ import annotations

import datetime as dt

import pytest

from mostik_engine.due_dates import due_date, parse_due

# Среда, 14 октября 2026.
WED = dt.date(2026, 10, 14)
FRI = dt.date(2026, 10, 16)
SAT = dt.date(2026, 10, 17)


@pytest.mark.parametrize("text, expected", [
    ("сегодня", "2026-10-14"),
    ("до конца дня", "2026-10-14"),
    ("завтра", "2026-10-15"),
    ("послезавтра", "2026-10-16"),
    ("до пятницы", "2026-10-16"),
    ("к пятнице", "2026-10-16"),
    ("в пятницу", "2026-10-16"),
    ("к пт", "2026-10-16"),
    ("до понедельника", "2026-10-19"),
    ("в среду", "2026-10-21"),  # сказано в среду — следующая среда
    ("в следующую пятницу", "2026-10-23"),
    ("к следующему вторнику", "2026-10-20"),
    ("до конца недели", "2026-10-16"),
    ("на этой неделе", "2026-10-16"),
    ("на следующей неделе", "2026-10-23"),
    ("до конца следующей недели", "2026-10-23"),
    ("до конца месяца", "2026-10-31"),
    ("в следующем месяце", "2026-11-30"),
    ("до конца квартала", "2026-12-31"),
    ("через 3 дня", "2026-10-17"),
    ("через два дня", "2026-10-16"),
    ("через неделю", "2026-10-21"),
    ("через две недели", "2026-10-28"),
    ("через месяц", "2026-11-14"),
    ("до 15 ноября", "2026-11-15"),
    ("к 3-го марта", "2027-03-03"),  # март уже прошёл — следующий год
    ("до 1 мая 2027", "2027-05-01"),
    ("к 20.10", "2026-10-20"),
    ("до 05.01.2027", "2027-01-05"),
    ("Срок — до пятницы, крайний", "2026-10-16"),
])
def test_russian(text, expected):
    assert due_date(text, WED) == expected


@pytest.mark.parametrize("text, expected", [
    ("today", "2026-10-14"),
    ("EOD", "2026-10-14"),
    ("tomorrow", "2026-10-15"),
    ("day after tomorrow", "2026-10-16"),
    ("by Friday", "2026-10-16"),
    ("on Mon", "2026-10-19"),
    ("next Friday", "2026-10-23"),
    ("end of the week", "2026-10-16"),
    ("next week", "2026-10-23"),
    ("end of month", "2026-10-31"),
    ("in 3 days", "2026-10-17"),
    ("in two weeks", "2026-10-28"),
    ("in a month", "2026-11-14"),
    ("by Nov 15", "2026-11-15"),
    ("by 15 November", "2026-11-15"),
    ("2026-11-15", "2026-11-15"),
    ("by 11/20", "2026-11-20"),  # по-английски месяц первым
])
def test_english(text, expected):
    assert due_date(text, WED) == expected


def test_same_weekday_means_next_week():
    assert due_date("до пятницы", FRI) == "2026-10-23"
    assert due_date("by Friday", FRI) == "2026-10-23"


def test_end_of_week_on_weekend_is_sunday():
    assert due_date("до конца недели", SAT) == "2026-10-18"


@pytest.mark.parametrize("text", ["", None, "как можно скорее", "ASAP", "потом", "когда будет время", "срочно",
                                  "сроки обсудим", "все"])
def test_unknown_is_none(text):
    assert parse_due(text, WED) is None


def test_kind_and_phrase():
    parsed = parse_due("Сделаю до  пятницы", WED)
    assert parsed == {"date": "2026-10-16", "kind": "weekday", "phrase": "до пятницы"}
    assert parse_due("через 2 недели", WED)["kind"] == "relative"
    assert parse_due("до 15 ноября", WED)["kind"] == "date"
    assert parse_due("до конца месяца", WED)["kind"] == "period"


def test_base_from_iso_string():
    assert due_date("завтра", "2026-10-14T15:30:00+03:00") == "2026-10-15"


def test_invalid_calendar_date_is_none():
    assert parse_due("до 31.02", WED) is None
