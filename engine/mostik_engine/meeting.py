"""Расшифровка записанной встречи: две дорожки → один транскрипт с говорящими.

Дорожка микрофона (`mic.wav`) — это «Я», она идёт без диаризации. Дорожка
системы (`system.wav`) — все собеседники, она идёт с диаризацией. Оба прогона
делает CLI transcriber (`transcribe.py --mode max`), строго последовательно и
с пониженным приоритетом (архитектура §4, §5, §12.12). Затем сегменты
сливаются по времени в `transcript.md` и `transcript.json`.

Чистые функции (эхо, слияние, имена, разметка) отделены от запуска процессов и
покрыты модульными тестами в `engine/tests/test_meeting.py`.
"""

from __future__ import annotations

import contextlib
import datetime as _dt
import difflib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path
from typing import Any, Callable, Iterable

from . import isolation
from . import meeting_folder as folder_contract
from . import privacy
from . import speaker_confidence
from . import speaker_timeline


ME = "Я"
INTERLOCUTOR = "Собеседник"
# Каналы — не люди (M2): эти слова как говорящий в выводе не появляются.
CHANNEL_WORDS = frozenset({"микрофон", "система", "системный звук", "mic", "microphone", "system"})
MARK_PREFIX = "> 📌"
ECHO_SIMILARITY = 0.6
# Порог тишины: RMS ниже -50 dBFS по всей дорожке — значит, дорожку не прогоняем.
SILENCE_DBFS = -50.0
# Сколько секунд между репликами одного говорящего ещё считаем одной репликой.
MERGE_GAP_SECONDS = 2.0

Emit = Callable[[dict[str, Any]], None]


# --------------------------------------------------------------------------
# Чистые функции
# --------------------------------------------------------------------------


def normalize_text(text: str) -> str:
    """Нижний регистр, без пунктуации, ё → е, схлопнутые пробелы."""
    lowered = text.lower().replace("ё", "е")
    cleaned = re.sub(r"[^\w\s]", " ", lowered)
    return " ".join(cleaned.split())


def text_similarity(left: str, right: str) -> float:
    """Похожесть текстов 0..1 по словам (SequenceMatcher на токенах).

    Эхо в микрофоне часто ловит только часть фразы собеседника, поэтому
    кроме общего отношения учитываем и покрытие более короткой стороны.
    """
    a = normalize_text(left).split()
    b = normalize_text(right).split()
    if not a or not b:
        return 0.0
    matcher = difflib.SequenceMatcher(None, a, b, autojunk=False)
    ratio = matcher.ratio()
    matched = sum(block.size for block in matcher.get_matching_blocks())
    shorter = min(len(a), len(b))
    # Покрытие короткой стороны учитываем, только если она не из одного-двух
    # слов: «да» в микрофоне не должно считаться эхом любой фразы с «да».
    coverage = matched / shorter if shorter >= 3 else 0.0
    return max(ratio, coverage)


def overlaps(a_start: float, a_end: float, b_start: float, b_end: float) -> bool:
    return min(a_end, b_end) > max(a_start, b_start)


def drop_echo(
    mic: list[dict[str, Any]],
    system: list[dict[str, Any]],
    threshold: float = ECHO_SIMILARITY,
) -> tuple[list[dict[str, Any]], int]:
    """Выбросить сегменты микрофона, которые повторяют системную дорожку.

    Сегмент считается эхом, если он пересекается по времени с сегментом
    системы (или с несколькими подряд) и текст похож с порогом ≥ threshold.
    Возвращает (оставшиеся, сколько выброшено).
    """
    kept: list[dict[str, Any]] = []
    dropped = 0
    for segment in mic:
        overlapping = [
            item
            for item in system
            if overlaps(segment["start"], segment["end"], item["start"], item["end"])
        ]
        if overlapping:
            joined = " ".join(item["text"] for item in overlapping)
            best = max(
                [text_similarity(segment["text"], joined)]
                + [text_similarity(segment["text"], item["text"]) for item in overlapping]
            )
            if best >= threshold:
                dropped += 1
                continue
        kept.append(segment)
    return kept, dropped


def speaker_labels(system: Iterable[dict[str, Any]]) -> dict[str, str]:
    """Метки диаризации → «Собеседник N» в порядке первого появления.

    `speaker_3`, заговоривший первым, станет «Собеседник 1»: номер модели
    случаен, а порядок появления читателю понятен.
    """
    labels: dict[str, str] = {}
    for segment in sorted(system, key=lambda item: item["start"]):
        for raw in segment.get("speakers") or ["speaker_?"]:
            if raw not in labels:
                labels[raw] = f"Собеседник {len(labels) + 1}"
    return labels


def label_system_segment(segment: dict[str, Any], labels: dict[str, str]) -> str:
    speakers = segment.get("speakers") or []
    if not speakers:
        # Диаризации не было или сегмент без метки: один общий собеседник.
        return labels.get("speaker_?", "Собеседник 1")
    if len(speakers) == 1:
        return labels[speakers[0]]
    return " + ".join(labels[item] for item in speakers)


def merge_tracks(
    mic: list[dict[str, Any]],
    system: list[dict[str, Any]],
    gap: float = MERGE_GAP_SECONDS,
) -> list[dict[str, Any]]:
    """Слить дорожки по времени начала; подряд идущие реплики одного говорящего склеить.

    Каждый вход — сегменты `{start, end, text, speakers?}` из `segments.json`.
    Выход — реплики `{speaker, source, start, end, text}`.
    """
    labels = speaker_labels(system)
    items: list[dict[str, Any]] = []
    for segment in mic:
        items.append(
            {
                "speaker": ME,
                "source": "mic",
                "start": float(segment["start"]),
                "end": float(segment["end"]),
                "text": segment["text"].strip(),
            }
        )
    for segment in system:
        items.append(
            {
                "speaker": label_system_segment(segment, labels),
                "source": "system",
                "start": float(segment["start"]),
                "end": float(segment["end"]),
                "text": segment["text"].strip(),
            }
        )
    # При равном начале микрофон первым: стабильный порядок для тестов.
    items.sort(key=lambda item: (item["start"], item["source"] != "mic", item["end"]))
    merged: list[dict[str, Any]] = []
    for item in items:
        if not item["text"]:
            continue
        last = merged[-1] if merged else None
        if last and last["speaker"] == item["speaker"] and item["start"] - last["end"] <= gap:
            last["text"] = f"{last['text']} {item['text']}"
            last["end"] = max(last["end"], item["end"])
            continue
        merged.append(dict(item))
    return merged


def format_clock(seconds: float) -> str:
    """mm:ss, а после часа — h:mm:ss."""
    total = max(0, int(seconds))
    hours, rest = divmod(total, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def participants(turns: list[dict[str, Any]]) -> list[str]:
    """Участники в порядке первого появления; одиночные метки, без перекрытий."""
    seen: list[str] = []
    for turn in turns:
        for name in turn["speaker"].split(" + "):
            if name not in seen:
                seen.append(name)
    return seen


def normalize_marks(raw: Any) -> list[dict[str, Any]]:
    """Метки M1 `[{at, text}]` → проверенные, по времени; пустые и битые выбрасываются."""
    marks: list[dict[str, Any]] = []
    for item in raw or []:
        if not isinstance(item, dict):
            continue
        text = " ".join(str(item.get("text") or "").split())
        try:
            at = max(0.0, float(item.get("at")))
        except (TypeError, ValueError):
            continue
        if text:
            marks.append({"at": round(at, 2), "text": text})
    marks.sort(key=lambda mark: mark["at"])
    return marks


def normalize_attendees(raw: Any) -> list[dict[str, Any]]:
    """Участники из календаря: строка-имя или `{name, self}`; `self` — владелец календаря."""
    result: list[dict[str, Any]] = []
    for item in raw or []:
        if isinstance(item, dict):
            name = " ".join(str(item.get("name") or "").split())
            is_self = bool(item.get("self") or item.get("is_self") or item.get("isCurrentUser"))
        else:
            name, is_self = " ".join(str(item or "").split()), False
        if name and not any(existing["name"] == name for existing in result):
            result.append({"name": name, "self": is_self})
    return result


def is_channel_word(name: str) -> bool:
    return name.strip().casefold() in CHANNEL_WORDS


def calendar_name(system: list[dict[str, Any]], attendees: list[dict[str, Any]], owner: str | None = None) -> str | None:
    """Имя для единственного собеседника — только из календаря и только без двусмысленности (M2).

    Подставляем, если на системной дорожке ровно один голос, а участник
    встречи, кроме владельца календаря, тоже ровно один. Имена из текста
    речи не берём никогда.
    """
    if not system or len(speaker_labels(system)) != 1:
        return None
    others = [
        item["name"]
        for item in attendees
        if not item["self"] and (not owner or item["name"].casefold() != owner.casefold())
    ]
    if len(others) != 1 or is_channel_word(others[0]) or others[0] == ME:
        return None
    return others[0]


def apply_speaker_names(turns: list[dict[str, Any]], names: dict[str, str]) -> list[dict[str, Any]]:
    """Подменить метки «Собеседник N» именами; канальные слова в говорящих не пропускать."""
    result = []
    for turn in turns:
        speaker = " + ".join(names.get(part, part) for part in turn["speaker"].split(" + "))
        if is_channel_word(speaker):
            speaker = ME if turn.get("source") == "mic" else f"{INTERLOCUTOR} 1"
        result.append({**turn, "speaker": speaker})
    return result


def render_markdown(
    turns: list[dict[str, Any]],
    *,
    date: _dt.datetime,
    duration_seconds: float,
    marks: list[dict[str, Any]] | None = None,
    title: str | None = None,
) -> str:
    people = participants(turns)
    header = [f"# {title}", "", f"- Дата: {date.strftime('%Y-%m-%d %H:%M')}"] if title else [
        f"# Встреча {date.strftime('%Y-%m-%d %H:%M')}",
        "",
    ]
    lines = [
        *header,
        f"- Длительность: {format_clock(duration_seconds)}",
        f"- Участники: {', '.join(people) if people else 'нет речи'}",
        "",
    ]
    pending = list(marks or [])

    def flush(until: float | None) -> None:
        # Метка встаёт перед первой репликой, которая начинается не раньше неё.
        while pending and (until is None or pending[0]["at"] <= until):
            mark = pending.pop(0)
            lines.append(f"{MARK_PREFIX} {format_clock(mark['at'])} — {mark['text']}")
            lines.append("")

    for turn in turns:
        flush(turn["start"])
        lines.append(f"**{turn['speaker']}** [{format_clock(turn['start'])}] {turn['text']}")
        lines.append("")
    flush(None)
    return "\n".join(lines).rstrip() + "\n"


def parse_progress_line(line: str) -> dict[str, Any] | None:
    """Строка stderr transcriber → {stage, done?, total?} или None для пустой.

    Формат строк: `[HH:MM:SS] текст`; окна — `…: окно 3/17`. Строки без
    метки времени (предупреждения Python, трассировки) — не ход работы: они
    идут только в хвост для сообщения об ошибке.
    """
    match = re.match(r"^\[\d{2}:\d{2}:\d{2}\]\s*(.*)$", line.strip())
    if not match or not match.group(1):
        return None
    text = match.group(1)
    result: dict[str, Any] = {"stage": text}
    match = re.search(r"окно (\d+)/(\d+)", text)
    if match:
        result["done"] = int(match.group(1))
        result["total"] = int(match.group(2))
    return result


# Фазы для приложения: оно само пишет «Подготовка», «Расшифровка · Whisper» и т. д.
# Сырые строки transcriber (дорожка, полное имя модели, «окно 0/6») пользователю не нужны.
PHASE_PREPARE = "prepare"
PHASE_VOICES = "voices"
PHASE_TRANSCRIBE = "transcribe"
PHASE_FINISH = "finish"
# Короткое имя семейства модели по началу метки transcriber («Whisper mlx-community/…», «GigaAM v3…»).
_MODEL_NAMES = (("faster-whisper", "Whisper"), ("whisper", "Whisper"), ("gigaam", "GigaAM"), ("parakeet", "Parakeet"))
# Доля дорожки на этапы до распознавания: с диаризацией голоса считаются заметное время.
_VOICES_SHARE = 0.3
_PREPARE_SHARE = 0.05
# Последние 5% общей полосы — сборка расшифровки и голосовая память после всех дорожек.
_TRACKS_SHARE = 0.95
PROGRESS_SCALE = 1000


def progress_phase(stage: str) -> tuple[str, str | None]:
    """Строка хода transcriber → (фаза, короткое имя модели или None)."""
    head = stage.split(":", 1)[0].strip()
    low = head.lower()
    if low.startswith(("диаризация", "нарезка окон")):
        return PHASE_VOICES, None
    for prefix, name in _MODEL_NAMES:
        if low.startswith(prefix):
            return PHASE_TRANSCRIBE, name
    if re.search(r"окно \d+/\d+", stage) and not low.startswith("определение языка"):
        # Незнакомая модель с окнами — первое слово метки без организации на HF.
        return PHASE_TRANSCRIBE, head.split()[0].rsplit("/", 1)[-1] if head else None
    return PHASE_PREPARE, None


def track_fraction(phase: str, parsed: dict[str, Any], *, diarize: bool) -> float:
    """Доля пройденного внутри дорожки, 0…1, по фазе и счётчику окон."""
    total = parsed.get("total") or 0
    windows = min(parsed.get("done", 0) / total, 1.0) if total else 0.0
    if phase == PHASE_VOICES:
        return _VOICES_SHARE * windows if diarize else 0.0
    if phase == PHASE_TRANSCRIBE:
        base = _VOICES_SHARE if diarize else _PREPARE_SHARE
        return base + (1 - base) * windows
    return 0.0


def overall_progress(index: int, count: int, fraction: float) -> int:
    """Общая доля всех дорожек в тысячных: дорожки делят первые 95% поровну."""
    count = max(count, 1)
    return round(PROGRESS_SCALE * _TRACKS_SHARE * (index + min(max(fraction, 0.0), 1.0)) / count)


def progress_event(phase: str, done: int, *, model: str | None = None, track: str | None = None) -> dict[str, Any]:
    event: dict[str, Any] = {"event": "progress", "task": "meeting", "stage": phase,
                             "done": done, "total": PROGRESS_SCALE}
    if model:
        event["model"] = model
    if track:
        event["track"] = track
    return event


# --------------------------------------------------------------------------
# WAV: проверка тишины и починка заголовка после падения
# --------------------------------------------------------------------------


def repair_wav_header(path: Path) -> bool:
    """Поправить размеры RIFF/data, если запись оборвалась до финального патча.

    `MeetingRecorder` пишет заголовок с заглушками и обновляет его по ходу;
    после падения размеры могут отставать от файла. Возвращает True, если
    заголовок пришлось поправить. Понимает только канонический 44-байтный
    PCM-заголовок, который пишет сам рекордер.
    """
    size = path.stat().st_size
    if size < 44:
        return False
    with path.open("r+b") as handle:
        header = handle.read(44)
        if header[0:4] != b"RIFF" or header[8:12] != b"WAVE" or header[36:40] != b"data":
            return False
        riff_size, = struct.unpack("<I", header[4:8])
        data_size, = struct.unpack("<I", header[40:44])
        block_align, = struct.unpack("<H", header[32:34])
        actual = size - 44
        if block_align:
            actual -= actual % block_align
        if data_size == actual and riff_size == actual + 36:
            return False
        handle.seek(4)
        handle.write(struct.pack("<I", actual + 36))
        handle.seek(40)
        handle.write(struct.pack("<I", actual))
    return True


def wav_stats(path: Path) -> tuple[float, float]:
    """(длительность в секундах, уровень RMS в dBFS) для PCM16-WAV."""
    import numpy as np

    with wave.open(str(path), "rb") as reader:
        rate = reader.getframerate()
        channels = reader.getnchannels()
        width = reader.getsampwidth()
        if width != 2:
            raise ValueError(f"{path.name}: ожидался PCM16, получено {width * 8} бит")
        total_sq = 0.0
        count = 0
        while True:
            chunk = reader.readframes(rate * 10)
            if not chunk:
                break
            samples = np.frombuffer(chunk, dtype="<i2").astype(np.float64)
            total_sq += float(np.dot(samples, samples))
            count += samples.size
    if count == 0:
        return 0.0, float("-inf")
    rms = (total_sq / count) ** 0.5
    dbfs = 20 * np.log10(rms / 32768.0) if rms > 0 else float("-inf")
    return count / channels / rate, float(dbfs)


def track_usable(path: str | Path | None) -> tuple[bool, float]:
    """Есть ли в дорожке что расшифровывать: (годна, длительность)."""
    if not path:
        return False, 0.0
    candidate = Path(path)
    if not candidate.is_file() or candidate.stat().st_size <= 44:
        return False, 0.0
    try:
        repair_wav_header(candidate)
        duration, level = wav_stats(candidate)
    except (wave.Error, ValueError, EOFError):
        return False, 0.0
    return duration >= 0.5 and level > SILENCE_DBFS, duration


# --------------------------------------------------------------------------
# Сегменты дорожек (M12)
# --------------------------------------------------------------------------


def track_segments(payload: dict[str, Any], out_dir: Path) -> dict[str, list[tuple[Path, float]]]:
    """Сегменты дорожек: из `payload.segments`, иначе из `manifest.recording.segments`.

    Формат команды — `{mic: [{file, offset_seconds}], system: [...]}`, манифеста — список
    `{track, file, offset_seconds}`. Относительные имена файлов — от папки встречи.
    """
    raw = payload.get("segments")
    items: list[tuple[str, Any, Any]] = []
    if isinstance(raw, dict):
        for track, parts in raw.items():
            for part in parts or []:
                if isinstance(part, dict):
                    items.append((track, part.get("file"), part.get("offset_seconds", part.get("offset"))))
    else:
        manifest = folder_contract.read_manifest(out_dir) or {}
        for part in (manifest.get("recording") or {}).get("segments") or []:
            if isinstance(part, dict):
                items.append((part.get("track"), part.get("file"), part.get("offset_seconds")))
    result: dict[str, list[tuple[Path, float]]] = {}
    for track, name, offset in items:
        if track not in ("mic", "system") or not name:
            continue
        path = Path(str(name)).expanduser()
        if not path.is_absolute():
            path = out_dir / path
        try:
            seconds = max(0.0, float(offset or 0.0))
        except (TypeError, ValueError):
            seconds = 0.0
        result.setdefault(track, []).append((path, seconds))
    for parts in result.values():
        parts.sort(key=lambda part: part[1])
    return result


def join_segments(parts: list[tuple[Path, float]], target: Path, rate: int = 16_000) -> Path | None:
    """Склеить сегменты в один PCM16-WAV: каждый встаёт на своё смещение, дыры — тишина.

    Если следующий сегмент начинается раньше конца предыдущего, хвост предыдущего обрезается:
    смещение нового сегмента — правда о времени, старый файл мог дописаться после остановки.
    """
    pieces: list[tuple[int, bytes]] = []
    for path, offset in parts:
        if not path.is_file() or path.stat().st_size <= 44:
            continue
        repair_wav_header(path)
        try:
            with wave.open(str(path), "rb") as reader:
                if reader.getsampwidth() != 2 or reader.getnchannels() != 1:
                    continue
                rate = reader.getframerate()
                frames = reader.readframes(reader.getnframes())
        except (wave.Error, EOFError):
            continue
        pieces.append((int(round(offset * rate)), frames))
    if not pieces:
        return None
    pieces.sort(key=lambda piece: piece[0])
    with wave.open(str(target), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(rate)
        position = 0
        for index, (start, frames) in enumerate(pieces):
            limit = pieces[index + 1][0] if index + 1 < len(pieces) else None
            if start > position:
                writer.writeframes(b"\0\0" * (start - position))
                position = start
            skip = position - start
            data = frames[skip * 2:]
            if limit is not None:
                data = data[: max(0, limit - position) * 2]
            writer.writeframes(data)
            position += len(data) // 2
    return target


def assemble_tracks(payload: dict[str, Any], out_dir: Path, scratch: Path) -> dict[str, str]:
    """Пути дорожек для прогона: один сегмент — как есть, несколько — склейка во временной папке."""
    result: dict[str, str] = {}
    for track, parts in track_segments(payload, out_dir).items():
        if len(parts) == 1 and parts[0][1] == 0.0:
            if parts[0][0].is_file():
                result[track] = str(parts[0][0])
            continue
        joined = join_segments(parts, scratch / f"{track}.joined.wav")
        if joined is not None:
            result[track] = str(joined)
    return result


# --------------------------------------------------------------------------
# Запуск transcriber
# --------------------------------------------------------------------------


def transcriber_scripts_dir() -> Path:
    from . import paths

    return paths.transcriber_scripts()


def transcriber_python() -> str:
    """`MOSTIK_TRANSCRIBER_PYTHON` → venv соседнего transcriber (разработка) → свой интерпретатор.

    Во встроенном Python .app зависимости transcriber уже лежат в его site-packages.
    """
    from . import paths

    configured = os.environ.get("MOSTIK_TRANSCRIBER_PYTHON")
    if configured and not paths.IN_APP_BUNDLE:  # в .app — только свой Python (П10)
        return configured

    repo = paths.transcriber_repo()
    if repo is not None and (repo / ".venv" / "bin" / "python").is_file():
        return str(repo / ".venv" / "bin" / "python")
    return sys.executable


def build_command(
    audio: Path,
    output: Path,
    *,
    language: str,
    diarize: bool,
    speakers: int | None,
    offline: bool = True,
    learn: bool = False,
    glossary: str | None = None,
) -> list[str]:
    """Командная строка одного прогона, с `nice` и `taskpolicy -c utility`, если они есть."""
    script = transcriber_scripts_dir() / "transcribe.py"
    command = [
        transcriber_python(),
        # П10 С1: без user site и PYTHON*; не -I — transcribe.py берёт пакет из папки скрипта.
        "-s",
        "-E",
        str(script),
        str(audio),
        "--mode",
        "max",
        "--language",
        language or "auto",
        "--output",
        str(output),
        "--overwrite",
        # Р2 Н6: без кэша гипотез. Иначе текст встречи, в том числе «чувствительной», 90 дней лежит
        # в общем ~/.cache/transcriber, куда не дотягиваются «Забыть», сроки хранения и пометка.
        "--no-cache",
    ]
    if offline:
        # Приложение в сеть не ходит (§7): модели — только из кэша.
        command.append("--offline")
    if not learn:
        # Чужая речь со встречи не должна учить личный словарь автозаменам.
        command.append("--no-learn")
    if glossary:
        command += ["--glossary", glossary]
    if diarize:
        command += ["--diarize", "--diarization-backend", "auto"]
        if speakers:
            command += ["--expected-speakers", str(int(speakers))]
    prefix: list[str] = []
    if shutil.which("nice"):
        prefix += ["nice", "-n", "10"]
    if shutil.which("taskpolicy"):
        # QoS utility, не background: у `-b` распознавание в разы
        # медленнее, а под нагрузкой фоновый прогон почти стоит. Utility уступает переднему плану так же.
        prefix += ["taskpolicy", "-c", "utility"]
    return prefix + command


# --- ffmpeg и ffprobe --------------------------------------------------------------------------
# Свои дорожки (WAV) transcriber читает без них (`audio.native_wav`, правка копии); ffmpeg нужен
# только для другого формата. Их нет ни в macOS, ни в бандле: transcriber ищет их по PATH, затем в /opt/homebrew/bin и
# /usr/local/bin (`audio_transcription.audio.find_command`). В выпуске PATH — только система и бандл
# (`privacy.release_path`), так что остаются эти две папки. Перед прогоном движок сверяет, что
# найденное — файл владельца или root, который не правят группа и прочие, в такой же папке.
# От процесса того же пользователя это не защищает — принятый риск, docs/release.md («Принятые риски П10»).

MEDIA_TOOLS = ("ffmpeg", "ffprobe")
MEDIA_TOOL_DIRS = (Path("/opt/homebrew/bin"), Path("/usr/local/bin"))


def media_tool_candidates(env: dict[str, str]) -> list[Path]:
    """Что transcriber возьмёт за ffmpeg и ffprobe с этим окружением — тем же порядком поиска."""
    found: list[Path] = []
    for name in MEDIA_TOOLS:
        hit = shutil.which(name, path=env.get("PATH", ""))
        if hit is None:
            hit = next((str(d / name) for d in MEDIA_TOOL_DIRS
                        if (d / name).is_file() and os.access(d / name, os.X_OK)), None)
        if hit:
            found.append(Path(hit))
    return found


def tool_problem(path: Path) -> str | None:
    """Что не так с внешним бинарником (по цели ссылки): None — можно запускать."""
    try:
        target = path.resolve(strict=True)
        owners = {0, os.getuid()}
        for item in (target, target.parent):
            info = item.stat()
            if info.st_uid not in owners:
                return f"{path.name}: {item} принадлежит другому пользователю"
            if info.st_mode & 0o022:
                return f"{path.name}: {item} могут менять группа или другие пользователи"
    except OSError as error:
        return f"{path.name}: {error}"
    return None


def needs_media_tools(audio: Path | None) -> bool:
    """Нужен ли прогону ffmpeg: PCM-WAV (свои дорожки Mostik) transcriber читает сам."""
    if audio is None:
        return True
    from . import paths

    paths.setup_import_path()
    from audio_transcription import audio as media  # type: ignore

    return media.native_wav(Path(audio)) is None


def check_media_tools(env: dict[str, str], audio: Path | None = None) -> None:
    """Отказ до прогона, если ffmpeg или ffprobe подозрительны. Нет их совсем — скажет transcriber.

    WAV читается без них — тогда и проверять нечего: старый ffmpeg в общей папке не должен
    ломать встречу, которой он не нужен.
    """
    if not needs_media_tools(audio):
        return
    for tool in media_tool_candidates(env):
        problem = tool_problem(tool)
        if problem:
            raise MeetingTrackError("media_tool_untrusted", f"не запускаю {problem}")


# --- разделение по голосам (fluidaudiocli) ------------------------------------------------------
# Диаризация системной дорожки — бинарник FluidAudio. Его может не быть ни в бандле, ни в PATH
# выпуска: тогда transcriber с `--diarize` падает, и встреча целиком оставалась без расшифровки.
# Движок проверяет это до прогона и расшифровывает дорожку без разделения — одним собеседником.

DIARIZATION_UNAVAILABLE = "diarization_unavailable"
# Модель голосов упала на этой записи дважды подряд (например, CoreML «Unable to compute the
# asynchronous prediction», хотя та же запись позже разделяется без ошибок) — дорожка
# расшифрована одним собеседником, встреча не теряется.
DIARIZATION_FAILED = "diarization_failed"
_DIARIZATION_SIGNS = ("coreml", "fluidaudio", "failed to process audio file", "диаризац")


def diarization_crash(message: str) -> bool:
    """Сбой прогона пришёлся на модель голосов, а не на распознавание."""
    text = message.lower()
    return any(sign in text for sign in _DIARIZATION_SIGNS)


def finished_track(output: Path, audio: Path, diarize: bool) -> bool:
    """Дорожка уже расшифрована прошлой попыткой — тем же режимом и с тем же разделением по голосам.

    Повтор встречи после сбоя на второй дорожке иначе заново гонит первую, и
    повтор длится дольше самой записи.
    """
    try:
        manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
        size = audio.stat().st_size
    except (OSError, ValueError):
        return False
    if not (output / "segments.json").is_file() or manifest.get("mode") != "max":
        return False
    if (manifest.get("source") or {}).get("size_bytes") != size:
        return False
    return (manifest.get("diarization_model") is not None) == diarize


def track_log(track: str, text: str) -> None:
    """Строка хода дорожки в engine.log — со временем: без него зависание не отличить от очереди."""
    print(f"[mostik {time.strftime('%H:%M:%S')}] meeting {track}: {text}", file=sys.stderr, flush=True)


def diarization_problem(*, offline: bool = True) -> str | None:
    """Почему системную дорожку не разделить по голосам на этом Mac; None — можно.

    Тот же поиск и та же проверка суммы, что у transcriber (`catalog.fluidaudio_binary_path`,
    `bundled_binary_problem`): окружение движка и его ребёнка совпадает — в .app оба с PATH
    выпуска (`privacy.scrub_dev_overrides`). Офлайн нужны и CoreML-модели FluidAudio: скачать
    их прогон не сможет.
    """
    from . import paths

    paths.setup_import_path()
    try:
        from audio_transcription import catalog, fluid_models  # type: ignore
    except Exception as error:  # noqa: BLE001
        return f"transcriber недоступен: {error}"
    binary = catalog.fluidaudio_binary_path()
    if binary is None:
        return "нет fluidaudiocli"
    problem = catalog.bundled_binary_problem(binary)
    if problem:
        return f"fluidaudiocli: {problem}"
    if offline and not fluid_models.ready():
        return "нет моделей FluidAudio"
    if offline:
        # П10 р3 Н-4: бинарник читает другой каталог и весь набор; неполный — он пошёл бы качать сам.
        from . import fluid_offline

        problem = fluid_offline.models_problem()
        if problem:
            return problem
    return None


# Признаки нехватки памяти в хвосте stderr transcriber'а (PyTorch, MLX, macOS).
_MEMORY_SIGNS = (
    "memoryerror",
    "out of memory",
    "cannot allocate memory",
    "insufficient memory",
    "failed to allocate",
    "not enough memory",
)


class MeetingTrackError(RuntimeError):
    """Сбой прогона дорожки с кодом для приложения; `code` уходит в событие `error`."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def memory_failure(code: int, tail: Iterable[str]) -> bool:
    """Прогон упал от нехватки памяти: SIGKILL от системы (-9 / 137) или явное сообщение."""
    if code in (-9, 137):
        return True
    text = " ".join(tail).lower()
    return any(sign in text for sign in _MEMORY_SIGNS)


def run_track(
    command: list[str],
    *,
    track: str,
    index: int,
    count: int,
    emit: Emit,
    diarize: bool = False,
    audio: Path | None = None,
) -> None:
    """Запустить прогон, транслируя его stderr в события `progress`.

    Нехватка памяти на прогоне с диаризацией — `MeetingTrackError("diarization_memory")`:
    приложение предложит повторить без разделения по голосам (`diarize: false`).
    """
    emit(progress_event(PHASE_PREPARE, overall_progress(index, count, 0.0), track=track))
    # Без сети HF, телеметрии и проверки обновлений transcriber; без PYTHON*, DYLD_*, LD_* (П10 С1).
    env = isolation.child_env(privacy.offline_env())
    check_media_tools(env, audio)
    process = subprocess.Popen(
        command,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    tail: list[str] = []
    started = time.monotonic()
    track_log(track, "старт" + (" с разделением по голосам" if diarize else ""))
    last_stage = ""
    # Полоса не откатывается: вторая модель или повтор окон не тянут её назад.
    fraction = 0.0
    assert process.stderr is not None
    for line in process.stderr:
        if line.strip():
            tail = (tail + [line.strip()])[-20:]
        parsed = parse_progress_line(line)
        if parsed is None:
            continue
        # В журнал — только название этапа, до двоеточия: дальше бывают пути и слова из записи.
        stage = parsed["stage"].split(":", 1)[0].strip()
        if "done" not in parsed and stage != last_stage:
            last_stage = stage
            track_log(track, stage)
        phase, model = progress_phase(parsed["stage"])
        fraction = max(fraction, track_fraction(phase, parsed, diarize=diarize))
        emit(progress_event(phase, overall_progress(index, count, fraction), model=model, track=track))
    stdout = process.stdout.read() if process.stdout else ""
    code = process.wait()
    track_log(track, f"код {code}, {time.monotonic() - started:.0f} с")
    if code != 0:
        detail = f"transcriber ({track}) завершился с кодом {code}: " + " | ".join(tail[-5:])
        if diarize and memory_failure(code, tail):
            raise MeetingTrackError("diarization_memory", "Не хватило памяти для модели голосов. " + detail)
        raise RuntimeError(detail)
    del stdout  # итоговый JSON не нужен: результат читаем из segments.json


def load_segments(output: Path) -> list[dict[str, Any]]:
    payload = json.loads((output / "segments.json").read_text(encoding="utf-8"))
    return [
        {
            "start": float(item["start"]),
            "end": float(item["end"]),
            "text": str(item.get("text") or ""),
            "speakers": list(item.get("speakers") or []),
        }
        for item in payload.get("readable", [])
        if str(item.get("text") or "").strip()
    ]


def run_meeting(payload: dict[str, Any], emit: Emit) -> dict[str, Any]:
    """Команда движка `meeting`: обе дорожки → transcript.md и transcript.json.

    payload: {mic, system, out_dir, language, speakers (None|int)}; необязательно
    marks [{at, text}], title, attendees [имя | {name, self}], owner,
    offline (True), learn (False), glossary (путь к YAML),
    diarize (True; False — системная дорожка одним собеседником, без модели голосов).
    """
    started = time.monotonic()
    if payload.get("voice_memory") and "voice_epoch" not in payload:
        from . import voices

        # Р2 Н7: стирание отпечатков после этой точки отменит их запись этой встречей.
        payload = {**payload, "voice_epoch": voices.epoch()}
    out_dir = Path(payload["out_dir"]).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    folder_contract.transcript_started(out_dir)
    scratch = Path(tempfile.mkdtemp(prefix="mostik-tracks-"))
    try:
        # Живучесть записи (M12): дорожку из нескольких сегментов склеиваем по смещениям.
        payload = {**payload, **assemble_tracks(payload, out_dir, scratch)}
        return _run_meeting(payload, emit, out_dir, started)
    except Exception as error:
        code = getattr(error, "code", None)
        folder_contract.transcript_failed(out_dir, f"{type(error).__name__}: {error}",
                                          code=code if isinstance(code, str) else None)
        raise
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def _run_meeting(payload: dict[str, Any], emit: Emit, out_dir: Path, started: float) -> dict[str, Any]:
    language = payload.get("language") or "auto"
    speakers = payload.get("speakers")
    options = {
        "offline": bool(payload.get("offline", True)),
        "learn": bool(payload.get("learn", False)),
        "glossary": payload.get("glossary"),
    }

    mic_ok, mic_duration = track_usable(payload.get("mic"))
    system_ok, system_duration = track_usable(payload.get("system"))
    # Повтор после нехватки памяти (`diarize: false`) или нет fluidaudiocli: без диаризации
    # все собеседники системной дорожки — «Собеседник 1».
    diarize_system = system_ok and payload.get("diarize", True) is not False
    unavailable = diarization_problem(offline=options["offline"]) if diarize_system else None
    if unavailable:
        print(f"meeting: без разделения по голосам — {unavailable}", file=sys.stderr, flush=True)
        diarize_system = False
    plan: list[tuple[str, Path, bool]] = []
    if mic_ok:
        plan.append(("mic", Path(payload["mic"]), False))
    if system_ok:
        plan.append(("system", Path(payload["system"]), diarize_system))

    segments: dict[str, list[dict[str, Any]]] = {"mic": [], "system": []}
    diarization_failed = False
    for index, (track, audio, diarize) in enumerate(plan):
        output = out_dir / f"{track}-transcript"
        if finished_track(output, audio, diarize):
            track_log(track, "уже расшифрована прошлой попыткой")
            segments[track] = load_segments(output)
            continue

        def run(diarize: bool) -> None:
            if not diarize:
                # Прошлый прогон с диаризацией мог оставить speakers.json — он не про этот текст.
                (output / "speakers.json").unlink(missing_ok=True)
            command = build_command(
                audio,
                output,
                language=language,
                diarize=diarize,
                speakers=speakers if diarize else None,
                **options,
            )
            run_track(command, track=track, index=index, count=len(plan), emit=emit, diarize=diarize,
                      audio=audio)

        try:
            run(diarize)
        except MeetingTrackError:
            raise
        except RuntimeError as error:
            if not (diarize and diarization_crash(str(error))):
                raise
            # Модель голосов идёт до распознавания: повтор стоит минуты, а сбой CoreML бывает разовым.
            track_log(track, "модель голосов упала, повторяю")
            try:
                run(True)
            except MeetingTrackError:
                raise
            except RuntimeError as again:
                if not diarization_crash(str(again)):
                    raise
                track_log(track, "модель голосов упала снова, расшифровываю одним собеседником")
                run(False)
                diarization_failed = True
                diarize_system = False
        segments[track] = load_segments(output)

    emit(progress_event(PHASE_FINISH, round(PROGRESS_SCALE * _TRACKS_SHARE)))
    mic_segments, echo_dropped = drop_echo(segments["mic"], segments["system"])
    turns = merge_tracks(mic_segments, segments["system"])
    # Исходная метка диаризации остаётся в `label`: на неё опираются уверенность (M15),
    # голосовая память и переименование (M14), имя — только в `speaker`.
    for turn in turns:
        if turn["source"] == "system":
            turn["label"] = turn["speaker"]
    review = speaker_confidence.annotate(
        turns,
        speaker_confidence.load_diarization(out_dir / "system-transcript") if system_ok else None,
        speaker_labels(segments["system"]),
    )
    title = " ".join(str(payload.get("title") or "").split()) or None
    attendees = normalize_attendees(payload.get("attendees"))
    marks = normalize_marks(payload.get("marks"))
    name = calendar_name(segments["system"], attendees, payload.get("owner"))
    speaker_names = {f"{INTERLOCUTOR} 1": name} if name else {}
    # Имена из окна ВКС по времени (лента приложения) важнее календаря: они про конкретную метку.
    own = [item["name"] for item in attendees if item["self"]] + ([payload["owner"]] if payload.get("owner") else [])
    named = speaker_timeline.names_for(out_dir, turns, own=own,
                                       duration=max(mic_duration, system_duration)) if system_ok else {}
    speaker_names.update({label: naming.name for label, naming in named.items()})
    turns = apply_speaker_names(turns, speaker_names)
    # Голосовой памяти нужны метки диаризации: без разделения по голосам её не трогаем.
    voices_block = _voice_memory(payload, out_dir, turns, emit) if diarize_system else None
    duration = max(mic_duration, system_duration)
    date = _meeting_date(out_dir)
    markdown = render_markdown(turns, date=date, duration_seconds=duration, marks=marks, title=title)

    md_path = out_dir / "transcript.md"
    json_path = out_dir / "transcript.json"
    md_path.write_text(markdown, encoding="utf-8")
    people = participants(turns)
    others = [name for name in people if name != ME]
    document = {
        "schema": folder_contract.TRANSCRIPT_SCHEMA,
        "version": folder_contract.VERSION,
        "id": out_dir.name,
        "date": date.isoformat(timespec="minutes"),
        "title": title,
        "attendees": [item["name"] for item in attendees],
        "marks": marks,
        "duration_seconds": round(duration, 2),
        "language": language,
        "participants": people,
        "tracks": {
            "mic": {"used": mic_ok, "duration_seconds": round(mic_duration, 2)},
            "system": {"used": system_ok, "duration_seconds": round(system_duration, 2)},
        },
        "echo_dropped": echo_dropped,
        # M15: сколько реплик системной дорожки с уверенностью метки ниже 0,6.
        "speaker_review": review,
        # M14: имена меток; `{метка: имя}`, правится из окна встречи.
        "speaker_names": speaker_names,
        # `id` реплики = её номер в массиве: на него ссылаются заметки, сводка и «Спросить».
        "turns": [{"id": index, **turn} for index, turn in enumerate(turns)],
    }
    if named:
        # Откуда имя у метки и насколько уверенно: правка в окне встречи по-прежнему главнее.
        document["speaker_timeline"] = {label: naming.to_dict() for label, naming in named.items()}
    if unavailable:
        # Окно встречи скажет «Разделение по голосам недоступно на этом Mac»; код — и в манифесте.
        document["diarization"] = {"available": False, "code": DIARIZATION_UNAVAILABLE}
    elif diarization_failed:
        document["diarization"] = {"available": False, "code": DIARIZATION_FAILED}
    with _voices_lock(voices_block):
        # Р2 Н7: стирание, пришедшее после расчёта голосов, но до записи, — подсказки не пишем;
        # пришедшее после записи уберёт их само (стирание и запись — под одним замком).
        if voices_block is not None and _voice_memory_current(payload):
            document["voices"] = voices_block
        json_path.write_text(json.dumps(document, ensure_ascii=False, indent=2), encoding="utf-8")
    # Контракт папки (M10): манифест, notes.md с пометками, meeting.md с YAML-шапкой.
    folder_contract.after_transcript(out_dir, {**payload, "attendees": attendees}, document)
    emit(progress_event(PHASE_FINISH, PROGRESS_SCALE))
    return {
        "event": "meeting_done",
        "transcript_md": str(md_path),
        "transcript_json": str(json_path),
        "meeting_md": str(out_dir / folder_contract.MEETING_MD),
        "manifest": str(out_dir / folder_contract.MANIFEST),
        "speakers": len(others),
        "seconds": round(time.monotonic() - started, 2),
    }


def _voice_memory(payload: dict[str, Any], out_dir: Path, turns: list[dict[str, Any]], emit: Emit) -> dict[str, Any] | None:
    """Голосовая память (M14): только если включена и есть согласие; сбой не роняет расшифровку."""
    if not payload.get("voice_memory"):
        return None
    from . import voices

    audio = payload.get("system")
    try:
        return voices.remember_meeting(out_dir.name, Path(audio) if audio else None, turns,
                                       since=payload.get("voice_epoch"))
    except voices.VoiceMemoryRevoked:
        return None
    except Exception as error:  # noqa: BLE001
        return {"enabled": True, "error": f"{type(error).__name__}: {error}", "suggestions": [], "pending": []}


def _voices_lock(voices_block: dict[str, Any] | None) -> Any:
    """Замок голосовой памяти, если встрече есть что записать; иначе — пустой контекст."""
    if voices_block is None:
        return contextlib.nullcontext()
    from . import voices

    return voices.LOCK


def _voice_memory_current(payload: dict[str, Any]) -> bool:
    from . import voices

    return voices.current(payload.get("voice_epoch"))


def _meeting_date(out_dir: Path) -> _dt.datetime:
    """Дата из имени папки `yyyy-MM-dd-HHmmss` (или старого `yyyy-MM-dd-HHmm`), иначе — текущее время."""
    parsed = folder_contract.folder_date(out_dir)
    return parsed.replace(tzinfo=None) if parsed else _dt.datetime.now()
