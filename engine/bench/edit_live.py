"""Живой прогон голосовой правки (D5) через `claude -p` на синтетических выделениях.

Выделения и команды придуманы для стенда, не взяты из данных пользователя. Команды
записаны так, как их выдаёт распознавание: строчными, без пунктуации, с паразитами.
Каждый вызов уходит в облако Anthropic по подписке пользователя, поэтому запуск только вручную:

    python engine/bench/edit_live.py
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mostik_engine import polish as P  # noqa: E402
from mostik_engine import voice_edit as V  # noqa: E402

CASES = [
    ("ru", "сделай списком",
     "На выезд нужно взять палатку, два спальника, газовую горелку и аптечку, а ещё не забыть фонарь."),
    ("ru", "переведи на английский",
     "Привет! Созвон по релизу переносим на четверг, 15:00. Повестка та же."),
    ("ru", "ну короче сделай короче",
     "Хотел бы ещё раз напомнить всем участникам команды о том, что в связи с плановыми работами "
     "на сервере сборки в пятницу вечером, примерно с 19 до 22 часов, ночные сборки будут недоступны, "
     "поэтому, пожалуйста, планируйте свои слияния заранее."),
    ("ru", "сделай более вежливо",
     "Пришли отчёт до завтра. Без него ничего не согласую."),
    ("ru", "исправь ошибки",
     "Мы проанализировали данные и пришли к выводу что конверсия выросла на 12% , а отток наоборот снизился."),
    ("en", "make it a numbered list",
     "Install the package, run the migrations, restart the worker and check the logs."),
    ("ru", "э ммм",
     "Короткий абзац, который не нужно трогать."),
    ("ru", "какая погода в москве",
     "Отчёт за третий квартал готов, лежит в общей папке."),
    ("ru", "сделай заголовок жирным",
     "# План работ\n\n- собрать требования\n- оценить сроки\n"),
]


def main() -> int:
    backend = P.ClaudeCliBackend()
    print(json.dumps(backend.status(), ensure_ascii=False), file=sys.stderr)
    rows = []
    for language, command, selection in CASES:
        started = time.monotonic()
        outcome = V.edit(backend, command, selection, language, timeout=30)
        wall = (time.monotonic() - started) * 1000
        rows.append({"command": command, "understood": outcome.command, "status": outcome.status,
                     "ms": round(wall), "in": selection, "out": outcome.text, "detail": outcome.detail})
        print(json.dumps(rows[-1], ensure_ascii=False), flush=True)
    times = sorted(row["ms"] for row in rows)
    print(json.dumps({"calls": len(rows), "median_ms": times[len(times) // 2], "max_ms": times[-1],
                      "min_ms": times[0]}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
