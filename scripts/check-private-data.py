#!/usr/bin/env python3
"""Сверка публикуемого с личными данными Mostik на этой машине.

Mostik расшифровывает личные и рабочие разговоры. Ни фраза из встречи или диктовки, ни слово
личного словаря, ни имя участника не должны оказаться в репозитории, в образе выпуска, в тексте
Release или в ленте. Список запрещённых строк (`check-denylist.sh`) ловит только заранее названное;
эта проверка сравнивает публикуемое с тем, что реально лежит в данных Mostik:

  • фразы — каждые N слов подряд (по умолчанию 5) из встреч, диктовок, сводок, заметок, календаря;
  • термины — записи личного словаря и словаря transcriber, имена людей, названия встреч,
    участники и названия событий календаря.

Запуск (только локально — у CI этих данных нет):

  scripts/check-private-data.py <цель>...            цель — папка, файл или `git:<репозиторий>`
                                                      (вся история всех веток: тексты правок и сообщения)
  scripts/check-private-data.py --self-test          проверка самой проверки на подложенной утечке

Совпадение — код 1. Нет данных или цели не читаются — код 2: проверка не может молча пройти.
Отчёт печатает, сколько отпечатков собрано и сколько файлов и слов просмотрено, — «чисто» без этих
чисел ничего не доказывает.

Разрешённые совпадения — в `.git/info/private-allow` (вне репозитория, по строке на термин или
фразу): общеизвестные слова из словаря вроде названий программ. Фразы разрешаются целиком.
Сами личные данные в вывод попадают только как совпавшая строка — вывод не публиковать.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

WORD = re.compile(r"[0-9A-Za-zА-Яа-яЁё]+(?:[-'’][0-9A-Za-zА-Яа-яЁё]+)*")
TEXT_SUFFIXES = {".json", ".jsonl", ".md", ".txt", ".yaml", ".yml", ".srt", ".vtt", ".log", ".csv"}
# Поля JSON, чьи значения — служебные, а не речь: идентификаторы, пути, имена моделей.
SKIP_KEYS = {
    "id", "session", "path", "folder", "file", "audio", "model", "models", "backend", "kind", "rule",
    "source", "language", "state", "status", "outcome", "version", "app", "bundle", "bundle_id", "url",
    "link", "uid", "hash", "sha", "label", "role", "type", "device", "codec", "format", "engine",
}
DEFAULT_HOME = Path.home() / "Library/Application Support/Mostik"
TRANSCRIBER_HOME = Path.home() / ".transcriber"


def words(text: str) -> list[str]:
    return [w.lower().replace("ё", "е") for w in WORD.findall(text)]


def digest(tokens: list[str]) -> bytes:
    return hashlib.blake2b(" ".join(tokens).encode(), digest_size=8).digest()


def json_strings(node, key: str = ""):
    if isinstance(node, str):
        if key not in SKIP_KEYS:
            yield node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from json_strings(v, str(k).lower())
    elif isinstance(node, list):
        for v in node:
            yield from json_strings(v, key)


def private_strings(path: Path):
    """Строки с человеческим текстом из файла данных: значения JSON, строки остальных файлов."""
    try:
        raw = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return
    if path.suffix == ".json":
        try:
            yield from json_strings(json.loads(raw))
            return
        except ValueError:
            pass
    if path.suffix == ".jsonl":
        for line in raw.splitlines():
            try:
                yield from json_strings(json.loads(line))
            except ValueError:
                yield line
        return
    yield from raw.splitlines()


class Fingerprints:
    def __init__(self, n: int):
        self.n = n
        self.phrases: set[bytes] = set()
        self.terms: dict[str, str] = {}  # нормализованный термин → откуда
        self.shorts: dict[str, str] = {}  # короткий кусок речи → откуда; ищется только в кавычках
        self.files = 0
        self.words = 0

    def add_text(self, text: str) -> None:
        tokens = words(text)
        self.words += len(tokens)
        for i in range(len(tokens) - self.n + 1):
            window = tokens[i : i + self.n]
            # Счёт и ряды чисел есть в любом коде: отпечатком считаем фразу хотя бы с двумя словами.
            if sum(1 for t in window if t.isalpha() and len(t) > 1) >= 2:
                self.phrases.add(digest(window))

    def add_short(self, text: str, origin: str) -> None:
        """Услышанное слово, исправление, вариант словаря. Слишком коротко для отпечатка фразы,
        поэтому ищем его целиком в кавычках — так примеры и попадают в тесты и комментарии."""
        tokens = words(text)
        if not tokens or len(tokens) > 8 or (len(tokens) == 1 and ordinary(text)):
            return
        self.shorts.setdefault(" ".join(tokens), origin)

    def add_term(self, term: str, origin: str) -> None:
        tokens = words(term)
        if not tokens or len(tokens) > 6:
            return
        key = " ".join(tokens)
        if len(key) < 3 or key.isdigit():
            return
        self.terms.setdefault(key, origin)


def glossary_terms(path: Path):
    """Каноны словаря (`canonical:`) — без зависимости от PyYAML. Варианты «как слышится» не берём:
    это обычные слова, и совпадают они со всем подряд."""
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return
    for line in lines:
        m = re.match(r"\s*(?:-\s*)?canonical\s*:\s*(.+)$", line)
        if m:
            yield m.group(1).strip().strip("'\"")


def glossary_aliases(path: Path):
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return
    inside = False
    for line in lines:
        if re.match(r"\s*aliases\s*:", line):
            inside = True
            inline = re.search(r"\[(.*)\]", line)
            if inline:
                for piece in inline.group(1).split(","):
                    yield piece.strip().strip("'\"")
                inside = False
            continue
        m = re.match(r"\s*-\s+(?!canonical\s*:)(.+)$", line) if inside else None
        if m:
            yield m.group(1).strip().strip("'\"")
        elif inside and line.strip():
            inside = False


SHORT_KEYS = {"heard", "suggestion", "from", "to"}


def short_values(path: Path):
    """Услышанное и исправленное в истории диктовок и в журнале обучения."""
    def walk(node, key=""):
        if isinstance(node, str):
            if key in SHORT_KEYS:
                yield node
        elif isinstance(node, dict):
            for k, v in node.items():
                yield from walk(v, str(k).lower())
        elif isinstance(node, list):
            for v in node:
                yield from walk(v, key)
    try:
        raw = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return
    for chunk in ([raw] if path.suffix == ".json" else raw.splitlines()):
        try:
            yield from walk(json.loads(chunk))
        except ValueError:
            continue


QUOTED = re.compile(r"[«\"“„']([^«»\"“”„'\n]{2,90})[»\"”']")

_ENGLISH: frozenset[str] | None = None


def english() -> frozenset[str]:
    global _ENGLISH
    if _ENGLISH is None:
        try:
            _ENGLISH = frozenset(Path("/usr/share/dict/words").read_text(errors="ignore").lower().split())
        except OSError:
            _ENGLISH = frozenset()
    return _ENGLISH


def ordinary(term: str) -> bool:
    """Обычное слово, а не название: английское из системного словаря (с простыми окончаниями)
    или русское, записанное строчными. Такие термины совпали бы с половиной любого текста."""
    for raw in WORD.findall(term):
        if re.search(r"\d", raw):
            return False
        if re.fullmatch(r"[А-Яа-яЁё'’-]+", raw):
            if raw != raw.lower():
                return False
            continue
        low = raw.lower()
        stems = {low, low.rstrip("s"), low[:-2] if low.endswith(("es", "ed")) else low,
                 low[:-3] if low.endswith("ing") else low, low[:-1] if low.endswith("d") else low}
        if not stems & english():
            return False
    return True


def first_heading(path: Path) -> str:
    try:
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines()[:8]:
            if line.startswith("# "):
                return line[2:].strip()
    except OSError:
        pass
    return ""


def collect(home: Path, n: int, transcriber: Path | None = TRANSCRIBER_HOME) -> Fingerprints:
    fp = Fingerprints(n)
    if not home.is_dir():
        return fp
    for path in sorted(home.rglob("*")):
        if not path.is_file() or path.suffix not in TEXT_SUFFIXES:
            continue
        rel = path.relative_to(home).parts
        if "logs" in rel:
            continue  # логи — предмет проверки, а не эталон
        fp.files += 1
        for text in private_strings(path):
            fp.add_text(text)
        if path.suffix in (".yaml", ".yml") and "glossary" in path.name:
            for term in glossary_terms(path):
                if not ordinary(term):
                    fp.add_term(term, "словарь")
            for alias in glossary_aliases(path):
                fp.add_short(alias, "вариант словаря")
        if path.name in ("history.jsonl", "learning.json"):
            for value in short_values(path):
                fp.add_short(value, path.name)
        if rel[0] == "people" and path.suffix == ".md":
            fp.add_term(path.stem.replace("-", " ").replace("_", " "), "человек")
            fp.add_term(first_heading(path), "человек")
        if path.name in ("meeting.md", "notes.md") and rel[0] == "meetings":
            fp.add_term(first_heading(path), "название встречи")
        if path.name in ("manifest.json", "calendar.json"):
            try:
                data = json.loads(path.read_text(encoding="utf-8", errors="ignore"))
            except (OSError, ValueError):
                continue
            for key, value in walk_named(data):
                for piece in re.split(r"[,;<>()]", value):
                    fp.add_term(piece, f"{path.name}:{key}")
    extra = [] if transcriber is None else sorted(transcriber.glob("glossary*.yaml")) + sorted(transcriber.glob("glossaries/**/*.yaml"))
    for path in extra:
        fp.files += 1
        for term in glossary_terms(path):
            if not ordinary(term):
                fp.add_term(term, "словарь transcriber")
    return fp


NAME_KEYS = {"title", "name", "names", "attendees", "participants", "people", "speaker", "speakers",
             "organizer", "display_name", "email"}


def walk_named(node, key: str = ""):
    if isinstance(node, str):
        if key in NAME_KEYS:
            yield key, node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from walk_named(v, str(k).lower())
    elif isinstance(node, list):
        for v in node:
            yield from walk_named(v, key)


class Scan:
    def __init__(self, fp: Fingerprints, allow: set[str]):
        self.fp = fp
        self.allow = allow
        self.max_term = max((len(t.split()) for t in fp.terms), default=1)
        self.files = 0
        self.words = 0
        self.phrase_hits: list[tuple[str, str]] = []
        self.term_hits: Counter = Counter()
        self.term_where: dict[str, str] = {}

    def text(self, where: str, text: str, binary: bool = False) -> None:
        for line in text.splitlines():
            tokens = words(line)
            if not tokens:
                continue
            self.words += len(tokens)
            n = self.fp.n
            hit_until = -1
            for i in range(len(tokens) - n + 1):
                if i <= hit_until:
                    continue
                if digest(tokens[i : i + n]) in self.fp.phrases:
                    phrase = " ".join(tokens[i : i + n])
                    if phrase not in self.allow:
                        self.phrase_hits.append((where, phrase))
                    hit_until = i + n - 1
            if self.fp.shorts and len(line) < 4000:
                for literal in QUOTED.findall(line):
                    key = " ".join(words(literal))
                    if key in self.fp.shorts and key not in self.allow:
                        self.term_hits[key] += 1
                        self.term_where.setdefault(key, where)
            if self.fp.terms:
                for size in range(1, min(self.max_term, len(tokens)) + 1):
                    for i in range(len(tokens) - size + 1):
                        key = " ".join(tokens[i : i + size])
                        if binary and len(key) < 6:
                            continue  # в двоичном файле три-пять букв совпадают со случайными байтами
                        if key in self.fp.terms and key not in self.allow:
                            self.term_hits[key] += 1
                            self.term_where.setdefault(key, where)

    def file(self, path: Path, label: str) -> None:
        try:
            data = path.read_bytes()
        except OSError as error:
            raise SystemExit(f"check-private-data: не прочитан {path}: {error}") from error
        self.files += 1
        # Двоичные файлы тоже читаем: строки в бинарнике и байткоде лежат в UTF-8 как есть.
        self.text(label, data.decode("utf-8", errors="ignore").replace("\x00", "\n"), binary=b"\x00" in data[:65536])

    def tree(self, root: Path) -> None:
        for path in sorted(root.rglob("*")):
            if path.is_symlink() or not path.is_file() or ".git" in path.relative_to(root).parts:
                continue
            self.file(path, str(path.relative_to(root)))

    def tracked(self, repo: Path) -> None:
        """Файлы, которые git отдаст наружу: без черновиков, сборок и прочего неотслеживаемого."""
        names = subprocess.run(["git", "-C", str(repo), "ls-files", "-z"], capture_output=True, check=True).stdout
        for name in names.decode("utf-8", errors="ignore").split("\x00"):
            path = repo / name
            if name and path.is_file() and not path.is_symlink():
                self.file(path, name)

    def git(self, repo: Path) -> None:
        out = subprocess.run(
            ["git", "-C", str(repo), "log", "--all", "-p", "--no-color", "--format=commit %h %an <%ae>%n%B"],
            capture_output=True, check=True,
        ).stdout.decode("utf-8", errors="ignore")
        current = "история"
        buffer: list[str] = []
        for line in out.splitlines():
            if line.startswith("commit ") or line.startswith("+++ b/"):
                self.text(current, "\n".join(buffer))
                buffer = []
                if line.startswith("commit "):
                    self.files += 1
                    commit = line.split()[1]
                    current = f"git {commit}"
                    buffer.append(line)
                else:
                    current = f"{current.split(':')[0]}:{line[6:]}"
            elif line.startswith("+") or not line.startswith(("-", "@@", "diff ", "index ")):
                buffer.append(line[1:] if line.startswith("+") else line)
        self.text(current, "\n".join(buffer))


def allow_path(root: Path) -> Path | None:
    """Список разрешённого лежит в `.git/info` — вне дерева: в нём слова из личного словаря."""
    try:
        common = subprocess.run(["git", "-C", str(root), "rev-parse", "--git-common-dir"],
                                capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    path = Path(common) if os.path.isabs(common) else root / common
    return path / "info" / "private-allow"


def load_allow(root: Path) -> set[str]:
    path = allow_path(root)
    try:
        lines = path.read_text(encoding="utf-8").splitlines() if path else []
    except OSError:
        return set()
    return {" ".join(words(line)) for line in lines if line.strip() and not line.lstrip().startswith("#")}


def run(targets: list[str], home: Path, n: int, allow: set[str], min_words: int,
        transcriber: Path | None = TRANSCRIBER_HOME, accept: Path | None = None) -> int:
    fp = collect(home, n, transcriber)
    print(f"Личные данные: файлов {fp.files}, слов {fp.words}, фраз по {n} слов {len(fp.phrases)}, терминов {len(fp.terms)}")
    if fp.words < min_words or not fp.phrases:
        print(f"check-private-data: в {home} слишком мало данных ({fp.words} слов) — сверять не с чем", file=sys.stderr)
        return 2
    scan = Scan(fp, allow)
    for target in targets:
        if target.startswith("git:"):
            scan.git(Path(target[4:]))
        elif target.startswith("tracked:"):
            scan.tracked(Path(target[8:]))
        else:
            path = Path(target)
            if path.is_dir():
                scan.tree(path)
            elif path.is_file():
                scan.file(path, path.name)
            else:
                print(f"check-private-data: нет цели {target}", file=sys.stderr)
                return 2
    print(f"Просмотрено: файлов и коммитов {scan.files}, слов {scan.words}; разрешённых строк {len(allow)}")
    if scan.words == 0:
        print("check-private-data: в целях нет ни одного слова — проверено ничего", file=sys.stderr)
        return 2
    if scan.phrase_hits:
        print(f"\nФразы из личных данных: {len(scan.phrase_hits)}")
        seen = Counter(phrase for _, phrase in scan.phrase_hits)
        first = {}
        for where, phrase in scan.phrase_hits:
            first.setdefault(phrase, where)
        for phrase, count in seen.most_common(400):
            print(f"  {count:4d}  «{phrase}»  — {first[phrase]}")
    if scan.term_hits:
        print(f"\nТермины из личных данных: {len(scan.term_hits)} разных")
        for term, count in scan.term_hits.most_common(400):
            print(f"  {count:5d}  {term}  [{fp.terms.get(term) or fp.shorts.get(term)}]  — {scan.term_where[term]}")
    if accept is not None and (scan.phrase_hits or scan.term_hits):
        new = sorted({phrase for _, phrase in scan.phrase_hits} | set(scan.term_hits))
        with accept.open("a", encoding="utf-8") as out:
            out.write("\n".join(new) + "\n")
        print(f"\ncheck-private-data: {len(new)} строк записано в {accept} как просмотренные и разрешённые")
        return 0
    if scan.phrase_hits or scan.term_hits:
        print("\ncheck-private-data: есть совпадения с личными данными. Утечку — убрать; общеизвестное слово —"
              " в .git/info/private-allow.", file=sys.stderr)
        return 1
    print("check-private-data: совпадений с личными данными нет")
    return 0


def self_test() -> int:
    """Подложенная утечка обязана найтись, чистый текст — пройти, пустые данные — остановить."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        home = root / "home"
        (home / "meetings" / "m1").mkdir(parents=True)
        (home / "meetings" / "m1" / "transcript.json").write_text(json.dumps({
            "segments": [{"speaker": "A", "text": "Договорились перенести запуск пилота на вторую неделю марта"}]}),
            encoding="utf-8")
        (home / "glossary.yaml").write_text("entries:\n- canonical: Кракозябрикс\n  aliases: [кракозябрик]\n", encoding="utf-8")
        (home / "history.jsonl").write_text(json.dumps({
            "text": "служебное", "doubts": [{"heard": "шоблон длякейнота", "suggestion": "шаблон для Keynote"}]},
            ensure_ascii=False) + "\n", encoding="utf-8")
        leak, clean, binary, pair = root / "leak", root / "clean", root / "binary", root / "pair"
        for folder in (leak, clean, binary, pair):
            folder.mkdir()
        (pair / "test.py").write_text('pairs = [("шоблон длякейнота", "x")]  # плагин для почты\n', encoding="utf-8")
        (leak / "test.py").write_text('assert fix("перенести запуск пилота на вторую неделю") == 1\n', encoding="utf-8")
        (clean / "test.py").write_text('assert fix("поправь тест и покажи дифф") == 1\n', encoding="utf-8")
        (binary / "blob.bin").write_bytes(b"\x00\x01\xff" + "слово кракозябрикс в бинарнике".encode() + b"\x00\x02")
        results = {
            "утечка фразы": run([str(leak)], home, 5, set(), 5, None) == 1,
            "чистый текст": run([str(clean)], home, 5, set(), 5, None) == 0,
            "термин в двоичном файле": run([str(binary)], home, 5, set(), 5, None) == 1,
            "услышанное из истории в кавычках": run([str(pair)], home, 5, set(), 5, None) == 1,
            "разрешённый термин": run([str(binary)], home, 5, {"кракозябрикс"}, 5, None) == 0,
            "нет данных": run([str(clean)], root / "missing", 5, set(), 5, None) == 2,
            "нет цели": run([str(root / "nothing")], home, 5, set(), 5, None) == 2,
        }
    print()
    for name, ok in results.items():
        print(("  ✓ " if ok else "  ✗ ") + name)
    return 0 if all(results.values()) else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("targets", nargs="*")
    parser.add_argument("--home", type=Path, default=Path(os.environ.get("MOSTIK_HOME", DEFAULT_HOME)))
    parser.add_argument("--phrase-words", type=int, default=5)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--accept", action="store_true",
                        help="после просмотра списка: записать найденное в .git/info/private-allow")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.targets:
        parser.error("нужна хотя бы одна цель")
    allow = load_allow(Path(__file__).resolve().parent.parent)
    accept = allow_path(Path(__file__).resolve().parent.parent) if args.accept else None
    if args.accept and accept is None:
        parser.error("--accept работает только из репозитория git")
    return run(args.targets, args.home, args.phrase_words, allow, min_words=1000, accept=accept)


if __name__ == "__main__":
    sys.exit(main())
