"""Обучение на правках (L1): что пользователь исправил во вставленном тексте.

Приложение 60 секунд после вставки перечитывает поле через Accessibility (только
чтение, у паролей не читает) и присылает пару «вставлено → стало» командой
`learn_edit`. Здесь — чистая логика:

1. **Дифф по словам.** Берутся только замены 1–3 слов на 1–3 слова. Если замен
   больше трёх или заменено больше половины слов — это переписывание, а не правка
   распознавания, и из него ничего не учим. Вставки и удаления слов не учим вовсе
   (удалённый блок сомнений, дописанная фраза).
2. **Похоже по звучанию.** `phonetic_similarity` transcriber: латиница читается
   по-русски, так что «клод» и «Claude» близки, а «встреча» и «созвон» — нет.
3. **Смысл не поменялся.** Отсекаются: смена формы слова («Яндексу → Яндексе» —
   одна основа), только заглавная буква в начале, другие числа, отрицание,
   замена обычного слова обычным словом («кот → кит», «тест → текст»). Остаётся
   правка, в которой появился термин или имя: латиница, цифра, заглавная внутри
   слова или слово с заглавной, которого нет в списке обычных слов.

Кандидат копится в `<home>/learning.json`: предложением он становится после двух
повторов за 7 дней (одна диктовка — один повтор). Отклонённое не предлагается
7 дней. Пар в ожидании — не больше 200, старые вытесняются. В словарь пара
попадает только после подтверждения пользователя (`learn_decide`).

Отклонённая подсказка к слову под вопросом (`doubt_reject`, «Отклонить» в истории)
хранится там же, но без срока: эта пара «услышано → вариант» больше не становится
ни сомнением диктовки, ни предложением из правок. Таких пар — не больше 500.
"""
from __future__ import annotations

import json
import os
import re
import tempfile
import threading
import time
from dataclasses import asdict, dataclass
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

from . import paths
from .speech_rules import is_number_word
from .textnorm import stem
from .wordlists import is_natural_word

from audio_transcription.phonetic import phonetic_similarity  # noqa: E402

WINDOW_S = 7 * 86_400
REPEATS = 2
MAX_PAIRS = 200
MAX_SPAN_WORDS = 3
MAX_REPLACEMENTS = 3
MAX_CHANGED_SHARE = 0.5
MIN_SOUND = 0.6
MAX_DOUBT_REJECTS = 500

_WORD = re.compile(r"[0-9A-Za-zА-Яа-яЁё]+(?:[-_.'’+#][0-9A-Za-zА-Яа-яЁё]+)*[+#]*")
_LATIN = re.compile(r"[A-Za-z]")
_DIGIT = re.compile(r"\d")
_NEGATIONS = {"не", "ни", "нет", "not", "no", "never", "don't", "doesn't", "isn't"}


@dataclass(frozen=True)
class EditPair:
    heard: str
    fixed: str


@dataclass(frozen=True)
class Verdict:
    heard: str
    fixed: str
    ok: bool
    reason: str  # "ok" | "case_only" | "inflection" | "number" | "negation" | "sound" | "meaning" | "length"
    sound: float


def words(text: str) -> list[str]:
    return _WORD.findall(text or "")


def _cosmetic(a: str, b: str) -> bool:
    """Одинаковые слова или разница только в первой букве регистра — не правка."""
    return a == b or (a.casefold() == b.casefold() and a[1:] == b[1:])


def _trim(left: list[str], right: list[str]) -> tuple[list[str], list[str]] | None:
    """Длинная сторона замены — правка плюс дописанный или удалённый текст: «клод → Claude!
    И ещё добавь тесты». Ищем у длинной стороны начало или конец в 1–3 слова, который
    звучит как короткая сторона; не нашли — замену не учим."""
    short, long_, flip = (left, right, False) if len(left) <= len(right) else (right, left, True)
    if len(short) > MAX_SPAN_WORDS:
        return None
    best: tuple[float, list[str]] | None = None
    for size in range(1, MAX_SPAN_WORDS + 1):
        for window in (long_[:size], long_[-size:]):
            score = phonetic_similarity(" ".join(short), " ".join(window))
            if best is None or score > best[0]:
                best = (score, window)
    if best is None or best[0] < MIN_SOUND:
        return None
    return (best[1], short) if flip else (short, best[1])


def diff_pairs(inserted: str, edited: str) -> tuple[list[EditPair], str | None]:
    """Замены слов между вставленным и итоговым; второе значение — почему не учим ничего.

    Замена нескольких слов на столько же слов делится на пословные пары, если хоть
    одна из них не проходит фильтры («телеграм Яндексу → Telegram Яндексе»); иначе
    остаётся фразой («клод код → Claude Code»): так «код» сам по себе не учится.
    """
    before, after = words(inserted), words(edited)
    if not before or not after:
        return [], "empty"
    if before == after:
        return [], "unchanged"
    # Сопоставление без регистра: «спроси → Спроси» в начале фразы не рвёт совпадение.
    matcher = SequenceMatcher(None, [w.casefold() for w in before], [w.casefold() for w in after],
                              autojunk=False)
    pairs: list[EditPair] = []
    changed = 0
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            # Совпало без регистра, но регистр внутри слова другой: «github → GitHub».
            pairs.extend(EditPair(a, b) for a, b in zip(before[i1:i2], after[j1:j2]) if not _cosmetic(a, b))
            continue
        if tag != "replace":
            continue
        left, right = before[i1:i2], after[j1:j2]
        if len(left) == len(right):
            singles = [(a, b) for a, b in zip(left, right) if not _cosmetic(a, b)]
            if len(left) > 1 and not all(judge(EditPair(a, b)).ok for a, b in zip(left, right)):
                pairs.extend(EditPair(a, b) for a, b in singles)
                continue
            if not singles:
                continue
        if len(left) > MAX_SPAN_WORDS or len(right) > MAX_SPAN_WORDS:
            trimmed = _trim(left, right)
            changed += len(left)
            if trimmed is None:
                continue
            left, right = trimmed
            changed -= len(left)
        pairs.append(EditPair(" ".join(left), " ".join(right)))
    changed += sum(len(pair.heard.split()) for pair in pairs)
    if len(pairs) > MAX_REPLACEMENTS or changed > max(2, len(before) * MAX_CHANGED_SHARE):
        return [], "rewrite"
    if not pairs:
        return [], "unchanged"
    return pairs, None


def _term_like(word: str) -> bool:
    """Термин или имя: латиница, цифра, заглавная внутри слова, или имя не из обычных слов."""
    if _LATIN.search(word) or _DIGIT.search(word):
        return True
    if any(ch.isupper() for ch in word[1:]):
        return True
    return word[:1].isupper() and not is_natural_word(word)


def _numbers_only(words: list[str]) -> bool:
    """Все слова — число цифрами или словами: «двадцать первого», «21-го»."""
    bare = [word.strip(".,;:!?…") for word in words]
    return bool(bare) and all(_DIGIT.search(word) or is_number_word(word) for word in bare if word)


def judge(pair: EditPair) -> Verdict:
    heard, fixed = pair.heard, pair.fixed
    sound = round(phonetic_similarity(heard, fixed), 3)

    def verdict(ok: bool, reason: str) -> Verdict:
        return Verdict(heard, fixed, ok, reason, sound)

    heard_words, fixed_words = heard.split(), fixed.split()
    if heard.casefold() == fixed.casefold():
        # Только регистр. «яндекс → Яндекс» — начало предложения или имя одной буквой;
        # «github → GitHub» — уже написание термина.
        if heard[1:] == fixed[1:]:
            return verdict(False, "case_only")
        return verdict(True, "ok")
    if {w.casefold() for w in heard_words} & _NEGATIONS != {w.casefold() for w in fixed_words} & _NEGATIONS:
        return verdict(False, "negation")
    if _DIGIT.search(heard) and _DIGIT.search(fixed):
        return verdict(False, "number")
    # «девятнадцать → 19»: как писать число, решает правило «числа цифрами», запоминать нечего.
    if (_DIGIT.search(heard) or _DIGIT.search(fixed)) and (
        _numbers_only(heard_words) or _numbers_only(fixed_words)
    ):
        return verdict(False, "number")
    if len(heard_words) == len(fixed_words) and all(
        stem(a.casefold()) == stem(b.casefold()) for a, b in zip(heard_words, fixed_words)
    ):
        return verdict(False, "inflection")
    ratio = len(fixed.replace(" ", "")) / max(1, len(heard.replace(" ", "")))
    if not 0.4 <= ratio <= 2.5:
        return verdict(False, "length")
    if sound < MIN_SOUND:
        return verdict(False, "sound")
    if not any(_term_like(word) for word in fixed_words):
        return verdict(False, "meaning")
    return verdict(True, "ok")


def candidates(inserted: str, edited: str) -> tuple[list[Verdict], str | None]:
    pairs, skipped = diff_pairs(inserted, edited)
    return [judge(pair) for pair in pairs], skipped


# --- накопитель ----------------------------------------------------------------


def _key(heard: str, canonical: str) -> str:
    return heard.casefold() + "→" + canonical


def _doubt_key(heard: str, suggestion: str) -> str:
    return heard.strip().casefold() + "→" + suggestion.strip().casefold()


class LearningStore:
    """`learning.json`: пары в ожидании и отклонённые; пишется атомарно, права 0600."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or paths.mostik_home() / "learning.json"
        self._lock = threading.Lock()

    def _load(self) -> dict[str, Any]:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        data.setdefault("version", 1)
        data.setdefault("pairs", {})
        data.setdefault("rejected", {})
        data.setdefault("doubt_rejected", {})
        if not isinstance(data["doubt_rejected"], dict):
            data["doubt_rejected"] = {}
        return data

    def _save(self, data: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp = tempfile.mkstemp(prefix=".learning-", suffix=".json", dir=self.path.parent)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=1)
        os.chmod(temp, 0o600)
        os.replace(temp, self.path)

    @staticmethod
    def _prune(data: dict[str, Any], now: float) -> None:
        data["rejected"] = {k: t for k, t in data["rejected"].items() if now - float(t) < WINDOW_S}
        for key in list(data["pairs"]):
            item = data["pairs"][key]
            item["seen"] = [t for t in item.get("seen", []) if now - float(t) < WINDOW_S]
            if not item["seen"]:
                del data["pairs"][key]
        if len(data["pairs"]) > MAX_PAIRS:
            ordered = sorted(data["pairs"], key=lambda k: max(data["pairs"][k]["seen"]))
            for key in ordered[: len(data["pairs"]) - MAX_PAIRS]:
                del data["pairs"][key]

    @staticmethod
    def _ready(data: dict[str, Any]) -> list[dict[str, Any]]:
        found = [
            {"heard": item["heard"], "canonical": item["canonical"], "language": item.get("language"),
             "count": len(item["seen"]), "last": max(item["seen"])}
            for item in data["pairs"].values()
            if len(item["seen"]) >= REPEATS
        ]
        return sorted(found, key=lambda item: -item["last"])

    def observe(self, verdicts: list[Verdict], language: str | None, now: float | None = None,
                known: set[str] | None = None) -> list[dict[str, Any]]:
        """Одна диктовка: годные пары +1 повтор. Возвращает все готовые предложения.

        `known` — ключи `_key(heard, canonical)` того, что уже есть в словаре: их не копим.
        """
        now = time.time() if now is None else now
        with self._lock:
            data = self._load()
            self._prune(data, now)
            seen_now: set[str] = set()
            for verdict in verdicts:
                if not verdict.ok:
                    continue
                key = _key(verdict.heard, verdict.fixed)
                if (key in seen_now or key in data["rejected"] or (known and key in known)
                        or _doubt_key(verdict.heard, verdict.fixed) in data["doubt_rejected"]):
                    continue
                seen_now.add(key)
                item = data["pairs"].setdefault(
                    key, {"heard": verdict.heard, "canonical": verdict.fixed, "language": language, "seen": []})
                item["seen"].append(now)
            self._prune(data, now)
            self._save(data)
            return self._ready(data)

    def suggestions(self, now: float | None = None) -> list[dict[str, Any]]:
        now = time.time() if now is None else now
        with self._lock:
            data = self._load()
            self._prune(data, now)
            return self._ready(data)

    def decide(self, heard: str, canonical: str, accept: bool, now: float | None = None) -> list[dict[str, Any]]:
        """Принято — пара уходит из ожидания (в словарь её кладёт сервер); отклонено — на 7 дней в отказ."""
        now = time.time() if now is None else now
        key = _key(heard, canonical)
        with self._lock:
            data = self._load()
            data["pairs"].pop(key, None)
            if not accept:
                data["rejected"][key] = now
            self._prune(data, now)
            self._save(data)
            return self._ready(data)

    def reject_doubt(self, heard: str, suggestion: str, now: float | None = None) -> None:
        """«Отклонить» у слова под вопросом: пара больше не предлагается — ни сомнением, ни из правок."""
        heard, suggestion = heard.strip(), suggestion.strip()
        if not heard:
            return
        now = time.time() if now is None else now
        with self._lock:
            data = self._load()
            data["pairs"].pop(_key(heard, suggestion), None)
            rejected = data["doubt_rejected"]
            rejected[_doubt_key(heard, suggestion)] = {"heard": heard, "suggestion": suggestion, "at": now}
            if len(rejected) > MAX_DOUBT_REJECTS:
                ordered = sorted(rejected, key=lambda k: float(rejected[k].get("at", 0)))
                for key in ordered[: len(rejected) - MAX_DOUBT_REJECTS]:
                    del rejected[key]
            self._save(data)

    def rejected_doubts(self) -> list[tuple[str, str]]:
        """Отклонённые пары «услышано → вариант» для отбора сомнений."""
        with self._lock:
            data = self._load()
        return [
            (str(item.get("heard", "")), str(item.get("suggestion", "")))
            for item in data["doubt_rejected"].values()
            if isinstance(item, dict)
        ]

    def stats(self) -> dict[str, int]:
        with self._lock:
            data = self._load()
        return {"pending": len(data["pairs"]), "rejected": len(data["rejected"])}


def verdicts_to_dict(verdicts: list[Verdict]) -> list[dict[str, Any]]:
    return [asdict(verdict) for verdict in verdicts]
