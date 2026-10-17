"""Голосовая память собеседников (M14): опция, выключена по умолчанию, только по согласию.

Что хранится — `<MOSTIK_HOME>/voices/`, формат в `docs/voice-memory.md`:

- `people.json` — люди и до `MAX_SAMPLES` образцов голоса на человека. Образец —
  вектор (эмбеддинг) голоса и сколько секунд речи за ним стоит. Аудио не храним.
- `pending/<id встречи>.json` — векторы говорящих последней расшифровки, ждущие
  решения человека. Векторы в папку встречи не попадают. Кластер удаляется, как только
  по метке принято решение («Это он», «Не он», имя), файл — когда решать нечего или
  через `PENDING_DAYS` дней. «Забыть» человека убирает и похожие на него кластеры (П10 С8).

Как совпадение становится подсказкой (пороги heed, MIT):

- у говорящего на встрече не меньше `MIN_SPEECH_SECONDS` речи;
- косинус с лучшим человеком ≥ `MATCH_THRESHOLD`; оценка человека — лучший из его образцов;
- лучший опережает второго человека не меньше чем на `MATCH_MARGIN`.

Подсказка не подставляется молча: имя появляется в расшифровке только после
«Это он» или когда человек сам назвал говорящего. Тогда вектор встречи
добавляется к образцам этого человека (переименование в существующее имя —
слияние). Дорожка микрофона («Я») не участвует никогда.

Модель голоса — интерфейс `VoiceEmbedder`. Боевая реализация — `FluidAudioEmbedder`:
та же модель WeSpeaker из pyannote community-1 (CoreML, 256 чисел), которой
transcriber уже делит говорящих; лежит локально, ничего не скачивается.
Для тестов — детерминированная `StubEmbedder`.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import json
import math
import os
import shutil
import subprocess
import tempfile
import threading
import uuid
from pathlib import Path
from typing import Any, Iterable, Protocol

from .paths import mostik_home

SCHEMA = "mostik.voices"
VERSION = 1
MIN_SPEECH_SECONDS = 4.0
MATCH_THRESHOLD = 0.62
MATCH_MARGIN = 0.08
MAX_SAMPLES = 10
PENDING_DAYS = 30  # П10 С8: нерешённые отпечатки третьих лиц не живут дольше месяца
ME = "Я"
SEPARATOR = " + "

Spans = dict[str, list[tuple[float, float]]]

# Р2 Н7: «эпоха» памяти. Стирание и выключение памяти её меняют; встреча запоминает эпоху на старте
# и после смены отпечатков не пишет — ни в `pending/`, ни подсказками в `transcript.json`.
# Под `LOCK` идут стирание (с чисткой подсказок) и каждая запись встречи, поэтому любое стирание
# приходится либо до записи (запись откажется), либо после (стирание её уберёт).
LOCK = threading.RLock()
_epoch = 0


class VoiceMemoryRevoked(Exception):
    """Память стёрли или выключили, пока встреча расшифровывалась."""


def epoch() -> int:
    with LOCK:
        return _epoch


def revoke() -> int:
    """Новая эпоха: идущие расшифровки отпечатков больше не запишут."""
    global _epoch
    with LOCK:
        _epoch += 1
        return _epoch


def current(since: int | None) -> bool:
    """Эпоха не менялась с `since` (None — проверка не нужна, вызов вне встречи)."""
    return since is None or epoch() == since


def now_iso() -> str:
    return _dt.datetime.now().astimezone().isoformat(timespec="seconds")


def normalize(vector: Iterable[float]) -> list[float]:
    values = [float(x) for x in vector]
    norm = math.sqrt(sum(x * x for x in values))
    return [x / norm for x in values] if norm > 0 else values


def cosine(left: list[float], right: list[float]) -> float:
    if not left or len(left) != len(right):
        return 0.0
    dot = sum(a * b for a, b in zip(left, right))
    norm = math.sqrt(sum(a * a for a in left) * sum(b * b for b in right))
    return dot / norm if norm > 0 else 0.0


# --------------------------------------------------------------------------
# Модель голоса
# --------------------------------------------------------------------------


class VoiceEmbedder(Protocol):
    """Вектор голоса для каждого говорящего записи.

    `spans` — `{метка: [(начало, конец), …]}` по системной дорожке. Ответ —
    `{метка: вектор}` только для меток, которые удалось посчитать. Векторы
    разных `model_id` несравнимы, поэтому образцы помечены моделью.
    """

    model_id: str

    def available(self) -> tuple[bool, str]: ...

    def embed(self, audio: Path, spans: Spans) -> dict[str, list[float]]: ...


class StubEmbedder:
    """Детерминированная заглушка для тестов: вектор из sha256 ключа голоса.

    `keys` — `{метка: ключ}`; одинаковый ключ на разных встречах = один и тот же
    «человек». `noise` смешивает вектор с вектором метки, чтобы гонять пороги.
    """

    model_id = "stub-sha256-16"

    def __init__(self, keys: dict[str, str] | None = None, *, noise: float = 0.0, dim: int = 16) -> None:
        self.keys = dict(keys or {})
        self.noise = noise
        self.dim = dim

    @staticmethod
    def vector(key: str, dim: int = 16) -> list[float]:
        digest = hashlib.sha256(key.encode("utf-8")).digest()
        while len(digest) < dim:
            digest += hashlib.sha256(digest).digest()
        return normalize((byte - 127.5) / 127.5 for byte in digest[:dim])

    def available(self) -> tuple[bool, str]:
        return True, "заглушка"

    def embed(self, audio: Path, spans: Spans) -> dict[str, list[float]]:
        result = {}
        for label in spans:
            base = self.vector(self.keys.get(label, label), self.dim)
            if self.noise:
                jitter = self.vector("noise:" + label, self.dim)
                base = normalize(b * (1 - self.noise) + j * self.noise for b, j in zip(base, jitter))
            result[label] = base
        return result


# Р3 Н-2: временные папки идущих расчётов голосов (`mostik-voices-*`) — их `wipe` не трогает.
_ACTIVE_SCRATCH: set[str] = set()


def _drop_voice_scratch() -> int:
    """Векторы голосов, брошенные во временной папке убитым движком: «Стереть отпечатки» убирает и их."""
    removed = 0
    for path in Path(tempfile.gettempdir()).glob("mostik-voices-*"):
        if str(path) in _ACTIVE_SCRATCH or path.is_symlink() or not path.is_dir():
            continue
        shutil.rmtree(path, ignore_errors=True)
        removed += 1
    return removed


def _transcriber_fluid() -> tuple[Path | None, bool, str]:
    """Путь к fluidaudiocli и готовность моделей — через модули transcriber, без скачивания.

    П10 р3 Н-5: та же сверка суммы поставочного бинарника, что у диаризации встречи
    (`meeting.diarization_problem`); Н-4: модели — полный офлайновый набор (`fluid_offline`).
    """
    from . import fluid_offline

    try:
        from audio_transcription.catalog import bundled_binary_problem, fluidaudio_binary_path  # type: ignore
        from audio_transcription.fluid_models import ready  # type: ignore
    except Exception as error:  # noqa: BLE001
        return None, False, f"transcriber недоступен: {error}"
    try:
        binary = fluidaudio_binary_path()
    except Exception as error:  # noqa: BLE001
        return None, False, f"fluidaudiocli: {error}"
    if binary is not None:
        problem = bundled_binary_problem(binary)
        if problem:
            return None, False, f"fluidaudiocli: {problem}"
    return binary, bool(ready()) and fluid_offline.models_problem() is None, ""


class FluidAudioEmbedder:
    """WeSpeaker v2 (pyannote community-1, CC-BY-4.0) через `fluidaudiocli process --mode offline`.

    CLI отдаёт отрезки своей диаризации с вектором 256 чисел. Вектор метки
    Mostik — среднее векторов отрезков FluidAudio, взвешенное по секундам
    пересечения с репликами метки, затем нормировка.
    """

    model_id = "fluidaudio-wespeaker-v2-256"

    def __init__(self, binary: Path | None = None, *, timeout: float | None = None) -> None:
        self._binary = binary
        self.timeout = timeout

    def _resolve(self) -> tuple[Path | None, str]:
        if self._binary is not None:
            return (self._binary, "") if Path(self._binary).is_file() else (None, f"нет файла {self._binary}")
        binary, models_ready, detail = _transcriber_fluid()
        if binary is None:
            return None, detail or "нет fluidaudiocli"
        if not models_ready:
            return None, "нет моделей FluidAudio (полного офлайнового набора) в ~/Library/Application Support/FluidAudio"
        return binary, ""

    def available(self) -> tuple[bool, str]:
        binary, detail = self._resolve()
        return binary is not None, detail or str(binary)

    def embed(self, audio: Path, spans: Spans) -> dict[str, list[float]]:
        binary, detail = self._resolve()
        if binary is None:
            raise RuntimeError(f"модель голоса недоступна: {detail}")
        from . import fluid_offline, isolation, privacy

        with tempfile.TemporaryDirectory(prefix="mostik-voices-") as scratch:
            # Р3 Н-2: занятую папку `wipe` не трогает, брошенные убитым движком — стирает.
            _ACTIVE_SCRATCH.add(scratch)
            try:
                output = Path(scratch) / "fluid.json"
                # Р3 Н-4: без сети — бинарник не скачает модели сам, даже если набор испортится.
                command = fluid_offline.no_network_prefix() + [
                    str(binary), "process", str(audio), "--mode", "offline", "--output", str(output),
                    "--compute-units", "cpu-only"]
                if spans:
                    command += ["--num-speakers", str(len(spans))]
                # Р4-1: системные утилиты — полным путём, не из PATH.
                prefix = (["/usr/bin/nice", "-n", "10"] if os.path.exists("/usr/bin/nice") else []) + (
                    ["/usr/sbin/taskpolicy", "-b"] if os.path.exists("/usr/sbin/taskpolicy") else [])
                # Р3 Н-5: окружение как у остальных детей движка — без PYTHON*/DYLD_*, офлайн.
                env = isolation.child_env(privacy.offline_env())
                subprocess.run(prefix + command, check=True, capture_output=True, timeout=self.timeout or 900, env=env)
                payload = json.loads(output.read_text(encoding="utf-8"))
            finally:
                _ACTIVE_SCRATCH.discard(scratch)
        return label_vectors(payload.get("segments") or [], spans)


def label_vectors(segments: list[dict[str, Any]], spans: Spans) -> dict[str, list[float]]:
    """Векторы отрезков FluidAudio → вектор метки по секундам пересечения с её репликами."""
    result: dict[str, list[float]] = {}
    for label, intervals in spans.items():
        total: list[float] | None = None
        weight_sum = 0.0
        for segment in segments:
            vector = segment.get("embedding")
            if not vector:
                continue
            start, end = float(segment.get("startTimeSeconds", 0)), float(segment.get("endTimeSeconds", 0))
            weight = sum(max(0.0, min(end, b) - max(start, a)) for a, b in intervals)
            if weight <= 0:
                continue
            unit = normalize(vector)
            total = [w * weight for w in unit] if total is None else [t + w * weight for t, w in zip(total, unit)]
            weight_sum += weight
        if total is not None and weight_sum > 0:
            result[label] = normalize(total)
    return result


def default_embedder() -> VoiceEmbedder:
    return FluidAudioEmbedder()


# --------------------------------------------------------------------------
# Хранилище
# --------------------------------------------------------------------------


def _write_private(path: Path, data: Any) -> None:
    """Атомарная запись с правами 0600: голоса — биометрия, остальным пользователям не видны."""
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=1)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def clean_name(name: Any) -> str:
    return " ".join(str(name or "").split())


class VoiceStore:
    """`<MOSTIK_HOME>/voices/`: люди с образцами и векторы встреч, ждущие решения."""

    def __init__(self, root: Path | None = None) -> None:
        self.root = Path(root) if root else mostik_home() / "voices"

    # --- файлы -----------------------------------------------------------

    @property
    def people_path(self) -> Path:
        return self.root / "people.json"

    def pending_path(self, meeting: str) -> Path:
        safe = "".join(ch for ch in meeting if ch.isalnum() or ch in "-_.") or "meeting"
        return self.root / "pending" / f"{safe}.json"

    def _load(self) -> dict[str, Any]:
        try:
            data = json.loads(self.people_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            data = {}
        if not isinstance(data, dict) or not isinstance(data.get("people"), list):
            data = {"schema": SCHEMA, "version": VERSION, "people": []}
        return data

    def _save(self, data: dict[str, Any]) -> None:
        data["schema"], data["version"] = SCHEMA, VERSION
        _write_private(self.people_path, data)

    # --- люди ------------------------------------------------------------

    def people(self) -> list[dict[str, Any]]:
        """Люди без векторов: для интерфейса и ответа движка."""
        return [
            {"id": person["id"], "name": person["name"], "samples": len(person.get("samples") or []),
             "seconds": round(sum(float(s.get("seconds") or 0) for s in person.get("samples") or []), 1),
             "updated": person.get("updated")}
            for person in self._load()["people"]
        ]

    def find(self, name: str) -> dict[str, Any] | None:
        key = clean_name(name).casefold()
        return next((p for p in self._load()["people"] if p["name"].casefold() == key), None)

    def match(self, vector: list[float], model: str) -> dict[str, Any] | None:
        """Лучший человек по косинусу, если прошёл пороги heed; иначе None."""
        scored = []
        for person in self._load()["people"]:
            samples = [s["vector"] for s in person.get("samples") or [] if s.get("model") == model]
            if samples:
                scored.append((max(cosine(vector, sample) for sample in samples), person))
        if not scored:
            return None
        scored.sort(key=lambda item: -item[0])
        best, person = scored[0]
        second = scored[1][0] if len(scored) > 1 else 0.0
        if best < MATCH_THRESHOLD or best - second < MATCH_MARGIN:
            return None
        return {"person_id": person["id"], "name": person["name"], "score": round(best, 3), "second": round(second, 3)}

    def add_sample(self, name: str, vector: list[float], *, model: str, seconds: float, meeting: str) -> dict[str, Any]:
        """Образец к человеку с этим именем (слияние) или новый человек. Старше `MAX_SAMPLES` — вытесняются."""
        name = clean_name(name)
        if not name or name == ME:
            raise ValueError("пустое имя или «Я»")
        data = self._load()
        key = name.casefold()
        person = next((p for p in data["people"] if p["name"].casefold() == key), None)
        merged = person is not None
        if person is None:
            person = {"id": uuid.uuid4().hex[:12], "name": name, "created": now_iso(), "samples": []}
            data["people"].append(person)
        samples = [s for s in person.get("samples") or [] if s.get("meeting") != meeting]
        samples.append({"vector": [round(x, 6) for x in normalize(vector)], "model": model,
                        "seconds": round(float(seconds), 1), "meeting": meeting, "added": now_iso()})
        person["samples"] = samples[-MAX_SAMPLES:]
        person["updated"] = now_iso()
        self._save(data)
        return {"person_id": person["id"], "name": person["name"], "merged": merged,
                "samples": len(person["samples"])}

    def meeting_sample(self, name: str, meeting: str) -> dict[str, Any] | None:
        """Образец человека `name` с этой встречи (у человека он один на встречу)."""
        person = self.find(name)
        return next((s for s in (person or {}).get("samples") or [] if s.get("meeting") == meeting), None)

    def take_meeting_sample(self, name: str, meeting: str) -> dict[str, Any] | None:
        """Снять образец встречи с человека (имя убрали или отдали другому). Без образцов человек
        не нужен — он удаляется."""
        data = self._load()
        key = clean_name(name).casefold()
        person = next((p for p in data["people"] if p["name"].casefold() == key), None)
        if person is None:
            return None
        sample = next((s for s in person.get("samples") or [] if s.get("meeting") == meeting), None)
        if sample is None:
            return None
        person["samples"] = [s for s in person["samples"] if s is not sample]
        if person["samples"]:
            person["updated"] = now_iso()
        else:
            data["people"] = [p for p in data["people"] if p is not person]
        self._save(data)
        return sample

    def rename(self, person_id: str, name: str) -> dict[str, Any]:
        """Переименовать; имя уже занято другим человеком — слить образцы в него."""
        name = clean_name(name)
        if not name or name == ME:
            raise ValueError("пустое имя или «Я»")
        data = self._load()
        person = next((p for p in data["people"] if p["id"] == person_id), None)
        if person is None:
            raise KeyError(person_id)
        target = next((p for p in data["people"] if p["id"] != person_id and p["name"].casefold() == name.casefold()), None)
        if target is None:
            person["name"], person["updated"] = name, now_iso()
            self._save(data)
            return {"person_id": person_id, "name": name, "merged": False}
        combined = sorted((target.get("samples") or []) + (person.get("samples") or []), key=lambda s: s.get("added") or "")
        target["samples"] = combined[-MAX_SAMPLES:]
        target["updated"] = now_iso()
        data["people"] = [p for p in data["people"] if p["id"] != person_id]
        self._save(data)
        return {"person_id": target["id"], "name": target["name"], "merged": True, "merged_from": person_id}

    def forget(self, person_id: str) -> bool:
        """Забыть человека: его образцы и нерешённые кластеры встреч, похожие на его голос."""
        data = self._load()
        person = next((p for p in data["people"] if p["id"] == person_id), None)
        if person is None:
            return False
        data["people"] = [p for p in data["people"] if p["id"] != person_id]
        self._save(data)
        samples = [s for s in person.get("samples") or [] if s.get("vector")]
        for path in self._pending_files():
            pending = self._read_pending(path)
            if pending is None:
                continue
            model = pending.get("model")
            clusters = pending.get("clusters") or {}
            kept = {label: cluster for label, cluster in clusters.items()
                    if not any(s.get("model") == model
                               and cosine(cluster.get("vector") or [], s["vector"]) >= MATCH_THRESHOLD
                               for s in samples)}
            if len(kept) != len(clusters):
                self._write_pending(path, pending, kept)
        return True

    def forget_all(self) -> int:
        """Стереть всех людей и все векторы встреч. Возвращает, сколько людей было."""
        with LOCK:
            revoke()
            count = len(self._load()["people"])
            if self.root.exists():
                shutil.rmtree(self.root)
            # П10 р4 Р4-3л: и векторы, брошенные убитым движком в $TMPDIR, — для «Забыть всех» и «Стереть отпечатки».
            _drop_voice_scratch()
            return count

    # --- векторы встреч ----------------------------------------------------

    def save_pending(self, meeting: str, model: str, clusters: dict[str, dict[str, Any]], *,
                     since: int | None = None) -> None:
        """Векторы встречи на решение. `since` — эпоха начала встречи: после стирания — отказ."""
        with LOCK:
            if not current(since):
                raise VoiceMemoryRevoked(meeting)
            _write_private(self.pending_path(meeting), {
                "schema": SCHEMA + ".pending", "version": VERSION, "meeting": meeting, "model": model,
                "created": now_iso(),
                "clusters": {label: {"vector": [round(x, 6) for x in c["vector"]], "seconds": round(c["seconds"], 1)}
                             for label, c in clusters.items()},
            })

    def load_pending(self, meeting: str) -> dict[str, Any] | None:
        return self._read_pending(self.pending_path(meeting))

    def put_pending(self, meeting: str, model: str, label: str, vector: list[float], seconds: float) -> None:
        """Вектор метки снова ждёт решения (имя убрали, метки слили). Вектор другой модели в файле
        встречи не смешивается: файл переписывается под новую модель."""
        with LOCK:
            path = self.pending_path(meeting)
            pending = self._read_pending(path)
            if pending is None or pending.get("model") != model:
                pending = {"schema": SCHEMA + ".pending", "version": VERSION, "meeting": meeting, "model": model,
                           "created": now_iso(), "clusters": {}}
            clusters = dict(pending.get("clusters") or {})
            clusters[label] = {"vector": [round(x, 6) for x in normalize(vector)], "seconds": round(float(seconds), 1)}
            self._write_pending(path, pending, clusters)

    def drop_pending(self, meeting: str, label: str) -> None:
        """По метке принято решение — её вектор больше не ждёт; пустой файл удаляется."""
        path = self.pending_path(meeting)
        pending = self._read_pending(path)
        if pending is None:
            return
        clusters = dict(pending.get("clusters") or {})
        if clusters.pop(label, None) is not None:
            self._write_pending(path, pending, clusters)

    def prune_pending(self, max_days: int = PENDING_DAYS, now: _dt.datetime | None = None) -> int:
        """Удалить нерешённые векторы старше `max_days` дней. Возвращает, сколько файлов удалено."""
        now = now or _dt.datetime.now().astimezone()
        horizon = now - _dt.timedelta(days=max_days)
        removed = 0
        for path in self._pending_files():
            pending = self._read_pending(path)
            created = None
            if pending is not None:
                try:
                    created = _dt.datetime.fromisoformat(str(pending.get("created") or ""))
                except ValueError:
                    created = None
            if created is None:
                try:
                    created = _dt.datetime.fromtimestamp(path.stat().st_mtime).astimezone()
                except OSError:
                    continue
            if created.tzinfo is None:
                created = created.astimezone()
            if created < horizon:
                path.unlink(missing_ok=True)
                removed += 1
        return removed

    def _pending_files(self) -> list[Path]:
        try:
            return sorted((self.root / "pending").glob("*.json"))
        except OSError:
            return []

    @staticmethod
    def _read_pending(path: Path) -> dict[str, Any] | None:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        return data if isinstance(data, dict) else None

    @staticmethod
    def _write_pending(path: Path, pending: dict[str, Any], clusters: dict[str, Any]) -> None:
        if clusters:
            _write_private(path, {**pending, "clusters": clusters})
        else:
            path.unlink(missing_ok=True)


# --------------------------------------------------------------------------
# Встреча
# --------------------------------------------------------------------------


def speech_spans(turns: list[dict[str, Any]]) -> Spans:
    """Реплики системной дорожки по исходной метке; реплики-перекрытия («A + B») не берём."""
    spans: Spans = {}
    for turn in turns:
        label = str(turn.get("label") or "")
        if turn.get("source") != "system" or not label or SEPARATOR in label or label == ME:
            continue
        spans.setdefault(label, []).append((float(turn["start"]), float(turn["end"])))
    return spans


def remember_meeting(
    meeting: str,
    audio: Path | None,
    turns: list[dict[str, Any]],
    *,
    embedder: VoiceEmbedder | None = None,
    store: VoiceStore | None = None,
    since: int | None = None,
) -> dict[str, Any]:
    """Векторы говорящих встречи → `pending/` и подсказки «похоже на X». В расшифровку — без векторов.

    `since` — эпоха памяти на старте встречи: если память за это время стёрли или выключили,
    `VoiceMemoryRevoked` (Р2 Н7).
    """
    embedder = embedder or default_embedder()
    store = store or VoiceStore()
    if not current(since):
        raise VoiceMemoryRevoked(meeting)
    ok, detail = embedder.available()
    block: dict[str, Any] = {"enabled": True, "model": embedder.model_id, "suggestions": [], "pending": [], "short": []}
    if not ok:
        return {**block, "available": False, "detail": detail}
    spans = speech_spans(turns)
    seconds = {label: sum(end - start for start, end in items) for label, items in spans.items()}
    long_enough = {label: items for label, items in spans.items() if seconds[label] >= MIN_SPEECH_SECONDS}
    block["short"] = sorted(label for label in spans if label not in long_enough)
    if not long_enough or audio is None:
        return block
    vectors = embedder.embed(Path(audio), long_enough)
    clusters = {label: {"vector": vector, "seconds": seconds[label]} for label, vector in vectors.items()}
    if clusters:
        store.save_pending(meeting, embedder.model_id, clusters, since=since)
    elif not current(since):
        raise VoiceMemoryRevoked(meeting)
    try:
        store.prune_pending()
    except OSError:
        pass
    block["pending"] = sorted(clusters)
    suggestions: dict[str, dict[str, Any]] = {}
    for label, cluster in clusters.items():
        found = store.match(cluster["vector"], embedder.model_id)
        if not found:
            continue
        # Один человек — одна метка: оставляем самое сильное совпадение.
        rival = next((key for key, value in suggestions.items() if value["person_id"] == found["person_id"]), None)
        if rival and suggestions[rival]["score"] >= found["score"]:
            continue
        if rival:
            del suggestions[rival]
        suggestions[label] = {"label": label, **found}
    block["suggestions"] = [suggestions[label] for label in sorted(suggestions)]
    return block


def wipe(meetings_root: Path, store: VoiceStore | None = None) -> tuple[int, int]:
    """«Стереть отпечатки»: люди, образцы, векторы встреч и подсказки в `transcript.json` — одним шагом
    под `LOCK`, с новой эпохой. Возвращает (сколько было людей, сколько встреч почищено)."""
    with LOCK:
        forgotten = (store or VoiceStore()).forget_all()  # и брошенные векторы в $TMPDIR (Р4-3л)
        return forgotten, drop_person_suggestions(meetings_root, None)


def drop_person_suggestions(meetings_root: Path, person_id: str | None = None) -> int:
    """Убрать подсказки забытого человека (или всех) из `transcript.json` встреч."""
    changed = 0
    if not meetings_root.is_dir():
        return 0
    for path in meetings_root.glob("*/transcript.json"):
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        voices = document.get("voices") if isinstance(document, dict) else None
        if not isinstance(voices, dict) or not voices.get("suggestions"):
            continue
        kept = [s for s in voices["suggestions"] if person_id is not None and s.get("person_id") != person_id]
        if len(kept) == len(voices["suggestions"]):
            continue
        voices["suggestions"] = kept
        if person_id is None:
            voices["pending"] = []
        _write_json(path, document)
        changed += 1
    return changed


def _write_json(path: Path, data: Any) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
