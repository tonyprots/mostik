"""Имена говорящих по времени → метки диаризации («Собеседник N» → «Пётр»).

Источник имён — лента `speaker-timeline.jsonl` в папке встречи. Её пишет приложение,
пока идёт запись: сейчас — наблюдатель Zoom через Accessibility, дальше — другие
источники (кадры окна, расшифровка Телемоста). Строка ленты — снимок «кто говорит»:

    {"at": 12.4, "active": ["Пётр Иванов"], "unmuted": ["Пётр Иванов"], "self": ["Анна"], "source": "zoom"}

`at` — секунды по часам встречи (как у пометок: паузы не идут), снимок действует до
следующей строки. `active` — собеседники с пометкой «говорит». `unmuted` — собеседники
с включённым микрофоном, своя плитка уже убрана приложением: запасной признак, когда
пометки «говорит» нет (Zoom 7.2 в галерее её не пишет). `self` — имена,
которые приложение узнало как своё: их речь идёт по микрофону («Я»). `present` — все
плитки в окне: по составу называется единственный собеседник (см. `roster_name`).

Имя ставится на метку, только когда оно явно преобладает в её речи (см. `match`):
ошибиться именем хуже, чем оставить «Собеседник 2». Спорное остаётся меткой — его
можно назвать вручную в окне встречи.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

TIMELINE_FILE = "speaker-timeline.jsonl"
# Индикатор «говорит» в окне ВКС загорается позже голоса: отрезок имени начинаем раньше.
LEAD_S = 0.6
# Метке нужно столько речи под одним именем, чтобы его поставить.
MIN_SECONDS = 4.0
# Доля речи метки под лучшим именем и перевес над вторым.
MIN_SHARE = 0.5
MIN_LEAD_RATIO = 2.0
# Последний снимок ленты действует не дольше: дальше приложение могло просто перестать писать.
MAX_TAIL_S = 30.0
# Один на один мелкие метки — обрывки того же голоса на стыках реплик
# (короткие куски уходят второй меткой). Вместе не больше этой доли речи — те же имя.
ROSTER_MINOR_SHARE = 0.25


@dataclass(frozen=True)
class Interval:
    start: float
    end: float
    name: str


@dataclass(frozen=True)
class Naming:
    label: str
    name: str
    seconds: float
    share: float
    source: str

    def to_dict(self) -> dict[str, Any]:
        return {"name": self.name, "seconds": round(self.seconds, 1), "share": round(self.share, 2),
                "source": self.source}


def _key(name: str) -> str:
    return " ".join(name.split()).casefold()


def load(folder: Path) -> list[dict[str, Any]]:
    """Снимки ленты по возрастанию времени; битые строки пропускаются, файла нет — пусто."""
    path = Path(folder) / TIMELINE_FILE
    if not path.is_file():
        return []
    events = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            item = json.loads(line)
            at = float(item["at"])
        except (ValueError, TypeError, KeyError):
            continue
        if at < 0:
            continue
        active = [" ".join(str(name).split()) for name in item.get("active") or [] if str(name).strip()]
        own = [" ".join(str(name).split()) for name in item.get("self") or [] if str(name).strip()]
        unmuted = [" ".join(str(name).split()) for name in item.get("unmuted") or [] if str(name).strip()]
        present = [" ".join(str(name).split()) for name in item.get("present") or [] if str(name).strip()]
        events.append({"at": at, "active": active, "unmuted": unmuted, "self": own, "present": present,
                       "source": str(item.get("source") or "")})
    events.sort(key=lambda item: item["at"])
    return events


def intervals(events: list[dict[str, Any]], *, own: Iterable[str] = (), end: float | None = None) -> list[Interval]:
    """Отрезки, где говорит ровно один человек, не я. Двое разом — неизвестно кто, отрезка нет."""
    mine = {_key(name) for name in own}
    for event in events:
        mine.update(_key(name) for name in event["self"])
    result: list[Interval] = []
    for index, event in enumerate(events):
        stop = events[index + 1]["at"] if index + 1 < len(events) else min(
            end if end is not None else event["at"] + MAX_TAIL_S, event["at"] + MAX_TAIL_S)
        if stop <= event["at"]:
            continue
        speaking = [name for name in event["active"] if _key(name) not in mine]
        if event["active"]:
            if len(event["active"]) == 1 and len(speaking) == 1:
                result.append(Interval(max(0.0, event["at"] - LEAD_S), stop, speaking[0]))
            continue
        # Пометки нет — единственный собеседник с открытым микрофоном. Микрофон открывают
        # до первого слова, поэтому без упреждения. Двое с микрофоном — неизвестно кто.
        open_mics = {_key(name): name for name in event.get("unmuted") or []}
        if len(open_mics) == 1:
            result.append(Interval(event["at"], stop, next(iter(open_mics.values()))))
    return result


def _overlap(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def match(turns: list[dict[str, Any]], spans: list[Interval], *, source: str = "") -> dict[str, Naming]:
    """Метка → имя, если одно имя явно преобладает в её речи.

    Берутся реплики системной дорожки с одной меткой (`label`, без « + »). Для метки
    складываются секунды её речи под каждым именем ленты. Имя ставится, если под ним
    не меньше `MIN_SECONDS`, это не меньше `MIN_SHARE` всей речи метки и вдвое
    больше, чем под вторым именем. Одно имя на две метки — допустимо: диаризация
    иногда делит одного человека надвое.
    """
    totals: dict[str, float] = {}
    by_name: dict[str, dict[str, float]] = {}
    shown: dict[str, str] = {}
    for turn in turns:
        label = turn.get("label")
        if turn.get("source") != "system" or not label or " + " in label:
            continue
        start, end = float(turn["start"]), float(turn["end"])
        if end <= start:
            continue
        totals[label] = totals.get(label, 0.0) + (end - start)
        for span in spans:
            seconds = _overlap(start, end, span.start, span.end)
            if seconds > 0:
                key = _key(span.name)
                shown.setdefault(key, " ".join(span.name.split()))
                names = by_name.setdefault(label, {})
                names[key] = names.get(key, 0.0) + seconds
    result: dict[str, Naming] = {}
    for label, names in by_name.items():
        ranked = sorted(names.items(), key=lambda item: item[1], reverse=True)
        best_key, best = ranked[0]
        second = ranked[1][1] if len(ranked) > 1 else 0.0
        share = best / totals[label] if totals.get(label) else 0.0
        if best >= MIN_SECONDS and share >= MIN_SHARE and best >= MIN_LEAD_RATIO * second:
            result[label] = Naming(label, shown[best_key], best, share, source)
    return result


def roster_name(turns: list[dict[str, Any]], events: list[dict[str, Any]], *,
                own: Iterable[str] = (), source: str = "") -> dict[str, Naming]:
    """Один на один: в окне за всю встречу — один человек, кроме меня, и его голос на системной дорожке.

    Запасной путь, когда пометок «говорит» не хватило (Zoom отдаёт состояние микрофона
    с опозданием). Меток может быть несколько: диаризация режет
    короткие куски того же голоса в отдельную метку. Имя получают все, если кроме
    главной метки речи не больше `ROSTER_MINOR_SHARE`; иначе вторая метка — может быть,
    второй человек у того же микрофона, и тогда имени нет никому. Без узнанного своего
    имени не срабатывает: иначе в окне двое и неизвестно, кто из них я.
    """
    mine = {_key(name) for name in own}
    for event in events:
        mine.update(_key(name) for name in event["self"])
    if not mine:
        return {}
    others: dict[str, str] = {}
    for event in events:
        for name in event.get("present") or []:
            if _key(name) not in mine:
                others.setdefault(_key(name), name)
    labels: dict[str, float] = {}
    for turn in turns:
        label = turn.get("label")
        if turn.get("source") != "system" or not label:
            continue
        for part in label.split(" + "):
            labels[part] = labels.get(part, 0.0) + max(0.0, float(turn["end"]) - float(turn["start"]))
    total = sum(labels.values())
    if len(others) != 1 or not labels or total <= 0:
        return {}
    if total - max(labels.values()) > ROSTER_MINOR_SHARE * total:
        return {}
    name = next(iter(others.values()))
    tag = f"{source}:roster" if source else "roster"
    return {label: Naming(label, name, seconds, seconds / total, tag) for label, seconds in labels.items()}


def names_for(folder: Path, turns: list[dict[str, Any]], *, own: Iterable[str] = (),
              duration: float | None = None) -> dict[str, Naming]:
    """Всё вместе для папки встречи: лента → отрезки → имена меток."""
    events = load(folder)
    if not events:
        return {}
    source = ",".join(sorted({event["source"] for event in events if event["source"]}))
    named = match(turns, intervals(events, own=own, end=duration), source=source)
    roster = roster_name(turns, events, own=own, source=source)
    # Состав дополняет ленту, но не спорит с ней: другое имя по времени — состав не трогаем.
    if roster and all(_key(naming.name) == _key(roster[label].name) for label, naming in named.items()):
        return {**roster, **named}
    return named
