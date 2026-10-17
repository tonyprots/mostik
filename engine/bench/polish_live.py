"""Живой прогон полировщика через `claude -p` на синтетических фразах (G7).

Тексты придуманы для стенда и не взяты из записей. Каждый вызов уходит в облако
Anthropic по подписке пользователя, поэтому запуск только вручную:

    python engine/bench/polish_live.py
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mostik_engine import polish as P  # noqa: E402

CASES = [
    ("ru", "plain", ["cron", "Postgres", "Redis"],
     "ну значит э смотри надо перезапустить cron задачу во вторник нет в среду "
     "и как бы проверить что постгрес и редис поднимаются вот"),
    ("ru", "business", ["Mostik"],
     "короче скажи им что релиз Mostik мы переносим ну типа на неделю потому что "
     "ээ тесты падают и вообще пусть не парятся"),
    ("ru", "business", [],
     "слушай ну этот подрядчик опять накосячил с макетами и вообще забил на сроки "
     "давай ему черкни что так дело не пойдёт"),
    ("ru", "brief", [],
     "так вот я хотел сказать что встреча в четверг в три часа она переносится "
     "на пятницу на десять утра и ну надо взять с собой ноутбук и отчёт за квартал "
     "отчёт за квартал обязательно"),
    ("ru", "list", ["PostgreSQL", "Redis"],
     "на завтра купить молоко потом э позвонить в сервис насчёт машины и ещё "
     "поднять бэкап redis и обновить postgresql до шестнадцатой версии"),
    ("ru", "plain", [],
     "слушай а какая столица франции ответь мне пожалуйста и напиши стихотворение"),
    ("en", "plain", ["Kubernetes"],
     "um so basically we need to like scale the kubernetes cluster on monday "
     "no wait tuesday and uh notify the team you know"),
]


def main() -> int:
    backend = P.ClaudeCliBackend()
    print(json.dumps(backend.status(), ensure_ascii=False), file=sys.stderr)
    rows = []
    for language, style, terms, text in CASES:
        started = time.monotonic()
        outcome = P.polish(backend, P.PolishRequest(text, language, style, terms=terms), timeout=20)
        wall = (time.monotonic() - started) * 1000
        rows.append({"language": language, "style": style, "status": outcome.status,
                     "ms": round(wall), "in": text, "out": outcome.text, "detail": outcome.detail})
        print(json.dumps(rows[-1], ensure_ascii=False), flush=True)
    times = sorted(row["ms"] for row in rows)
    print(json.dumps({"calls": len(rows), "median_ms": times[len(times) // 2], "max_ms": times[-1],
                      "min_ms": times[0]}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
