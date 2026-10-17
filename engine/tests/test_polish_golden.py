"""Эталонные пары P5: набор цел, синтетичен, детерминированная часть проходит без модели."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bench"))

import llm_cases as C  # noqa: E402
import polish_golden as G  # noqa: E402
from mostik_engine import polish as P  # noqa: E402
from mostik_engine import speech_rules as R  # noqa: E402


def test_golden_is_well_formed():
    ids = [case["id"] for case in G.GOLDEN]
    assert len(ids) == len(set(ids)) and len(ids) >= 20
    for case in G.GOLDEN:
        assert set(case["tags"]) <= set(G.TAGS), case["id"]
        assert case["language"] in ("ru", "en") and case["style"] in P.STYLES
        assert case["raw"].strip() and case["expected"].strip()
    assert {tag for case in G.GOLDEN for tag in case["tags"]} == set(G.TAGS)  # каждый тег покрыт


def test_golden_is_synthetic_and_disjoint():
    """С примерами промпта и набором стенда — ни одной общей фразы (иначе набор меряет память промпта)."""
    prompt_inputs = [raw for pairs in (P._EXAMPLES, P._DEV_EXAMPLES, P._TASK_EXAMPLES) for lang in pairs
                     for raw, _ in pairs[lang]]
    prompt_inputs += [raw for pairs in P._TRANSLATE_EXAMPLES.values() for raw, _ in pairs]
    bench = [case["text"] for case in [*C.RU, *C.EN, *C.DEV]]
    for case in G.GOLDEN:
        raw = case["raw"].lower()
        for other in prompt_inputs + bench:
            assert raw != other.lower() and raw[:30] not in other.lower(), (case["id"], other)


def test_golden_deterministic_pairs_pass_without_model():
    checked = 0
    for case in G.GOLDEN:
        if not case.get("deterministic"):
            continue
        text, _ = R.apply(case["raw"], case["language"], case.get("rules"))
        assert text == case["expected"], case["id"]
        low = text.lower()
        assert all(any(alt in low for alt in must.split("|")) for must in case["must"]), case["id"]
        assert not any(bad in low for bad in case["must_not"]), case["id"]
        checked += 1
    assert checked >= 9
