"""Индекс «Спросить» (M8): реплики встреч и куски документов в `<home>/index.sqlite`.

Что лежит в индексе:
- реплика встречи — папка встречи, номер реплики в `transcript.json`
  (`turns`), говорящий, время от начала; ссылка `<папка>#<номер>`;
- кусок документа источника (`.md`, `.txt`, `.pdf`) — путь и первая строка
  куска; ссылка `<путь>:<строка>`.

Поиск — SQLite FTS5 с BM25 по основам слов (`textnorm`): падежи сводятся
стеммером, а не моделью. Модели эмбеддингов на машине нет, поэтому векторный
поиск — только место под него: таблица `embeddings`, интерфейс `Embedder` и
`VectorRetriever`. `HybridRetriever` сливает выдачи по рангу (RRF): когда
появится модель, её достаточно передать в `AskIndex(embedder=...)`.

Обход — инкрементальный по mtime и размеру: неизменённые файлы не читаются,
исчезнувшие удаляются из индекса. Папки обходятся так же, как словарь
источников (`project_glossary._walk`): в ширину, без архива, черновиков,
скрытого и папок с данными, не больше 2000 файлов и 20 МБ текста на источник.
"""
from __future__ import annotations

import contextlib
import datetime as _dt
import json
import math
import os
import re
import sqlite3
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Iterator, Protocol, Sequence

from . import paths
from . import project_glossary as pg
from .textnorm import normalize, query_terms

SCHEMA_VERSION = 1
CHUNK_CHARS = 700
MAX_CHUNK_CHARS = 1200
CONTEXT_CHARS = 300
# Сколько кусков одного файла или одной встречи попадает в выдачу.
PER_FILE = 3
# BM25 по колонкам FTS: заголовок (встреча и говорящий, путь и раздел), текст, соседняя реплика.
BM25_WEIGHTS = (2.0, 1.0, 0.3)
RRF_K = 60
SCOPES = ("all", "meetings", "sources")
KIND_MEETING = "meeting"
KIND_SOURCE = "source"
_SCOPE_KIND = {"meetings": KIND_MEETING, "sources": KIND_SOURCE}

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS files(
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL,
    root TEXT NOT NULL,
    path TEXT NOT NULL UNIQUE,
    mtime REAL NOT NULL,
    size INTEGER NOT NULL,
    text_bytes INTEGER NOT NULL DEFAULT 0,
    title TEXT,
    date TEXT
);
CREATE TABLE IF NOT EXISTS chunks(
    id INTEGER PRIMARY KEY,
    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    ref TEXT NOT NULL,
    title TEXT NOT NULL,
    text TEXT NOT NULL,
    context TEXT NOT NULL DEFAULT '',
    line INTEGER,
    turn INTEGER,
    speaker TEXT,
    at REAL
);
CREATE INDEX IF NOT EXISTS chunks_file ON chunks(file_id);
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    title, body, context, tokenize = 'unicode61 remove_diacritics 2'
);
-- Место под векторный поиск: одна строка на кусок и модель эмбеддингов.
CREATE TABLE IF NOT EXISTS embeddings(
    chunk_id INTEGER NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
    model TEXT NOT NULL,
    dim INTEGER NOT NULL,
    vector BLOB NOT NULL,
    PRIMARY KEY (chunk_id, model)
);
"""


def _in_sensitive_meeting(path: Path, root: Path, cache: dict[Path, bool]) -> bool:
    """Файл лежит в папке «чувствительной» встречи (Р2, низкие): папку встреч добавили источником —
    её заметки, расшифровки и кадры в индекс как источники не идут. `cache` — по папкам, на один обход."""
    from .meeting_folder import MANIFEST, MEETING_MD, is_sensitive

    for folder in path.parents:
        if folder in cache:
            if cache[folder]:
                return True
        else:
            cache[folder] = ((folder / MANIFEST).is_file() or (folder / MEETING_MD).is_file()) and is_sensitive(folder)
            if cache[folder]:
                return True
        if folder == root or folder == folder.parent:
            break
    return False


FRAMES_DIR = "frames"
FRAME_OCR_SUFFIX = ".ocr.txt"


def frame_clock(image_name: str) -> str:
    """`0412-35.jpg` → «04:12:35»/`0412.jpg` → «04:12»: имя кадра — время от начала встречи."""
    stem = image_name.rsplit(".", 1)[0]
    digits = re.sub(r"\D", "", stem)
    if len(digits) >= 6:
        return f"{digits[:2]}:{digits[2:4]}:{digits[4:6]}"
    if len(digits) >= 4:
        return f"{digits[:2]}:{digits[2:4]}"
    return stem


def index_path() -> Path:
    return paths.mostik_home() / "index.sqlite"


def meetings_root() -> Path:
    return paths.mostik_home() / "meetings"


def iso_now(timestamp: float | None = None) -> str:
    return _dt.datetime.fromtimestamp(timestamp or time.time()).astimezone().isoformat(timespec="seconds")


# --- куски ------------------------------------------------------------------------

@dataclass
class Chunk:
    kind: str
    ref: str
    title: str
    text: str
    context: str = ""
    line: int | None = None
    turn: int | None = None
    speaker: str | None = None
    at: float | None = None


def _split_long(text: str, limit: int = CHUNK_CHARS) -> list[str]:
    """Длинный абзац → куски по предложениям, не длиннее `limit` (слово длиннее — режется)."""
    text = text.strip()
    if len(text) <= MAX_CHUNK_CHARS:
        return [text] if text else []
    sentences = re.split(r"(?<=[.!?…])\s+", text)
    pieces: list[str] = []
    current = ""
    for sentence in sentences:
        while len(sentence) > MAX_CHUNK_CHARS:
            head, sentence = sentence[:limit], sentence[limit:]
            if current:
                pieces.append(current)
                current = ""
            pieces.append(head)
        if current and len(current) + 1 + len(sentence) > limit:
            pieces.append(current)
            current = sentence
        else:
            current = f"{current} {sentence}".strip()
    if current:
        pieces.append(current)
    return pieces


_HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$")


def chunk_document(text: str, *, markdown: bool) -> list[tuple[int, str, str]]:
    """Документ → куски `(первая строка, раздел, текст)`.

    Кусок — несколько абзацев подряд до ~700 знаков; заголовок Markdown
    начинает новый кусок и становится разделом для следующих. YAML-шапка
    заметки пропускается.
    """
    lines = text.splitlines()
    start = 0
    if markdown and lines and lines[0].strip() == "---":
        for number in range(1, min(len(lines), 200)):
            if lines[number].strip() in ("---", "..."):
                start = number + 1
                break
    chunks: list[tuple[int, str, str]] = []
    heading = ""
    buffer: list[str] = []
    buffer_line = 0

    def flush() -> None:
        nonlocal buffer
        body = "\n".join(buffer).strip()
        if body:
            for piece in _split_long(body):
                chunks.append((buffer_line, heading, piece))
        buffer = []

    paragraph: list[str] = []
    paragraph_line = 0

    def close_paragraph() -> None:
        nonlocal paragraph, buffer_line
        if not paragraph:
            return
        size = sum(len(line) + 1 for line in buffer)
        text_block = "\n".join(paragraph)
        if buffer and size + len(text_block) > CHUNK_CHARS:
            flush()
        if not buffer:
            buffer_line = paragraph_line
        buffer.extend(paragraph)
        paragraph = []

    for number in range(start, len(lines)):
        line = lines[number]
        match = _HEADING.match(line) if markdown else None
        if match:
            close_paragraph()
            flush()
            heading = match.group(1).strip()
            continue
        if not line.strip():
            close_paragraph()
            continue
        if not paragraph:
            paragraph_line = number + 1
        paragraph.append(line.rstrip())
    close_paragraph()
    flush()
    return chunks


def _meeting_date(folder: Path, payload: dict[str, Any]) -> _dt.datetime | None:
    for pattern in ("%Y-%m-%d-%H%M%S", "%Y-%m-%d-%H%M"):
        try:
            return _dt.datetime.strptime(folder.name, pattern)
        except ValueError:
            continue
    raw = payload.get("date")
    if isinstance(raw, str):
        try:
            return _dt.datetime.fromisoformat(raw)
        except ValueError:
            return None
    return None


def meeting_title(folder: Path, payload: dict[str, Any]) -> tuple[str, str | None]:
    """Название встречи и дата ISO: из календаря, иначе «Встреча d.mm.yyyy HH:MM»."""
    date = _meeting_date(folder, payload)
    title = " ".join(str(payload.get("title") or "").split())
    if not title:
        title = f"Встреча {date:%d.%m.%Y %H:%M}" if date else f"Встреча {folder.name}"
    return title, date.isoformat(timespec="minutes") if date else None


def raw_turns(payload: Any) -> list[Any]:
    """Реплики из `transcript.json` как есть: `turns` движка, на всякий случай `segments`/`lines` или массив.

    Номер реплики в ссылке — индекс в этом списке, пустые реплики его не сдвигают.
    """
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("turns", "segments", "lines"):
            if isinstance(payload.get(key), list):
                return payload[key]
    return []


def chunk_meeting(folder: Path, payload: Any) -> tuple[str, str | None, list[Chunk]]:
    data = payload if isinstance(payload, dict) else {}
    title, date = meeting_title(folder, data)
    chunks: list[Chunk] = []
    previous = ""
    for number, turn in enumerate(raw_turns(payload)):
        if not isinstance(turn, dict):
            continue
        text = " ".join(str(turn.get("text") or "").split())
        if not text:
            continue
        speaker = str(turn.get("speaker") or "").strip() or None
        try:
            at = float(turn.get("start") or 0.0)
        except (TypeError, ValueError):
            at = 0.0
        for piece in _split_long(text):
            chunks.append(Chunk(
                kind=KIND_MEETING, ref=f"{folder.name}#{number}", title=f"{title} · {speaker or ''}".strip(" ·"),
                text=piece, context=previous[-CONTEXT_CHARS:], turn=number, speaker=speaker, at=round(at, 2),
            ))
        previous = f"{speaker}: {text}" if speaker else text
    return title, date, chunks


# --- эмбеддинги: место под модель ---------------------------------------------------

class Embedder(Protocol):
    """Модель эмбеддингов (этап B, когда появится): имя и векторы для текстов."""

    model: str

    def embed(self, texts: Sequence[str]) -> list[list[float]]: ...


def _pack(vector: Sequence[float]) -> bytes:
    import array

    return array.array("f", vector).tobytes()


def _unpack(blob: bytes) -> list[float]:
    import array

    values = array.array("f")
    values.frombytes(blob)
    return list(values)


# --- выдача -----------------------------------------------------------------------

@dataclass
class Hit:
    chunk_id: int
    kind: str
    ref: str
    title: str
    text: str
    context: str
    path: str
    root: str
    file_title: str
    date: str | None
    line: int | None
    turn: int | None
    speaker: str | None
    at: float | None
    score: float = 0.0
    sources: list[str] = field(default_factory=list)


class Retriever(Protocol):
    """Поиск по индексу. `scope`: all | meetings | sources."""

    name: str

    def search(self, query: str, *, scope: str = "all", k: int = 8) -> list[Hit]: ...


_HIT_COLUMNS = (
    "c.id, c.kind, c.ref, c.title, c.text, c.context, f.path, f.root, f.title, f.date, c.line, c.turn, "
    "c.speaker, c.at"
)


def _hit(row: Sequence[Any], score: float, source: str) -> Hit:
    return Hit(*row, score=score, sources=[source])


def _diverse(hits: Iterable[Hit], k: int, per_file: int = PER_FILE) -> list[Hit]:
    """Не больше `per_file` кусков одного файла: одна длинная встреча не забивает выдачу."""
    taken: list[Hit] = []
    count: dict[str, int] = {}
    for hit in hits:
        if count.get(hit.path, 0) >= per_file:
            continue
        count[hit.path] = count.get(hit.path, 0) + 1
        taken.append(hit)
        if len(taken) >= k:
            break
    return taken


def _scope_clause(scope: str) -> tuple[str, list[Any]]:
    kind = _SCOPE_KIND.get(scope)
    return (" AND c.kind = ?", [kind]) if kind else ("", [])


def fts_query(query: str, *, prefix: bool = False) -> str:
    """Вопрос → запрос FTS5: основы через OR, каждая в кавычках (спецсимволы FTS не пройдут)."""
    terms = [term.replace('"', "") for term in query_terms(query)]
    return " OR ".join(f'"{term}"' + ("*" if prefix and len(term) >= 4 else "") for term in terms if term)


class LexicalRetriever:
    """BM25 по основам слов (FTS5)."""

    name = "bm25"

    def __init__(self, index: "AskIndex", *, prefix: bool = False) -> None:
        self.index = index
        self.prefix = prefix

    def search(self, query: str, *, scope: str = "all", k: int = 8) -> list[Hit]:
        match = fts_query(query, prefix=self.prefix)
        if not match:
            return []
        clause, params = _scope_clause(scope)
        weights = ", ".join(str(w) for w in BM25_WEIGHTS)
        sql = (
            f"SELECT {_HIT_COLUMNS}, bm25(chunks_fts, {weights}) AS score "
            "FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid JOIN files f ON f.id = c.file_id "
            f"WHERE chunks_fts MATCH ?{clause} ORDER BY score LIMIT ?"
        )
        with self.index.connect() as db:
            rows = db.execute(sql, [match, *params, k * 6]).fetchall()
        return _diverse((_hit(row[:-1], -float(row[-1]), self.name) for row in rows), k)


class VectorRetriever:
    """Косинусная близость по таблице `embeddings` (перебором; на десятки тысяч кусков хватает)."""

    name = "vector"

    def __init__(self, index: "AskIndex", embedder: Embedder) -> None:
        self.index = index
        self.embedder = embedder

    def search(self, query: str, *, scope: str = "all", k: int = 8) -> list[Hit]:
        vector = self.embedder.embed([query])[0]
        norm = math.sqrt(sum(v * v for v in vector)) or 1.0
        clause, params = _scope_clause(scope)
        sql = (
            f"SELECT {_HIT_COLUMNS}, e.vector FROM embeddings e JOIN chunks c ON c.id = e.chunk_id "
            f"JOIN files f ON f.id = c.file_id WHERE e.model = ?{clause}"
        )
        scored: list[tuple[float, Sequence[Any]]] = []
        with self.index.connect() as db:
            for row in db.execute(sql, [self.embedder.model, *params]):
                other = _unpack(row[-1])
                other_norm = math.sqrt(sum(v * v for v in other)) or 1.0
                cosine = sum(a * b for a, b in zip(vector, other)) / (norm * other_norm)
                scored.append((cosine, row[:-1]))
        scored.sort(key=lambda item: -item[0])
        return _diverse((_hit(row, score, self.name) for score, row in scored[: k * 6]), k)


class HybridRetriever:
    """Слияние выдач по рангу (Reciprocal Rank Fusion); с одним поиском — его порядок."""

    name = "hybrid"

    def __init__(self, retrievers: Sequence[Retriever], weights: Sequence[float] | None = None) -> None:
        self.retrievers = list(retrievers)
        self.weights = list(weights) if weights else [1.0] * len(self.retrievers)

    def search(self, query: str, *, scope: str = "all", k: int = 8) -> list[Hit]:
        fused: dict[int, Hit] = {}
        scores: dict[int, float] = {}
        for retriever, weight in zip(self.retrievers, self.weights):
            for rank, hit in enumerate(retriever.search(query, scope=scope, k=k * 2)):
                scores[hit.chunk_id] = scores.get(hit.chunk_id, 0.0) + weight / (RRF_K + rank + 1)
                if hit.chunk_id in fused:
                    fused[hit.chunk_id].sources.extend(hit.sources)
                else:
                    fused[hit.chunk_id] = hit
        ordered = sorted(fused.values(), key=lambda hit: -scores[hit.chunk_id])
        for hit in ordered:
            hit.score = round(scores[hit.chunk_id], 6)
        return _diverse(ordered, k)


# --- индекс -----------------------------------------------------------------------

# Состояния обновления: обход без находок — «checking», чтение новых и изменённых файлов — «indexing».
STATE_CHECKING = "checking"
STATE_INDEXING = "indexing"


class AskIndex:
    """Индекс в SQLite: инкрементальное обновление в фоне, поиск из любого потока."""

    def __init__(self, path: str | Path | None = None, *, embedder: Embedder | None = None) -> None:
        self.path = Path(path) if path else index_path()
        self.embedder = embedder
        self._refresh_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._state: dict[str, Any] = {"state": "idle"}
        self._init()

    # Соединение — своё на каждый вызов и закрывается сразу; WAL: читатели не ждут писателя.
    @contextlib.contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(self.path, timeout=30, isolation_level=None, check_same_thread=False)
        try:
            db.execute("PRAGMA foreign_keys = ON")
            db.execute("PRAGMA secure_delete = ON")  # П10: удалённые отрывки не остаются на свободных страницах
            db.execute("PRAGMA busy_timeout = 30000")
            yield db
        finally:
            db.close()

    def _init(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.execute("PRAGMA journal_mode = WAL")
            version = None
            try:
                row = db.execute("SELECT value FROM meta WHERE key = 'schema'").fetchone()
                version = int(row[0]) if row else None
            except sqlite3.DatabaseError:
                version = None
            if version not in (None, SCHEMA_VERSION):
                for table in ("embeddings", "chunks_fts", "chunks", "files", "meta"):
                    db.execute(f"DROP TABLE IF EXISTS {table}")
            db.executescript(_SCHEMA)
            db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('schema', ?)", (str(SCHEMA_VERSION),))
            # Р2, низкие: удаление из FTS5 стирает и токены в сегментах, а не только помечает их удалёнными.
            # Нужен SQLite ≥ 3.44 (встроенный Python — 3.53); старее — токены уходят при слиянии сегментов.
            try:
                db.execute("INSERT INTO chunks_fts(chunks_fts, rank) VALUES ('secure-delete', 1)")
            except sqlite3.DatabaseError:
                pass

    def _meta(self, db: sqlite3.Connection, key: str) -> str | None:
        row = db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None

    def retriever(self) -> Retriever:
        lexical = LexicalRetriever(self)
        if self.embedder is None:
            return HybridRetriever([lexical])
        return HybridRetriever([lexical, VectorRetriever(self, self.embedder)])

    # --- состояние ---

    def status(self) -> dict[str, Any]:
        with self.connect() as db:
            counts = dict(db.execute("SELECT kind, COUNT(*) FROM files GROUP BY kind").fetchall())
            chunks = dict(db.execute("SELECT kind, COUNT(*) FROM chunks GROUP BY kind").fetchall())
            updated = self._meta(db, "updated_ts")
            roots = json.loads(self._meta(db, "roots") or "[]")
            truncated = json.loads(self._meta(db, "truncated") or "[]")
            vectors = db.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0]
        with self._state_lock:
            state = dict(self._state)
        return {
            "state": state.get("state", "idle"),
            "meetings": int(counts.get(KIND_MEETING, 0)),
            "documents": int(counts.get(KIND_SOURCE, 0)),
            "chunks": int(sum(chunks.values())),
            "replies": int(chunks.get(KIND_MEETING, 0)),
            "passages": int(chunks.get(KIND_SOURCE, 0)),
            "updated_at": iso_now(float(updated)) if updated else None,
            "updated_ts": float(updated) if updated else None,
            "roots": roots,
            "truncated": truncated,
            "vector": bool(self.embedder) and vectors > 0,
            **({"error": state["error"]} if state.get("error") else {}),
            **({"progress": state["progress"]} if state.get("progress") else {}),
            **({"seconds": state["seconds"]} if "seconds" in state else {}),
        }

    def age(self) -> float | None:
        """Сколько секунд прошло с последнего обновления; None — индекс ещё не строился."""
        with self.connect() as db:
            updated = self._meta(db, "updated_ts")
        return time.time() - float(updated) if updated else None

    def busy(self) -> bool:
        thread = self._thread
        return thread is not None and thread.is_alive()

    # --- обновление ---

    def refresh_async(self, roots: Iterable[str], *, meetings: str | Path | None = None,
                      force: bool = False) -> threading.Thread:
        """Обновление в фоне; если уже идёт — возвращает идущий поток."""
        roots = list(roots)
        with self._state_lock:
            if self._thread is not None and self._thread.is_alive():
                return self._thread
            # «checking» — тихий обход: в интерфейсе ничего не мигает, пока не нашлось новое или изменённое.
            self._state = {"state": STATE_CHECKING}
            thread = threading.Thread(target=self._refresh_job, args=(roots, meetings, force),
                                      name="mostik-ask-index", daemon=True)
            self._thread = thread
        thread.start()
        return thread

    def _refresh_job(self, roots: list[str], meetings: str | Path | None, force: bool) -> None:
        try:
            self.refresh(roots, meetings=meetings, force=force)
        except Exception as error:  # noqa: BLE001 — индекс не роняет движок
            with self._state_lock:
                self._state = {"state": "error", "error": f"{type(error).__name__}: {error}"}

    def refresh(self, roots: Iterable[str], *, meetings: str | Path | None = None,
                force: bool = False) -> dict[str, Any]:
        """Синхронное обновление: встречи и папки источников. Возвращает счётчики прохода."""
        started = time.monotonic()
        with self._refresh_lock:
            with self._state_lock:
                self._state = {"state": STATE_CHECKING}
            meetings_dir = Path(meetings).expanduser() if meetings else meetings_root()
            clean_roots: list[str] = []
            for root in roots:
                try:
                    resolved = str(Path(root).expanduser().resolve())
                except OSError:
                    continue
                if resolved not in clean_roots:
                    clean_roots.append(resolved)
            stats = {"added": 0, "updated": 0, "removed": 0, "unchanged": 0}
            with self.connect() as db:
                if force:
                    self._clear(db)
                known = {row[0]: (row[1], row[2], row[3], row[4]) for row in
                         db.execute("SELECT path, id, mtime, size, text_bytes FROM files")}
                seen: set[str] = set()
                self._refresh_meetings(db, meetings_dir, known, seen, stats)
                truncated: list[str] = []
                for root in clean_roots:
                    if self._refresh_root(db, Path(root), known, seen, stats):
                        truncated.append(root)
                for path, (file_id, *_rest) in known.items():
                    if path not in seen:
                        self._delete_file(db, file_id)
                        stats["removed"] += 1
                now = time.time()
                for key, value in (("updated_ts", str(now)), ("roots", json.dumps(clean_roots, ensure_ascii=False)),
                                   ("truncated", json.dumps(truncated, ensure_ascii=False))):
                    db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", (key, value))
            seconds = round(time.monotonic() - started, 3)
            with self._state_lock:
                self._state = {"state": "idle", "seconds": seconds}
            return {**stats, "seconds": seconds, "truncated": truncated}

    def _clear(self, db: sqlite3.Connection) -> None:
        db.execute("BEGIN")
        db.execute("DELETE FROM chunks_fts")
        db.execute("DELETE FROM embeddings")
        db.execute("DELETE FROM chunks")
        db.execute("DELETE FROM files")
        db.execute("COMMIT")

    def _progress(self, text: str) -> None:
        with self._state_lock:
            self._state = {"state": STATE_INDEXING, "progress": text}

    def _refresh_meetings(self, db: sqlite3.Connection, root: Path, known: dict, seen: set[str],
                          stats: dict[str, int]) -> None:
        try:
            folders = sorted((item for item in root.iterdir() if item.is_dir()), key=lambda p: p.name, reverse=True)
        except OSError:
            return
        for folder in folders:
            # Текст кадров окна встречи (W26), распознанный на Mac, — ищется как документ встречи.
            self._refresh_frames(db, root, folder, known, seen, stats)
            path = folder / "transcript.json"
            try:
                stat = path.stat()
            except OSError:
                continue
            key = str(path)
            seen.add(key)
            previous = known.get(key)
            if previous and previous[1] == stat.st_mtime and previous[2] == stat.st_size:
                stats["unchanged"] += 1
                continue
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                payload = {}
            title, date, chunks = chunk_meeting(folder, payload)
            self._progress(title)
            self._store(db, previous[0] if previous else None, KIND_MEETING, str(root), key, stat, stat.st_size,
                        title, date, chunks)
            stats["updated" if previous else "added"] += 1

    def _refresh_frames(self, db: sqlite3.Connection, root: Path, folder: Path, known: dict, seen: set[str],
                        stats: dict[str, int]) -> None:
        """`frames/*.ocr.txt` (W26): один файл — один кадр; в выдаче — путь к картинке кадра.

        Кадры встречи «только на этом Mac» индексируются, как и её расшифровка: их видит только
        локальная модель, облаку и агентам выдачу режет `privacy.drop_sensitive` по пути.
        """
        frames = folder / FRAMES_DIR
        try:
            files = sorted(frames.glob("*" + FRAME_OCR_SUFFIX))
        except OSError:
            return
        if not files:
            return
        try:
            manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            manifest = {}
        title, date = meeting_title(folder, manifest if isinstance(manifest, dict) else {})
        for path in files:
            try:
                stat = path.stat()
            except OSError:
                continue
            key = str(path)
            seen.add(key)
            previous = known.get(key)
            if previous and previous[1] == stat.st_mtime and previous[2] == stat.st_size:
                stats["unchanged"] += 1
                continue
            text = _read_text(path)
            image = path.name[: -len(FRAME_OCR_SUFFIX)]
            label = f"{title} · кадр {frame_clock(image)}"
            self._progress(label)
            chunks = [
                Chunk(kind=KIND_SOURCE, ref=f"{frames / image}:{line}", title=label, text=body, line=line)
                for line, _heading, body in chunk_document(text, markdown=False)
            ]
            self._store(db, previous[0] if previous else None, KIND_SOURCE, str(root), key, stat,
                        len(text.encode("utf-8")), label, date, chunks)
            stats["updated" if previous else "added"] += 1

    def _refresh_root(self, db: sqlite3.Connection, root: Path, known: dict, seen: set[str],
                      stats: dict[str, int]) -> bool:
        """Одна папка источника; True — упёрлись в лимит файлов или текста."""
        if not root.is_dir():
            return False
        files = 0
        text_bytes = 0
        sensitive: dict[Path, bool] = {}
        for path, kind in pg._walk(root, "docs"):
            if files >= pg.MAX_FILES or text_bytes >= pg.MAX_TEXT_BYTES:
                return True
            if _in_sensitive_meeting(path, root, sensitive):
                continue
            try:
                stat = path.stat()
            except OSError:
                continue
            ceiling = pg.MAX_PDF_BYTES if kind == "pdf" else pg.MAX_DOC_BYTES
            if stat.st_size > ceiling:
                continue
            key = str(path)
            if key in seen:  # папка внутри другого источника
                continue
            seen.add(key)
            files += 1
            previous = known.get(key)
            if previous and previous[1] == stat.st_mtime and previous[2] == stat.st_size:
                text_bytes += int(previous[3] or 0)
                stats["unchanged"] += 1
                continue
            text = pg._pdf_text(path) if kind == "pdf" else _read_text(path)
            size = len(text.encode("utf-8"))
            text_bytes += size
            relative = str(path.relative_to(root))
            label = f"{root.name}/{relative}"
            chunks = [
                Chunk(kind=KIND_SOURCE, ref=f"{path}:{line}", title=f"{label} · {heading}" if heading else label,
                      text=body, line=line)
                for line, heading, body in chunk_document(text, markdown=kind == "markdown")
            ]
            self._progress(label)
            self._store(db, previous[0] if previous else None, KIND_SOURCE, str(root), key, stat, size,
                        label, None, chunks)
            stats["updated" if previous else "added"] += 1
        return False

    def _delete_file(self, db: sqlite3.Connection, file_id: int) -> None:
        db.execute("BEGIN")
        self._delete_chunks(db, file_id)
        db.execute("DELETE FROM files WHERE id = ?", (file_id,))
        db.execute("COMMIT")

    @staticmethod
    def _delete_chunks(db: sqlite3.Connection, file_id: int) -> None:
        ids = [row[0] for row in db.execute("SELECT id FROM chunks WHERE file_id = ?", (file_id,))]
        db.executemany("DELETE FROM chunks_fts WHERE rowid = ?", [(chunk_id,) for chunk_id in ids])
        db.execute("DELETE FROM embeddings WHERE chunk_id IN (SELECT id FROM chunks WHERE file_id = ?)", (file_id,))
        db.execute("DELETE FROM chunks WHERE file_id = ?", (file_id,))

    def _store(self, db: sqlite3.Connection, file_id: int | None, kind: str, root: str, path: str,
               stat: os.stat_result, text_bytes: int, title: str, date: str | None, chunks: list[Chunk]) -> None:
        """Файл и его куски — одной транзакцией: поиск не видит полуобновлённый файл."""
        vectors: list[list[float]] = []
        if self.embedder is not None and chunks:
            vectors = self.embedder.embed([f"{chunk.title}\n{chunk.text}" for chunk in chunks])
        db.execute("BEGIN")
        try:
            if file_id is not None:
                self._delete_chunks(db, file_id)
                db.execute("UPDATE files SET kind=?, root=?, mtime=?, size=?, text_bytes=?, title=?, date=? WHERE id=?",
                           (kind, root, stat.st_mtime, stat.st_size, text_bytes, title, date, file_id))
            else:
                file_id = db.execute(
                    "INSERT INTO files(kind, root, path, mtime, size, text_bytes, title, date) VALUES (?,?,?,?,?,?,?,?)",
                    (kind, root, path, stat.st_mtime, stat.st_size, text_bytes, title, date),
                ).lastrowid
            for number, chunk in enumerate(chunks):
                chunk_id = db.execute(
                    "INSERT INTO chunks(file_id, kind, ref, title, text, context, line, turn, speaker, at) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (file_id, chunk.kind, chunk.ref, chunk.title, chunk.text, chunk.context, chunk.line, chunk.turn,
                     chunk.speaker, chunk.at),
                ).lastrowid
                db.execute("INSERT INTO chunks_fts(rowid, title, body, context) VALUES (?,?,?,?)",
                           (chunk_id, normalize(chunk.title), normalize(chunk.text), normalize(chunk.context)))
                if vectors:
                    vector = vectors[number]
                    db.execute("INSERT INTO embeddings(chunk_id, model, dim, vector) VALUES (?,?,?,?)",
                               (chunk_id, self.embedder.model, len(vector), _pack(vector)))
            db.execute("COMMIT")
        except Exception:
            db.execute("ROLLBACK")
            raise


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return ""
