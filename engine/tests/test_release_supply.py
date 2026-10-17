"""Сборка и поставка (П10): пути сборщика в бандле, закреплённые суммы, RECORD пакетов, SBOM."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
NEEDLE = "/Users/builder-p10"


def _run(*args: str | Path) -> subprocess.CompletedProcess:
    return subprocess.run([str(a) for a in args], capture_output=True, text=True)


# --- С5: пути сборщика ---------------------------------------------------------------

def _fake_app(tmp_path: Path) -> Path:
    app = tmp_path / "Mostik.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/MacOS/Mostik").write_bytes(b"\xcf\xfa\xed\xfe clean binary")
    (app / "Contents/Info.plist").write_text("<plist/>")
    (app / "Contents/Resources/python/lib").mkdir(parents=True)
    return app


def test_leak_check_catches_path_in_thousands_of_pyc(tmp_path):
    # Старая проверка (`grep -r -l … | head -5` под pipefail) молчала: grep получал SIGPIPE,
    # присваивание падало, и ветка ошибки не выполнялась. Нужно много файлов, как в настоящем бандле.
    app = _fake_app(tmp_path)
    lib = app / "Contents/Resources/python/lib"
    for i in range(1500):
        name = f"module_with_a_rather_long_name_for_pipe_buffer_{i:05d}.cpython-314.pyc"
        (lib / name).write_bytes(b"\x2b\x0e\r\n" + b"\0" * 12 + b"\xe3" + f"{NEEDLE}/x/{i}.py".encode())
    result = _run("bash", SCRIPTS / "check-leaks.sh", app, NEEDLE)
    assert result.returncode != 0, result.stderr


def test_leak_check_looks_into_frameworks_and_binary(tmp_path):
    app = _fake_app(tmp_path)
    fw = app / "Contents/Frameworks/Sparkle.framework"
    fw.mkdir(parents=True)
    (fw / "Sparkle").write_bytes(b"\0\0" + f"{NEEDLE}/src/Sparkle.m".encode())
    assert _run("bash", SCRIPTS / "check-leaks.sh", app, NEEDLE).returncode != 0


def test_leak_check_passes_clean_bundle(tmp_path):
    app = _fake_app(tmp_path)
    (app / "Contents/Resources/python/lib/ok.pyc").write_bytes(b"Mostik.app/Contents/Resources/engine/x.py")
    result = _run("bash", SCRIPTS / "check-leaks.sh", app, NEEDLE)
    assert result.returncode == 0, result.stderr


def test_bytecode_does_not_remember_build_directory(tmp_path):
    res = tmp_path / "build-host" / "Mostik.app/Contents/Resources"
    pkg = res / "engine/pkg"
    pkg.mkdir(parents=True)
    (pkg / "mod.py").write_text("def boom():\n    raise ValueError('x')\n")
    result = _run("bash", SCRIPTS / "compile-bytecode.sh", sys.executable, res, res / "engine")
    assert result.returncode == 0, result.stderr
    pycs = list(res.rglob("*.pyc"))
    assert pycs
    for pyc in pycs:
        assert str(tmp_path).encode() not in pyc.read_bytes(), pyc
    # Путь в трейсбеке — внутри бандла, без машины сборщика.
    assert b"Mostik.app/Contents/Resources/engine/pkg/mod.py" in pycs[0].read_bytes()



def test_bytecode_rewrites_pyc_left_by_imports(tmp_path):
    # Python, собирающий байткод, сам импортирует часть своей stdlib (encodings, pathlib,
    # multiprocessing у -j 0) и пишет для неё обычные .pyc с полным путём. Без -f compileall
    # считает их свежими и пропускает: в первой сборке после правки так остались 93 файла.
    import py_compile
    res = tmp_path / "build-host" / "Mostik.app/Contents/Resources"
    lib = res / "python/lib"
    lib.mkdir(parents=True)
    (lib / "imported_at_startup.py").write_text("X = 1\n")
    py_compile.compile(str(lib / "imported_at_startup.py"))
    stale = next(lib.rglob("*.pyc"))
    assert str(tmp_path).encode() in stale.read_bytes()
    result = _run("bash", SCRIPTS / "compile-bytecode.sh", sys.executable, res, lib)
    assert result.returncode == 0, result.stderr
    assert str(tmp_path).encode() not in stale.read_bytes()


# --- С9, С10, С11: закреплённые суммы, RECORD, SBOM, грязное дерево ---------------------

import base64
import hashlib
import importlib.util
import io
import json
import re
import tarfile

SPEC = importlib.util.spec_from_file_location("mostik_vendor_python", SCRIPTS / "vendor_python.py")
vp = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vp)


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()


def _venv(root: Path, files: dict[str, bytes], name: str = "demo", version: str = "1.0") -> Path:
    sp = root / "lib/python3.14/site-packages"
    info = sp / f"{name}-{version}.dist-info"
    info.mkdir(parents=True)
    rows = []
    for rel, data in {**files, f"{info.name}/METADATA": b"Name: demo\n"}.items():
        (sp / rel).parent.mkdir(parents=True, exist_ok=True)
        (sp / rel).write_bytes(data)
        rows.append(f"{rel},sha256={_b64(data)},{len(data)}")
    rows += [f"{info.name}/RECORD,,", f"demo/__pycache__/x.cpython-314.pyc,,", "../../../bin/demo,sha256=AAAA,1"]
    (info / "RECORD").write_text("\n".join(rows) + "\n")
    return sp


def _layout(tmp_path: Path, monkeypatch, files=None) -> dict:
    """vendor/python с пустым site-packages, venv с пакетом demo и lock-файлы под ним."""
    vendor = tmp_path / "vendor/python"
    (vendor / "lib/python3.14/site-packages").mkdir(parents=True)
    tr = tmp_path / "tr"
    sp = _venv(tr, files or {"demo/__init__.py": b"VALUE = 1\n", "demo/core.so": b"\xcf\xfa\xed\xfe"})
    llm = tmp_path / "llm"
    (llm / "lib/python3.14/site-packages").mkdir(parents=True)
    packages = tmp_path / "vendor-packages.txt"
    packages.write_text("demo tr\n")
    req = tmp_path / "requirements.lock"
    record_sha = hashlib.sha256((sp / "demo-1.0.dist-info/RECORD").read_bytes()).hexdigest()
    req.write_text(f"# lock\ndemo==1.0  # record-sha256={record_sha}\n")
    for attr, value in {"VENDOR": vendor, "PACKAGES": packages, "REQ_LOCK": req}.items():
        monkeypatch.setattr(vp, attr, value)
    return {"vendor": vendor, "tr": tr, "llm": llm, "sp": sp, "req": req}


def test_site_copies_files_that_match_record(tmp_path, monkeypatch):
    lay = _layout(tmp_path, monkeypatch)
    assert vp.site(lay["tr"], lay["llm"]) == 0
    assert (lay["vendor"] / "lib/python3.14/site-packages/demo/__init__.py").read_bytes() == b"VALUE = 1\n"


def test_site_and_fluidaudio_explain_what_is_missing(tmp_path, monkeypatch, capsys):
    # П8: без соседнего transcriber и без vendor/ — понятная остановка, а не трассировка.
    lay = _layout(tmp_path, monkeypatch)
    assert vp.site(tmp_path / "нет-venv", lay["llm"]) == 1
    assert "pip install -r scripts/requirements.lock" in capsys.readouterr().err
    monkeypatch.setattr(vp, "VENDOR", tmp_path / "пусто")
    assert vp.site(lay["tr"], lay["llm"]) == 1
    assert "extract" in capsys.readouterr().err
    problems = vp.fluidaudio_problems(vp.load_vendor_lock(), tmp_path / "нет-fluidaudio")
    assert len(problems) == 1 and vp.load_vendor_lock()["fluidaudio"]["source"] in problems[0]


def test_default_sources_live_in_the_repository():
    assert vp.ROOT in vp.DEFAULT_TR.parents and vp.ROOT in vp.DEFAULT_LLM.parents


def test_site_refuses_file_changed_after_install(tmp_path, monkeypatch):
    # С10: файл в venv подменён после установки — RECORD это видит, копирование не начинается.
    lay = _layout(tmp_path, monkeypatch)
    (lay["sp"] / "demo/__init__.py").write_bytes(b"import os; os.system('evil')\n")
    assert vp.site(lay["tr"], lay["llm"]) == 1
    assert not (lay["vendor"] / "lib/python3.14/site-packages/demo").exists()


def test_site_refuses_package_not_in_lock(tmp_path, monkeypatch):
    lay = _layout(tmp_path, monkeypatch)
    lay["req"].write_text("demo==0.9  # record-sha256=" + "0" * 64 + "\n")
    assert vp.site(lay["tr"], lay["llm"]) == 1


def _tar(path: Path, entries: dict[str, bytes | str], mode: str) -> str:
    with tarfile.open(path, mode) as tar:
        for name, data in entries.items():
            info = tarfile.TarInfo(name)
            if isinstance(data, str):
                info.type, info.linkname = tarfile.SYMTYPE, data
                tar.addfile(info)
            else:
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
    return hashlib.sha256(path.read_bytes()).hexdigest()


FA_BINARY = b"\xcf\xfa\xed\xfe fluidaudiocli pinned"
FA_NOTICES = {"LICENSE": b"Apache License 2.0\n", "NOTICE.md": b"# FluidAudio CLI\n"}


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _fluidaudio(root: Path, monkeypatch) -> Path:
    """vendor/fluidaudio как после копирования из transcriber: бинарник, его .sha256 и уведомления."""
    fa = root / "vendor/fluidaudio"
    fa.mkdir(parents=True)
    (fa / "fluidaudiocli").write_bytes(FA_BINARY)
    (fa / "fluidaudiocli").chmod(0o755)
    (fa / "fluidaudiocli.sha256").write_text(f"{_sha(FA_BINARY)}  fluidaudiocli\n")
    for name, data in FA_NOTICES.items():
        (fa / name).write_bytes(data)
    monkeypatch.setattr(vp, "FLUIDAUDIO", fa, raising=False)
    return fa


def _vendor_lock(tmp_path: Path, monkeypatch, py_sha: str, sp_sha: str) -> Path:
    lock = tmp_path / "vendor.lock"
    lock.write_text(json.dumps({
        "python": {"version": "3.14.0", "archive": "cpython-test.tar.gz", "sha256": py_sha, "source": "https://x"},
        "sparkle": {"version": "9.9", "archive": "Sparkle-9.9.tar.xz", "sha256": sp_sha, "source": "https://y"},
        "fluidaudio": {"version": "5c19d5e", "file": "fluidaudiocli", "sha256": _sha(FA_BINARY), "source": "https://z",
                       "upstream": "https://u", "license": "Apache-2.0",
                       "notices": {name: _sha(data) for name, data in FA_NOTICES.items()}},
    }))
    monkeypatch.setattr(vp, "VENDOR_LOCK", lock)
    return lock


def test_extract_trusts_tracked_lock_not_release_sums(tmp_path, monkeypatch):
    # С9: архив и SHA256SUMS из одного (подменённого) релиза согласны между собой — этого мало.
    archive = tmp_path / "cpython-test.tar.gz"
    sha = _tar(archive, {"python/bin/python3": b"evil"}, "w:gz")
    sums = tmp_path / "SHA256SUMS"
    sums.write_text(f"{sha}  {archive.name}\n")
    _vendor_lock(tmp_path, monkeypatch, "1" * 64, "2" * 64)
    monkeypatch.setattr(vp, "VENDOR", tmp_path / "vendor/python")
    assert vp.extract(archive, sums) == 1
    assert not (tmp_path / "vendor/python/bin").exists()


def _full_vendor(tmp_path: Path, monkeypatch) -> dict:
    lay = _layout(tmp_path, monkeypatch)
    dl = tmp_path / "vendor/python-download"
    dl.mkdir(parents=True)
    py_archive = dl / "cpython-test.tar.gz"
    py_sha = _tar(py_archive, {"python/bin/python3": b"#python", "python/lib/python3.14/os.py": b"# os\n",
                               "python/lib/python3.14/site-packages/README.txt": b"readme"}, "w:gz")
    sparkle = tmp_path / "vendor/sparkle"
    (sparkle / "dl").mkdir(parents=True)
    sp_archive = sparkle / "dl/Sparkle-9.9.tar.xz"
    sp_sha = _tar(sp_archive, {"./Sparkle.framework/Versions/B/Sparkle": b"\xcf\xfa\xed\xfe sparkle",
                               "./Sparkle.framework/Sparkle": "Versions/Current/Sparkle",
                               "./bin/sign_update": b"\xcf\xfa\xed\xfe sign"}, "w:xz")
    _vendor_lock(tmp_path, monkeypatch, py_sha, sp_sha)
    lay["fluidaudio"] = _fluidaudio(tmp_path, monkeypatch)
    monkeypatch.setattr(vp, "PY_DOWNLOAD", dl)
    monkeypatch.setattr(vp, "SPARKLE", sparkle)
    for archive, dest, strip in ((py_archive, lay["vendor"], "python/"), (sp_archive, sparkle / "9.9", "./")):
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                member.name = member.name.removeprefix(strip)
                tar.extract(member, dest, filter="tar")
    (sparkle / "current").symlink_to("9.9")
    (lay["vendor"] / "MOSTIK-VENDOR.json").write_text(json.dumps({"sha256": py_sha}))
    assert vp.site(lay["tr"], lay["llm"]) == 0
    return lay


def test_verify_passes_untouched_vendor(tmp_path, monkeypatch):
    _full_vendor(tmp_path, monkeypatch)
    assert vp.verify() == 0


def test_verify_catches_tampered_sparkle(tmp_path, monkeypatch):
    _full_vendor(tmp_path, monkeypatch)
    (tmp_path / "vendor/sparkle/9.9/bin/sign_update").write_bytes(b"\xcf\xfa\xed\xfe other")
    assert vp.verify() == 1


def test_verify_catches_planted_pth_and_changed_package(tmp_path, monkeypatch):
    lay = _full_vendor(tmp_path, monkeypatch)
    target = lay["vendor"] / "lib/python3.14/site-packages"
    (target / "zzz-hook.pth").write_text("import evil\n")
    assert vp.verify() == 1
    (target / "zzz-hook.pth").unlink()
    assert vp.verify() == 0
    (target / "demo/__init__.py").write_bytes(b"VALUE = 2\n")
    assert vp.verify() == 1


def test_verify_catches_archive_not_matching_lock(tmp_path, monkeypatch):
    _full_vendor(tmp_path, monkeypatch)
    _vendor_lock(tmp_path, monkeypatch, "3" * 64, json.loads(vp.VENDOR_LOCK.read_text())["sparkle"]["sha256"])
    assert vp.verify() == 1


def test_verify_catches_swapped_fluidaudiocli(tmp_path, monkeypatch):
    # Готовый fluidaudiocli из transcriber закреплён суммой в scripts/vendor.lock: подмена в vendor/
    # должна остановить выпуск, даже если рядом лежит «согласная» с ней .sha256.
    lay = _full_vendor(tmp_path, monkeypatch)
    assert vp.verify() == 0
    evil = b"\xcf\xfa\xed\xfe fluidaudiocli swapped"
    (lay["fluidaudio"] / "fluidaudiocli").write_bytes(evil)
    (lay["fluidaudio"] / "fluidaudiocli.sha256").write_text(f"{_sha(evil)}  fluidaudiocli\n")
    assert vp.verify() == 1


def test_verify_requires_fluidaudiocli_and_its_notices(tmp_path, monkeypatch):
    lay = _full_vendor(tmp_path, monkeypatch)
    (lay["fluidaudio"] / "NOTICE.md").unlink()
    assert vp.verify() == 1
    (lay["fluidaudio"] / "NOTICE.md").write_bytes(FA_NOTICES["NOTICE.md"])
    (lay["fluidaudio"] / "fluidaudiocli").unlink()
    assert vp.verify() == 1


def test_fluidaudio_command_checks_one_binary_against_lock(tmp_path, monkeypatch):
    # sign-app.sh сверяет бинарник в бандле с vendor.lock до переподписи этой командой.
    lay = _full_vendor(tmp_path, monkeypatch)
    binary = lay["fluidaudio"] / "fluidaudiocli"
    assert vp.main(["fluidaudio", "--binary", str(binary)]) == 0
    binary.write_bytes(b"\xcf\xfa\xed\xfe other")
    assert vp.main(["fluidaudio", "--binary", str(binary)]) == 1


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), "-c", "user.email=t@t", "-c", "user.name=t", *args],
                          check=True, capture_output=True, text=True).stdout


def _repo(path: Path) -> Path:
    path.mkdir(parents=True)
    _git(path, "init", "-q")
    (path / "engine").mkdir()
    (path / "engine/a.py").write_text("a = 1\n")
    (path / "notes.md").write_text("x\n")
    _git(path, "add", ".")
    _git(path, "commit", "-q", "-m", "init")
    return path


def test_git_state_sees_modified_and_untracked_in_bundle_paths(tmp_path):
    repo = _repo(tmp_path / "repo")
    assert vp.git_state(repo, ("engine",))["dirty"] is False
    (repo / "notes.md").write_text("changed outside bundle\n")
    (repo / "drafts").mkdir()
    (repo / "drafts/x.md").write_text("draft\n")
    assert vp.git_state(repo, ("engine",))["dirty"] is False
    (repo / "engine/new.py").write_text("planted = True\n")
    assert vp.git_state(repo, ("engine",))["dirty"] is True
    (repo / "engine/new.py").unlink()
    (repo / "engine/a.py").write_text("a = 2\n")
    state = vp.git_state(repo, ("engine",))
    assert state["dirty"] is True and len(state["commit"]) == 40


def test_git_state_cli_fails_on_dirty_tree(tmp_path):
    repo = _repo(tmp_path / "tr")
    assert vp.main(["git-state", str(repo)]) == 0
    (repo / "engine/a.py").write_text("a = 3\n")
    assert vp.main(["git-state", str(repo)]) == 1


def test_sbom_records_commits_versions_and_no_paths(tmp_path, monkeypatch):
    _full_vendor(tmp_path, monkeypatch)
    repo = _repo(tmp_path / "mostik")
    (repo / "engine/a.py").write_text("dirty\n")
    source = tmp_path / "SOURCE.md"
    source.write_text("- Коммит: " + "ab" * 20 + " (2026-10-11)\n")
    out = tmp_path / "MOSTIK-VENDOR.json"
    lock = json.loads(vp.VENDOR_LOCK.read_text())
    lock["fluidaudio"]["taken_from"] = {"commit": "cd" * 20}
    vp.VENDOR_LOCK.write_text(json.dumps(lock))
    assert vp.sbom(out, with_python=True, with_sparkle=True, repo=repo, source_md=source,
                   with_fluidaudio=True) == 0
    data = json.loads(out.read_text())
    assert data["mostik"] == {"commit": _git(repo, "rev-parse", "HEAD").strip(), "dirty": True}
    assert data["transcriber"] == {"commit": "ab" * 20, "vendored": "engine/vendor_transcriber"}
    assert data["python"]["sha256"] == json.loads(vp.VENDOR_LOCK.read_text())["python"]["sha256"]
    assert data["packages"][0]["name"] == "demo" and data["packages"][0]["version"] == "1.0"
    assert data["sparkle"]["version"] == "9.9"
    assert data["fluidaudio"]["sha256"] == _sha(FA_BINARY), "сумма до подписи, как в vendor.lock"
    assert data["fluidaudio"]["transcriber_commit"] == "cd" * 20
    assert str(tmp_path) not in out.read_text() and "/Users/" not in out.read_text()


# --- С2 и мелочи выпуска: release.sh отказывает до сборки -------------------------------

import os


def _release(tmp_path: Path, *args: str, **env: str) -> subprocess.CompletedProcess:
    # Отказы ниже стоят в release.sh до связки ключей и сборки. Подменить Sparkle заглушкой через
    # MOSTIK_SPARKLE_BIN с р3 Н-6 нельзя: выпуск этот override сам отвергает.
    base = {k: v for k, v in os.environ.items() if not k.startswith(("MOSTIK_", "DEVELOPER_ID", "TEAM_ID"))}
    base.update({"MOSTIK_RELEASE_OUT": str(tmp_path / "out"), **env})
    return subprocess.run(["bash", str(SCRIPTS / "release.sh"), *args], capture_output=True, text=True,
                          env=base, timeout=60)


def test_adhoc_release_refuses_to_make_a_feed(tmp_path):
    result = _release(tmp_path, "--adhoc", MOSTIK_DOWNLOAD_URL="https://downloads.example/")
    assert result.returncode != 0
    assert "--adhoc" in result.stderr and "ленту" in result.stderr
    assert not (tmp_path / "out/stage").exists()


def test_release_requires_https_download_url(tmp_path):
    result = _release(tmp_path, MOSTIK_DOWNLOAD_URL="http://downloads.example/")
    assert result.returncode != 0
    assert "MOSTIK_DOWNLOAD_URL должен быть https" in result.stderr


def test_sbom_reads_real_vendored_transcriber_commit():
    assert re.fullmatch(r"[0-9a-f]{40}", vp.vendored_transcriber_commit())


# --- Р2 Н5: .DS_Store образа не помнит, где его собирали ------------------------------------------

import shutil as _shutil
import tempfile as _tempfile

import pytest as _pytest


@_pytest.mark.skipif(not (_shutil.which("hdiutil") and _shutil.which("swift")), reason="нужны hdiutil и swift (macOS)")
def test_dmg_ds_store_has_no_bookmark_with_build_path(tmp_path):
    """Промежуточный образ лежит в папке с «логином»: закладка pBBk тащила этот путь в .DS_Store тома."""
    login_dir = tmp_path / "leakmark-builder"
    login_dir.mkdir()
    image = login_dir / "rw.dmg"
    assert _run("hdiutil", "create", "-quiet", "-size", "4m", "-fs", "HFS+", "-volname", "Mostik", "-ov",
                image).returncode == 0
    mount = Path(_tempfile.mkdtemp(prefix="mostik-dmg-test."))
    try:
        assert _run("hdiutil", "attach", "-quiet", "-readwrite", "-noverify", "-noautoopen", "-nobrowse",
                    "-mountpoint", mount, image).returncode == 0
        try:
            (mount / ".background").mkdir()
            (mount / ".background/background.tiff").write_bytes(b"II*\0")
            done = _run("swift", SCRIPTS / "dmg-layout.swift", "dsstore", mount, "Mostik.app")
            assert done.returncode == 0, done.stderr
            store = (mount / ".DS_Store").read_bytes()
        finally:
            _run("hdiutil", "detach", "-quiet", mount)
    finally:
        _shutil.rmtree(mount, ignore_errors=True)
    assert b"leakmark-builder" not in store and b"leakmark-builder".decode().encode("utf-16-be") not in store
    assert b"pBBk" not in store, "закладку фона не пишем: в ней путь к образу на машине сборщика"
    assert b"icvp" in store and b"background.tiff" in store, "фон по-прежнему задан alias-записью"


def test_leak_check_scans_whole_tree_with_hidden_files(tmp_path):
    """Проверка образа: весь смонтированный том, включая .DS_Store и .background, и голый логин."""
    volume = tmp_path / "Mostik"
    (volume / "Mostik.app/Contents").mkdir(parents=True)
    (volume / ".background").mkdir()
    (volume / ".background/background.tiff").write_bytes(b"II*\0 clean")
    (volume / ".DS_Store").write_bytes(b"Bud1\0\0book\0\0Users\0\0builder-p10\0\0rw.dmg")
    found = _run("bash", SCRIPTS / "check-leaks.sh", "--tree", volume, "builder-p10")
    assert found.returncode == 1, found.stderr
    assert ".DS_Store" in found.stderr
    (volume / ".DS_Store").write_bytes(b"Bud1\0\0icvp\0\0background.tiff")
    clean = _run("bash", SCRIPTS / "check-leaks.sh", "--tree", volume, "builder-p10")
    assert clean.returncode == 0, clean.stderr


def test_release_checks_mounted_dmg_and_builds_rw_image_outside_home():
    script = (SCRIPTS / "release.sh").read_text(encoding="utf-8")
    assert "check-leaks.sh\" --tree" in script, "готовый .dmg проверяется целиком"
    assert "-readonly" in script, "образ на проверку монтируется только на чтение"
    assert '"$OUT/Mostik-rw.dmg"' not in script, "промежуточный образ — во временной папке, не в release-out"


# --- Р2, низкие сборки ------------------------------------------------------------------------

@_pytest.mark.parametrize("mode", ["--adhoc", "--self-signed", "--developer-id"])
def test_release_refuses_feed_url_from_environment(tmp_path, mode):
    """Адрес ленты один — release/release.conf; переменная окружения его не подменяет ни в каком режиме."""
    result = _release(tmp_path, mode, MOSTIK_FEED_URL="https://feed.example/appcast.xml")
    assert result.returncode != 0
    assert "MOSTIK_FEED_URL" in result.stderr and "release/release.conf" in result.stderr
    assert not (tmp_path / "out/stage").exists()


def test_release_conf_pins_feed_repo_and_certificate_slot():
    conf = (ROOT / "release" / "release.conf").read_text(encoding="utf-8")
    values = dict(line.split("=", 1) for line in conf.splitlines() if line and not line.startswith("#"))
    assert values["MOSTIK_FEED_URL"] == "https://tonyprots.github.io/mostik/appcast.xml"
    assert values["MOSTIK_GITHUB_REPO"] == "tonyprots/mostik"
    assert values["MOSTIK_SIGN_CERT_NAME"].strip('"') == "Mostik Release"
    sha = values["MOSTIK_SIGN_CERT_SHA1"]
    assert sha == "" or re.fullmatch(r"[0-9A-F]{40}", sha), "SHA-1 сертификата — 40 знаков в верхнем регистре"


SPARKLE_PRESENT = (ROOT / "vendor/sparkle/current/bin/sign_update").is_file()


@_pytest.mark.skipif(not SPARKLE_PRESENT, reason="нужен vendor/sparkle: до него release.sh останавливается раньше")
def test_self_signed_release_stops_without_pinned_certificate(tmp_path, monkeypatch):
    """Пока SHA-1 не закреплён, самоподписанный выпуск честно останавливается до сборки и связки ключей."""
    conf = (ROOT / "release" / "release.conf").read_text(encoding="utf-8")
    if not re.search(r"^MOSTIK_SIGN_CERT_SHA1=\s*$", conf, re.M):
        _pytest.skip("сертификат уже закреплён")
    result = _release(tmp_path)
    assert result.returncode == 2, result.stderr
    assert "MOSTIK_SIGN_CERT_SHA1" in result.stderr and "Mostik Release" in result.stderr
    assert not (tmp_path / "out/stage").exists()


@_pytest.mark.parametrize("name", ["MOSTIK_TEST_FEED_URL", "MOSTIK_TEST_DOWNLOAD_URL", "MOSTIK_SIGN_CERT_SHA1",
                                    "SPARKLE_ED_KEY_FILE", "MOSTIK_TEST_PUBLIC_ED_KEY"])
def test_test_release_overrides_need_explicit_test_mode(tmp_path, name):
    """Временные сертификат, ключ и лента — только в пробном выпуске: без MOSTIK_TEST_RELEASE=1 — остановка."""
    result = _release(tmp_path, **{name: "http://127.0.0.1:9/x"})
    assert result.returncode != 0
    assert name in result.stderr and "MOSTIK_TEST_RELEASE" in result.stderr
    assert not (tmp_path / "out/stage").exists()


def test_test_release_only_on_loopback(tmp_path):
    env = dict(MOSTIK_TEST_RELEASE="1", MOSTIK_TEST_FEED_URL="https://tonyprots.github.io/mostik/appcast.xml",
               MOSTIK_TEST_DOWNLOAD_URL="http://127.0.0.1:9/", MOSTIK_SIGN_CERT_SHA1="A" * 40,
               SPARKLE_ED_KEY_FILE="/nonexistent", MOSTIK_TEST_PUBLIC_ED_KEY="x")
    result = _release(tmp_path, **env)
    assert result.returncode != 0 and "127.0.0.1" in result.stderr
    result = _release(tmp_path, "--developer-id", **dict(env, MOSTIK_TEST_FEED_URL="http://127.0.0.1:9/a.xml"))
    assert result.returncode != 0 and "самоподписанным" in result.stderr


def test_release_writes_signing_requirement_and_always_on_checks():
    script = (SCRIPTS / "release.sh").read_text(encoding="utf-8")
    assert "--requirement \"$ACTUAL_DR\"" in script, "требование подписи уходит в ленту"
    assert 'certificate leaf = H\\"$CERT_SHA1\\"' in script, "ожидаемое требование — по закреплённому SHA-1"
    assert "SUEnableAutomaticChecks true" in script and "SUEnableAutomaticChecks false" not in script
    sign = (SCRIPTS / "sign-app.sh").read_text(encoding="utf-8")
    assert 'certificate leaf = H\\"$IDENTITY\\"' in sign, "sign-app.sh подписывает с явным требованием"


@_pytest.mark.parametrize("name", ["MOSTIK_VENDOR_PYTHON", "MOSTIK_SPARKLE", "MOSTIK_SPARKLE_BIN"])
def test_release_refuses_vendor_overrides(tmp_path, name):
    """release.sh сверяет vendor/ с lock-файлами — сборка не должна брать Python или Sparkle из другого места."""
    result = _release(tmp_path, "--adhoc", **{name: str(tmp_path / "elsewhere")})
    assert result.returncode != 0
    assert name in result.stderr
    assert not (tmp_path / "out/stage").exists()


def test_copy_tracked_skips_ignored_and_untracked(tmp_path):
    """Движок в бандл — по `git ls-files`: игнорируемое и неотслеживаемое рабочего дерева не едет."""
    repo = tmp_path / "repo"
    engine = repo / "engine"
    (engine / "pkg").mkdir(parents=True)
    (engine / "tests").mkdir()
    (engine / "pkg" / "mod.py").write_text("x = 1\n")
    (engine / "tests" / "test_x.py").write_text("")
    (repo / ".gitignore").write_text("secret.env\n")
    git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
    assert _run("git", "init", "-q", repo).returncode == 0
    assert _run(*git, "add", "-A").returncode == 0
    assert _run(*git, "commit", "-q", "-m", "x").returncode == 0
    (engine / "secret.env").write_text("TOKEN=1\n")
    (engine / "pkg" / "scratch.py").write_text("")
    out = tmp_path / "out"
    done = _run("bash", SCRIPTS / "copy-tracked.sh", engine, out, "tests")
    assert done.returncode == 0, done.stderr
    copied = sorted(str(p.relative_to(out)) for p in out.rglob("*") if p.is_file())
    assert copied == ["pkg/mod.py"]


# --- Сборка в папку за символической ссылкой (/tmp → /private/tmp) ------------------------------

def test_bundle_resolves_output_dir_through_symlinks(tmp_path):
    """MOSTIK_DIST=/tmp/…: движок видит себя по resolve() (/private/tmp/…), а bundle.sh сравнивал
    с путём как есть — проверка импорта встроенным Python падала. Путь вывода нормализуется до сборки."""
    real = tmp_path / "real-out"
    real.mkdir()
    link = tmp_path / "link-out"
    link.symlink_to(real)
    stub = tmp_path / "stub-bin"
    stub.mkdir()
    # Заглушка swift: bundle.sh должен назвать папку сборки раньше, чем начнёт что-то собирать.
    (stub / "swift").write_text("#!/bin/sh\necho 'swift-stub: остановка' >&2\nexit 3\n")
    (stub / "swift").chmod(0o755)
    env = {**os.environ, "PATH": f"{stub}:{os.environ.get('PATH', '')}", "MOSTIK_DIST": str(link)}
    result = subprocess.run(["bash", str(SCRIPTS / "bundle.sh")], capture_output=True, text=True, env=env,
                            timeout=60)
    assert result.returncode == 3, result.stderr
    assert f"{real.resolve()}/Mostik.app" in result.stdout, result.stdout
    assert str(link) not in result.stdout


# --- fluidaudiocli в подписи выпуска -------------------------------------------------------------

VENDOR_FA = ROOT / "vendor/fluidaudio/fluidaudiocli"


def _signable_app(tmp_path: Path, binary: Path) -> tuple[Path, Path]:
    app = tmp_path / "Mostik.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    _shutil.copyfile("/usr/bin/true", app / "Contents/MacOS/Mostik")
    (app / "Contents/MacOS/Mostik").chmod(0o755)
    (app / "Contents/Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
        "<key>CFBundleIdentifier</key><string>app.mostik.mac</string>"
        "<key>CFBundleExecutable</key><string>Mostik</string></dict></plist>\n")
    fa_dir = app / "Contents/Resources/engine/bin/macos-arm64"
    fa_dir.mkdir(parents=True)
    fa = fa_dir / "fluidaudiocli"
    _run("cp", "-c", binary, fa)  # клон APFS: 20 МБ не копируются
    fa.chmod(0o755)
    (fa_dir / "fluidaudiocli.sha256").write_text(f"{vp.sha256(fa)}  fluidaudiocli\n")
    return app, fa


def _sign_app(app: Path, **env: str) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(SCRIPTS / "sign-app.sh"), str(app)], capture_output=True, text=True,
                          env={**os.environ, "SIGN_MODE": "adhoc", **env}, timeout=300)


@_pytest.mark.parametrize("identity", ["", "Mostik Release", "a" * 40, "A" * 39])
def test_sign_app_self_signed_needs_sha1(tmp_path, identity):
    """Самоподписанная подпись — только по SHA-1 сертификата: имя может совпасть у двух сертификатов."""
    result = _sign_app(tmp_path / "Mostik.app", SIGN_MODE="self-signed", SIGN_IDENTITY=identity)
    assert result.returncode != 0
    assert "SIGN_IDENTITY" in result.stderr


def test_sign_app_rejects_unknown_mode(tmp_path):
    result = _sign_app(tmp_path / "Mostik.app", SIGN_MODE="selfsigned")
    assert result.returncode != 0 and "SIGN_MODE" in result.stderr


@_pytest.mark.skipif(not VENDOR_FA.is_file() or not _shutil.which("codesign"),
                     reason="нужны vendor/fluidaudio и codesign (macOS)")
def test_sign_app_refuses_swapped_fluidaudiocli(tmp_path):
    """Подменённый в бандле fluidaudiocli не переподписывается: подпись выпуска не «узаконит» чужой файл."""
    evil = tmp_path / "evil"
    _shutil.copyfile(VENDOR_FA, evil)
    with evil.open("r+b") as handle:  # тот же размер и та же подпись, один байт в конце другой
        handle.seek(-1, 2)
        last = handle.read(1)
        handle.seek(-1, 2)
        handle.write(bytes([last[0] ^ 1]))
    app, fa = _signable_app(tmp_path, evil)
    before = vp.sha256(fa)
    result = _sign_app(app)
    assert result.returncode != 0
    assert "vendor.lock" in result.stderr
    assert vp.sha256(fa) == before, "файл не должен быть переподписан"


@_pytest.mark.skipif(not VENDOR_FA.is_file() or not _shutil.which("codesign"),
                     reason="нужны vendor/fluidaudio и codesign (macOS)")
def test_sign_app_resigns_fluidaudiocli_and_keeps_sum_check_working(tmp_path):
    """После переподписи сумма в .sha256 — уже подписанного файла, и проверка transcriber её принимает."""
    app, fa = _signable_app(tmp_path, VENDOR_FA)
    result = _sign_app(app)
    assert result.returncode == 0, result.stderr
    pinned = json.loads(vp.VENDOR_LOCK.read_text())["fluidaudio"]["sha256"]
    signed = vp.sha256(fa)
    assert signed != pinned, "переподпись меняет файл — иначе проверка ниже ничего не доказывает"
    assert (fa.parent / "fluidaudiocli.sha256").read_text().split()[0] == signed
    assert _run("codesign", "--verify", "--deep", "--strict", app).returncode == 0
    sys.path.insert(0, str(ROOT / "engine/vendor_transcriber"))
    try:
        from audio_transcription import catalog
    finally:
        sys.path.pop(0)
    engine = app / "Contents/Resources/engine"
    assert catalog.bundled_binary_problem(fa, skill_dir=engine) is None
    # Печать ресурсов .app закрывает .sha256: правка ломает подпись приложения.
    (fa.parent / "fluidaudiocli.sha256").write_text(f"{pinned}  fluidaudiocli\n")
    assert _run("codesign", "--verify", "--deep", "--strict", app).returncode != 0
