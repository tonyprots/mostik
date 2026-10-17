"""Подсказки во время встречи (M9): на пойманный вопрос — поиск по своим источникам.

Где ищем, всё локально:
- индекс «Спросить» (`index.py`, FTS5): документы-источники и архив встреч,
  включая текст кадров окна встречи (W26), если они есть;
- словарь проекта и папок-источников (`project_glossary`, только кэш, без обхода):
  термин из вопроса → файл и строка, где он встречается.

Чего не показываем: текущую встречу (вопрос из неё же), чувствительные встречи —
карточку видно на экране, а экран во время звонка часто показывают. Найденное
должно делить с вопросом хотя бы две основы слов (одну, если в вопросе она
одна), иначе карточка — шум.

Ответ словами — только локальной моделью, если она уже загружена, бюджет памяти
не превышен и есть согласие на ИИ встреч; иначе карточка показывает фрагмент и
ссылку. Облако здесь не зовётся никогда: идёт звонок с чужими голосами.

Протокол: `meeting_hint {question, folder?, question_id?, sources?, project?,
consent?, answer?}` → ответ `{status: found|none, question, answer, answer_by,
snippet, source, more, glossary, timings}`.
"""
from __future__ import annotations

import re
import threading
import time
from pathlib import Path
from typing import Any, Iterable, Sequence

from . import ask as ask_mod
from . import index as ix
from . import meeting_folder
from . import meeting_questions as mq
from . import project_glossary as pg
from .textnorm import normalize, query_terms

SEARCH_K = 12
MORE = 2
GLOSSARY_MAX = 2
ANSWER_TIMEOUT_S = 6.0


class _Fixed:
    """Retriever с уже отобранной выдачей: модель отвечает только по показанным отрывкам."""

    name = "fixed"

    def __init__(self, hits: Sequence[ix.Hit]) -> None:
        self.hits = list(hits)

    def search(self, query: str, *, scope: str = "all", k: int = 8) -> list[ix.Hit]:
        return self.hits[:k]


def meeting_of(hit: ix.Hit) -> Path | None:
    """Папка встречи, к которой относится отрывок: реплика или текст кадров `frames/`."""
    path = Path(hit.path)
    if hit.kind == ix.KIND_MEETING:
        return path.parent
    for parent in path.parents:
        if parent.name == "frames":
            return parent.parent
    return None


def relevant(question: str, hit: ix.Hit) -> bool:
    terms = set(query_terms(question))
    if not terms:
        return False
    found = set(normalize(f"{hit.title} {hit.text}").split())
    need = 1 if len(terms) == 1 else 2
    return len(terms & found) >= need


def filter_hits(question: str, hits: Iterable[ix.Hit], *, current: Path | None) -> list[ix.Hit]:
    kept: list[ix.Hit] = []
    current_resolved = _resolve(current)
    for hit in hits:
        folder = meeting_of(hit)
        if folder is not None:
            if current_resolved is not None and _resolve(folder) == current_resolved:
                continue
            if meeting_folder.is_sensitive(folder):
                continue
        if relevant(question, hit):
            kept.append(hit)
    return kept


def _resolve(path: Path | None) -> Path | None:
    if path is None:
        return None
    try:
        return Path(path).expanduser().resolve()
    except OSError:
        return None


def glossary_hits(question: str, roots: Iterable[tuple[str, str]], limit: int = GLOSSARY_MAX) -> list[dict[str, Any]]:
    """Термины словаря проекта и папок-источников, прозвучавшие в вопросе, — где они в файлах."""
    words = question.casefold().replace("ё", "е")
    found: list[dict[str, Any]] = []
    for kind, root in roots:
        cached = pg.cached_result(root, kind)
        if not cached:
            continue
        base = Path(cached["root"])
        for entry in cached.get("entries", []):
            term = str(entry.get("term") or "")
            if len(term) < 3 or not entry.get("origins"):
                continue
            pattern = r"(?<![\w-])" + re.escape(term.casefold().replace("ё", "е")) + r"(?![\w-])"
            if not re.search(pattern, words):
                continue
            relative, _, line = str(entry["origins"][0]).rpartition(":")
            found.append({"term": term, "kind": entry.get("kind"), "path": str(base / relative),
                          "line": int(line) if line.isdigit() else None, "root": str(base),
                          "source": "repo" if kind == "repo" else "docs"})
            if len(found) >= limit:
                return found
    return found


def answer_backend(backend: Any) -> Any:
    """Локальная модель для ответа — по тем же правилам, что судья M19: загружена и в бюджете."""
    if backend is None:
        return None
    return backend if mq.Judge(backend).state()["available"] else None


def hint(question: str, *, retriever: ix.Retriever, current: Path | None = None,
         glossary_roots: Iterable[tuple[str, str]] = (), backend: Any = None, consent: bool = False,
         timeout: float = ANSWER_TIMEOUT_S) -> dict[str, Any]:
    started = time.monotonic()
    question = " ".join(str(question or "").split())
    timings: dict[str, float] = {}
    result: dict[str, Any] = {"question": question, "status": "none", "answer": None, "answer_by": None,
                              "snippet": None, "source": None, "more": [], "glossary": [], "timings": timings}
    if not question:
        return result
    search_started = time.monotonic()
    hits = filter_hits(question, retriever.search(question, scope="all", k=SEARCH_K), current=current)
    result["glossary"] = glossary_hits(question, glossary_roots)
    timings["search_ms"] = round((time.monotonic() - search_started) * 1000, 1)
    if hits:
        citations = [ask_mod.citation(hit, number) for number, hit in enumerate(hits[:1 + MORE], 1)]
        result.update(status="found", snippet=citations[0]["snippet"], source=citations[0], more=citations[1:])
        if backend is not None and consent:
            answered = ask_mod.answer(question, retriever=_Fixed(hits[:1 + MORE]), backend=backend, consent=True,
                                      timeout=timeout, k=1 + MORE)
            timings["answer_ms"] = answered.get("timings", {}).get("total_ms", 0)
            if answered.get("status") == "done" and answered.get("answer"):
                result.update(answer=answered["answer"], answer_by="local_model", used=answered.get("used", []))
    elif result["glossary"]:
        result["status"] = "found"
    timings["total_ms"] = round((time.monotonic() - started) * 1000, 1)
    return result


class HintService:
    """Команда `meeting_hint`: индекс и источники — общие со «Спросить» (`ask.service`)."""

    def __init__(self, engine: Any) -> None:
        self.engine = engine

    def hint(self, command: dict) -> None:
        question = str(command.get("question") or "").strip()
        if not question:
            raise ValueError("пустой question")
        asker = ask_mod.service(self.engine)
        asker._scope(command)
        folder = str(command.get("folder") or "")
        current = Path(folder).expanduser() if folder else None
        roots: list[tuple[str, str]] = []
        if command.get("project"):
            roots.append(("repo", str(command["project"])))
        roots.extend(("docs", root) for root in asker.roots if root != command.get("project"))
        want_answer = command.get("answer", True) is not False
        backend = answer_backend(getattr(self.engine, "polishers", {}).get("mlx")) if want_answer else None
        consent = bool(command.get("consent"))
        command_id = command.get("id")
        question_id = command.get("question_id")

        def job() -> None:
            asker.ensure_fresh(wait=True)  # первый обход ждёт до 15 с, обновление — секунду
            result = hint(question, retriever=asker.index.retriever(), current=current, glossary_roots=roots,
                          backend=backend, consent=consent)
            if current is not None and question_id and result["status"] == "found":
                source = result.get("source") or {}
                glossary = result["glossary"][0] if result["glossary"] else {}
                mq.attach_hint(current, str(question_id), {
                    "shown_at": mq._now(), "answer_by": result["answer_by"],
                    "path": source.get("path") or glossary.get("path"),
                    "ref": source.get("ref"), "line": source.get("line") or glossary.get("line"),
                    "title": source.get("title") or glossary.get("term"),
                })
            self.engine.reply(command_id, **result)

        threading.Thread(target=job, name="mostik-hint", daemon=True).start()


def service(engine: Any) -> HintService:
    existing = getattr(engine, "_hint_service", None)
    if existing is None:
        existing = HintService(engine)
        engine._hint_service = existing
    return existing
