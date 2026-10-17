"""Словарь источника: репозиторий (§12.15) или папка документов (S2, S3).

Репозиторий: имена функций, классов, модулей и файлов из кода, зависимости из
манифестов, Markdown-файлы по правилам документов (README, AGENTS.md, docs/).
Папка документов: `.md`, `.markdown`, `.txt`, `.pdf` (через `pdftotext`, если
он есть). Правила извлечения из текста — в `extract`.

У каждого термина есть вид (`person`, `project`, `tech`, `acronym`,
`identifier`) и происхождение — `"<относительный путь>:<строка>"`.

Кэш — `MOSTIK_HOME/projects/<sha1 корня>.json`:
`{version, root, kind, scanned_at, scanned_ts, files_count, truncated, counts, terms: [{term, kind, origins}]}`.
Рядом `<sha1 корня>.files.json`: по каждому файлу mtime, размер и найденные
термины, поэтому повторный обход перечитывает только изменённые файлы, а
старт сессии читает маленький основной файл. Обход целиком не чаще раза в
`max_age_s` (10 минут для сессий и `sources`), если не пришёл `rescan`.

Корнем бывает не репозиторий, а рабочая папка агента — например,
общая папка с десятками проектов. Поэтому обход идёт в
ширину (ближние к корню файлы первыми, на каждом уровне — свежие папки
первыми), пропускает архив, черновики, скрытое и папки с данными, а лимит
2000 файлов и 20 МБ текста обрезает самое глубокое и старое.
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import json
import functools
import os
import re
import shutil
import stat
import subprocess
import threading
import time
import tomllib
from collections import Counter, deque
from pathlib import Path
from typing import Any

from . import paths
from .extract import KINDS, rejected, shape_kind, terms_from_document
from .wordlists import CODE_COMMON

CACHE_VERSION = 2
LIMIT = 2000
MIN_LENGTH = 3
RESCAN_AFTER_S = 600.0
MAX_ORIGINS = 3
MAX_FILES = 2000
MAX_TEXT_BYTES = 20 * 1024 * 1024
SOURCE_EXTENSIONS = frozenset(
    {".py", ".swift", ".ts", ".tsx", ".js", ".go", ".rs", ".kt", ".java", ".rb"}
)
DOC_EXTENSIONS = frozenset({".md", ".markdown", ".txt", ".pdf"})
MARKDOWN_EXTENSIONS = frozenset({".md", ".markdown"})
HEADING_FILES = ("AGENTS.md", "CLAUDE.md")
MANIFESTS = frozenset({"package.json", "pyproject.toml", "Cargo.toml", "go.mod"})
EXCLUDED_DIRS = frozenset(
    {".git", "node_modules", ".venv", "build", "dist", ".build", "__pycache__", ".worktrees",
     "venv", ".mypy_cache", ".pytest_cache", ".tox", "target", "Pods", "DerivedData", ".obsidian",
     "06_archive", "drafts", ".claude"}
)
# Папка с данными: много файлов, и почти все — выгрузки, картинки, звук.
DATA_EXTENSIONS = frozenset(
    {".json", ".jsonl", ".ndjson", ".csv", ".tsv", ".parquet", ".xlsx", ".xls", ".png", ".jpg",
     ".jpeg", ".gif", ".webp", ".heic", ".svg", ".wav", ".mp3", ".m4a", ".flac", ".ogg", ".mp4",
     ".mov", ".npy", ".npz", ".pkl", ".bin", ".onnx", ".safetensors", ".log", ".html", ".xml"}
)
DATA_DIR_MIN_FILES = 20
DATA_DIR_SHARE = 0.8
MAX_DIRS = 20_000
# Сколько старт сессии ждёт обход; дальше — фон и прошлый результат.
BACKGROUND_WAIT_S = 0.2
MAX_FILE_BYTES = 1_000_000
MAX_DOC_BYTES = 5_000_000
MAX_PDF_BYTES = 50_000_000
PDF_TIMEOUT_S = 20

# Объявления во всех десяти языках одной регуляркой: ключевое слово + имя.
_DECLARATION = re.compile(
    r"\b(?:def|class|func|struct|enum|protocol|interface|type|fn|function|fun|trait|"
    r"module|object|extension|actor|typealias|record|impl)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
_IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_CAMEL_PART = re.compile(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+")
_REQUIREMENT_NAME = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)")

# Общеупотребительные слова и служебные имена кода живут в `wordlists`.
COMMON_WORDS = CODE_COMMON

# Запись о термине в файле: [частота, вид, строка, нужен_повтор].
Found = dict[str, list]


def _split_identifier(name: str) -> list[str]:
    """Целое имя и его части: `EngineClient` → Engine, Client; `load_vad` → load, vad."""
    parts: list[str] = []
    for chunk in name.split("_"):
        if not chunk:
            continue
        pieces = _CAMEL_PART.findall(chunk)
        if len(pieces) > 1:
            parts.extend(pieces)
        if chunk != name:
            parts.append(chunk)
    return [name, *[part for part in parts if part != name]]


def _keep(term: str) -> bool:
    if len(term) < MIN_LENGTH or term.isdigit():
        return False
    if not any(char.isalpha() for char in term):
        return False
    if term.casefold() in COMMON_WORDS:
        return False
    # Версии и хэши — не термины и в коде (`v2`, `a3f9c1e`).
    return "_" in term or not rejected(term)


def _code_kind(term: str) -> str:
    kind = shape_kind(term)
    return kind if kind in ("acronym", "tech") else "identifier"


def _line_at(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def _put(found: Found, term: str, kind: str, line: int, weight: int = 1) -> None:
    record = found.get(term)
    if record is None:
        found[term] = [weight, kind, line, 0]
    else:
        record[0] += weight


def _names_from_source(text: str, stem: str) -> Found:
    found: Found = {}
    declarations = [(stem, 1)] + [(m.group(1), _line_at(text, m.start())) for m in _DECLARATION.finditer(text)]
    for name, line in declarations:
        for term in _split_identifier(name):
            if _keep(term):
                _put(found, term, _code_kind(term), line)
    # Частота имени в коде — вес термина: объявленное и часто зовущееся
    # важнее объявленного раз и забытого.
    if found:
        for identifier in _IDENTIFIER.findall(text):
            if identifier in found:
                found[identifier][0] += 1
    return found


def _dependency_names(name: str, text: str) -> list[str]:
    names: list[str] = []
    try:
        if name == "package.json":
            payload = json.loads(text)
            for key in ("dependencies", "devDependencies", "peerDependencies"):
                names.extend((payload.get(key) or {}).keys())
        elif name == "pyproject.toml":
            payload = tomllib.loads(text)
            project = payload.get("project", {})
            requirements = list(project.get("dependencies", []))
            for extra in (project.get("optional-dependencies") or {}).values():
                requirements.extend(extra)
            for requirement in requirements:
                match = _REQUIREMENT_NAME.match(str(requirement))
                if match:
                    names.append(match.group(1))
            poetry = payload.get("tool", {}).get("poetry", {})
            names.extend(key for key in (poetry.get("dependencies") or {}) if key != "python")
        elif name == "Cargo.toml":
            payload = tomllib.loads(text)
            for key in ("dependencies", "dev-dependencies", "build-dependencies"):
                names.extend((payload.get(key) or {}).keys())
        elif name == "go.mod":
            for match in re.finditer(r"^\s*(?:require\s+)?([\w.\-]+/[\w.\-/]+)\s+v", text, re.MULTILINE):
                names.append(match.group(1).rstrip("/").split("/")[-1])
    except (ValueError, tomllib.TOMLDecodeError, AttributeError):
        return []
    # «@scope/pkg» → «pkg»: произносят имя пакета, а не scope.
    return [item.split("/")[-1] for item in names if item]


def _names_from_manifest(name: str, text: str) -> Found:
    found: Found = {}

    def line_of(dependency: str) -> int:
        offset = text.find(dependency)
        return _line_at(text, offset) if offset >= 0 else 1

    for dependency in _dependency_names(name, text):
        line = line_of(dependency)
        if _keep(dependency):
            _put(found, dependency, "tech", line, 3)
        for part in re.split(r"[-_.]", dependency):
            if part != dependency and _keep(part):
                _put(found, part, "tech", line)
    return found


def pdftotext_available() -> bool:
    return shutil.which("pdftotext") is not None


def _kind(path: Path, source: str) -> str | None:
    """Как читать файл: source, manifest, markdown, text, pdf — или пропустить."""
    suffix = path.suffix.lower()
    if source == "repo":
        if suffix in SOURCE_EXTENSIONS:
            return "source"
        if path.name in MANIFESTS:
            return "manifest"
        if suffix in MARKDOWN_EXTENSIONS or path.name.startswith("README") or path.name in HEADING_FILES:
            return "markdown"
        return None
    if suffix in MARKDOWN_EXTENSIONS:
        return "markdown"
    if suffix == ".txt":
        return "text"
    if suffix == ".pdf":
        return "pdf" if pdftotext_available() else None
    return None


def _pdf_text(path: Path) -> str:
    from . import isolation

    tool = shutil.which("pdftotext")  # в выпуске PATH системный — Homebrew не найдётся, PDF пропускаются
    if tool is None:
        return ""
    try:
        result = subprocess.run(
            [tool, "-enc", "UTF-8", "-q", str(path), "-"],
            capture_output=True,
            env=isolation.tool_env(),
            timeout=PDF_TIMEOUT_S,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.decode("utf-8", "replace") if result.returncode == 0 else ""


def _scan_file(path: Path, kind: str) -> tuple[Found, int]:
    """Термины файла и сколько байт текста прочитано."""
    if kind == "pdf":
        text = _pdf_text(path)
    else:
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            return {}, 0
    size = len(text.encode("utf-8"))
    if kind == "source":
        return _names_from_source(text, path.stem), size
    if kind == "manifest":
        return _names_from_manifest(path.name, text), size
    return terms_from_document(text, markdown=kind == "markdown"), size


# П10: репозиторий может быть чужим. Его `.git/config` не должен ничего запускать: `core.fsmonitor`
# выполняется уже на `ls-files`, хуки и прочие внешние команды — тоже мимо.
SAFE_GIT = ("-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false",
            "-c", "core.sshCommand=false", "-c", "protocol.allow=never")


# Р4-1: по имени из `PATH` мог найтись чужой git — только полный путь и окружение-белый список
# (`isolation.tool_env`): без `DEVELOPER_DIR`, `TOOLCHAINS`, `SDKROOT` и `GIT_*`.
# П10 р5 Р5-2: и не шим `/usr/bin/git`: он спрашивает путь у xcrun, а xcrun верит своему кэшу `xcrun_db`
# (в `DARWIN_USER_TEMP_DIR` или по переменной `xcrun_db`) — подложенный кэш уводит шим в любую программу.
# Git берём прямо из папки разработчика (`xcode-select -p`), только из системных мест; иначе — обход папки.
COMMAND_LINE_TOOLS = "/Library/Developer/CommandLineTools"
XCODE_SELECT = "/usr/bin/xcode-select"


def _system_developer_dir(path: str) -> bool:
    if path == COMMAND_LINE_TOOLS:
        return True
    parts = path.split("/")
    return (len(parts) == 5 and parts[0] == "" and parts[1] == "Applications" and parts[2].endswith(".app")
            and len(parts[2]) > 4 and not parts[2].startswith(".") and parts[3:] == ["Contents", "Developer"])


def git_executable(developer_dir: str | None, is_executable=lambda p: os.access(p, os.X_OK),
                   lstat=os.lstat) -> str | None:
    """Git из папки разработчика, если она системная и файл есть (повторяет `SafeGit.executable` приложения).

    П10 хвост р5 Ф-1: форма пути — не доверие. `/Applications` (root:admin 775) открыт на запись админу, Xcode из
    `.xip` или Xcodes принадлежит пользователю. Поэтому вся цепочка от `<имя>.app` (или CLT) до самого файла git —
    root, без записи группе и прочим, без ссылок (`lstat` подставляется в тестах).
    """
    path = (developer_dir or "").strip()
    if not path.startswith("/"):
        return None
    while len(path) > 1 and path.endswith("/"):
        path = path[:-1]
    resolved = os.path.realpath(path)
    if not (_system_developer_dir(path) and _system_developer_dir(resolved)):
        return None
    git = os.path.join(resolved, "usr", "bin", "git")
    if not is_executable(git):
        return None
    return git if all(_root_only(link, lstat) for link in _trust_chain(resolved)) else None


def _trust_chain(developer_dir: str) -> list[str]:
    """Звенья от CLT или `<имя>.app` до `usr/bin/git`. Сам `/Applications` (root:admin 775) в цепочку не входит."""
    top = COMMAND_LINE_TOOLS if developer_dir == COMMAND_LINE_TOOLS else "/Applications/" + developer_dir.split("/")[2]
    chain = [top]
    for part in [*developer_dir[len(top):].split("/"), "usr", "bin", "git"]:
        if part:
            chain.append(chain[-1] + "/" + part)
    return chain


def _root_only(path: str, lstat) -> bool:
    try:
        st = lstat(path)
    except OSError:
        return False
    return st.st_uid == 0 and not stat.S_ISLNK(st.st_mode) and not st.st_mode & 0o022


XCODE_SELECT_TIMEOUT = 5.0


def developer_dir(tool: str = XCODE_SELECT, timeout: float = XCODE_SELECT_TIMEOUT) -> str | None:
    """Вывод `xcode-select -p` с окружением без `DEVELOPER_DIR` (как `SafeGit.developerDir` приложения).

    П10 хвост р5 Ф-5: завис дольше `timeout`, упал или не запустился — None, как при отказе: обход папки.
    """
    from . import isolation

    try:
        out = subprocess.run([tool, "-p"], capture_output=True, text=True, timeout=timeout, check=True,
                             env=isolation.tool_env())
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout


@functools.cache
def _developer_dir() -> str | None:
    """`xcode-select -p` один раз за процесс."""
    return developer_dir()


def _git_path() -> str | None:
    """Путь git перед каждым запуском: владельцев цепочки проверяем заново (Ф-1), `.app` могли подменить."""
    return git_executable(_developer_dir())


def _git_env() -> dict[str, str]:
    from . import isolation

    env = isolation.tool_env()
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
    return env


def _inside(path: Path, root: Path) -> bool:
    """Файл и его настоящее место — внутри корня: симлинк наружу не читаем (П10)."""
    try:
        return path.resolve().is_relative_to(root.resolve())
    except (OSError, RuntimeError):
        return False


def _git_files(root: Path) -> list[str] | None:
    """Файлы репозитория по git (с неотслеживаемыми, без игнорируемых).

    Обход дерева упирается в `scandir`: на transcriber это 935 каталогов и 2 с
    (результаты прогонов, эксперименты), а git отдаёт список за сотые.
    """
    if not (root / ".git").exists():
        return None
    git = _git_path()
    if git is None:
        return None
    try:
        result = subprocess.run(
            [git, *SAFE_GIT, "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            timeout=20,
            check=True,
            env=_git_env(),
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return sorted(name for name in result.stdout.decode("utf-8", "replace").split("\0") if name)


def _skipped_dir(name: str) -> bool:
    return name in EXCLUDED_DIRS or name.startswith(".")


def looks_like_data(files: list[str]) -> bool:
    """Папка выгрузок: от 20 файлов, и не меньше 80 % из них — данные."""
    if len(files) < DATA_DIR_MIN_FILES:
        return False
    data = sum(1 for name in files if os.path.splitext(name)[1].lower() in DATA_EXTENSIONS)
    return data / len(files) >= DATA_DIR_SHARE


def _fs_lister(root: Path):
    def list_dir(relative: str) -> tuple[list[str], list[str]]:
        subdirs: list[str] = []
        files: list[str] = []
        try:
            with os.scandir(root / relative) as entries:
                for item in entries:
                    try:
                        if item.is_dir(follow_symlinks=False):
                            subdirs.append(item.name)
                        elif item.is_file(follow_symlinks=False):
                            files.append(item.name)
                    except OSError:
                        continue
        except OSError:
            pass
        return subdirs, files

    return list_dir


def _git_lister(listed: list[str]):
    tree: dict[str, tuple[set[str], list[str]]] = {}
    for name in listed:
        parts = name.split("/")
        for depth in range(len(parts) - 1):
            tree.setdefault("/".join(parts[:depth]), (set(), []))[0].add(parts[depth])
        tree.setdefault("/".join(parts[:-1]), (set(), []))[1].append(parts[-1])

    def list_dir(relative: str) -> tuple[list[str], list[str]]:
        subdirs, files = tree.get(relative, (set(), []))
        return list(subdirs), list(files)

    return list_dir


def _walk(root: Path, source: str = "repo"):
    """Файлы источника в ширину: сначала ближние к корню, на уровне — свежие папки первыми."""
    listed = _git_files(root)
    list_dir = _git_lister(listed) if listed is not None else _fs_lister(root)
    queue: deque[str] = deque([""])
    visited = 0
    while queue and visited < MAX_DIRS:
        relative = queue.popleft()
        visited += 1
        subdirs, files = list_dir(relative)
        if relative and looks_like_data(files):
            continue
        for name in sorted(files):
            if name.startswith("."):
                continue
            path = root / relative / name
            if not _inside(path, root):
                continue
            kind = _kind(path, source)
            if kind is not None:
                yield path, kind

        def freshness(name: str) -> tuple[float, str]:
            try:
                return -(root / relative / name).stat().st_mtime, name
            except OSError:
                return 0.0, name

        for name in sorted((name for name in subdirs if not _skipped_dir(name)), key=freshness):
            queue.append(f"{relative}/{name}" if relative else name)


def cache_path(root: Path) -> Path:
    digest = hashlib.sha1(str(root).encode("utf-8")).hexdigest()
    return paths.projects_dir() / f"{digest}.json"


def files_path(root: Path) -> Path:
    return cache_path(root).with_suffix(".files.json")


def _load_cache(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(payload, dict) or payload.get("version") != CACHE_VERSION:
        return {}
    return payload


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    os.replace(temp, path)


def cached_result(root: str | Path, kind: str = "repo", *, limit: int = LIMIT) -> dict[str, Any] | None:
    """Прошлый результат из кэша без обхода и без оглядки на возраст; None — кэша нет."""
    try:
        resolved = Path(root).expanduser().resolve()
    except OSError:
        return None
    cache = _load_cache(cache_path(resolved))
    if not cache or cache.get("kind") != kind or cache.get("root") != str(resolved):
        return None
    return _result(cache, limit=limit, started=time.monotonic(), reused=int(cache.get("files_count", 0)), cached=True)


def iso_time(timestamp: float) -> str:
    return _dt.datetime.fromtimestamp(timestamp).astimezone().isoformat(timespec="seconds")


def merge_files(files: dict[str, Any], *, limit: int = LIMIT) -> list[dict[str, Any]]:
    """Находки по файлам → термины источника `{term, kind, origins, weight}` по частоте.

    Одно имя в разных регистрах — один термин, пишется самым частым написанием.
    Кандидат в имена собственные без второго вхождения на весь источник выпадает.
    """
    groups: dict[str, dict[str, Any]] = {}
    for relative in sorted(files):
        for term, record in files[relative]["names"].items():
            count, kind, line, repeat = int(record[0]), str(record[1]), int(record[2]), int(record[3])
            group = groups.setdefault(
                term.casefold(),
                {"count": 0, "spellings": Counter(), "kinds": Counter(), "origins": [], "repeat": True},
            )
            group["count"] += count
            group["spellings"][term] += count
            group["kinds"][kind] += count * (2 if kind == "project" else 1)
            group["repeat"] = group["repeat"] and bool(repeat)
            origin = f"{relative}:{line}"
            if len(group["origins"]) < MAX_ORIGINS and origin not in group["origins"]:
                group["origins"].append(origin)
    entries = []
    for group in groups.values():
        if group["repeat"] and group["count"] < 2:
            continue
        kind = group["kinds"].most_common(1)[0][0]
        entries.append(
            {
                "term": group["spellings"].most_common(1)[0][0],
                "kind": kind if kind in KINDS else "tech",
                "origins": group["origins"],
                "weight": group["count"],
            }
        )
    entries.sort(key=lambda entry: (-entry["weight"], entry["term"]))
    return entries[:limit]


def count_kinds(entries: list[dict[str, Any]]) -> dict[str, int]:
    counts = {kind: 0 for kind in KINDS}
    for entry in entries:
        counts[entry["kind"]] = counts.get(entry["kind"], 0) + 1
    return counts


def _result(payload: dict[str, Any], *, limit: int, started: float, reused: int, cached: bool) -> dict[str, Any]:
    entries = [
        {"term": item["term"], "kind": item["kind"], "origins": list(item["origins"])}
        for item in payload["terms"][:limit]
    ]
    return {
        "root": payload["root"],
        "kind": payload["kind"],
        "terms": [entry["term"] for entry in entries],
        "entries": entries,
        "counts": count_kinds(entries),
        "count": len(entries),
        "files": int(payload.get("files_count", 0)),
        "reused": reused,
        "cached": cached,
        "truncated": bool(payload.get("truncated")),
        "scanned_at": payload["scanned_at"],
        "seconds": round(time.monotonic() - started, 3),
    }


def build(
    root: str | Path,
    *,
    kind: str = "repo",
    limit: int = LIMIT,
    max_age_s: float = 0.0,
    force: bool = False,
) -> dict[str, Any]:
    """Термины источника по частоте.

    `max_age_s` > 0: если кэш моложе, дерево не обходится вовсе.
    `force`: обойти всё заново, не глядя на кэш файлов (`rescan`).
    """
    started = time.monotonic()
    if kind not in ("repo", "docs"):
        raise ValueError(f"вид источника {kind!r}: repo или docs")
    root = Path(root).expanduser().resolve()
    if not root.is_dir():
        raise FileNotFoundError(f"Нет каталога: {root}")
    store = cache_path(root)
    cache = {} if force else _load_cache(store)
    if cache.get("kind") != kind or cache.get("root") != str(root):
        cache = {}
    if cache and max_age_s > 0 and time.time() - float(cache.get("scanned_ts", 0)) < max_age_s:
        return _result(cache, limit=limit, started=started, reused=int(cache.get("files_count", 0)), cached=True)
    cached_files: dict[str, Any] = {}
    if cache:
        sidecar = _load_cache(files_path(root))
        cached_files = sidecar.get("files", {}) if sidecar.get("root") == str(root) else {}
    files: dict[str, Any] = {}
    reused = 0
    text_bytes = 0
    truncated = False
    for path, file_kind in _walk(root, kind):
        if len(files) >= MAX_FILES or text_bytes >= MAX_TEXT_BYTES:
            truncated = True
            break
        try:
            stat = path.stat()
        except OSError:
            continue
        ceiling = {"source": MAX_FILE_BYTES, "manifest": MAX_FILE_BYTES, "pdf": MAX_PDF_BYTES}.get(
            file_kind, MAX_DOC_BYTES
        )
        if stat.st_size > ceiling:
            continue
        relative = str(path.relative_to(root))
        previous = cached_files.get(relative)
        if previous and previous["mtime"] == stat.st_mtime and previous["size"] == stat.st_size:
            files[relative] = previous
            text_bytes += int(previous.get("text_bytes", previous["size"]))
            reused += 1
            continue
        names, size = _scan_file(path, file_kind)
        text_bytes += size
        files[relative] = {"mtime": stat.st_mtime, "size": stat.st_size, "text_bytes": size, "names": names}
    now = time.time()
    payload = {
        "version": CACHE_VERSION,
        "root": str(root),
        "kind": kind,
        "scanned_at": iso_time(now),
        "scanned_ts": now,
        "files_count": len(files),
        "truncated": truncated,
        "terms": merge_files(files, limit=max(limit, LIMIT)),
    }
    payload["counts"] = count_kinds(payload["terms"])
    _write_json(files_path(root), {"version": CACHE_VERSION, "root": str(root), "files": files})
    _write_json(store, payload)
    return _result(payload, limit=limit, started=started, reused=reused, cached=False)


class ProjectGlossaries:
    """Память движка поверх кэша: на одну сессию не обходим дерево дважды за минуту.

    На диске правило другое: полный обход не чаще раза в `max_age_s`
    (10 минут), пока не пришёл `rescan` (`force=True`).

    `wait_s` — для старта сессии: обход идёт в фоне, сессия ждёт его не
    дольше `wait_s` и, если не дождалась, берёт прошлый результат (из памяти
    или из кэша на диске). Свежий результат подхватит следующая сессия.
    """

    def __init__(self, ttl_s: float = 60.0, max_age_s: float = RESCAN_AFTER_S) -> None:
        self.ttl_s = ttl_s
        self.max_age_s = max_age_s
        self._memory: dict[tuple[str, str], tuple[float, dict[str, Any] | None]] = {}
        self._running: dict[tuple[str, str], threading.Thread] = {}
        self._lock = threading.Lock()

    def _build(self, key: tuple[str, str], force: bool) -> None:
        root, kind = key
        try:
            result = build(root, kind=kind, max_age_s=0.0 if force else self.max_age_s, force=force)
        except (OSError, ValueError):
            result = None
        with self._lock:
            self._memory[key] = (time.monotonic(), result)

    def _background(self, key: tuple[str, str], force: bool) -> threading.Thread:
        with self._lock:
            thread = self._running.get(key)
            if thread is not None and thread.is_alive():
                return thread

            def job() -> None:
                try:
                    self._build(key, force)
                finally:
                    with self._lock:
                        if self._running.get(key) is threading.current_thread():
                            self._running.pop(key, None)

            thread = threading.Thread(target=job, name=f"mostik-scan-{kind_label(key)}", daemon=True)
            self._running[key] = thread
            thread.start()
            return thread

    def scan(
        self,
        root: str | None,
        kind: str = "repo",
        *,
        force: bool = False,
        wait_s: float | None = None,
    ) -> dict[str, Any] | None:
        """Результат `build` или None, если каталога нет (или ещё нечего показать)."""
        if not root:
            return None
        key = (str(root), kind)
        with self._lock:
            hit = self._memory.get(key)
        if hit and not force and time.monotonic() - hit[0] < self.ttl_s:
            return hit[1]
        if wait_s is None:
            self._build(key, force)
            with self._lock:
                return self._memory[key][1]
        thread = self._background(key, force)
        thread.join(wait_s)
        with self._lock:
            fresh = self._memory.get(key)
        if not thread.is_alive() and fresh is not None:
            return fresh[1]
        if hit is not None:
            return hit[1]
        return cached_result(root, kind)

    def terms(self, root: str | None, kind: str = "repo", *, wait_s: float | None = None) -> list[str]:
        result = self.scan(root, kind, wait_s=wait_s)
        return list(result["terms"]) if result else []

    def entries(self, root: str | None, kind: str = "repo", *, wait_s: float | None = None) -> list[dict[str, Any]]:
        result = self.scan(root, kind, wait_s=wait_s)
        return list(result["entries"]) if result else []

    def forget(self, root: str | None = None) -> None:
        with self._lock:
            if root is None:
                self._memory.clear()
            else:
                for key in [key for key in self._memory if key[0] == str(root)]:
                    self._memory.pop(key, None)


def kind_label(key: tuple[str, str]) -> str:
    return f"{key[1]}-{hashlib.sha1(key[0].encode('utf-8')).hexdigest()[:8]}"
