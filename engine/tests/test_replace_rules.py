"""L3: замены личного словаря — целые слова, длинное побеждает, без цепочек."""
from __future__ import annotations

from mostik_engine.replace_rules import apply_rules, apply_text  # кладёт transcriber в sys.path

from audio_transcription.glossary import GlossaryEntry
from audio_transcription.models import Segment


def rule(canonical: str, *aliases: str, case_sensitive: bool = False) -> GlossaryEntry:
    return GlossaryEntry(canonical=canonical, aliases=tuple(aliases), auto_apply=True, case_sensitive=case_sensitive)


def test_whole_words_only():
    text, fixes = apply_text("клод и клодовый код", [rule("Claude", "клод")])
    assert text == "Claude и клодовый код"
    assert fixes == [("клод", "Claude")]


def test_whole_words_latin_and_digits():
    text, _ = apply_text("gpt4 и gpt40", [rule("GPT-4", "gpt4")])
    assert text == "GPT-4 и gpt40"


def test_longest_rule_wins_even_if_shorter_starts_earlier():
    entries = [rule("Claude", "клод"), rule("Claude Code", "клод код"), rule("X", "код клод")]
    text, fixes = apply_text("пишу код клод код сегодня", entries)
    # «код клод» и «клод код» одной длины — берётся левое; «клод» внутри него не правится.
    assert text == "пишу X код сегодня"
    assert fixes == [("код клод", "X")]


def test_longer_overlapping_beats_shorter():
    entries = [rule("Claude", "клод"), rule("Claude Code", "клод код")]
    assert apply_text("открой клод код", entries)[0] == "открой Claude Code"
    assert apply_text("спроси клод", entries)[0] == "спроси Claude"


def test_output_does_not_feed_another_rule():
    # «а» — обычное слово и само не заменяется, поэтому правило с выдуманным «ыа».
    entries = [rule("бэ", "ыа"), rule("вэ", "бэ")]
    text, fixes = apply_text("ыа бэ", entries)
    assert text == "бэ вэ"
    assert fixes == [("ыа", "бэ"), ("бэ", "вэ")]


def test_case_insensitive_unless_marked():
    assert apply_text("Яндекс трекер", [rule("Yandex Tracker", "яндекс трекер")])[0] == "Yandex Tracker"
    assert apply_text("Яндекс трекер", [rule("Yandex Tracker", "яндекс трекер", case_sensitive=True)])[0] == "Яндекс трекер"


def test_canonical_already_in_place_is_not_a_fix():
    text, fixes = apply_text("MCP и mcp", [rule("MCP", "MCP", "mcp")])
    assert text == "MCP и MCP"
    assert fixes == [("mcp", "MCP")]


def test_not_auto_apply_is_ignored():
    entry = GlossaryEntry(canonical="Claude", aliases=("клод",), auto_apply=False)
    assert apply_text("клод", [entry])[0] == "клод"


def test_segments_and_audit():
    segments, audit = apply_rules([Segment(0.0, 1.0, "клод пишет")], [rule("Claude", "клод")])
    assert segments[0].text == "Claude пишет"
    assert [(c.before, c.after, c.rule) for c in audit] == [("клод", "Claude", "exact_alias")]


def test_common_word_alias_is_not_replaced():
    """«код» — обычное слово: «вайб-код» не становится «вайб-Claude». Фраза из слов — работает."""
    entries = [rule("Claude", "клод", "код"), rule("End", "and"), rule("Claude Code", "клод код")]
    assert apply_text("пишем вайб-код и код ревью", entries) == ("пишем вайб-код и код ревью", [])
    assert apply_text("rock and roll", entries)[0] == "rock and roll"
    assert apply_text("спроси клод код", entries)[0] == "спроси Claude Code"
    assert apply_text("спроси клод", entries)[0] == "спроси Claude"


def test_common_word_case_fix_still_applies():
    assert apply_text("код", [rule("Код", "код", case_sensitive=True)])[0] == "Код"


def test_canonical_tail_already_following_is_absorbed():
    """«Romashka 24» → «Ромашка24», а не «Ромашка24 24»; без хвоста — как раньше."""
    entries = [rule("Ромашка24", "Romashka", "Ромашка", "Ромашки")]
    text, fixes = apply_text("у Romashka 24 и Ромашка-24, а у Ромашки свой", entries)
    assert text == "у Ромашка24 и Ромашка24, а у Ромашка24 свой"
    assert fixes == [("Romashka 24", "Ромашка24"), ("Ромашка-24", "Ромашка24"), ("Ромашки", "Ромашка24")]
    assert apply_text("Ромашка 240 рублей", entries)[0] == "Ромашка24 240 рублей"
    assert apply_text("в Сфера 360", [rule("Сфера 360", "сфера")])[0] == "в Сфера 360"
