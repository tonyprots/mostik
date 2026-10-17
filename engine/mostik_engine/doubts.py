"""Отбор сомнений диктовки: только расхождения на терминах, не больше N.

Цепочка по §12.4: гипотезы основной и проверяющей по окнам →
`find_review_items` → `take_verifier_canonicals` (правки словаря) → отброс
мелких видов → фильтр терминов (§3) → ранжирование → top-N. Очередь проверки
transcriber на диктовках давала десятки мест (61 в среднем) — агенту нужно
пять, и только там, где ошибка меняет смысл: названия, имена, код.
"""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass, replace
from typing import Iterable

from . import paths  # noqa: F401 — кладёт transcriber в sys.path

from audio_transcription import phonetic  # noqa: E402
from audio_transcription.glossary import (  # noqa: E402
    MIN_PHONETIC_LETTERS,
    VERIFIER_CANONICAL_KINDS,
    GlossaryEntry,
    take_verifier_canonicals,
)
from audio_transcription.models import Correction, Hypothesis, ReviewItem, Segment  # noqa: E402
from audio_transcription.reconcile import (  # noqa: E402
    find_review_items,
    normalize_text,
    without_fillers,
)

DEFAULT_LIMIT = 5
TERM_SIMILARITY = 0.8
# Виды, которые не работа для человека (§12.4), плюс «window»: у окна нет
# пары от проверяющей — спорить не с кем, это не сомнение, а опоздание.
EXCLUDED_KINDS = frozenset(
    {"filler", "equivalent", "disfluency", "verifier_artifact", "verifier_canonical", "verifier_latin", "window"}
)
SOURCE_FACTOR = {"project": 3, "personal": 2}
_LATIN_OR_DIGIT = re.compile(r"[A-Za-z0-9]")
_SENTENCE_END = ".!?…"
_MAX_NGRAM = 3
MIN_ALIAS_LETTERS = 3
MAX_SPAN_WORDS = 5


@dataclass(frozen=True)
class Doubt:
    heard: str
    suggestion: str
    context: str
    # Почему место — сомнение: project / personal / latin / proper.
    kind: str
    weight: int
    similarity: float
    start: float
    diff: str

    def to_dict(self) -> dict:
        data = asdict(self)
        data["similarity"] = round(self.similarity, 3)
        data["start"] = round(self.start, 2)
        return data


@dataclass(frozen=True)
class TermHit:
    canonical: str
    source: str
    score: float


def _letters(text: str) -> int:
    return sum(1 for char in text if char.isalpha())


class TermIndex:
    """Термины проекта и личного словаря с заранее посчитанными чтениями.

    Фонетика на 2 000 терминов против каждого спорного слова — сотни тысяч
    расстояний Левенштейна на чистом Python. Поэтому коды считаются один раз,
    а сравниваются только чтения с той же первой буквой и близкой длиной:
    при пороге 0,8 длины не могут расходиться больше чем на пятую часть.
    """

    def __init__(
        self,
        project_terms: Iterable[str] = (),
        personal: Iterable[GlossaryEntry] = (),
    ) -> None:
        self.exact: dict[str, TermHit] = {}
        self._buckets: dict[str, list[tuple[str, str, str, str]]] = {}
        for term in project_terms:
            self._add(term, term, "project")
        for entry in personal:
            for spelling in (entry.canonical, *entry.aliases):
                # Алиас из одной-двух букв («e», «sm») совпадает с чем угодно.
                if spelling != entry.canonical and _letters(spelling) < MIN_ALIAS_LETTERS:
                    continue
                self._add(spelling, entry.canonical, "personal")

    def __len__(self) -> int:
        return len(self.exact)

    def _add(self, spelling: str, canonical: str, source: str) -> None:
        key = normalize_text(spelling)
        if not key:
            return
        current = self.exact.get(key)
        if current is None or SOURCE_FACTOR[source] > SOURCE_FACTOR[current.source]:
            self.exact[key] = TermHit(canonical, source, 1.0)
        if _letters(spelling) < MIN_PHONETIC_LETTERS:
            return
        for code in phonetic.phonetic_codes(spelling):
            self._buckets.setdefault(code[:1], []).append(
                (code, phonetic._skeleton(code), canonical, source)
            )

    def match(self, text: str, threshold: float = TERM_SIMILARITY) -> TermHit | None:
        """Лучший термин для куска текста (n-граммы до трёх слов)."""
        words = [word for word in text.split() if normalize_text(word)]
        best: TermHit | None = None
        for size in range(1, min(_MAX_NGRAM, len(words)) + 1):
            for start in range(len(words) - size + 1):
                piece = " ".join(words[start : start + size])
                hit = self._match_piece(piece, threshold)
                if hit and (
                    best is None
                    or (SOURCE_FACTOR[hit.source], hit.score)
                    > (SOURCE_FACTOR[best.source], best.score)
                ):
                    best = hit
        return best

    def _match_piece(self, piece: str, threshold: float) -> TermHit | None:
        key = normalize_text(piece)
        if key in self.exact:
            return self.exact[key]
        if _letters(piece) < MIN_PHONETIC_LETTERS - 1:
            return None
        best: TermHit | None = None
        for code in phonetic.phonetic_codes(piece):
            skeleton = phonetic._skeleton(code)
            for other, other_skeleton, canonical, source in self._buckets.get(code[:1], ()):
                longest = max(len(code), len(other))
                if abs(len(code) - len(other)) > (1 - threshold) * longest:
                    continue
                score = min(
                    phonetic._ratio(skeleton, other_skeleton), phonetic._ratio(code, other)
                )
                if score >= threshold and (
                    best is None
                    or (SOURCE_FACTOR[source], score) > (SOURCE_FACTOR[best.source], best.score)
                ):
                    best = TermHit(canonical, source, score)
        return best


def _proper_noun(item: ReviewItem) -> bool:
    """Проверяющая написала имя собственное, а основная — нет.

    Заглавная в начале предложения не считается: позиция берётся по контексту
    проверяющей (слова до расхождения взяты из текста основной, с её точками).
    """

    def capitals(span: str, context: str) -> list[str]:
        found: list[str] = []
        at = context.find(span) if span else -1
        for index, word in enumerate(span.split()):
            letters = word.lstrip("«\"'(")
            if not letters or not letters[0].isupper():
                continue
            if index == 0:
                before = context[:at].rstrip() if at >= 0 else ""
                before = before.removeprefix("…").strip()
                if not before or before[-1] in _SENTENCE_END:
                    continue
            elif span.split()[index - 1][-1:] in _SENTENCE_END:
                continue
            found.append(letters)
        return found

    verifier = capitals(item.verifier_span, item.comparison_text)
    if not verifier:
        return False
    primary = {normalize_text(word) for word in capitals(item.primary_span, item.readable_text)}
    return any(normalize_text(word) not in primary for word in verifier)


def _writes_canonical(span: str, canonical: str) -> bool:
    """Фрагмент уже содержит канон словом целиком («Астра.» → Астра)."""
    words = normalize_text(span).split()
    target = normalize_text(canonical).split()
    size = len(target)
    return bool(size) and any(words[i : i + size] == target for i in range(len(words) - size + 1))


def _same_time(left: str, right: str) -> bool:
    """«8:00» и «8» — одно и то же время, спорить не о чем."""
    def strip(text: str) -> str:
        return normalize_text(re.sub(r"(?<=\d)[:.,]00\b", "", text)).replace(" ", "")

    return bool(strip(left)) and strip(left) == strip(right)


def classify(item: ReviewItem, terms: TermIndex) -> tuple[str, TermHit | None] | None:
    """Вид сомнения или None, если расхождение не на термине."""
    if item.kind in EXCLUDED_KINDS:
        return None
    primary_hit = verifier_hit = None
    if len(terms):
        primary_hit = terms.match(item.primary_span)
        verifier_hit = terms.match(item.verifier_span)
    hits = [found for found in (primary_hit, verifier_hit) if found is not None]
    if hits:
        hit = max(hits, key=lambda found: (SOURCE_FACTOR[found.source], found.score))
        # Основная уже написала канон, а у проверяющей ни термина, ни латиницы:
        # права основная («Астра» против «острое»), спрашивать нечего.
        if (
            (verifier_hit is None or verifier_hit.canonical == hit.canonical)
            and _writes_canonical(item.primary_span, hit.canonical)
            and not _LATIN_OR_DIGIT.search(item.verifier_span)
        ):
            return None
        return hit.source, hit
    longest = max(len(item.primary_span.split()), len(item.verifier_span.split()))
    if longest > MAX_SPAN_WORDS:
        # Длинный фрагмент без термина — срыв одной из моделей (Whisper
        # дописывает фразу в паузу), а не спорное название.
        return None
    if not without_fillers(normalize_text(item.primary_span)) and longest > 2:
        return None
    if _same_time(item.primary_span, item.verifier_span):
        return None
    if _LATIN_OR_DIGIT.search(item.primary_span) or _LATIN_OR_DIGIT.search(item.verifier_span):
        return "latin", None
    if _proper_noun(item):
        return "proper", None
    return None


def rejected_keys(pairs: Iterable[tuple[str, str]]) -> frozenset[tuple[str, str]]:
    """Отклонённые пользователем пары «услышано → вариант» в виде ключей отбора."""
    return frozenset((normalize_text(heard), normalize_text(suggestion)) for heard, suggestion in pairs)


def select_doubts(
    items: Iterable[ReviewItem],
    terms: TermIndex,
    limit: int = DEFAULT_LIMIT,
    rejected: frozenset[tuple[str, str]] = frozenset(),
) -> tuple[list[Doubt], int]:
    """Фильтр терминов, ранжирование, обрезка. Возвращает (top-N, всего кандидатов).

    `rejected` — ключи `rejected_keys`: пары, которые пользователь отклонил, не предлагаются.
    """
    ranked: list[tuple[tuple, Doubt]] = []
    seen: set[tuple[str, str]] = set()
    for item in items:
        verdict = classify(item, terms)
        if verdict is None:
            continue
        kind, hit = verdict
        # Канон словаря — только если основная написала не его: иначе спорить
        # не о чем, а предлагать стоит написание проверяющей.
        suggestion = item.verifier_span.strip()
        if hit is not None and normalize_text(hit.canonical) != normalize_text(item.primary_span):
            suggestion = hit.canonical
        if not suggestion or normalize_text(suggestion) == normalize_text(item.primary_span):
            continue
        key = (normalize_text(item.primary_span), normalize_text(suggestion))
        if key in seen or key in rejected:
            continue
        seen.add(key)
        doubt = Doubt(
            heard=item.primary_span.strip(),
            suggestion=suggestion,
            context=item.readable_text,
            kind=kind,
            weight=item.weight,
            similarity=item.similarity,
            start=item.start,
            diff=item.kind,
        )
        factor = SOURCE_FACTOR.get(kind, 1)
        ranked.append(((-factor, -item.weight, item.similarity, item.start), doubt))
    ranked.sort(key=lambda pair: pair[0])
    return [doubt for _, doubt in ranked[: max(0, limit)]], len(ranked)


_CYRILLIC = re.compile(r"[А-Яа-яЁё]")
_LATIN_LETTER = re.compile(r"[A-Za-z]")
# Насколько фраза проверяющей может быть длиннее: «Hookan Musis Miting» — «Who can use this meeting».
LATIN_EXTRA_WORDS = 2


def _english_only(span: str) -> bool:
    return bool(_LATIN_LETTER.search(span)) and not _CYRILLIC.search(span)


def take_verifier_latin(
    segments: list[Segment], items: list[ReviewItem], terms: TermIndex
) -> tuple[list[Segment], list[ReviewItem], list[Correction]]:
    """Английское «на слух» у русской основной заменяется английским проверяющей.

    GigaAM пишет английскую речь латиницей по звуку: «Fixed by glossary» → «Fix by Glocy».
    Whisper многоязычный и слышит такие фразы как английские. Текст проверяющей вообще
    не подставляется (на eval40 это удвоило ошибку), но здесь узкий случай: обе стороны —
    одна латиница без кириллицы, фрагмент короткий, и основная не написала термин словаря.
    Решение автора. Закрытое место уходит из сомнений с видом `verifier_latin`.
    """
    texts = [segment.text for segment in segments]
    taken: list[Correction] = []
    kept: list[ReviewItem] = []
    for item in items:
        heard, written = item.primary_span.strip(), item.verifier_span.strip()
        words, other = len(heard.split()), len(written.split())
        index = None
        if (
            item.kind in VERIFIER_CANONICAL_KINDS
            and _english_only(heard) and _english_only(written)
            and words <= MAX_SPAN_WORDS and 0 < other <= words + LATIN_EXTRA_WORDS
            and normalize_text(heard) != normalize_text(written)
            and (not len(terms) or terms.match(heard) is None)
        ):
            pattern = rf"(?<!\w){re.escape(heard)}(?!\w)"
            index = next((i for i, segment in enumerate(segments)
                          if segment.start <= item.start < segment.end and re.search(pattern, texts[i])), None)
        if index is None:
            kept.append(item)
            continue
        texts[index] = re.sub(pattern, lambda _: written, texts[index], count=1)
        taken.append(Correction(start=segments[index].start, end=segments[index].end, before=heard,
                                after=written, canonical=written, rule="verifier_latin", automatic=True))
        kept.append(replace(item, kind="verifier_latin"))
    corrected = [segment if text == segment.text else replace(segment, text=text)
                 for segment, text in zip(segments, texts)]
    return corrected, kept, taken


@dataclass
class Analysis:
    segments: list[Segment]
    doubts: list[Doubt]
    corrections: list[Correction]
    candidates: int
    review_items: int


def analyze(
    primary: list[Segment],
    verifier: list[Segment] | None,
    *,
    language: str,
    project_terms: Iterable[str] = (),
    personal: list[GlossaryEntry] | None = None,
    limit: int = DEFAULT_LIMIT,
    terms: TermIndex | None = None,
    rejected: frozenset[tuple[str, str]] = frozenset(),
) -> Analysis:
    """Пары окон основная/проверяющая → исправленные сегменты, сомнения, правки."""
    personal = personal or []
    if verifier is None or not primary:
        return Analysis(list(primary), [], [], 0, 0)
    readable = Hypothesis("primary", language, 0.0, list(primary))
    lexical = Hypothesis("verifier", language, 0.0, list(verifier))
    items = find_review_items(readable, lexical, comparison_label="Whisper")
    corrected, items, taken = take_verifier_canonicals(list(primary), items, personal)
    index = terms if terms is not None else TermIndex(project_terms, personal)
    if language == "ru":
        corrected, items, latin = take_verifier_latin(corrected, items, index)
        taken = [*taken, *latin]
    doubts, candidates = select_doubts(items, index, limit, rejected)
    return Analysis(corrected, doubts, taken, candidates, len(items))
