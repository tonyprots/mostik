"""Отбор сомнений на синтетических парах основная/проверяющая."""
from __future__ import annotations

from mostik_engine.doubts import DEFAULT_LIMIT, TermIndex, analyze, rejected_keys, select_doubts

from audio_transcription.glossary import GlossaryEntry
from audio_transcription.models import ReviewItem, Segment


def seg(text: str, start: float = 0.0, end: float = 5.0) -> Segment:
    return Segment(start, end, text)


def run(primary: list[str], verifier: list[str], **kwargs):
    p = [seg(text, i * 5.0, i * 5.0 + 5.0) for i, text in enumerate(primary)]
    v = [seg(text, i * 5.0, i * 5.0 + 5.0) for i, text in enumerate(verifier)]
    return analyze(p, v, language="ru", **kwargs)


def test_latin_on_verifier_side_is_doubt():
    result = run(["Мы используем пара кит для английского."], ["Мы используем Parakeet для английского."])
    assert len(result.doubts) == 1
    doubt = result.doubts[0]
    assert doubt.kind == "latin"
    assert doubt.suggestion == "Parakeet"
    assert "пара кит" in doubt.heard


def test_plain_word_disagreement_is_not_doubt():
    result = run(["Вчера мы купили дом у реки."], ["Вчера мы купили том у реки."])
    assert result.doubts == []
    assert result.review_items >= 1


def test_fillers_and_numbers_are_not_doubts():
    result = run(["Ну это стоит двадцать пять рублей."], ["Это стоит 25 рублей."])
    assert result.doubts == []


def test_project_term_ranks_first_and_gives_canonical():
    primary = ["Сервис запускает лонч ди, а потом пишет в Redis лог."]
    verifier = ["Сервис запускает launch dee, а потом пишет в Redis log."]
    result = run(primary, verifier, project_terms=["launchd"])
    assert result.doubts, "ожидалось сомнение на термине проекта"
    first = result.doubts[0]
    assert first.kind == "project"
    assert first.suggestion == "launchd"


def test_personal_alias_gives_canonical_suggestion():
    notion = GlossaryEntry("Notion", ("ноушн",), auto_apply=False)
    result = run(["Открой наушн и найди страницу."], ["Открой Nation и найди страницу."], personal=[notion])
    assert [d.kind for d in result.doubts] == ["personal"]
    assert result.doubts[0].suggestion == "Notion"


def test_verifier_canonical_becomes_correction_not_doubt():
    claude = GlossaryEntry("Claude", ("клод",), auto_apply=True)
    result = run(["Спроси клот про это."], ["Спроси Claude про это."], personal=[claude])
    assert [(c.before, c.after) for c in result.corrections] == [("клот", "Claude")]
    assert "Claude" in result.segments[0].text
    assert result.doubts == []


def test_primary_already_wrote_canonical_is_not_doubt():
    astra = GlossaryEntry("Астра", ("астра",), auto_apply=True)
    result = run(["Мы ставим Астра на сервер."], ["Мы ставим острое на сервер."], personal=[astra])
    assert result.doubts == []


def test_proper_noun_only_from_verifier():
    result = run(["Мы были в бразилии летом."], ["Мы были в Бразилии летом."])
    # Регистр не расхождение: нормализация сводит их, спорить не о чем.
    assert result.doubts == []
    result = run(["Мы ходили к маше вечером."], ["Мы ходили к Саше вечером."])
    assert [d.kind for d in result.doubts] == ["proper"]


def test_capital_at_sentence_start_is_not_proper_noun():
    result = run(["Дом стоит у реки."], ["Том стоит у реки."])
    assert result.doubts == []


def test_long_verifier_hallucination_is_dropped():
    result = run(["Э-э."], ["у нас есть activity у нас есть классы у нас есть дел по горло"])
    assert result.doubts == []


def test_same_time_written_differently():
    result = run(["Встреча в 8:00 утра."], ["Встреча в 8 утра."])
    assert result.doubts == []


def test_limit_and_ranking_by_weight():
    primary = [f"Подключи сервис номер {name} сегодня." for name in ("альфа", "бета", "гамма", "дельта", "эпсилон", "зета", "эта")]
    verifier = [f"Подключи сервис номер {name} сегодня." for name in ("Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta")]
    result = run(primary, verifier)
    assert len(result.doubts) == DEFAULT_LIMIT
    assert result.candidates == 7
    limited = run(primary, verifier, limit=2)
    assert len(limited.doubts) == 2


def test_no_verifier_means_no_doubts():
    result = analyze([seg("Привет, мир.")], None, language="ru")
    assert result.doubts == [] and result.corrections == []
    assert result.segments[0].text == "Привет, мир."


def test_term_index_phonetic_and_exact():
    index = TermIndex(["Parakeet", "launchd", "VAD"], [GlossaryEntry("Obsidian", ("обсидиан",))])
    assert index.match("пара кит").canonical == "Parakeet"
    assert index.match("vad").canonical == "VAD"
    hit = index.match("обсидиан")
    assert hit.canonical == "Obsidian" and hit.source == "personal"
    assert index.match("корова") is None


def test_select_doubts_dedupes_and_skips_empty_suggestion():
    item = ReviewItem(
        start=0.0, end=1.0, readable_text="про Python тут", comparison_text="про ∅ тут",
        similarity=0.0, differing_tokens=(), reason="", weight=1, kind="substantive",
        primary_span="Python", verifier_span="",
    )
    doubts, total = select_doubts([item, item], TermIndex())
    assert doubts == [] and total == 0
    twin = ReviewItem(
        start=0.0, end=1.0, readable_text="про пайтон тут", comparison_text="про Python тут",
        similarity=0.2, differing_tokens=(), reason="", weight=1, kind="substantive",
        primary_span="пайтон", verifier_span="Python",
    )
    doubts, total = select_doubts([twin, twin], TermIndex())
    assert len(doubts) == 1 and total == 1
    assert doubts[0].to_dict()["heard"] == "пайтон"


def test_select_doubts_skips_rejected_pairs():
    """C5: отклонённая пара «услышано → вариант» больше не становится сомнением, другие — да."""
    twin = ReviewItem(
        start=0.0, end=1.0, readable_text="про пайтон тут", comparison_text="про Python тут",
        similarity=0.2, differing_tokens=(), reason="", weight=1, kind="substantive",
        primary_span="пайтон", verifier_span="Python",
    )
    assert len(select_doubts([twin], TermIndex())[0]) == 1
    rejected = rejected_keys([("Пайтон", "python")])
    assert select_doubts([twin], TermIndex(), rejected=rejected) == ([], 0)
    other = rejected_keys([("пайтон", "Pyton")])
    assert len(select_doubts([twin], TermIndex(), rejected=other)[0]) == 1


def test_english_by_ear_takes_verifier_english():
    result = run(["Тут написано Push the Bataun, это можно убрать."],
                 ["Тут написано Pushed the button, это можно убрать."])
    assert "Pushed the button" in result.segments[0].text
    assert "Bataun" not in result.segments[0].text
    assert result.corrections and {c.rule for c in result.corrections} == {"verifier_latin"}
    assert result.doubts == []


def test_cyrillic_verifier_does_not_replace_latin():
    result = run(["Открой Zoom и подключись."], ["Открой зум и подключись."])
    assert "Zoom" in result.segments[0].text
    assert not [c for c in result.corrections if c.rule == "verifier_latin"]


def test_latin_glossary_term_on_primary_side_stays():
    result = run(["Обнови parakeet_tdt в движке."], ["Обнови parakeet tet в движке."],
                 project_terms=["parakeet_tdt"])
    assert "parakeet_tdt" in result.segments[0].text


def test_english_replacement_only_for_russian():
    p = [seg("Push the Bataun here.")]
    v = [seg("Pushed the button here.")]
    result = analyze(p, v, language="en")
    assert "Bataun" in result.segments[0].text
