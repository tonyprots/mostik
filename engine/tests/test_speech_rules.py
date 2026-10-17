"""Правила речи (P3) и числа цифрами (V4): детерминированно, до модели. Всё синтетика."""
from __future__ import annotations

import pytest

from mostik_engine import speech_rules as R


# --- «новый абзац» ---------------------------------------------------------------------------

@pytest.mark.parametrize("raw, expected", [
    ("Привет. Новый абзац. Как дела?", "Привет.\n\nКак дела?"),
    ("привет новый абзац, как дела", "привет.\n\nКак дела"),
    ("Список покупок. Новая строка. Хлеб.", "Список покупок.\nХлеб."),
    ("Итоги, с новой строки, сроки сдвигаются", "Итоги.\nСроки сдвигаются"),
    ("Открой новый абзац в документе", "Открой новый абзац в документе"),  # просьба, не команда
    ("Hello. New paragraph. How are you?", "Hello.\n\nHow are you?"),
])
def test_paragraph_commands(raw, expected):
    language = "en" if raw.startswith("Hello") else "ru"
    assert R.apply_commands(raw, language) == expected


# --- «зачеркни» ------------------------------------------------------------------------------

@pytest.mark.parametrize("raw, expected", [
    ("Купи хлеб. Купи молоко. Зачеркни. Купи сыр.", "Купи хлеб. Купи сыр."),
    ("Встреча в пятницу, зачеркни это, встреча в понедельник.", "Встреча в понедельник."),
    ("Зачеркни вторую строку в таблице.", "Зачеркни вторую строку в таблице."),  # просьба агенту
    ("Send it today. Scratch that. Send it tomorrow.", "Send it tomorrow."),
])
def test_scratch(raw, expected):
    language = "en" if "Send" in raw else "ru"
    assert R.apply_scratch(raw, language) == expected


def test_actually_is_not_a_deterministic_rule():
    # После вопроса «нет, на самом деле» — обычная речь: правило не трогает её вовсе.
    text = "Думаешь, это сложно? Нет, на самом деле это просто."
    assert R.apply(text, "ru", dict(R.DEFAULT_RULES, numbers=True))[0] == text


# --- списки ----------------------------------------------------------------------------------

def test_list_from_ordinals():
    raw = "Нужно сделать три вещи. Во-первых, обновить зависимости, во-вторых, прогнать тесты, в-третьих, выложить сборку."
    assert R.apply_lists(raw) == ("Нужно сделать три вещи:\n- Обновить зависимости\n- Прогнать тесты\n"
                                  "- Выложить сборку")


def test_list_keeps_tail_after_last_item():
    raw = "во первых купить хлеб во вторых забрать посылку. Потом созвонимся."
    assert R.apply_lists(raw) == "- Купить хлеб\n- Забрать посылку\n\nПотом созвонимся."


def test_single_ordinal_is_not_a_list():
    raw = "Во-первых, спасибо за встречу."
    assert R.apply_lists(raw) == raw
    assert R.single_item_list("- Купить хлеб") == "Купить хлеб"
    assert R.single_item_list("- раз\n- два") == "- раз\n- два"


def test_english_list_needs_sentence_start():
    raw = "Two things. First, update the docs. Second, ping the team."
    assert R.apply_lists(raw, "en") == "Two things:\n- Update the docs\n- Ping the team"
    prose = "I came first and second place went to them."
    assert R.apply_lists(prose, "en") == prose


# --- числа -----------------------------------------------------------------------------------

@pytest.mark.parametrize("raw, expected", [
    ("пришло двести человек", "пришло 200 человек"),
    ("подарки двумстам участникам", "подарки 200 участникам"),
    ("бюджет две тысячи двадцать пять рублей", "бюджет 2025 рублей"),
    ("около миллиона двухсот тысяч строк", "около 1200000 строк"),
    ("рост три запятая пять процента", "рост 3,5 процента"),
    ("рост три целых пять десятых процента", "рост 3,5 процента"),
    ("ждать полтора часа или три с половиной", "ждать полтора часа или 3,5"),
    ("ставка три запятая ноль пять", "ставка 3,05"),
    ("займёт пять минут", "займёт 5 минут"),
    ("два варианта на выбор", "два варианта на выбор"),  # однозначное без единицы — словами
    ("двадцать пятого марта", "двадцать пятого марта"),  # порядковое — не трогаем
    ("к сорока двум задачам", "к 42 задачам"),
    ("один из нас", "один из нас"),
    ("2 тысячи пользователей", "2000 пользователей"),
    ("номера два три четыре", "номера два три четыре"),  # перечисление цифр не складывается
    ("созвон в двенадцать ноль ноль", "созвон в 12:00"),
    ("начнём в девять сорок пять", "начнём в 9:45"),
    ("в восемь ноль пять", "в 8:05"),
    ("в двенадцать человек", "в 12 человек"),
])
def test_russian_numbers(raw, expected):
    assert R.apply_numbers(raw, "ru") == expected


@pytest.mark.parametrize("raw, expected", [
    ("we need two hundred and fifty seats", "we need 250 seats"),
    ("about twenty-five people", "about 25 people"),
    ("three point five percent", "3.5 percent"),
    ("one of us", "one of us"),
    ("the second time", "the second time"),
])
def test_english_numbers(raw, expected):
    assert R.apply_numbers(raw, "en") == expected


# --- вместе и вопросы ---------------------------------------------------------------------------

def test_apply_reports_rules_and_respects_switches():
    raw = "План такой. Во-первых, двести тестов, во-вторых, релиз. Новый абзац. Вопросы?"
    text, applied = R.apply(raw, "ru", {"commands": True, "lists": True, "numbers": True, "scratch": True})
    assert text == "План такой:\n- 200 тестов\n- Релиз\n\nВопросы?"
    assert applied == ["commands", "lists", "numbers"]
    assert R.apply(raw, "ru", None) == (raw, [])
    assert R.apply(raw, "ru", {"numbers": True})[0] == raw.replace("двести", "200")


def test_parse_rules():
    assert R.parse_rules(None) is None
    assert R.parse_rules(["lists"]) == {"commands": False, "scratch": False, "lists": True, "numbers": False}
    assert R.parse_rules({"numbers": 1}) == {"commands": False, "scratch": False, "lists": False, "numbers": True}
    assert R.parse_rules("всё") is None


def test_answered_question_guard():
    raw = "Как настроить прокси в гите?"
    assert R.answered_question(raw, "Чтобы настроить прокси, выполните git config --global http.proxy адрес.")
    assert not R.answered_question(raw, "Как настроить прокси в Git?")
    assert not R.answered_question("Настрой прокси в гите.", "Настрой прокси в Git, это долго и сложно делать.")
