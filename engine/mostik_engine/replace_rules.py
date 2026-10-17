"""Замены личного словаря (L3): «что модель пишет вместо» → «как пишется».

Правила:

- только целые слова: «клод» не правится внутри «клодовый»; граница — не буква и не цифра;
- длинное правило побеждает: если совпадения пересекаются, берётся самое длинное
  (при равной длине — левое), так «код клод» → «Claude Code» не сломает «клод» → «Claude»;
- один проход по исходному тексту: вывод правила не питает другое правило, поэтому
  цепочки «a → b, b → c» не бывает, а «c» в тексте после замены не правится повторно;
- регистр не важен, если у записи нет `case_sensitive`;
- место, где уже стоит канон, правкой не считается.

Формат записей — `GlossaryEntry` transcriber: `canonical` и `aliases` (это и есть
колонка «что модель пишет вместо»), автозамена — только у `auto_apply`.
"""
from __future__ import annotations

import re
from typing import Iterable

from . import paths  # noqa: F401 — кладёт transcriber в sys.path

from audio_transcription.glossary import Correction, GlossaryEntry  # noqa: E402
from audio_transcription.models import Segment  # noqa: E402


def _pattern(alias: str) -> str:
    return rf"(?<![\w]){re.escape(alias)}(?![\w])"


def find_matches(text: str, entries: Iterable[GlossaryEntry]) -> list[tuple[int, int, GlossaryEntry, str]]:
    """Непересекающиеся совпадения: длинные первыми, при равной длине — левые."""
    found: list[tuple[int, int, GlossaryEntry, str]] = []
    for entry in entries:
        if not entry.auto_apply:
            continue
        flags = 0 if entry.case_sensitive else re.IGNORECASE
        for alias in entry.aliases:
            alias = str(alias).strip()
            if not alias:
                continue
            for match in re.finditer(_pattern(alias), text, flags=flags):
                found.append((match.start(), match.end(), entry, match.group(0)))
    selected: list[tuple[int, int, GlossaryEntry, str]] = []
    for candidate in sorted(found, key=lambda item: (-(item[1] - item[0]), item[0])):
        if any(candidate[0] < kept[1] and candidate[1] > kept[0] for kept in selected):
            continue
        selected.append(candidate)
    return sorted(selected, key=lambda item: item[0])


def apply_text(text: str, entries: Iterable[GlossaryEntry]) -> tuple[str, list[tuple[str, str]]]:
    """Текст после замен и список пар (было, стало) — в порядке текста."""
    pieces: list[str] = []
    fixes: list[tuple[str, str]] = []
    cursor = 0
    for start, end, entry, before in find_matches(text, entries):
        pieces.append(text[cursor:start])
        if before == entry.canonical:
            pieces.append(before)
        else:
            pieces.append(entry.canonical)
            fixes.append((before, entry.canonical))
        cursor = end
    pieces.append(text[cursor:])
    return "".join(pieces), fixes


def apply_rules(segments: list[Segment], entries: list[GlossaryEntry]) -> tuple[list[Segment], list[Correction]]:
    """То же для сегментов, с журналом правок в формате transcriber."""
    corrected: list[Segment] = []
    audit: list[Correction] = []
    for segment in segments:
        text, fixes = apply_text(segment.text, entries)
        for before, after in fixes:
            audit.append(
                Correction(
                    start=segment.start, end=segment.end, before=before, after=after,
                    canonical=after, rule="exact_alias", automatic=True,
                )
            )
        corrected.append(
            Segment(segment.start, segment.end, text, confidence=segment.confidence, speakers=segment.speakers)
        )
    return corrected, audit
