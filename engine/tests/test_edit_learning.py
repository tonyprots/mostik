"""L1: дифф правки, два фильтра (звучание и смысл), накопление и отказ."""
from __future__ import annotations

from mostik_engine.edit_learning import (
    MAX_PAIRS, WINDOW_S, EditPair, LearningStore, candidates, diff_pairs, judge,
)


def ok(heard: str, fixed: str) -> bool:
    return judge(EditPair(heard, fixed)).ok


def reason(heard: str, fixed: str) -> str:
    return judge(EditPair(heard, fixed)).reason


def test_diff_finds_local_replacements():
    pairs, skipped = diff_pairs("открой клод код и проверь гигам", "открой Claude Code и проверь GigaAM")
    assert skipped is None
    assert pairs == [EditPair("клод код", "Claude Code"), EditPair("гигам", "GigaAM")]


def test_diff_ignores_punctuation_and_appended_text():
    pairs, _ = diff_pairs("спроси клод.", "Спроси Claude! И ещё добавь тесты.")
    assert EditPair("клод", "Claude") in pairs


def test_case_inside_word_is_kept():
    pairs, _ = diff_pairs("залей на github", "Залей на GitHub")
    assert pairs == [EditPair("github", "GitHub")]


def test_rewrite_is_not_learned():
    pairs, skipped = diff_pairs("сделай отчёт по задаче до вечера", "напиши письмо Маше завтра утром срочно")
    assert pairs == [] and skipped == "rewrite"
    pairs, skipped = diff_pairs("раз два три четыре пять", "раз два три четыре пять")
    assert skipped == "unchanged"


def test_sound_filter_cyrillic_and_latin_with_transliteration():
    assert ok("клод", "Claude")
    assert ok("гигам", "GigaAM")
    assert ok("кубернетис", "Kubernetes")
    assert ok("пайтон", "Python")
    assert reason("встреча", "Созвон") == "sound"


def test_case_change_of_russian_word_is_not_a_rule():
    assert reason("Яндексу", "Яндексе") == "inflection"
    assert reason("встречи", "встрече") == "inflection"
    assert reason("meetings", "meeting") == "inflection"


def test_meaning_filter():
    assert reason("кот", "кит") == "meaning"  # обычное слово на обычное
    assert reason("тест", "текст") == "meaning"
    assert reason("5", "6") == "number"
    assert reason("не работает", "работает") in {"negation", "sound"}
    assert reason("яндекс", "Яндекс") == "case_only"
    assert ok("github", "GitHub")
    assert ok("мостик", "Mostik")


def test_candidates_end_to_end():
    verdicts, skipped = candidates("Скинь в телеграм Яндексу", "Скинь в Telegram Яндексе")
    assert skipped is None
    assert [(v.heard, v.fixed, v.ok) for v in verdicts] == [
        ("телеграм", "Telegram", True), ("Яндексу", "Яндексе", False)]


def test_store_two_repeats_within_7_days(mostik_home):
    store = LearningStore()
    verdict = judge(EditPair("клод", "Claude"))
    assert store.observe([verdict], "ru", now=1000.0) == []
    # Та же диктовка дважды — один повтор.
    assert store.observe([verdict, verdict], "ru", now=1000.0 + 10) != []
    store2 = LearningStore()
    assert store2.suggestions(now=1000.0 + 20)[0]["canonical"] == "Claude"
    assert store2.path.stat().st_mode & 0o777 == 0o600


def test_store_repeats_expire_after_7_days(mostik_home):
    store = LearningStore()
    verdict = judge(EditPair("клод", "Claude"))
    store.observe([verdict], "ru", now=0.0)
    assert store.observe([verdict], "ru", now=WINDOW_S + 1) == []


def test_rejected_is_not_suggested_for_7_days(mostik_home):
    store = LearningStore()
    verdict = judge(EditPair("клод", "Claude"))
    store.observe([verdict], "ru", now=0.0)
    store.observe([verdict], "ru", now=1.0)
    assert store.decide("клод", "Claude", accept=False, now=2.0) == []
    store.observe([verdict], "ru", now=3.0)
    assert store.observe([verdict], "ru", now=4.0) == []
    # Через 7 дней отказ истёк — снова копится.
    store.observe([verdict], "ru", now=WINDOW_S + 10)
    assert store.observe([verdict], "ru", now=WINDOW_S + 11)[0]["heard"] == "клод"


def test_known_pairs_and_bad_verdicts_are_not_stored(mostik_home):
    store = LearningStore()
    good = judge(EditPair("клод", "Claude"))
    bad = judge(EditPair("кот", "кит"))
    store.observe([good, bad], "ru", now=0.0, known={"клод→Claude"})
    assert store.stats() == {"pending": 0, "rejected": 0}


def test_store_keeps_at_most_200_pairs(mostik_home):
    store = LearningStore()
    for i in range(MAX_PAIRS + 15):
        tail_ru = "абвгдклмнп"[i % 10] + "абвгдклмнп"[i // 10 % 10] + "абвгдклмнп"[i // 100]
        tail_en = "abvgdklmnp"[i % 10] + "abvgdklmnp"[i // 10 % 10] + "abvgdklmnp"[i // 100]
        verdict = judge(EditPair("гигам" + tail_ru, "GigaAM" + tail_en))
        assert verdict.ok, verdict
        store.observe([verdict], "ru", now=float(i))
    assert store.stats()["pending"] == MAX_PAIRS


def test_accept_removes_pending(mostik_home):
    store = LearningStore()
    verdict = judge(EditPair("клод", "Claude"))
    store.observe([verdict], "ru", now=0.0)
    store.observe([verdict], "ru", now=1.0)
    assert store.decide("клод", "Claude", accept=True, now=2.0) == []
    assert store.stats() == {"pending": 0, "rejected": 0}


def test_rejected_doubt_is_never_learned_from_edits(mostik_home):
    """C5: «Отклонить» у слова под вопросом — та же пара не копится из правок и без срока."""
    store = LearningStore()
    verdict = judge(EditPair("клод", "Claude"))
    store.observe([verdict], "ru", now=0.0)
    store.reject_doubt("Клод", "claude", now=1.0)
    assert store.suggestions(now=2.0) == []
    store.observe([verdict], "ru", now=WINDOW_S * 5)
    assert store.observe([verdict], "ru", now=WINDOW_S * 5 + 1) == []
    assert LearningStore().rejected_doubts() == [("Клод", "claude")]
    store.reject_doubt("  ", "x")
    assert len(store.rejected_doubts()) == 1
