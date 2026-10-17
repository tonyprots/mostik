"""Замер детектора вопросов (M19) на синтетике: точность и полнота эвристики.

    python bench/question_bench.py [--set tuning|holdout|all] [--errors]

Судья (локальная модель) здесь не участвует: замер слоя без модели — нижняя
граница. Решение эвристики — балл ≥ ACCEPT, как когда судья недоступен.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from mostik_engine import meeting_questions as mq  # noqa: E402
from question_corpus import HOLDOUT, TUNING  # noqa: E402


def measure(cases):
    tp = fp = fn = tn = 0
    errors = []
    for text, label in cases:
        found = bool(mq.classify(text))
        if found and label:
            tp += 1
        elif found and not label:
            fp += 1
            errors.append(("FP", text, mq.score_sentence(mq.sentences(text)[0]).__dict__))
        elif label:
            fn += 1
            errors.append(("FN", text, mq.score_sentence(mq.sentences(text)[0]).__dict__))
        else:
            tn += 1
    precision = tp / (tp + fp) if tp + fp else 1.0
    recall = tp / (tp + fn) if tp + fn else 1.0
    return {"n": len(cases), "tp": tp, "fp": fp, "fn": fn, "tn": tn,
            "precision": round(precision, 3), "recall": round(recall, 3)}, errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", default="all", choices=["tuning", "holdout", "all"])
    parser.add_argument("--errors", action="store_true")
    args = parser.parse_args()
    sets = {"tuning": TUNING, "holdout": HOLDOUT}
    for name in (["tuning", "holdout"] if args.set == "all" else [args.set]):
        for lang in ("ru", "en"):
            cases = [(t, l) for t, l in sets[name] if (mq.question_language(t) == lang)]
            stats, errors = measure(cases)
            print(f"{name:8} {lang}: {stats}")
            if args.errors:
                for kind, text, info in errors:
                    print(f"   {kind} {text!r} score={info['score']} {info['reasons']}")
        stats, _ = measure(sets[name])
        print(f"{name:8} всё: {stats}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
