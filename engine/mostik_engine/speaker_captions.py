"""Имена говорящих по субтитрам ВКС → метки диаризации.

Лента `speaker-captions.jsonl` в папке встречи — реплики субтитров с именем, которые
приложение прочитало в окне звонка (Zoom, Meet, Teams, Slack), если пользователь сам
включил субтитры:

    {"at": 12.4, "end": 15.0, "name": "Пётр Иванов", "text": "добрый день", "source": "zoom"}

`at` — когда реплика появилась, `end` — когда последний раз менялась, по часам встречи.
Субтитры запаздывают за голосом на секунду-две и режут речь по-своему, поэтому реплику
сводим с репликой расшифровки по словам: где слова совпали, там и говорящий. Нет общих
слов (другой язык субтитров, шум) — по одному времени, с меньшим весом.

Имя ставится по тем же порогам, что и по ленте окна (`speaker_timeline.match`): ошибиться
хуже, чем оставить «Собеседник 2».
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Iterable

from .speaker_timeline import MIN_LEAD_RATIO, MIN_SECONDS, MIN_SHARE, Naming, _key

CAPTIONS_FILE = "speaker-captions.jsonl"
# Субтитры появляются позже голоса: реплику ищем в окне до стольких секунд раньше и позже.
WINDOW_BEFORE_S = 5.0
WINDOW_AFTER_S = 3.0
# Слова короче не в счёт: «и», «да», «то» есть в любой реплике.
MIN_WORD = 3
# Реплика расшифровки «та же», если с ней общих слов не меньше этого и не меньше доли слов субтитра.
MIN_SHARED_WORDS = 2
MIN_SHARED_SHARE = 0.3
# Вес совпадения только по времени, без слов.
TIME_ONLY_WEIGHT = 0.3

_WORD = re.compile(r"[\w-]+", re.UNICODE)


def _words(text: str) -> set[str]:
    return {word.replace("ё", "е") for word in _WORD.findall(text.casefold()) if len(word) >= MIN_WORD}


def load(folder: Path) -> list[dict[str, Any]]:
    """Реплики субтитров по времени; битые строки пропускаются, файла нет — пусто."""
    path = Path(folder) / CAPTIONS_FILE
    if not path.is_file():
        return []
    result = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            item = json.loads(line)
            at = float(item["at"])
            end = float(item.get("end", at))
        except (ValueError, TypeError, KeyError):
            continue
        name = " ".join(str(item.get("name") or "").split())
        text = " ".join(str(item.get("text") or "").split())
        if at < 0 or not name or not text:
            continue
        result.append({"at": at, "end": max(at, end), "name": name, "text": text,
                       "source": str(item.get("source") or "")})
    result.sort(key=lambda item: item["at"])
    return result


def match(turns: list[dict[str, Any]], captions: list[dict[str, Any]], *,
          own: Iterable[str] = ()) -> dict[str, Naming]:
    """Метка → имя по субтитрам.

    Каждую реплику субтитров отдаём одной реплике системной дорожки рядом по времени:
    той, с которой больше общих слов. Её секунды идут имени у её метки. Слов не нашлось —
    всем репликам рядом по их пересечению со временем субтитра, с весом `TIME_ONLY_WEIGHT`.
    Свои имена пропускаем: моя речь — на микрофоне, на системной дорожке её быть не должно.
    """
    mine = {_key(name) for name in own}
    system = [turn for turn in turns
              if turn.get("source") == "system" and turn.get("label") and " + " not in turn["label"]
              and float(turn["end"]) > float(turn["start"])]
    totals: dict[str, float] = {}
    for turn in system:
        totals[turn["label"]] = totals.get(turn["label"], 0.0) + float(turn["end"]) - float(turn["start"])
    # Секунды реплики расшифровки за именем — не больше, чем она длится: несколько строк субтитров
    # на одну длинную реплику её не умножают.
    credit: dict[tuple[str, int], float] = {}
    shown: dict[str, str] = {}
    sources: set[str] = set()
    for caption in captions:
        key = _key(caption["name"])
        if key in mine:
            continue
        lo, hi = caption["at"] - WINDOW_BEFORE_S, caption["end"] + WINDOW_AFTER_S
        near = [turn for turn in system if float(turn["start"]) < hi and float(turn["end"]) > lo]
        if not near:
            continue
        said = _words(caption["text"])
        best, best_shared = None, 0
        for turn in near:
            shared = len(said & _words(str(turn.get("text") or "")))
            if shared > best_shared:
                best, best_shared = turn, shared
        weights: list[tuple[dict[str, Any], float]]
        if best is not None and best_shared >= MIN_SHARED_WORDS and best_shared >= MIN_SHARED_SHARE * len(said):
            weights = [(best, float(best["end"]) - float(best["start"]))]
        else:
            weights = []
            for turn in near:
                overlap = min(float(turn["end"]), caption["end"]) - max(float(turn["start"]), caption["at"])
                if overlap > 0:
                    weights.append((turn, overlap * TIME_ONLY_WEIGHT))
        for turn, seconds in weights:
            index = id(turn)
            length = float(turn["end"]) - float(turn["start"])
            credit[(key, index)] = min(length, credit.get((key, index), 0.0) + seconds)
            shown.setdefault(key, caption["name"])
            if caption["source"]:
                sources.add(caption["source"])
    by_label: dict[str, dict[str, float]] = {}
    labels = {id(turn): turn["label"] for turn in system}
    for (key, index), seconds in credit.items():
        names = by_label.setdefault(labels[index], {})
        names[key] = names.get(key, 0.0) + seconds
    tag = "captions:" + ",".join(sorted(sources)) if sources else "captions"
    result: dict[str, Naming] = {}
    for label, names in by_label.items():
        ranked = sorted(names.items(), key=lambda item: item[1], reverse=True)
        best_key, best_seconds = ranked[0]
        second = ranked[1][1] if len(ranked) > 1 else 0.0
        share = best_seconds / totals[label] if totals.get(label) else 0.0
        if best_seconds >= MIN_SECONDS and share >= MIN_SHARE and best_seconds >= MIN_LEAD_RATIO * second:
            result[label] = Naming(label, shown[best_key], best_seconds, min(1.0, share), tag)
    return result


def names_for(folder: Path, turns: list[dict[str, Any]], *, own: Iterable[str] = ()) -> dict[str, Naming]:
    """Всё вместе для папки встречи: субтитры → имена меток."""
    captions = load(folder)
    return match(turns, captions, own=own) if captions else {}
