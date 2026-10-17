"""Встроенный Python для Mostik (П8, пункт 2) и его цепочка поставки (П10, С9–С11).

    python3 scripts/vendor_python.py extract --archive <cpython-…-install_only.tar.gz> [--sums <SHA256SUMS>]
    python3 scripts/vendor_python.py site [--tr <venv transcriber>] [--llm <engine/.venv-llm>]
    python3 scripts/vendor_python.py lock [--tr …] [--llm …]      # пересобрать scripts/requirements.lock
    python3 scripts/vendor_python.py verify                       # всё, что уйдёт в выпуск, против lock-файлов
    python3 scripts/vendor_python.py fluidaudio [--binary <файл>]    # fluidaudiocli против vendor.lock
    python3 scripts/vendor_python.py sbom --out <файл> [--python] [--sparkle] [--fluidaudio]
    python3 scripts/vendor_python.py git-state <папка> [путь…]    # коммит; код 1, если дерево грязное

Ожидаемые суммы лежат в git, а не рядом с архивом:
- `scripts/vendor.lock` — имена и полные SHA256 архивов python-build-standalone и Sparkle, а также
  готового `fluidaudiocli` (разделение встреч по голосам) и его LICENSE и NOTICE.md;
- `scripts/requirements.lock` — точные версии пакетов и SHA256 их файла RECORD. Каждый файл
  пакета сверяется со своей строкой RECORD (`sha256=` в urlsafe-base64), так что цепочка
  «git → RECORD → файл» не оставляет непроверенных байтов.

`extract` сверяет архив с `vendor.lock` (файл сумм релиза — дополнительно, если дан) и
распаковывает его в пустую `vendor/python/`. Архив качается вручную один раз, например:
    gh release download <тег> -R astral-sh/python-build-standalone \\
       -p 'cpython-3.14.*-aarch64-apple-darwin-install_only.tar.gz' -p SHA256SUMS

`site` собирает `vendor/python/lib/python3.X/site-packages` копированием дистрибутивов
из `scripts/vendor-packages.txt` (по их RECORD) из локальных venv — PyPI не нужен.
Копии на APFS — клоны (`cp -c`), места почти не занимают.
"""
from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "python"
PY_DOWNLOAD = ROOT / "vendor" / "python-download"
SPARKLE = ROOT / "vendor" / "sparkle"
# Готовый fluidaudiocli из transcriber (не скачивается): бинарник, его .sha256 и .url, LICENSE, NOTICE.md.
FLUIDAUDIO = ROOT / "vendor" / "fluidaudio"
PACKAGES = ROOT / "scripts" / "vendor-packages.txt"
VENDOR_LOCK = ROOT / "scripts" / "vendor.lock"
REQ_LOCK = ROOT / "scripts" / "requirements.lock"
# Источники пакетов для `site` и `lock`: venv с версиями из scripts/requirements.lock. По умолчанию — внутри
# репозитория; соседний transcriber не нужен (у автора его venv передаётся явно: `--tr ../transcriber/.venv`).
DEFAULT_TR = ROOT / "engine" / ".venv-vendor"
DEFAULT_LLM = ROOT / "engine" / ".venv-llm"
VENV_HINT = """Нужен venv с пакетами из scripts/vendor-packages.txt в версиях scripts/requirements.lock, на том же Python,
что в vendor/python, например:
    python3.14 -m venv engine/.venv-vendor
    engine/.venv-vendor/bin/pip install -r scripts/requirements.lock
Один venv годится для обоих источников: без engine/.venv-llm пакеты llm берутся из --tr.
Другая папка — флагами --tr и --llm."""
# Что из репозитория попадает в бандл или собирает его: грязное здесь — грязный выпуск.
VENDORED_TRANSCRIBER = ROOT / "engine" / "vendor_transcriber"
REPO_BUNDLE_PATHS = ("Package.swift", "Sources", "Resources", "engine", "bin", "integrations",
                     "scripts", "release")
SBOM_FORMAT = "mostik-vendor/1"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def norm(name: str) -> str:
    return re.sub(r"[-_.]+", "_", name).lower()


# --- lock-файлы ----------------------------------------------------------------------

def load_vendor_lock(path: Path | None = None) -> dict:
    return json.loads((path or VENDOR_LOCK).read_text(encoding="utf-8"))


def load_requirements_lock(path: Path | None = None) -> dict[str, tuple[str, str]]:
    """`имя==версия  # record-sha256=<hex>` → {norm(имя): (версия, hex)}."""
    out: dict[str, tuple[str, str]] = {}
    for raw in (path or REQ_LOCK).read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Za-z0-9_.\-]+)==(\S+)\s+#\s*record-sha256=([0-9a-f]{64})\s*$", raw)
        if match:
            out[norm(match[1])] = (match[2], match[3])
        elif raw.strip() and not raw.lstrip().startswith("#"):
            raise SystemExit(f"requirements.lock: непонятная строка: {raw!r}")
    return out


def package_list(path: Path | None = None) -> list[tuple[str, str]]:
    rows = []
    for raw in (path or PACKAGES).read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            name, tag = line.split()
            rows.append((name, tag))
    return rows


# --- дистрибутивы и RECORD -----------------------------------------------------------

def site_packages(prefix: Path) -> Path:
    found = sorted(prefix.glob("lib/python3.*/site-packages"))
    if not found:
        raise SystemExit(f"нет site-packages в {prefix}")
    return found[0]


def dist_info(sp: Path, name: str) -> Path:
    for info in sp.glob("*.dist-info"):
        if norm(info.name.removesuffix(".dist-info").rsplit("-", 1)[0]) == norm(name):
            return info
    raise SystemExit(f"в {sp} нет дистрибутива {name}")


def dist_version(info: Path) -> str:
    return info.name.removesuffix(".dist-info").rsplit("-", 1)[1]


def record_files(info: Path) -> list[tuple[Path, str]]:
    """Строки RECORD, которые копируются: без bin/-скриптов venv и кэша байткода."""
    rows = []
    with (info / "RECORD").open(newline="") as handle:
        for row in csv.reader(handle):
            if not row or not row[0]:
                continue
            rel = Path(row[0])
            if rel.is_absolute() or rel.parts[0] == ".." or "__pycache__" in rel.parts:
                continue
            rows.append((rel, row[1] if len(row) > 1 else ""))
    return rows


def record_problems(sp: Path, info: Path) -> list[str]:
    """Каждый файл дистрибутива — против своей строки RECORD (С10). Пусто — всё сходится."""
    problems = []
    record_rel = info.relative_to(sp) / "RECORD"
    for rel, spec in record_files(info):
        path = sp / rel
        if rel == record_rel:
            continue  # сам RECORD хэша не имеет, его сумма — в requirements.lock
        if not spec:
            problems.append(f"{rel}: в RECORD нет хэша")
            continue
        algo, _, want = spec.partition("=")
        if algo != "sha256":
            problems.append(f"{rel}: хэш {algo}, ожидался sha256")
            continue
        if not path.is_file():
            problems.append(f"{rel}: файла нет")
            continue
        got = base64.urlsafe_b64encode(bytes.fromhex(sha256(path))).rstrip(b"=").decode()
        if got != want.rstrip("="):
            problems.append(f"{rel}: sha256 не совпал с RECORD")
    return problems


def lock_problems(info: Path, locked: dict[str, tuple[str, str]]) -> list[str]:
    name = norm(info.name.removesuffix(".dist-info").rsplit("-", 1)[0])
    if name not in locked:
        return [f"{info.name}: нет в requirements.lock"]
    version, record_sha = locked[name]
    problems = []
    if dist_version(info) != version:
        problems.append(f"{info.name}: версия {dist_version(info)}, в requirements.lock {version}")
    if sha256(info / "RECORD") != record_sha:
        problems.append(f"{info.name}: RECORD не совпал с requirements.lock")
    return problems


def clone(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if subprocess.run(["cp", "-c", str(src), str(dst)], capture_output=True).returncode != 0:
        shutil.copy2(src, dst)


def _sources(tr: Path, llm: Path, version: str | None) -> dict[str, Path] | None:
    if llm == DEFAULT_LLM and not llm.exists():
        llm = tr
    for tag, prefix in (("tr", tr), ("llm", llm)):
        if not prefix.is_dir():
            print(f"{tag}: нет venv {prefix}\n{VENV_HINT}", file=sys.stderr)
            return None
    sources = {"tr": site_packages(tr), "llm": site_packages(llm)}
    for tag, sp in sources.items():
        if version and sp.parent.name != version:
            print(f"{tag}: {sp.parent.name} не совпадает с встроенным {version}", file=sys.stderr)
            return None
    return sources


# --- команды -------------------------------------------------------------------------

def extract(archive: Path, sums: Path | None) -> int:
    locked = load_vendor_lock()["python"]
    if archive.name != locked["archive"]:
        print(f"архив {archive.name}, а в scripts/vendor.lock — {locked['archive']}", file=sys.stderr)
        return 1
    actual = sha256(archive)
    if actual != locked["sha256"]:
        print(f"SHA256 не совпал с scripts/vendor.lock: {actual} != {locked['sha256']}", file=sys.stderr)
        return 1
    if sums is not None:
        expected = None
        for line in sums.read_text().splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[1].lstrip("*") == archive.name:
                expected = parts[0].lower()
        if expected != actual:
            print(f"в {sums} другая сумма или нет строки для {archive.name}", file=sys.stderr)
            return 1
    if VENDOR.exists() and any(VENDOR.iterdir()):
        print(f"{VENDOR} не пуста — распаковываю только в пустую папку", file=sys.stderr)
        return 1
    VENDOR.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as tar:
        members = []
        for member in tar.getmembers():
            parts = Path(member.name).parts
            if not parts or parts[0] != "python" or ".." in parts or member.name.startswith("/"):
                print(f"подозрительный путь в архиве: {member.name}", file=sys.stderr)
                return 1
            member.name = str(Path(*parts[1:])) if len(parts) > 1 else "."
            members.append(member)
        tar.extractall(VENDOR, members=members, filter="tar")
    (VENDOR / "MOSTIK-VENDOR.json").write_text(json.dumps(
        {"archive": archive.name, "sha256": actual}, ensure_ascii=False, indent=1) + "\n")
    print(f"OK: {VENDOR} ({archive.name}, sha256 {actual[:16]}…)")
    return 0


def site(tr: Path, llm: Path) -> int:
    if not any(VENDOR.glob("lib/python3.*/site-packages")):
        print(f"нет распакованного Python в {VENDOR} — сначала `vendor_python.py extract --archive …` (docs/packaging.md)",
              file=sys.stderr)
        return 1
    target = site_packages(VENDOR)
    sources = _sources(tr, llm, target.parent.name)
    if sources is None:
        return 1
    locked = load_requirements_lock()
    plan, problems = [], []
    for name, tag in package_list():
        sp = sources[tag]
        info = dist_info(sp, name)
        found = lock_problems(info, locked) + record_problems(sp, info)
        problems += [f"{tag}/{p}" for p in found]
        plan.append((sp, info, tag))
    if problems:  # сначала всё сверить, потом копировать: наполовину собранный site-packages не нужен
        print("пакеты не совпали с RECORD или scripts/requirements.lock:", file=sys.stderr)
        print("\n".join(f"  {p}" for p in problems), file=sys.stderr)
        return 1
    copied = []
    for sp, info, tag in plan:
        files = 0
        for rel, _ in record_files(info):
            src = sp / rel
            if src.is_file():
                clone(src, target / rel)
                files += 1
        copied.append(f"{info.name.removesuffix('.dist-info')} ({tag}, {files} файлов)")
    meta = VENDOR / "MOSTIK-VENDOR.json"
    payload = json.loads(meta.read_text()) if meta.is_file() else {}
    payload["packages"] = copied
    meta.write_text(json.dumps(payload, ensure_ascii=False, indent=1) + "\n")
    print("\n".join(copied))
    return 0


def lock(tr: Path, llm: Path, out: Path | None = None) -> int:
    """Пересобрать requirements.lock из установленных пакетов, без сети (С10).

    Хэшей колёс (`--hash` для pip) офлайн нет: колёса cp314 для numpy, onnxruntime, mlx, regex
    в кэше pip отсутствуют. Поэтому фиксируется SHA256 файла RECORD — а через него каждый файл.
    """
    sources = _sources(tr, llm, None)
    if sources is None:
        return 1
    lines = [
        "# Пакеты встроенного Python Mostik: точная версия и SHA256 файла RECORD дистрибутива.",
        "# Собрано `scripts/vendor_python.py lock` из установленных venv, без сети. Каждый файл пакета",
        "# сверяется с RECORD, RECORD — с этой строкой. Хэшей колёс (pip --hash) здесь нет: офлайн их",
        "# не получить — см. docs/packaging.md, «Цепочка поставки».",
    ]
    problems = []
    for name, tag in package_list():
        info = dist_info(sources[tag], name)
        problems += [f"{tag}/{p}" for p in record_problems(sources[tag], info)]
        lines.append(f"{info.name.removesuffix('.dist-info').rsplit('-', 1)[0]}=={dist_version(info)}"
                     f"  # record-sha256={sha256(info / 'RECORD')}")
    if problems:
        print("файлы в venv не совпадают со своим RECORD — lock не пишу:", file=sys.stderr)
        print("\n".join(f"  {p}" for p in problems), file=sys.stderr)
        return 1
    (out or REQ_LOCK).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"OK: {out or REQ_LOCK} ({len(lines) - 4} пакетов)")
    return 0


def _tree_vs_archive(archive: Path, root: Path, strip: str, skip_extra) -> list[str]:
    """Каждый файл и ссылка архива — на месте и байт в байт; лишнего в дереве нет."""
    problems, seen = [], set()
    with tarfile.open(archive) as tar:
        for member in tar:
            parts = Path(member.name).parts
            if strip:
                if not parts or parts[0] != strip:
                    continue
                parts = parts[1:]
            if not parts or "__pycache__" in parts:
                continue  # байткод bundle.sh удаляет и собирает заново
            rel = Path(*parts)
            seen.add(rel)
            path = root / rel
            if member.isdir():
                continue
            if member.issym():
                if not path.is_symlink() or str(Path(path.readlink())) != str(Path(member.linkname)):
                    problems.append(f"{rel}: ссылка не совпала с архивом")
                continue
            if not member.isfile():
                continue
            if path.is_symlink() or not path.is_file():
                problems.append(f"{rel}: нет файла из архива")
                continue
            handle = tar.extractfile(member)
            digest = hashlib.sha256()
            while chunk := handle.read(1 << 20):
                digest.update(chunk)
            if digest.hexdigest() != sha256(path):
                problems.append(f"{rel}: не совпал с архивом")
    for path in root.rglob("*"):
        rel = path.relative_to(root)
        if rel in seen or path.is_dir() and not path.is_symlink():
            continue
        if not skip_extra(rel):
            problems.append(f"{rel}: лишний файл, его нет в архиве")
    return problems


def fluidaudio_problems(lock: dict, folder: Path | None = None) -> list[str]:
    """vendor/fluidaudio против scripts/vendor.lock: бинарник, его .sha256 и уведомления лицензии."""
    folder = folder or FLUIDAUDIO
    pinned = lock["fluidaudio"]
    binary = folder / pinned["file"]
    problems = []
    if not binary.is_file():
        return [f"fluidaudio: нет {pinned['file']} в vendor/fluidaudio. Скрипт его не качает: возьмите файл по адресу "
                f"{pinned['source']} (или из рабочей копии transcriber), рядом положите .sha256 с суммой, LICENSE и NOTICE.md "
                f"(Apache-2.0, FluidAudio {pinned['upstream']}); все суммы сверятся со scripts/vendor.lock (docs/packaging.md)"]
    if sha256(binary) != pinned["sha256"]:
        problems.append(f"fluidaudio: {pinned['file']} не совпал с scripts/vendor.lock")
    sidecar = binary.with_name(binary.name + ".sha256")
    try:
        published = sidecar.read_text(encoding="utf-8").split()[0].lower()
    except (OSError, IndexError):
        published = ""
    if published != pinned["sha256"]:
        problems.append(f"fluidaudio: {sidecar.name} не совпал с scripts/vendor.lock")
    for name, want in pinned.get("notices", {}).items():
        if not (folder / name).is_file():
            problems.append(f"fluidaudio: нет {name} (лицензия Apache-2.0 едет в бандл)")
        elif sha256(folder / name) != want:
            problems.append(f"fluidaudio: {name} не совпал с scripts/vendor.lock")
    return problems


def fluidaudio(binary: Path | None = None) -> int:
    """Без аргумента — весь vendor/fluidaudio; с `--binary` — один файл против суммы до подписи."""
    lock = load_vendor_lock()
    if binary is None:
        problems = fluidaudio_problems(lock)
    elif not binary.is_file():
        problems = [f"fluidaudio: нет файла {binary}"]
    elif sha256(binary) != lock["fluidaudio"]["sha256"]:
        problems = [f"fluidaudio: {binary.name} не совпал с scripts/vendor.lock ({sha256(binary)[:12]} вместо "
                    f"{lock['fluidaudio']['sha256'][:12]})"]
    else:
        problems = []
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    print(f"OK: fluidaudiocli {lock['fluidaudio']['sha256'][:16]}… совпадает с scripts/vendor.lock")
    return 0


def verify(python_archive: Path | None = None, sparkle_archive: Path | None = None) -> int:
    """Всё, что уйдёт в выпуск, против scripts/vendor.lock и scripts/requirements.lock (С9, С10)."""
    vlock = load_vendor_lock()
    problems: list[str] = []
    # Python: архив, след распаковки, само дерево.
    py = vlock["python"]
    archive = python_archive or PY_DOWNLOAD / py["archive"]
    if not archive.is_file():
        problems.append(f"python: нет архива {archive.name} (vendor/python-download) — сверять не с чем")
    elif sha256(archive) != py["sha256"]:
        problems.append(f"python: {archive.name} не совпал с scripts/vendor.lock")
    meta = VENDOR / "MOSTIK-VENDOR.json"
    if not meta.is_file() or json.loads(meta.read_text()).get("sha256") != py["sha256"]:
        problems.append("python: vendor/python распакован не из архива scripts/vendor.lock")
    target = site_packages(VENDOR)
    sp_rel = target.relative_to(VENDOR)
    locked = load_requirements_lock()
    owned: set[Path] = set()
    for name, tag in package_list():
        info = dist_info(target, name)
        problems += [f"python/{p}" for p in lock_problems(info, locked) + record_problems(target, info)]
        owned |= {sp_rel / rel for rel, _ in record_files(info)}

    def py_extra(rel: Path) -> bool:  # кэш байткода, след распаковки и файлы пакетов из списка
        return "__pycache__" in rel.parts or rel == Path("MOSTIK-VENDOR.json") or rel in owned
    if archive.is_file():
        problems += [f"python/{p}" for p in _tree_vs_archive(archive, VENDOR, "python", py_extra)]
    # Sparkle: архив и распакованная версия, на которую смотрит current.
    sp_lock = vlock["sparkle"]
    s_archive = sparkle_archive or SPARKLE / "dl" / sp_lock["archive"]
    s_dir = SPARKLE / sp_lock["version"]
    if not s_archive.is_file():
        problems.append(f"sparkle: нет архива {s_archive.name} (vendor/sparkle/dl)")
    elif sha256(s_archive) != sp_lock["sha256"]:
        problems.append(f"sparkle: {s_archive.name} не совпал с scripts/vendor.lock")
    else:
        problems += [f"sparkle/{p}" for p in _tree_vs_archive(s_archive, s_dir, "", lambda rel: False)]
    current = SPARKLE / "current"
    if current.resolve() != s_dir.resolve():
        problems.append(f"sparkle: vendor/sparkle/current смотрит не на {sp_lock['version']}")
    # fluidaudiocli: готовый бинарник из transcriber, сумма до подписи — в scripts/vendor.lock.
    problems += fluidaudio_problems(vlock)
    if problems:
        print("vendor не совпал с lock-файлами:", file=sys.stderr)
        print("\n".join(f"  {p}" for p in problems[:50]), file=sys.stderr)
        if len(problems) > 50:
            print(f"  … и ещё {len(problems) - 50}", file=sys.stderr)
        return 1
    print(f"OK: python {py['archive']}, {len(package_list())} пакетов, sparkle {sp_lock['archive']}, "
          f"fluidaudiocli {vlock['fluidaudio']['sha256'][:12]} — "
          "совпадают с scripts/vendor.lock и scripts/requirements.lock")
    return 0


def git_state(path: Path, pathspec: tuple[str, ...] = (".",)) -> dict:
    """Коммит и грязность дерева (С11): изменённые, удалённые и неотслеживаемые файлы в pathspec."""
    def git(*args: str) -> str:
        result = subprocess.run(["git", "-C", str(path), "-c", "core.fsmonitor=false", *args],
                                capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(f"git {' '.join(args)} в {path}: {result.stderr.strip()}")
        return result.stdout
    commit = git("rev-parse", "HEAD").strip()
    changes = [line for line in git("status", "--porcelain", "--untracked-files=all", "--",
                                    *pathspec).splitlines() if line.strip()]
    return {"commit": commit, "dirty": bool(changes), "changes": changes}


def vendored_transcriber_commit(source_md: Path | None = None) -> str:
    """Коммит transcriber, с которого снята копия engine/vendor_transcriber (строка «Коммит:» в SOURCE.md)."""
    text = (source_md or VENDORED_TRANSCRIBER / "SOURCE.md").read_text(encoding="utf-8")
    match = re.search(r"Коммит:\s*`?([0-9a-f]{40})\b", text)
    if not match:
        raise SystemExit("в engine/vendor_transcriber/SOURCE.md нет строки «Коммит: <40 знаков>»")
    return match[1]


def sbom(out: Path, with_python: bool, with_sparkle: bool, repo: Path = ROOT,
         source_md: Path | None = None, with_fluidaudio: bool = False) -> int:
    """MOSTIK-VENDOR.json в бандл (С9): из чего собран выпуск. Без путей машины сборщика."""
    vlock = load_vendor_lock()
    mostik = git_state(repo, REPO_BUNDLE_PATHS)
    payload: dict = {
        "format": SBOM_FORMAT,
        "mostik": {"commit": mostik["commit"], "dirty": mostik["dirty"]},
        "transcriber": None,
        "python": None,
        "packages": [],
        "sparkle": None,
        "fluidaudio": None,
    }
    # Код transcriber — копия в репозитории (П10 С11): его чистоту покрывает dirty у Mostik.
    payload["transcriber"] = {"commit": vendored_transcriber_commit(source_md),
                              "vendored": "engine/vendor_transcriber"}
    if with_python:
        payload["python"] = {k: vlock["python"][k] for k in ("version", "archive", "sha256", "source")}
        locked = load_requirements_lock()
        payload["packages"] = [
            {"name": name, "from": tag, "version": locked[norm(name)][0],
             "record_sha256": locked[norm(name)][1]}
            for name, tag in package_list()]
    if with_sparkle:
        payload["sparkle"] = {k: vlock["sparkle"][k] for k in ("version", "archive", "sha256", "source")}
    if with_fluidaudio:
        # Сумма — до подписи: sign-app.sh сверяет с ней бинарник и только потом переподписывает его.
        fa = vlock["fluidaudio"]
        payload["fluidaudio"] = {**{k: fa[k] for k in ("version", "file", "sha256", "source", "upstream",
                                                       "license")},
                                 "transcriber_commit": fa["taken_from"]["commit"]}
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    ex = sub.add_parser("extract")
    ex.add_argument("--archive", type=Path, required=True)
    ex.add_argument("--sums", type=Path)
    for cmd in ("site", "lock"):
        st = sub.add_parser(cmd)
        st.add_argument("--tr", type=Path, default=DEFAULT_TR)
        st.add_argument("--llm", type=Path, default=DEFAULT_LLM)
    ve = sub.add_parser("verify")
    ve.add_argument("--python-archive", type=Path)
    ve.add_argument("--sparkle-archive", type=Path)
    sb = sub.add_parser("sbom")
    sb.add_argument("--out", type=Path, required=True)
    sb.add_argument("--python", action="store_true")
    sb.add_argument("--sparkle", action="store_true")
    sb.add_argument("--fluidaudio", action="store_true")
    fa = sub.add_parser("fluidaudio")
    fa.add_argument("--binary", type=Path)
    gs = sub.add_parser("git-state")
    gs.add_argument("path", type=Path)
    gs.add_argument("pathspec", nargs="*")
    args = parser.parse_args(argv)
    if args.cmd == "extract":
        return extract(args.archive, args.sums)
    if args.cmd == "site":
        return site(args.tr, args.llm)
    if args.cmd == "lock":
        return lock(args.tr, args.llm)
    if args.cmd == "verify":
        return verify(args.python_archive, args.sparkle_archive)
    if args.cmd == "sbom":
        return sbom(args.out, args.python, args.sparkle, with_fluidaudio=args.fluidaudio)
    if args.cmd == "fluidaudio":
        return fluidaudio(args.binary)
    if args.cmd == "git-state":
        spec = tuple(args.pathspec) or ((".",) if args.path.resolve() != ROOT.resolve() else REPO_BUNDLE_PATHS)
        state = git_state(args.path, spec)
        print(state["commit"])
        for line in state["changes"][:20]:
            print(f"  {line}", file=sys.stderr)
        return 1 if state["dirty"] else 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
