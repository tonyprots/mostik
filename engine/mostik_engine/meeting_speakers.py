"""Правка говорящих в готовой расшифровке (M14, M15): назвать, подтвердить подсказку, переназначить реплику.

У каждой реплики системной дорожки есть исходная метка диаризации `label`
(«Собеседник 2»), а видимое имя — `speaker`. Имена меток живут в
`transcript.json → speaker_names` (`{метка: имя}`), поэтому переименование
обратимо и не путает реплики-перекрытия «Собеседник 1 + Собеседник 2».
Дорожка микрофона («Я») не переименовывается.

После правки переписываются `transcript.json`, `transcript.md` и `meeting.md`.
Если включена голосовая память и у метки есть вектор встречи, имя пополняет
образцы человека (`voices.VoiceStore.add_sample`, одноимённый — слияние).
"""

from __future__ import annotations

import datetime as _dt
import json
from pathlib import Path
from typing import Any

from . import meeting_folder as folder_contract
from .voices import ME, SEPARATOR, VoiceStore, clean_name, normalize

INTERLOCUTOR = "Собеседник"


class SpeakerEditError(ValueError):
    pass


def transcript_path(folder: Path) -> Path:
    return Path(folder) / "transcript.json"


def load(folder: Path) -> dict[str, Any]:
    path = transcript_path(folder)
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SpeakerEditError(f"нет расшифровки: {path}") from error
    if not isinstance(document, dict) or not isinstance(document.get("turns"), list):
        raise SpeakerEditError("расшифровка без реплик")
    return document


def turn_label(turn: dict[str, Any]) -> str:
    """Исходная метка; у расшифровок до M14 её нет — тогда метка = видимое имя."""
    return str(turn.get("label") or turn.get("speaker") or "")


def display(label: str, names: dict[str, str]) -> str:
    return SEPARATOR.join(names.get(part, part) for part in label.split(SEPARATOR))


def save(folder: Path, document: dict[str, Any]) -> None:
    """transcript.json + transcript.md + meeting.md."""
    from .meeting import participants, render_markdown

    folder = Path(folder)
    document["participants"] = participants(document["turns"])
    folder_contract.write_json_atomic(transcript_path(folder), document)
    try:
        date = _dt.datetime.fromisoformat(str(document.get("date")))
    except ValueError:
        date = folder_contract.folder_date(folder) or _dt.datetime.now()
    markdown = render_markdown(
        document["turns"], date=date.replace(tzinfo=None), duration_seconds=float(document.get("duration_seconds") or 0),
        marks=document.get("marks") or [], title=document.get("title"),
    )
    (folder / "transcript.md").write_text(markdown, encoding="utf-8")
    if folder_contract.read_manifest(folder) is not None:
        folder_contract.write_meeting_md(folder)


def _system_labels(document: dict[str, Any]) -> set[str]:
    labels: set[str] = set()
    for turn in document["turns"]:
        if turn.get("source", "system") == "system" and turn_label(turn) != ME:
            labels.update(turn_label(turn).split(SEPARATOR))
    return labels


def _voices(document: dict[str, Any]) -> dict[str, Any]:
    block = document.get("voices")
    if not isinstance(block, dict):
        block = {}
        document["voices"] = block
    return block


def _labels_in_order(document: dict[str, Any]) -> list[str]:
    order: list[str] = []
    for turn in document["turns"]:
        if turn.get("source", "system") == "system" and turn_label(turn) != ME:
            for part in turn_label(turn).split(SEPARATOR):
                if part not in order:
                    order.append(part)
    return order


def _holder(document: dict[str, Any], name: str, *, besides: str) -> str | None:
    """Метка, которая уже носит это имя (или сама так называется), кроме `besides`."""
    names = document.get("speaker_names") or {}
    key = name.casefold()
    return next((label for label in _labels_in_order(document)
                 if label != besides and names.get(label, label).casefold() == key), None)


def rename(
    folder: Path,
    label: str,
    name: str,
    *,
    remember: bool = False,
    store: VoiceStore | None = None,
) -> dict[str, Any]:
    """Назвать метку: все её реплики получают имя. `remember` — пополнить голосовую память.

    Одно имя — один человек (E2): если имя уже носит другая метка этой встречи, метка
    сливается с ней (`merge_label`), а не заводит второго «Катю» в списке говорящих.
    """
    folder = Path(folder)
    label, name = clean_name(label), clean_name(name)
    if not name:
        raise SpeakerEditError("пустое имя")
    if label == ME or name == ME:
        raise SpeakerEditError("«Я» — дорожка микрофона, её не переименовывают")
    document = load(folder)
    if label not in _system_labels(document):
        raise SpeakerEditError(f"нет говорящего {label!r}")
    store = store or VoiceStore()
    meeting = _meeting_id(folder, document)
    label = _collapsed(document, label, meeting, remember=remember, store=store)
    other = _holder(document, name, besides=label)
    if other is not None:
        merged = _merge_in(document, label, other, name=name, meeting=meeting, remember=remember, store=store)
        save(folder, document)
        return {"label": other, "name": name, "person": merged["person"], "merged_from": label}
    names = dict(document.get("speaker_names") or {})
    old = names.get(label)
    names[label] = name
    document["speaker_names"] = names
    _redisplay(document, label)
    voices = _voices(document)
    voices["suggestions"] = [s for s in voices.get("suggestions") or [] if s.get("label") != label]
    person = None
    if old and old.casefold() != name.casefold():
        # Было другое имя: образец этой встречи был не тому человеку — вернуть его к метке.
        _return_sample(store, meeting, label, old, remember=remember)
    if remember:
        person = _remember(folder, document, label, name, store)
    save(folder, document)
    store.drop_pending(meeting, label)  # решение принято (П10 С8)
    return {"label": label, "name": name, "person": person}


def unname(folder: Path, label: str, *, remember: bool = False, store: VoiceStore | None = None) -> dict[str, Any]:
    """«Убрать имя» (E1): метка снова «Собеседник N». Образец голоса этой встречи снимается
    с человека; при включённой памяти вектор снова ждёт решения, как до имени."""
    folder = Path(folder)
    label = clean_name(label)
    if label == ME:
        raise SpeakerEditError("«Я» — дорожка микрофона, её не переименовывают")
    document = load(folder)
    if label not in _system_labels(document):
        raise SpeakerEditError(f"нет говорящего {label!r}")
    store = store or VoiceStore()
    meeting = _meeting_id(folder, document)
    label = _collapsed(document, label, meeting, remember=remember, store=store)
    names = dict(document.get("speaker_names") or {})
    old = names.pop(label, None)
    if not old:
        raise SpeakerEditError(f"у говорящего {label!r} нет имени")
    document["speaker_names"] = names
    _redisplay(document, label)
    _return_sample(store, meeting, label, old, remember=remember)
    save(folder, document)
    return {"label": label, "name": label, "removed": old}


def _meeting_id(folder: Path, document: dict[str, Any]) -> str:
    return str(document.get("id") or Path(folder).name)


def _collapsed(document: dict[str, Any], label: str, meeting: str, *, remember: bool, store: VoiceStore) -> str:
    """Слить одноимённые метки старой расшифровки; вернуть метку, под которой теперь живёт `label`."""
    before = (document.get("speaker_names") or {}).get(label, label)
    _collapse_duplicates(document, meeting, remember=remember, store=store)
    if label in _system_labels(document):
        return label
    return _holder(document, before, besides="") or label


def _redisplay(document: dict[str, Any], label: str) -> None:
    """Видимое имя всех реплик, где участвует метка (и в перекрытиях)."""
    names = dict(document.get("speaker_names") or {})
    for turn in document["turns"]:
        if turn.get("source", "system") != "system":
            continue
        current = turn_label(turn)
        if label in current.split(SEPARATOR):
            turn.setdefault("label", current)
            turn["speaker"] = display(current, names)


def _return_sample(store: VoiceStore, meeting: str, label: str, name: str, *, remember: bool) -> None:
    """Снять образец встречи с человека `name`; при включённой памяти — вектор обратно в ожидание."""
    sample = store.take_meeting_sample(name, meeting)
    if sample and remember and sample.get("vector"):
        store.put_pending(meeting, str(sample.get("model") or ""), label, sample["vector"],
                          float(sample.get("seconds") or 0))


def _remember(folder: Path, document: dict[str, Any], label: str, name: str, store: VoiceStore) -> dict[str, Any] | None:
    meeting = str(document.get("id") or folder.name)
    pending = store.load_pending(meeting) or {}
    cluster = (pending.get("clusters") or {}).get(label)
    if not cluster:
        return None
    return store.add_sample(name, cluster["vector"], model=str(pending.get("model") or ""),
                            seconds=float(cluster.get("seconds") or 0), meeting=meeting)


def confirm(folder: Path, label: str, *, remember: bool = True, store: VoiceStore | None = None) -> dict[str, Any]:
    """«Это он»: имя из подсказки голосовой памяти + новый образец этому человеку."""
    document = load(folder)
    suggestion = next((s for s in _voices(document).get("suggestions") or [] if s.get("label") == label), None)
    if suggestion is None:
        raise SpeakerEditError(f"нет подсказки для {label!r}")
    return rename(folder, label, suggestion["name"], remember=remember, store=store)


def reject(folder: Path, label: str) -> dict[str, Any]:
    """«Не он»: подсказка убирается и для этой встречи больше не появится."""
    folder = Path(folder)
    document = load(folder)
    voices = _voices(document)
    suggestions = voices.get("suggestions") or []
    dropped = [s for s in suggestions if s.get("label") == label]
    if not dropped:
        raise SpeakerEditError(f"нет подсказки для {label!r}")
    voices["suggestions"] = [s for s in suggestions if s.get("label") != label]
    voices["rejected"] = (voices.get("rejected") or []) + [
        {"label": label, "person_id": s.get("person_id")} for s in dropped
    ]
    folder_contract.write_json_atomic(transcript_path(folder), document)
    VoiceStore().drop_pending(str(document.get("id") or folder.name), label)  # «Не он» — тоже решение (П10 С8)
    return {"label": label}


def _new_label(document: dict[str, Any]) -> str:
    """Свободная метка «Собеседник N» для говорящего, которого диаризация не выделила."""
    taken = _system_labels(document) | set((document.get("speaker_names") or {}).keys())
    number = 1
    while f"{INTERLOCUTOR} {number}" in taken:
        number += 1
    return f"{INTERLOCUTOR} {number}"


def set_turn(folder: Path, turn_id: int, label: str = "", *, name: str | None = None) -> dict[str, Any]:
    """Переназначить одну реплику — после проверки человеком (M15).

    `label` — другая метка встречи (альтернатива или любой говорящий из списка). `name` вместо
    метки — человек по имени: если имя уже носит метка этой встречи, реплика уходит к ней,
    иначе заводится новая метка с этим именем (диаризация не выделила его голос).
    """
    folder = Path(folder)
    label = clean_name(label or "")
    document = load(folder)
    if name is not None and not label:
        name = clean_name(name)
        if not name or name == ME:
            raise SpeakerEditError("пустое имя" if not name else "«Я» — дорожка микрофона")
        label = _holder(document, name, besides="") or ""
        if not label:
            label = _new_label(document)
            document["speaker_names"] = {**(document.get("speaker_names") or {}), label: name}
    elif label == ME or label not in _system_labels(document):
        raise SpeakerEditError(f"нет говорящего {label!r}")
    turns = document["turns"]
    turn = next((t for t in turns if t.get("id") == turn_id), None)
    if turn is None and 0 <= turn_id < len(turns):
        turn = turns[turn_id]
    if turn is None or turn.get("source", "system") != "system":
        raise SpeakerEditError(f"нет реплики {turn_id} системной дорожки")
    turn["label"] = label
    turn["speaker"] = display(label, dict(document.get("speaker_names") or {}))
    turn["speaker_confidence"] = 1.0
    turn["reviewed"] = True
    turn.pop("review", None)
    turn.pop("speaker_alternatives", None)
    save(folder, document)
    return {"turn": turn_id, "label": label, "speaker": turn["speaker"]}


def merge_label(
    folder: Path,
    source: str,
    target: str,
    *,
    remember: bool = False,
    store: VoiceStore | None = None,
) -> dict[str, Any]:
    """Вся метка — другому говорящему (W17, E2): диаризация разрезала одного человека на два голоса.

    Реплики `source` (и её части в перекрытиях «А + Б») получают метку `target`; перекрытие,
    ставшее «Б + Б», схлопывается в одну метку. Имя остаётся у `target`, а если его нет — переходит
    от `source`. Голосовая память — см. `_merge_voices`. «Я» не участвует.
    """
    folder = Path(folder)
    source, target = clean_name(source), clean_name(target)
    if source == target:
        raise SpeakerEditError("та же метка")
    if ME in (source, target):
        raise SpeakerEditError("«Я» — дорожка микрофона, её метку не переназначают")
    document = load(folder)
    labels = _system_labels(document)
    for label in (source, target):
        if label not in labels:
            raise SpeakerEditError(f"нет говорящего {label!r}")
    store = store or VoiceStore()
    meeting = _meeting_id(folder, document)
    source = _collapsed(document, source, meeting, remember=remember, store=store)
    target = _collapsed(document, target, meeting, remember=remember, store=store)
    if source == target:  # одноимённые метки старой расшифровки — уже слиты сворачиванием
        save(folder, document)
        names = document.get("speaker_names") or {}
        return {"source": source, "target": target, "moved": 0, "speaker": display(target, names), "person": None}
    names = document.get("speaker_names") or {}
    name = names.get(target) or names.get(source)
    result = _merge_in(document, source, target, name=name, meeting=meeting, remember=remember, store=store)
    save(folder, document)
    return result


def _merge_in(
    document: dict[str, Any],
    source: str,
    target: str,
    *,
    name: str | None,
    meeting: str,
    remember: bool,
    store: VoiceStore,
) -> dict[str, Any]:
    """Слияние меток в документе (без записи на диск): реплики, имя, подсказки, голосовая память."""
    names = dict(document.get("speaker_names") or {})
    source_name = names.pop(source, None)
    target_name = names.get(target)
    if name:
        names[target] = name
    document["speaker_names"] = names
    moved = 0
    for turn in document["turns"]:
        if turn.get("source", "system") != "system":
            continue
        parts = turn_label(turn).split(SEPARATOR)
        if source not in parts and target not in parts:
            continue
        merged: list[str] = []
        for part in parts:
            part = target if part == source else part
            if part not in merged:
                merged.append(part)
        label = SEPARATOR.join(merged)
        turn["label"] = label
        turn["speaker"] = display(label, names)
        if source in parts:
            moved += 1
            if len(merged) == 1:
                turn.pop("review", None)
                turn.pop("speaker_alternatives", None)
    voices = _voices(document)
    voices["suggestions"] = [s for s in voices.get("suggestions") or []
                             if s.get("label") != source and not (name and s.get("label") == target)]
    person = _merge_voices(store, meeting, source, target, source_name=source_name, target_name=target_name,
                           name=name, remember=remember)
    return {"source": source, "target": target, "moved": moved, "speaker": display(target, names), "person": person}


def _merge_voices(
    store: VoiceStore,
    meeting: str,
    source: str,
    target: str,
    *,
    source_name: str | None,
    target_name: str | None,
    name: str | None,
    remember: bool,
) -> dict[str, Any] | None:
    """Голосовая память при слиянии (E2): отпечатки обеих меток — одному человеку.

    Вектор каждой метки берётся из ожидания (`pending/`) или из образца этой встречи у человека,
    которому метку уже назвали. Вектор слитой метки — среднее, взвешенное по секундам речи.
    - Имя есть и память включена — один образец этой встречи этому человеку (прежний заменяется).
    - Имя есть, памяти нет — векторы этой встречи больше не ждут решения (как у `rename`).
    - Имени нет — общий вектор ждёт решения под меткой `target`.
    Образец, отданный под другим именем (`source` звали иначе), с того человека снимается.
    """
    pending = store.load_pending(meeting) or {}
    clusters = pending.get("clusters") or {}
    parts: list[tuple[list[float], float, str]] = []
    seen: set[int] = set()
    for label, label_name in ((source, source_name), (target, target_name)):
        cluster = clusters.get(label)
        if cluster and cluster.get("vector"):
            parts.append((cluster["vector"], float(cluster.get("seconds") or 0), str(pending.get("model") or "")))
            continue
        sample = store.meeting_sample(label_name, meeting) if label_name else None
        if sample and sample.get("vector") and id(sample) not in seen:
            seen.add(id(sample))
            parts.append((sample["vector"], float(sample.get("seconds") or 0), str(sample.get("model") or "")))
    for old in {source_name, target_name} - {None, name}:
        if old and (not name or old.casefold() != name.casefold()):
            store.take_meeting_sample(old, meeting)
    model = parts[0][2] if parts else ""
    parts = [p for p in parts if p[2] == model]  # векторы разных моделей не смешиваем
    vector, seconds = centroid([(v, s) for v, s, _ in parts]) if parts else (None, 0.0)
    store.drop_pending(meeting, source)
    if name:
        store.drop_pending(meeting, target)
        if remember and vector:
            return store.add_sample(name, vector, model=model, seconds=seconds, meeting=meeting)
        return None
    if vector and remember:
        store.put_pending(meeting, model, target, vector, seconds)
    return None


def centroid(items: list[tuple[list[float], float]]) -> tuple[list[float], float]:
    """Среднее нормированных векторов, взвешенное по секундам (без секунд — поровну)."""
    total = sum(max(0.0, s) for _, s in items)
    dim = len(items[0][0])
    out = [0.0] * dim
    for vector, seconds in items:
        weight = (max(0.0, seconds) / total) if total > 0 else 1.0 / len(items)
        for i, x in enumerate(normalize(vector)[:dim]):
            out[i] += weight * x
    return normalize(out), total


def _collapse_duplicates(document: dict[str, Any], meeting: str, *, remember: bool, store: VoiceStore) -> int:
    """Старые расшифровки: две метки с одним именем — один человек, сливаем в первую."""
    names = document.get("speaker_names") or {}
    first: dict[str, str] = {}
    merges: list[tuple[str, str]] = []
    for label in _labels_in_order(document):
        if label not in names:
            continue
        key = names[label].casefold()
        if key in first:
            merges.append((label, first[key]))
        else:
            first[key] = label
    for source, target in merges:
        _merge_in(document, source, target, name=(document.get("speaker_names") or {}).get(target),
                  meeting=meeting, remember=remember, store=store)
    return len(merges)


def mark_reviewed(folder: Path, turn_id: int) -> dict[str, Any]:
    """«Верно»: метка реплики подтверждена человеком, с проверки снимается."""
    folder = Path(folder)
    document = load(folder)
    turns = document["turns"]
    turn = next((t for t in turns if t.get("id") == turn_id), None)
    if turn is None:
        raise SpeakerEditError(f"нет реплики {turn_id}")
    turn["reviewed"] = True
    turn.pop("review", None)
    folder_contract.write_json_atomic(transcript_path(folder), document)
    return {"turn": turn_id}
