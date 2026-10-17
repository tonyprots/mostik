"""Уверенность меток говорящих (M15): какие реплики отдать человеку на проверку.

Диаризация transcriber (Sortformer или FluidAudio) уверенности по репликам не
отдаёт: в `speakers.json` есть только отрезки `{start, end, speakers}`. Поэтому
уверенность считаем сами — по тому, насколько отрезки диаризации покрывают
реплику и насколько назначенный говорящий опережает ближайшего соперника.

Для реплики длиной `d` секунд:

- `ov_A` — сколько секунд реплики покрыто отрезками назначенных говорящих
  (у реплики «Собеседник 1 + Собеседник 2» — объединение обоих);
- `ov_B` — то же для самого заметного *другого* говорящего;
- `share = min(1, ov_A / d)` — доля окна за назначенным;
- `margin = max(0, (ov_A − ov_B) / (ov_A + ov_B))` — зазор до второго, 0 если
  оба нуля;
- `confidence = 0,5 · share + 0,5 · margin`, округление до сотых.

Реплика целиком под одним голосом — 1,0. Наполовину в тишине без соперника —
0,75. Поровну с другим голосом — около 0,2. Реплика, которую transcriber
приписал «ближайшему» говорящему, потому что диаризация её не покрыла, — 0.
Если на всей дорожке диаризация нашла один голос, путать не с кем — 1,0.

Ниже `REVIEW_BELOW` (0,6) — на проверку: `review: true` и альтернативы —
другие говорящие с долей окна, а если в окне никого нет — соседи по времени.
Дорожка микрофона («Я») не оценивается: это всегда владелец.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable

REVIEW_BELOW = 0.6
MAX_ALTERNATIVES = 3
SEPARATOR = " + "


def load_diarization(output: Path) -> list[dict[str, Any]] | None:
    """Отрезки диаризации из `speakers.json` прогона transcriber; None — диаризации не было."""
    path = Path(output) / "speakers.json"
    if not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    turns = []
    for item in payload.get("turns") or []:
        try:
            start, end = float(item["start"]), float(item["end"])
        except (KeyError, TypeError, ValueError):
            continue
        speakers = [str(s) for s in item.get("speakers") or []]
        if end > start and speakers:
            turns.append({"start": start, "end": end, "speakers": speakers})
    return turns


def _overlap(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def coverage(start: float, end: float, diarization: Iterable[dict[str, Any]]) -> dict[str, float]:
    """Секунды окна `[start, end]` под каждым говорящим диаризации."""
    result: dict[str, float] = {}
    for turn in diarization:
        seconds = _overlap(start, end, turn["start"], turn["end"])
        if seconds <= 0:
            continue
        for speaker in turn["speakers"]:
            result[speaker] = result.get(speaker, 0.0) + seconds
    return result


def _union_overlap(start: float, end: float, diarization: Iterable[dict[str, Any]], speakers: set[str]) -> float:
    """Секунды окна, где говорит хоть кто-то из `speakers` (перекрытия не считаем дважды)."""
    spans = sorted(
        (max(start, turn["start"]), min(end, turn["end"]))
        for turn in diarization
        if speakers.intersection(turn["speakers"]) and _overlap(start, end, turn["start"], turn["end"]) > 0
    )
    total, cursor = 0.0, start
    for left, right in spans:
        left = max(left, cursor)
        if right > left:
            total += right - left
            cursor = right
    return total


def score(start: float, end: float, assigned: set[str], diarization: list[dict[str, Any]]) -> tuple[float, dict[str, float]]:
    """Уверенность по формуле модуля и секунды окна у остальных говорящих."""
    duration = max(end - start, 0.01)
    others = {k: v for k, v in coverage(start, end, diarization).items() if k not in assigned}
    ov_a = _union_overlap(start, end, diarization, assigned)
    ov_b = max(others.values(), default=0.0)
    share = min(1.0, ov_a / duration)
    margin = max(0.0, (ov_a - ov_b) / (ov_a + ov_b)) if ov_a + ov_b > 0 else 0.0
    return round(0.5 * share + 0.5 * margin, 2), others


def _neighbours(start: float, end: float, diarization: list[dict[str, Any]], assigned: set[str]) -> list[str]:
    """Говорящие ближайших отрезков до и после окна — альтернатива, когда в окне никого нет."""
    before = [t for t in diarization if t["end"] <= start]
    after = [t for t in diarization if t["start"] >= end]
    found: list[tuple[float, str]] = []
    if before:
        turn = max(before, key=lambda t: t["end"])
        found += [(start - turn["end"], s) for s in turn["speakers"]]
    if after:
        turn = min(after, key=lambda t: t["start"])
        found += [(turn["start"] - end, s) for s in turn["speakers"]]
    result: list[str] = []
    for _, speaker in sorted(found):
        if speaker not in assigned and speaker not in result:
            result.append(speaker)
    return result


def annotate(
    turns: list[dict[str, Any]],
    diarization: list[dict[str, Any]] | None,
    labels: dict[str, str],
) -> int:
    """Проставить `speaker_confidence`, `review`, `speaker_alternatives` репликам системной дорожки.

    `labels` — `{сырой id диаризации: «Собеседник N»}` из `meeting.speaker_labels`;
    у реплики должна быть исходная метка в `label`. Меняет `turns` на месте и
    возвращает число реплик на проверку. Без диаризации ничего не делает.
    """
    if not diarization:
        return 0
    raw_by_label = {label: raw for raw, label in labels.items()}
    voices = {speaker for turn in diarization for speaker in turn["speakers"]}
    flagged = 0
    for turn in turns:
        if turn.get("source") != "system":
            continue
        label = str(turn.get("label") or turn.get("speaker") or "")
        assigned = {raw_by_label[part] for part in label.split(SEPARATOR) if part in raw_by_label}
        if len(voices) <= 1 and assigned:
            turn["speaker_confidence"] = 1.0
            continue
        if not assigned:
            # Сегмент без метки диаризации: сравнивать не с чем, сразу на проверку.
            confidence, others = 0.0, coverage(turn["start"], turn["end"], diarization)
        else:
            confidence, others = score(turn["start"], turn["end"], assigned, diarization)
        turn["speaker_confidence"] = confidence
        if confidence >= REVIEW_BELOW:
            continue
        flagged += 1
        turn["review"] = True
        duration = max(turn["end"] - turn["start"], 0.01)
        ranked = [raw for raw, _ in sorted(others.items(), key=lambda kv: (-kv[1], kv[0]))]
        if not ranked:
            ranked = _neighbours(turn["start"], turn["end"], diarization, assigned)
        alternatives = []
        for raw in ranked:
            name = labels.get(raw)
            if name and name != label:
                alternatives.append({"label": name, "share": round(min(1.0, others.get(raw, 0.0) / duration), 2)})
            if len(alternatives) == MAX_ALTERNATIVES:
                break
        turn["speaker_alternatives"] = alternatives
    return flagged
