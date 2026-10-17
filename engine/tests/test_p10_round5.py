"""П10, прогон 5: Р5-2 (git мимо кэша xcrun), Р5-3л и Р5-4л (PRIVACY.md говорит правду о хранении), инфо.

Пробы шима идут только в подпроцессах с собственным `xcrun_db` во временной папке: настоящий кэш пользователя
(`getconf DARWIN_USER_TEMP_DIR`/xcrun_db) и `xcode-select` не трогаем.
"""
from __future__ import annotations

import functools
import os
import re
import stat
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from mostik_engine import project_glossary as pg

REPO = Path(__file__).resolve().parent.parent.parent
CLT = "/Library/Developer/CommandLineTools"


# --- Р5-2: шим /usr/bin/git читает кэш xcrun — git вызываем по пути из xcode-select -p -------------------


def _root_stat(_path):
    return SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o755)


def test_git_executable_accepts_only_system_developer_dirs():
    exists = {f"{CLT}/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"}
    # Ф-1: владелец проверяется отдельно (test_git_executable_requires_root_chain), здесь — только форма пути.
    git_executable = functools.partial(pg.git_executable, lstat=_root_stat)
    assert git_executable(CLT, exists.__contains__) == f"{CLT}/usr/bin/git"
    assert git_executable(CLT + "/\n", exists.__contains__) == f"{CLT}/usr/bin/git", "хвост вывода xcode-select"
    assert git_executable("/Applications/Xcode.app/Contents/Developer", exists.__contains__) \
        == "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
    for bad in ("/tmp/evil", "/Users/a/Library/Developer/CommandLineTools", "/Applications/../tmp/x.app/Contents/Developer",
                "/Applications/Xcode.app/Contents/Developer/../../../../tmp", "CommandLineTools", "", "/", None):
        assert git_executable(bad, lambda _: True) is None, bad
    assert git_executable(CLT, lambda _: False) is None, "файла нет — без git, обход папки"


# --- Ф-1 (хвост р5): git только из цепочки, которая целиком принадлежит root -----------------------------

XCODE_DEV = "/Applications/Xcode.app/Contents/Developer"


@pytest.fixture
def fake_applications(tmp_path):
    """Временная папка пользователя в роли корня: `<tmp>/Applications/Xcode.app/…/usr/bin/git`."""
    bin_dir = tmp_path / XCODE_DEV.lstrip("/") / "usr" / "bin"
    bin_dir.mkdir(parents=True)
    git = bin_dir / "git"
    git.write_text("#!/bin/sh\n")
    for path in [*(tmp_path / XCODE_DEV.lstrip("/")).parents][:2] + [tmp_path / XCODE_DEV.lstrip("/"), bin_dir.parent,
                                                                         bin_dir, git]:
        path.chmod(0o755)
    return tmp_path


def _mapped(base):
    return lambda path: os.lstat(str(base) + path)


def _as_root(base):
    def lstat(path):
        st = os.lstat(str(base) + path)
        return SimpleNamespace(st_uid=0, st_mode=st.st_mode)
    return lstat


def test_git_executable_requires_root_chain(fake_applications):
    base = fake_applications
    exists = lambda p: os.access(str(base) + p, os.X_OK)  # noqa: E731
    assert pg.git_executable(XCODE_DEV, exists, lstat=_mapped(base)) is None, "Xcode пользователя (uid ≠ 0) — без git"
    assert pg.git_executable(XCODE_DEV, exists, lstat=_as_root(base)) == XCODE_DEV + "/usr/bin/git", "цепочка root"
    for link, mode in (("/Applications/Xcode.app", 0o775), ("/Applications/Xcode.app/Contents", 0o757),
                       (XCODE_DEV, 0o775), (XCODE_DEV + "/usr/bin", 0o777), (XCODE_DEV + "/usr/bin/git", 0o775)):
        target = Path(str(base) + link)
        target.chmod(mode)
        assert pg.git_executable(XCODE_DEV, exists, lstat=_as_root(base)) is None, f"{link} {oct(mode)}"
        target.chmod(0o755)

    def missing(path):
        if path.endswith("/usr"):
            raise FileNotFoundError(path)
        return _as_root(base)(path)
    assert pg.git_executable(XCODE_DEV, exists, lstat=missing) is None, "звено не читается — без git"

    def user_contents(path):
        return SimpleNamespace(st_uid=501, st_mode=stat.S_IFDIR | 0o755) if path.endswith(".app/Contents") \
            else _as_root(base)(path)
    assert pg.git_executable(XCODE_DEV, exists, lstat=user_contents) is None, "Contents пользователя — без git"

    git = Path(str(base) + XCODE_DEV + "/usr/bin/git")
    git.unlink()
    git.symlink_to("/bin/sh")
    assert pg.git_executable(XCODE_DEV, exists, lstat=_as_root(base)) is None, "git-ссылка — без git"


def test_git_trust_chain_starts_at_app_bundle_or_clt():
    seen: list[str] = []

    def lstat(path):
        seen.append(path)
        if path == "/Applications":
            return SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o775)
        return _root_stat(path)
    assert pg.git_executable(XCODE_DEV, lambda _: True, lstat=lstat) == XCODE_DEV + "/usr/bin/git"
    assert seen == ["/Applications/Xcode.app", "/Applications/Xcode.app/Contents", XCODE_DEV, XCODE_DEV + "/usr",
                    XCODE_DEV + "/usr/bin", XCODE_DEV + "/usr/bin/git"], "/Applications (root:admin 775) не в цепочке"
    seen.clear()
    pg.git_executable(CLT, lambda _: True, lstat=lstat)
    assert seen == [CLT, f"{CLT}/usr", f"{CLT}/usr/bin", f"{CLT}/usr/bin/git"]
    if os.access(f"{CLT}/usr/bin/git", os.X_OK) and os.lstat(CLT).st_uid == 0:
        assert pg.git_executable(CLT) == f"{CLT}/usr/bin/git", "настоящий CLT проходит"


def test_git_owner_checked_on_every_run_not_cached(monkeypatch):
    """Проверка владельцев — перед каждым запуском git: подмену `.app` после старта видно."""
    monkeypatch.setattr(pg, "_developer_dir", lambda: XCODE_DEV)
    calls = []
    monkeypatch.setattr(pg, "git_executable", lambda d: calls.append(d) or None)
    pg._git_path()
    pg._git_path()
    assert calls == [XCODE_DEV, XCODE_DEV]


def test_git_files_uses_resolved_git_not_the_shim(tmp_path, monkeypatch):
    seen: dict = {}

    def fake_run(command, **kwargs):
        seen["command"] = list(command)
        raise OSError("stop")

    repo = tmp_path / "repo"
    (repo / ".git").mkdir(parents=True)
    monkeypatch.setattr(pg, "_git_path", lambda: f"{CLT}/usr/bin/git")
    monkeypatch.setattr(subprocess, "run", fake_run)
    pg._git_files(repo)
    assert seen["command"][0] == f"{CLT}/usr/bin/git"
    source = (REPO / "engine" / "mostik_engine" / "project_glossary.py").read_text(encoding="utf-8")
    assert '"/usr/bin/git"' not in source, "Р5-2: шим /usr/bin/git не вызывается"


def test_git_files_without_git_falls_back_to_walk(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    (repo / ".git").mkdir(parents=True)
    monkeypatch.setattr(pg, "_git_path", lambda: None)
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: pytest.fail("git без проверенного пути не запускается"))
    assert pg._git_files(repo) is None


# --- Ф-5 (хвост р5): xcode-select -p с таймаутом; завис — как отказ ------------------------------------


def _stub(folder: Path, name: str, body: str) -> str:
    path = folder / name
    path.write_text(f"#!/bin/sh\n{body}\n")
    path.chmod(0o755)
    return str(path)


def test_developer_dir_times_out_like_refusal(tmp_path):
    started = time.monotonic()
    assert pg.developer_dir(_stub(tmp_path, "slow", "exec /bin/sleep 30"), timeout=0.3) is None, "завис — None"
    assert time.monotonic() - started < 5, "ждём не дольше таймаута"
    assert pg.developer_dir(_stub(tmp_path, "fast", f"echo {CLT}"), timeout=5) == CLT + "\n"
    assert pg.developer_dir(_stub(tmp_path, "fail", "echo /x; exit 2"), timeout=5) is None, "ошибка — None"
    assert pg.developer_dir(str(tmp_path / "missing"), timeout=5) is None, "нет программы — None"
    assert 0 < pg.XCODE_SELECT_TIMEOUT <= 10


def test_git_path_without_developer_dir_walks_folder(monkeypatch):
    monkeypatch.setattr(pg, "_developer_dir", lambda: None)
    assert pg._git_path() is None


@pytest.fixture
def short_tmp():
    """Короткий путь в /private/tmp: подложенный путь в кэше той же длины, что и настоящий."""
    folder = Path(tempfile.mkdtemp(prefix="mr5-", dir="/private/tmp"))
    yield folder
    shutil.rmtree(folder, ignore_errors=True)


@pytest.mark.skipif(not Path("/usr/bin/xcrun").exists(), reason="нет xcrun")
def test_planted_xcrun_cache_redirects_shim_but_not_mostik_git(short_tmp, monkeypatch):
    real = pg._git_path()
    if not real:
        pytest.skip("xcode-select не дал системного git")
    env = {"HOME": os.environ.get("HOME", "/tmp"), "PATH": "/usr/bin:/bin", "TMPDIR": str(short_tmp) + "/"}
    db = short_tmp / "db"
    subprocess.run(["/usr/bin/xcrun", "--find", "git"], env={**env, "xcrun_db": str(db)}, check=True,
                   capture_output=True, timeout=30)
    data = db.read_bytes()
    if real.encode() not in data:
        pytest.skip("формат кэша xcrun другой")
    marker = short_tmp / "pwned"
    fake_dir = short_tmp / "x"
    fake_dir.mkdir()
    pad = len(real) - len(str(fake_dir)) - 1
    if pad < 1:
        pytest.skip("временная папка длиннее пути git")
    fake = fake_dir / ("g" * pad)
    fake.write_text(f"#!/bin/sh\necho pwned >> '{marker}'\n")
    fake.chmod(0o755)
    db.write_bytes(data.replace(real.encode(), str(fake).encode()))
    poisoned = {**env, "xcrun_db": str(db)}

    # Сам шим: подложенный кэш уводит /usr/bin/git в чужую программу (так было до Р5-2).
    subprocess.run(["/usr/bin/git", "--version"], env=poisoned, capture_output=True, timeout=30)
    if not marker.exists():
        pytest.skip("шим не читает подложенный кэш — проба не воспроизводится на этой системе")
    marker.unlink()

    # Git Mostik — мимо шима: тот же подложенный кэш ни на что не влияет.
    out = subprocess.run([real, "--version"], env=poisoned, capture_output=True, text=True, timeout=30)
    assert out.stdout.startswith("git version") and not marker.exists()
    repo = short_tmp / "repo"
    (repo / ".git").mkdir(parents=True)
    monkeypatch.setenv("xcrun_db", str(db))
    pg._git_files(repo)
    assert not marker.exists(), "Р5-2: построение словаря проекта не запускает подложенный «git»"


# --- Р5-3л: инвентарь хранения — литералы путей из кода против таблицы PRIVACY.md -----------------------


def _privacy_halves() -> tuple[str, str]:
    ru, en = (REPO / "PRIVACY.md").read_text(encoding="utf-8").split("\n---\n", 1)
    return ru, en


def _swift_sources() -> list[Path]:
    return [p for d in ("Mostik", "MostikCore", "MostikKit", "MostikUI") for p in (REPO / "Sources" / d).glob("*.swift")]


# Не данные пользователя или уже названы общим словом в PRIVACY.md.
NOT_STORAGE = {
    "logs": "старое место журналов (до П10 р5), Mostik туда больше не пишет — MostikPaths.legacyLogs",
}


def _stored_names() -> set[str]:
    names: set[str] = set()
    for path in _swift_sources():
        text = path.read_text(encoding="utf-8")
        names.update(re.findall(r'paths\.(?:root|logs)\.appendingPathComponent\("([A-Za-z0-9._-]+)', text))
        names.update(m for m in re.findall(r'paths\.root\.appendingPathComponent\("([A-Za-z0-9._-]+)/', text))
        if path.name in ("Settings.swift", "LogPolicy.swift"):
            names.update(re.findall(r'public var \w+: URL \{ root\.appendingPathComponent\("([A-Za-z0-9._-]+)"', text))
        if path.name in ("AgentQueue.swift", "AgentEvents.swift"):
            names.update(re.findall(r'public static let folderName = "([A-Za-z0-9._-]+)"', text))
    for path in (REPO / "engine" / "mostik_engine").glob("*.py"):
        text = path.read_text(encoding="utf-8")
        names.update(re.findall(r'mostik_home\(\)\)? / "([A-Za-z0-9._-]+)"', text))
        for pair in re.findall(r'mostik_home\(\) / \("([a-z]+)" if [^)]* else "([a-z]+)"\)', text):
            names.update(pair)
        names.update(re.findall(r'^(?:PEOPLE|RECIPES)_DIR = "([a-z-]+)"', text, re.M))
    return {n for n in names if not n.startswith(".")}


def test_privacy_names_every_storage_path_in_code():
    names = _stored_names()
    # Проверка самого сборщика: известные места находятся, иначе тест молча ничего не сверял бы.
    for known in ("history.jsonl", "settings.json", "meeting-prep.json", "styles", "voices", "index.sqlite",
                  "agent-queue", "agent-events", "meeting-hooks.log", "app.log", "crashes", "people", "recipes"):
        assert known in names, f"сборщик не нашёл {known}"
    ru, en = _privacy_halves()
    missing = {label: sorted(n for n in names - NOT_STORAGE.keys() if n not in half)
               for half, label in ((ru, "RU"), (en, "EN"))}
    assert missing == {"RU": [], "EN": []}, missing


def test_privacy_names_temp_files():
    ru, en = _privacy_halves()
    for half, label in ((ru, "RU"), (en, "EN")):
        for name in ("mostik-live-", "mostik-commands-", "transcriber-asr-", "transcriber-download-", "mostik-polish-"):
            assert name in half, f"{label}: нет {name}"
        assert "Mostik-commands" not in half


# --- инфо прогона 5 — в «Принятые риски» --------------------------------------------------------------


def test_release_risks_list_round5_info_with_cloud_address_change():
    text = (REPO / "docs" / "release.md").read_text(encoding="utf-8")
    risks = text.split("## Принятые риски", 1)[1].split("\n## ", 1)[0]
    assert "смена адресата облака" in risks.lower()
    for name in ("ANTHROPIC_BASE_URL", "HTTPS_PROXY", "NODE_EXTRA_CA_CERTS", "AXSecureTextField", "GIT_CONFIG_GLOBAL"):
        assert name in risks, name
    assert "кэшем xcrun" in risks, "проба кэша xcrun описана"
