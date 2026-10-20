"""Личный словарь Mostik: `MOSTIK_HOME/glossary.yaml` в формате transcriber.

Записи — те же `canonical / aliases / auto_apply`, что читает
`glossary.parse_entries`; служебные поля `source` и `language` он игнорирует.
`remember` пишет алиас с автозаменой (§12.4). При первом запуске словарь
заполняется из transcriber: выверенный `drafts/personal-glossary.yaml` поверх
выученного `~/.transcriber/glossary.yaml` (и `glossary.en.yaml` для en).
"""
from __future__ import annotations

import os
import tempfile
import threading
from pathlib import Path
from typing import Any

import yaml

from . import paths

from audio_transcription.glossary import GlossaryEntry, merge_glossaries, parse_entries  # noqa: E402

def _curated_source() -> Path | None:
    """Выверенный словарь transcriber: `MOSTIK_CURATED_GLOSSARY` или `drafts/` соседнего репозитория.

    В .app его нет — у нового пользователя своего выверенного словаря нет.
    """
    raw = os.environ.get("MOSTIK_CURATED_GLOSSARY")
    if raw:
        return Path(raw).expanduser()
    repo = paths.transcriber_repo()
    return repo / "drafts" / "personal-glossary.yaml" if repo is not None else None


CURATED_SOURCE = _curated_source()
_LOADER = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
# Пара в словарь приходит фрагментом текста («там три,» → «3,»): знаки на краях — запись,
# а не термин. Канон без букв — число, а не название; длиннее пяти слов — фраза, а не термин.
_EDGE_PUNCTUATION = ".,;:!?…"
MAX_TERM_WORDS = 5


def clean_pair(heard: str, canonical: str) -> tuple[str, str] | None:
    """Пара «как слышится → как пишется», пригодная для словаря, или None."""
    heard = str(heard or "").strip().strip(_EDGE_PUNCTUATION).strip()
    canonical = str(canonical or "").strip().strip(_EDGE_PUNCTUATION).strip()
    if not any(char.isalpha() for char in canonical):
        return None
    if len(canonical.split()) > MAX_TERM_WORDS or len(heard.split()) > MAX_TERM_WORDS:
        return None
    return heard, canonical


def _read(path: Path) -> Any:
    return yaml.load(path.read_text(encoding="utf-8"), Loader=_LOADER) or {}


def _raw_entries(payload: Any) -> list[dict]:
    raw = payload.get("entries", []) if isinstance(payload, dict) else payload
    return [item for item in raw or [] if isinstance(item, dict) and item.get("canonical")]


def _learned_store(language: str) -> Path | None:
    """Где transcriber держит выученный словарь — его же правилом."""
    try:
        from audio_transcription.glossary_store import store_path

        return store_path(language=language)
    except Exception:  # noqa: BLE001 — нет transcriber — нечего импортировать
        return None


def _as_record(entry: GlossaryEntry, source: str, language: str | None) -> dict[str, Any]:
    record: dict[str, Any] = {
        "canonical": entry.canonical,
        "aliases": list(entry.aliases),
        "auto_apply": entry.auto_apply,
        "source": source,
    }
    if entry.case_sensitive:
        record["case_sensitive"] = True
    if entry.context:
        record["context"] = entry.context
    if language:
        record["language"] = language
    return record


class PersonalGlossary:
    def __init__(self, path: Path | None = None, *, import_transcriber: bool | None = None) -> None:
        self.path = path or paths.personal_glossary_path()
        if import_transcriber is None:
            import_transcriber = os.environ.get("MOSTIK_IMPORT_TRANSCRIBER", "1") != "0"
        self.import_transcriber = import_transcriber
        self._lock = threading.Lock()
        self._doc: dict[str, Any] | None = None
        self._mtime: float | None = None

    # --- файл -------------------------------------------------------------

    def _load(self) -> dict[str, Any]:
        if not self.path.exists():
            doc: dict[str, Any] = {"version": 1, "entries": []}
            if self.import_transcriber:
                doc = self._import(doc)
            self._save(doc)
        mtime = self.path.stat().st_mtime
        if self._doc is None or mtime != self._mtime:
            payload = _read(self.path)
            if not isinstance(payload, dict):
                payload = {"version": 1, "entries": payload or []}
            payload.setdefault("version", 1)
            payload["entries"] = _raw_entries(payload)
            self._doc, self._mtime = payload, mtime
        return self._doc

    def _save(self, doc: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp = tempfile.mkstemp(prefix=".glossary-", suffix=".yaml", dir=self.path.parent)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            yaml.safe_dump(doc, handle, allow_unicode=True, sort_keys=False)
        os.chmod(temp, 0o600)
        os.replace(temp, self.path)
        self._doc, self._mtime = doc, self.path.stat().st_mtime

    def _import(self, doc: dict[str, Any]) -> dict[str, Any]:
        """Первый запуск: забираем словари transcriber, выверенный — главнее."""
        imported: list[str] = []
        records: list[dict[str, Any]] = []
        for language in ("ru", "en"):
            curated: list[GlossaryEntry] = []
            if language == "ru" and CURATED_SOURCE is not None and CURATED_SOURCE.is_file():
                try:
                    curated = parse_entries(_read(CURATED_SOURCE))
                    imported.append(str(CURATED_SOURCE))
                except (OSError, ValueError, yaml.YAMLError):
                    curated = []
            learned: list[GlossaryEntry] = []
            store = _learned_store(language)
            if store is not None and store.is_file():
                try:
                    learned = parse_entries(_raw_entries(_read(store)))
                    imported.append(str(store))
                except (OSError, ValueError, yaml.YAMLError):
                    learned = []
            curated_names = {entry.canonical for entry in curated}
            for entry in merge_glossaries(curated, learned):
                source = "transcriber" if entry.canonical in curated_names else "transcriber-learned"
                records.append(_as_record(entry, source, language))
        doc["entries"] = records
        doc["imported_from"] = imported
        return doc

    # --- чтение -----------------------------------------------------------

    def entries(self, language: str | None = None) -> list[GlossaryEntry]:
        with self._lock:
            raw = [
                item
                for item in self._load()["entries"]
                if language is None or item.get("language") in (None, language)
            ]
        return parse_entries(raw)

    def trusted(self, language: str | None = None) -> list[GlossaryEntry]:
        """Записи для фильтра сомнений: утверждённые человеком или с автозаменой.

        Невыученное до конца (learned без `auto_apply`) несёт алиасы вроде
        «мест» и «лист»: по ним обычные слова становились «терминами», и
        сомнением оказывалось почти каждое расхождение (10 из 12 на минуте).
        """
        with self._lock:
            raw = [
                item
                for item in self._load()["entries"]
                if (language is None or item.get("language") in (None, language))
                and (item.get("auto_apply") or item.get("source") != "transcriber-learned")
            ]
        return parse_entries(raw)

    def hotwords(self, language: str, limit: int = 30) -> list[str]:
        """Каноны, которые человек утвердил сам: выученное в подсказку не идёт."""
        with self._lock:
            raw = self._load()["entries"]
        picked: list[str] = []
        for item in reversed(raw):  # свежие `remember` — в конце файла
            if item.get("language") not in (None, language):
                continue
            if item.get("source") == "transcriber-learned":
                continue
            canonical = str(item["canonical"])
            if canonical not in picked:
                picked.append(canonical)
            if len(picked) >= limit:
                break
        return picked

    def list(self) -> list[dict[str, Any]]:
        with self._lock:
            raw = self._load()["entries"]
        return [
            {
                "canonical": str(item["canonical"]),
                "aliases": [str(alias) for alias in item.get("aliases", [])],
                "source": str(item.get("source", "personal")),
                "auto_apply": bool(item.get("auto_apply", False)),
                "language": item.get("language"),
            }
            for item in raw
        ]

    # --- запись -----------------------------------------------------------

    def remember(self, heard: str, canonical: str, language: str | None = None) -> None:
        if not canonical.strip():
            raise ValueError("canonical пустой")
        self.remember_many([(heard, canonical)], language)

    def remember_many(self, pairs: list[tuple[str, str]], language: str | None = None) -> int:
        """Несколько пар «как слышится → как пишется» одной записью файла (импорт, L6).

        Пустой `heard` — термин без замены: он идёт в подсказку модели. Возвращает,
        сколько пар записано (пары, не прошедшие `clean_pair`, пропускаются)."""
        written = 0
        with self._lock:
            doc = self._load()
            for heard, canonical in pairs:
                pair = clean_pair(heard, canonical)
                if pair is None:
                    continue
                self._remember(doc, *pair, language)
                written += 1
            if written:
                self._save(doc)
        return written

    @staticmethod
    def _remember(doc: dict[str, Any], heard: str, canonical: str, language: str | None) -> None:
        entries = doc["entries"]
        target = next(
            (
                item
                for item in entries
                if str(item["canonical"]) == canonical
                and item.get("language") in (None, language)
            ),
            None,
        )
        # Алиас, занятый другим каноном, переезжает: решение человека
        # свежее любой выученной записи.
        folded = heard.casefold()
        for item in entries:
            if item is target or not heard:
                continue
            aliases = [a for a in item.get("aliases", []) if str(a).casefold() != folded]
            if len(aliases) != len(item.get("aliases", [])):
                item["aliases"] = aliases
        doc["entries"] = [
            item for item in entries if item is target or item.get("aliases")
            or item.get("source") != "transcriber-learned"
        ]
        if target is None:
            target = {"canonical": canonical, "aliases": [], "auto_apply": True, "source": "personal"}
            if language:
                target["language"] = language
            doc["entries"].append(target)
        if heard and heard.casefold() not in {str(a).casefold() for a in target["aliases"]}:
            target["aliases"].append(heard)
        target["auto_apply"] = True
        if target.get("source") == "transcriber-learned":
            target["source"] = "personal"

    def forget(self, canonical: str) -> bool:
        with self._lock:
            doc = self._load()
            before = len(doc["entries"])
            doc["entries"] = [item for item in doc["entries"] if str(item["canonical"]) != canonical]
            changed = len(doc["entries"]) != before
            if changed:
                self._save(doc)
            return changed
