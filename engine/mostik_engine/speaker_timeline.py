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
Необязательные `count` — сколько людей в звонке вместе со мной по счётчику клиента
(десктопный Телемост имён не отдаёт, только число) и `title` — название встречи в окне.
По `count` разговор один на один отличается от группы; имя тогда берётся из календаря
или из названия вида «Антон х Пётр» (см. `count_name`).

Имя ставится на метку, только когда оно явно преобладает в её речи (см. `match`):
ошибиться именем хуже, чем оставить «Собеседник 2». Спорное остаётся меткой — его
можно назвать вручную в окне встречи.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
import re
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
        count = item.get("count")
        count = int(count) if isinstance(count, (int, float)) and not isinstance(count, bool) and count > 0 else None
        title = " ".join(str(item.get("title") or "").split()) or None
        events.append({"at": at, "active": active, "unmuted": unmuted, "self": own, "present": present,
                       "count": count, "title": title, "source": str(item.get("source") or "")})
    events.sort(key=lambda item: item["at"])
    return events


def _own_names(own: Iterable[str], events: list[dict[str, Any]]) -> list[str]:
    """Свои имена: переданные и те, что приложение узнало как своё."""
    return [name for name in [*own, *(name for event in events for name in event["self"])] if _key(name)]


def _is_mine(name: str, mine: list[str]) -> bool:
    """Моё ли имя на плитке: так же написанное или то же лицо в другом написании («Anton Prots»)."""
    return any(_key(name) == _key(me) or same_person(name, me) for me in mine)


def intervals(events: list[dict[str, Any]], *, own: Iterable[str] = (), end: float | None = None) -> list[Interval]:
    """Отрезки, где говорит ровно один человек, не я. Двое разом — неизвестно кто, отрезка нет."""
    mine = _own_names(own, events)
    result: list[Interval] = []
    for index, event in enumerate(events):
        stop = events[index + 1]["at"] if index + 1 < len(events) else min(
            end if end is not None else event["at"] + MAX_TAIL_S, event["at"] + MAX_TAIL_S)
        if stop <= event["at"]:
            continue
        speaking = [name for name in event["active"] if not _is_mine(name, mine)]
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
    mine = _own_names(own, events)
    if not mine:
        return {}
    # Счётчик клиента видел троих и больше — это группа, даже если плиток в окне две.
    if max_count(events) > 2:
        return {}
    others: dict[str, str] = {}
    for event in events:
        for name in event.get("present") or []:
            if not _is_mine(name, mine):
                others.setdefault(_key(name), name)
    if len(others) != 1:
        return {}
    tag = f"{source}:roster" if source else "roster"
    return _single_voice(turns, next(iter(others.values())), tag)


def _single_voice(turns: list[dict[str, Any]], name: str, tag: str) -> dict[str, Naming]:
    """Все метки системной дорожки — одному имени, если голос по сути один (`ROSTER_MINOR_SHARE`)."""
    labels: dict[str, float] = {}
    for turn in turns:
        label = turn.get("label")
        if turn.get("source") != "system" or not label:
            continue
        for part in label.split(" + "):
            labels[part] = labels.get(part, 0.0) + max(0.0, float(turn["end"]) - float(turn["start"]))
    total = sum(labels.values())
    if not labels or total <= 0:
        return {}
    if total - max(labels.values()) > ROSTER_MINOR_SHARE * total:
        return {}
    return {label: Naming(label, name, seconds, seconds / total, tag) for label, seconds in labels.items()}


def max_count(events: list[dict[str, Any]]) -> int:
    """Больше всего людей в звонке по счётчику клиента; счётчика не было — 0."""
    return max((event.get("count") or 0 for event in events), default=0)


def meeting_title(events: list[dict[str, Any]]) -> str | None:
    """Название встречи из окна звонка: последнее, какое было."""
    titles = [event["title"] for event in events if event.get("title")]
    return titles[-1] if titles else None


# Пометки разговора один на один в названии — не имена.
_ONE_ON_ONE = re.compile(r"^\s*(1\s*[xх×:/-]\s*1|one[- ]on[- ]one|1on1)\s*[:|,.-]?\s*", re.IGNORECASE)
# Пара людей: «Антон х Зоя», «Иван и Антон», «Anton <> Maria», «Антон — Пётр».
_PAIR_SPLIT = re.compile(r"\s+[xх×&и]\s+|\s*<>\s*|\s+[-–—]\s+", re.IGNORECASE)
# Части названия: пара и тема («Антон х Фрося / regular»), или пара через косую черту («Антон / Мария»).
_TOPIC_SPLIT = re.compile(r"\s*/\s*|\s*\|\s*")
_STRIP = " :|,.-_"


def _name_like(part: str) -> bool:
    """Одно-три слова с заглавной, только буквы и дефис: «Зоя», «Иван Сидоров»."""
    words = part.split()
    return 1 <= len(words) <= 3 and all(word[:1].isupper() and word.replace("-", "").isalpha() for word in words)


def title_partner(title: str | None, own: Iterable[str]) -> str | None:
    """Собеседник из названия встречи один на один; не уверены — None.

    Понимает «1х1 Антон / Пётр», «Антон х Зоя», «Антон х Фрося / regular» (тема после «/» или «|»),
    «Антон х Зоя: подготовка» (тема после двоеточия), «🍵 1-1 Лёва-Антон». Моё — часть, чьё первое
    слово совпадает с первым словом любого своего имени; собеседник — часть в паре со мной,
    одно-три слова с заглавной. Два кандидата («Антон / Мария / Пётр») — не угадываем.
    """
    if not title:
        return None
    firsts = {_skeleton(name.split()[0]) for name in own if name.split()}
    if not firsts:
        return None

    def mine(part: str) -> bool:
        return bool(part.split()) and _skeleton(part.split()[0]) in firsts

    # Эмодзи и значки в начале, затем пометка «1х1».
    rest = re.sub(r"^[^\w]+", "", title.strip())
    rest = _ONE_ON_ONE.sub("", rest).strip(_STRIP)
    # Пометки в скобках — повтор и формат, не имена: «[weekly]», «(перенос)».
    rest = re.sub(r"\s*[\[(][^\])]*[\])]", " ", rest).strip(_STRIP)
    # Тема после двоеточия: «Антон х Зоя: подготовка к гринлайту».
    head, colon, _ = rest.partition(":")
    if colon and any(mine(part.strip(_STRIP)) for part in _PAIR_SPLIT.split(_TOPIC_SPLIT.split(head)[0])):
        rest = head.strip(_STRIP)
    segments = [segment.strip(_STRIP) for segment in _TOPIC_SPLIT.split(rest)]
    segments = [segment for segment in segments if segment]

    # Пара внутри одной части: «Антон х Гена / Ромашка-толк», «Лёва-Антон».
    paired = []
    for segment in segments:
        parts = [part.strip(_STRIP) for part in _PAIR_SPLIT.split(segment)]
        if len(parts) == 1 and " " not in segment and segment.count("-") == 1:
            parts = segment.split("-")
        parts = [part for part in parts if part]
        if len(parts) == 2 and sum(map(mine, parts)) == 1:
            paired.append(parts[1] if mine(parts[0]) else parts[0])
    if paired:
        return paired[0] if len(paired) == 1 and _name_like(paired[0]) else None

    # Пара через «/» или «|»: «1х1 Антон / Мария». Остальные части — тема, не имена.
    if sum(map(mine, segments)) != 1:
        return None
    others = [segment for segment in segments if not mine(segment) and _name_like(segment)]
    return others[0] if len(others) == 1 else None


def count_name(turns: list[dict[str, Any]], events: list[dict[str, Any]], *, own: Iterable[str] = (),
               attendees: Iterable[str] = (), source: str = "") -> dict[str, Naming]:
    """Один на один по счётчику клиента, когда плиток с именами нет (десктопный Телемост).

    Счётчик всю встречу не больше двух и хоть раз ровно два — значит, собеседник один.
    Имя — единственный участник календаря, кроме меня; нет календаря — собеседник из названия
    встречи (`title_partner`). Метки — по тому же правилу одного голоса, что у состава.
    """
    events = list(events)
    if max_count(events) != 2 or any(len(set(map(_key, event.get("present") or []))) > 2 for event in events):
        return {}
    mine = [*own, *(name for event in events for name in event["self"])]
    others = [name for name in attendees if not any(same_person(name, me) for me in mine)]
    tag_base = f"{source}:count" if source else "count"
    if len(others) == 1:
        return _single_voice(turns, " ".join(others[0].split()), f"{tag_base}+calendar")
    if others:
        return {}
    partner = title_partner(meeting_title(events), mine)
    return _single_voice(turns, partner, f"{tag_base}+title") if partner else {}


_TRANSLIT = str.maketrans({
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i",
    "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
    "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "i", "ь": "",
    "э": "e", "ю": "iu", "я": "ia",
})


def _skeleton(word: str) -> str:
    """Слово без алфавита и написания: «Ярославна», «yaroslavna», «Iaroslavna» → одно и то же."""
    text = word.casefold().translate(_TRANSLIT)
    for old, new in (("kh", "h"), ("ts", "c"), ("ph", "f"), ("y", "i"), ("j", "i"), ("w", "v"), ("x", "ks")):
        text = text.replace(old, new)
    text = re.sub(r"[^a-z]", "", text)
    return re.sub(r"(.)\1+", r"\1", text)


def same_person(a: str, b: str) -> bool:
    """Одно ли лицо: совпало слово от четырёх букв в любом алфавите или логин вошёл в имя.

    «Пётр Иванов» и «Petr Ivanov», «Иванов Пётр», «pivanov» (логин), «Мария» и «Мария Смирнова»;
    но не «Мария Смирнова» и «Мария Иванова». Уменьшительных
    (Ксюша — Ксения) не знает: лучше не узнать, чем узнать чужого.
    """
    left = [_skeleton(word) for word in re.split(r"[\s@._-]+", a) if word]
    right = [_skeleton(word) for word in re.split(r"[\s@._-]+", b) if word]
    left = [word for word in left if len(word) >= 4]
    right = [word for word in right if len(word) >= 4]
    shared = [word for word in left if word in right]
    if shared:
        # Общее имя при разных фамилиях — разные люди: «Мария Смирнова» не «Мария Иванова».
        return not ([word for word in left if word not in right] and [word for word in right if word not in left])
    # Логин одним словом: фамилия с инициалом впереди или имя с фамилией слитно.
    # Остаток логина — инициалы или остальные слова имени, иначе «Александров» был бы «Александром Петровым».
    for logins, words in ((left, right), (right, left)):
        if len(logins) != 1 or len(words) < 2:
            continue
        login = logins[0]
        for word in words:
            if len(word) < 5 or word == login or not (login.startswith(word) or login.endswith(word)):
                continue
            rest = login[len(word):] if login.startswith(word) else login[:-len(word)]
            others = [other for other in words if other != word]
            if rest in {"".join(other[0] for other in others), "".join(others), *others}:
                return True
    return False


@dataclass
class Resolution:
    """Имена меток и отвергнутые кандидаты — для окна встречи («может быть, это …»)."""
    named: dict[str, Naming]
    hints: dict[str, list[str]]


def resolve(folder: Path, turns: list[dict[str, Any]], *, own: Iterable[str] = (),
            duration: float | None = None, attendees: Iterable[str] = ()) -> Resolution:
    """Всё вместе для папки встречи: лента и субтитры → имена меток, сверка с календарём.

    `attendees` — участники встречи из календаря, кроме меня (может быть пусто).
    Пометки «говорит» сильнее состава и счётчика; слабое имя, которого нет в календаре,
    когда календарь есть, уходит в подсказки.
    """
    own = list(own)
    attendees = [" ".join(name.split()) for name in attendees if name and name.strip()]
    from . import speaker_captions  # он сам берёт отсюда пороги — импорт здесь, без цикла

    events = load(folder)
    mine = [*own, *(name for event in events for name in event["self"])]
    captioned = speaker_captions.names_for(folder, turns, own=mine)
    if not events and not captioned:
        return Resolution({}, {})
    hints: dict[str, list[str]] = {}
    source = ",".join(sorted({event["source"] for event in events if event["source"]}))
    named = match(turns, intervals(events, own=own, end=duration), source=source) if events else {}
    # Субтитры называют метку не хуже пометки «говорит»; спорят с ней — оставляем ленту, субтитры в подсказки.
    for label, naming in captioned.items():
        if label not in named:
            named[label] = naming
        elif _key(named[label].name) != _key(naming.name):
            hints.setdefault(label, []).append(naming.name)
    guess = (roster_name(turns, events, own=own, source=source) or count_name(
        turns, events, own=own, attendees=attendees, source=source)) if events else {}
    if guess and attendees:
        if not any(same_person(next(iter(guess.values())).name, person) for person in attendees):
            for label, naming in guess.items():
                hints.setdefault(label, []).append(naming.name)
            guess = {}
    # Догадка дополняет ленту, но не спорит с ней: другое имя по времени — догадку не берём.
    if guess and all(_key(naming.name) == _key(guess[label].name) for label, naming in named.items() if label in guess):
        named = {**guess, **named}
    elif guess:
        for label, naming in guess.items():
            if label not in named:
                hints.setdefault(label, []).append(naming.name)
    return Resolution(named, hints)


def names_for(folder: Path, turns: list[dict[str, Any]], *, own: Iterable[str] = (),
              duration: float | None = None, attendees: Iterable[str] = ()) -> dict[str, Naming]:
    """Имена меток для папки встречи (без подсказок) — см. `resolve`."""
    return resolve(folder, turns, own=own, duration=duration, attendees=attendees).named
