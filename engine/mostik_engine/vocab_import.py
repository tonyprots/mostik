"""Импорт словаря из других диктовок (L6): Handy, Wispr Flow, CSV, строки из буфера.

Файлы чужих приложений только читаются:

- **Handy** — `~/Library/Application Support/com.pais.handy/settings_store.json`,
  поле `settings.custom_words` (список слов). Остальное в файле (ключи API и пр.)
  не трогаем и никуда не выводим.
- **Wispr Flow** — `~/Library/Application Support/Wispr Flow/flow.sqlite`, таблица
  `Dictionary(phrase, replacement, isDeleted, isSnippet)`. Сама база не открывается:
  она и её `-wal` копируются во временную папку, читается копия с `query_only`,
  копия удаляется. Удалённые строки и сниппеты пропускаются. Строка с `replacement` —
  это «слышится как `phrase`, пишется `replacement`», без него — просто термин.
  Формат сверен с открытыми импортёрами (TypeWhisper, EnviousWispr): на этой машине
  Wispr Flow не установлен, поэтому чтение проверено на синтетической базе.
- **CSV** — одна колонка: термины; две: «как слышится, как пишется». Заголовок
  пропускается, если похож на заголовок.
- **Строки** — «добавить слова из буфера построчно»: строка — термин, или
  «как слышится → как пишется» (также `->` и `=>`).

Ограничения: 25 000 строк, 8 МБ на JSON и CSV, 100 знаков на слово.
"""
from __future__ import annotations

import csv
import io
import json
import shutil
import sqlite3
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

MAX_ROWS = 25_000
MAX_TEXT_BYTES = 8 * 1024 * 1024
MAX_WORD = 100
SUPPORT = Path.home() / "Library" / "Application Support"
DEFAULT_PATHS = {
    "handy": SUPPORT / "com.pais.handy" / "settings_store.json",
    "wispr": SUPPORT / "Wispr Flow" / "flow.sqlite",
}
_HEADERS = {"phrase", "term", "terms", "word", "words", "original", "heard", "слово", "слова", "термин",
            "термины", "как слышится", "как пишется", "spelling", "replacement"}
_ARROWS = ("→", "->", "=>")


class VocabImportError(ValueError):
    """Файл не того формата или слишком большой; текст — для пользователя."""


@dataclass(frozen=True)
class ImportEntry:
    canonical: str
    heard: str = ""

    def to_dict(self) -> dict[str, str]:
        return {"canonical": self.canonical, "heard": self.heard}


def _clean(text: object) -> str:
    return " ".join(str(text or "").replace("\0", "").split())


def _entry(canonical: object, heard: object = "") -> ImportEntry | None:
    canonical, heard = _clean(canonical), _clean(heard)
    if not canonical or len(canonical) > MAX_WORD or len(heard) > MAX_WORD:
        return None
    if heard.casefold() == canonical.casefold() and heard == canonical:
        heard = ""
    return ImportEntry(canonical, heard)


def _dedupe(entries: Iterable[ImportEntry | None]) -> list[ImportEntry]:
    seen: set[tuple[str, str]] = set()
    out: list[ImportEntry] = []
    for entry in entries:
        if entry is None:
            continue
        key = (entry.canonical, entry.heard.casefold())
        if key in seen:
            continue
        seen.add(key)
        out.append(entry)
        if len(out) > MAX_ROWS:
            raise VocabImportError(f"больше {MAX_ROWS} строк")
    return out


def _read_text(path: Path) -> str:
    if not path.is_file():
        raise VocabImportError(f"нет файла {path}")
    if path.stat().st_size > MAX_TEXT_BYTES:
        raise VocabImportError("файл больше 8 МБ")
    return path.read_text(encoding="utf-8-sig")


def read_handy(path: Path | None = None) -> list[ImportEntry]:
    path = Path(path or DEFAULT_PATHS["handy"])
    try:
        payload = json.loads(_read_text(path))
    except ValueError as error:
        raise VocabImportError(f"не JSON: {error}") from None
    settings = payload.get("settings") if isinstance(payload, dict) else None
    words = settings.get("custom_words") if isinstance(settings, dict) else None
    if words is None:
        return []
    if not isinstance(words, list):
        raise VocabImportError("custom_words — не список")
    return _dedupe(_entry(word) for word in words if isinstance(word, str))


def read_wispr(path: Path | None = None) -> list[ImportEntry]:
    path = Path(path or DEFAULT_PATHS["wispr"])
    if not path.is_file() or path.is_symlink():
        raise VocabImportError(f"нет файла {path}")
    with tempfile.TemporaryDirectory(prefix="mostik-wispr-") as folder:
        copy = Path(folder) / "flow.sqlite"
        shutil.copyfile(path, copy)
        for suffix in ("-wal", "-shm"):
            side = path.with_name(path.name + suffix)
            if side.is_file() and not side.is_symlink():
                shutil.copyfile(side, copy.with_name(copy.name + suffix))
        connection = sqlite3.connect(str(copy))
        try:
            connection.execute("PRAGMA trusted_schema=OFF")
            connection.execute("PRAGMA query_only=ON")
            rows = connection.execute(
                "SELECT phrase, replacement, isDeleted, isSnippet FROM Dictionary ORDER BY id LIMIT ?",
                (MAX_ROWS + 1,),
            ).fetchall()
        except sqlite3.DatabaseError as error:
            raise VocabImportError(f"не база Wispr Flow: {error}") from None
        finally:
            connection.close()
    if len(rows) > MAX_ROWS:
        raise VocabImportError(f"больше {MAX_ROWS} строк")
    entries: list[ImportEntry | None] = []
    for phrase, replacement, deleted, snippet in rows:
        if deleted or snippet or not isinstance(phrase, str):
            continue
        replacement = replacement if isinstance(replacement, str) else ""
        if _clean(replacement):
            entries.append(_entry(replacement, phrase))
        else:
            entries.append(_entry(phrase))
    return _dedupe(entries)


def parse_csv(text: str) -> list[ImportEntry]:
    if len(text.encode("utf-8")) > MAX_TEXT_BYTES:
        raise VocabImportError("текст больше 8 МБ")
    rows = [row for row in csv.reader(io.StringIO(text.lstrip("﻿"))) if any(cell.strip() for cell in row)]
    if rows and all(_clean(cell).casefold() in _HEADERS for cell in rows[0] if _clean(cell)):
        rows = rows[1:]
    entries: list[ImportEntry | None] = []
    for row in rows:
        cells = [cell for cell in row if cell.strip()]
        if len(cells) == 1:
            entries.append(_entry(cells[0]))
        elif len(cells) >= 2:
            entries.append(_entry(cells[1], cells[0]))
    return _dedupe(entries)


def read_csv(path: Path) -> list[ImportEntry]:
    return parse_csv(_read_text(Path(path)))


def parse_lines(text: str) -> list[ImportEntry]:
    """Строка — термин; «как слышится → как пишется» — замена."""
    if len(text.encode("utf-8")) > MAX_TEXT_BYTES:
        raise VocabImportError("текст больше 8 МБ")
    entries: list[ImportEntry | None] = []
    for line in text.splitlines():
        line = line.strip().lstrip("-•*").strip()
        if not line:
            continue
        for arrow in _ARROWS:
            if arrow in line:
                heard, canonical = line.split(arrow, 1)
                entries.append(_entry(canonical, heard))
                break
        else:
            entries.append(_entry(line))
    return _dedupe(entries)


def detect() -> dict[str, bool]:
    """Какие файлы есть на месте — только по метаданным, содержимое не читается."""
    return {name: path.is_file() and not path.is_symlink() for name, path in DEFAULT_PATHS.items()}


def load(source: str, *, path: str | None = None, text: str | None = None) -> list[ImportEntry]:
    if source == "handy":
        return read_handy(Path(path) if path else None)
    if source == "wispr":
        return read_wispr(Path(path) if path else None)
    if source == "csv":
        if text is not None:
            return parse_csv(text)
        if not path:
            raise VocabImportError("нужен путь к CSV")
        return read_csv(Path(path))
    if source == "lines":
        return parse_lines(text or "")
    raise VocabImportError(f"источник {source!r}: ожидается handy, wispr, csv или lines")


def split_new(entries: list[ImportEntry], existing: list[dict]) -> tuple[list[ImportEntry], int]:
    """Новые записи и число дублей: канон уже есть и (если есть «как слышится») алиас тоже."""
    known: dict[str, set[str]] = {}
    for item in existing:
        known.setdefault(str(item["canonical"]), set()).update(str(a).casefold() for a in item.get("aliases", []))
    fresh: list[ImportEntry] = []
    duplicates = 0
    for entry in entries:
        aliases = known.get(entry.canonical)
        if aliases is not None and (not entry.heard or entry.heard.casefold() in aliases):
            duplicates += 1
        else:
            fresh.append(entry)
    return fresh, duplicates
