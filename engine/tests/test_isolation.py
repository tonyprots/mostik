"""П10 С1: рабочие процессы движка запускаются изолированно.

`-I` (без user site и его `.pth`, без `PYTHON*`), путь к движку — аргументом загрузчика,
из окружения убраны `PYTHON*`, `DYLD_*`, `LD_*`.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

from mostik_engine import isolation, llm_mlx as L, verifier_worker as V

ENGINE = Path(__file__).resolve().parent.parent
REPO = ENGINE.parent
DIRTY = {
    "PATH": "/usr/bin:/bin", "HOME": "/Users/a", "PYTHONPATH": "/evil", "PYTHONHOME": "/evil",
    "PYTHONSTARTUP": "/evil/x.py", "PYTHONUSERBASE": "/evil", "DYLD_INSERT_LIBRARIES": "/evil.dylib",
    "DYLD_LIBRARY_PATH": "/evil", "LD_PRELOAD": "/evil.so", "HF_HUB_OFFLINE": "1",
}


def _unsafe(env: dict) -> list[str]:
    """`PYTHON*`, `DYLD_*`, `LD_*`, кроме `PYTHONNOUSERSITE=1` и `PYTHONSAFEPATH=1` — их движок ставит
    внукам сам (Р2 Н2, Р3 Н-3)."""
    return sorted(k for k in env if k.startswith(("PYTHON", "DYLD_", "LD_"))
                  and not (k in ("PYTHONNOUSERSITE", "PYTHONSAFEPATH") and env[k] == "1"))


def test_child_env_drops_code_injection_variables():
    env = isolation.child_env(DIRTY)
    assert _unsafe(env) == []
    assert env["PATH"] == "/usr/bin:/bin" and env["HOME"] == "/Users/a" and env["HF_HUB_OFFLINE"] == "1"


def test_module_command_is_isolated_and_passes_engine_dir_as_argument():
    command = isolation.module_command("/py", "mostik_engine.llm_mlx")
    assert command[:3] == ["/py", "-I", "-u"]
    assert "-m" not in command
    boot = command[command.index("-c") + 1]
    assert "runpy.run_module" in boot and str(ENGINE) not in boot
    assert command[-2:] == [str(ENGINE), "mostik_engine.llm_mlx"]


class _Captured(Exception):
    pass


def _capture(monkeypatch) -> dict:
    seen: dict = {}

    def fake_popen(command, **kwargs):
        seen["command"] = list(command)
        seen["env"] = dict(kwargs.get("env") or {})
        raise _Captured()

    monkeypatch.setattr(subprocess, "Popen", fake_popen)
    for key, value in DIRTY.items():
        monkeypatch.setenv(key, value)
    return seen


def test_llm_worker_starts_isolated(monkeypatch, tmp_path):
    seen = _capture(monkeypatch)
    monkeypatch.setattr(L, "model_path", lambda repo, hub=None: tmp_path)
    client = L.LlmClient(L.MODELS[L.DEFAULT_MODEL], python="/py")
    with pytest.raises(_Captured):
        client.ensure()
    assert seen["command"][:3] == ["/py", "-I", "-u"]
    assert seen["command"][-1] == "mostik_engine.llm_mlx"
    assert _unsafe(seen["env"]) == []
    assert seen["env"]["MOSTIK_LLM_MODEL_PATH"] == str(tmp_path)


def test_verifier_worker_starts_isolated(monkeypatch):
    seen = _capture(monkeypatch)
    worker = V.VerifierClient(python="/py")
    with pytest.raises(_Captured):
        worker.ensure()
    assert seen["command"][:3] == ["/py", "-I", "-u"]
    assert seen["command"][-1] == "mostik_engine.verifier_worker"
    assert _unsafe(seen["env"]) == []


def _vendored_python() -> Path | None:
    for candidate in (REPO / "vendor" / "python" / "bin" / "python3",):
        if candidate.is_file():
            return candidate
    return None


@pytest.mark.skipif(_vendored_python() is None, reason="нет vendor/python")
def test_user_site_pth_is_not_executed(tmp_path):
    """Подложенный `.pth` в user site временного HOME: старый запуск его исполняет, новый — нет."""
    python = str(_vendored_python())
    home = tmp_path / "home"
    marker = tmp_path / "pwned"
    clean = {"PATH": "/usr/bin:/bin", "HOME": str(home), "MOSTIK_HOME": str(tmp_path / "m")}
    user_site = subprocess.run([python, "-c", "import site; print(site.getusersitepackages())"],
                               env=clean, capture_output=True, text=True, check=True).stdout.strip()
    assert user_site.startswith(str(home)), "user site должен лежать во временном HOME"
    Path(user_site).mkdir(parents=True)
    (Path(user_site) / "evil.pth").write_text(f"import pathlib; pathlib.Path({str(marker)!r}).write_text('x')\n")

    # Старый способ (`-m` + PYTHONPATH) — .pth исполняется: тест видит атаку.
    subprocess.run([python, "-m", "mostik_engine.paths"], env={**clean, "PYTHONPATH": str(ENGINE)},
                   capture_output=True, check=True, timeout=60)
    assert marker.exists()
    marker.unlink()

    # Новый способ — тот же модуль запускается, .pth молчит.
    done = subprocess.run(isolation.module_command(python, "mostik_engine.paths"),
                          env=isolation.child_env({**clean, "PYTHONPATH": "/evil"}), capture_output=True, timeout=60)
    assert done.returncode == 0, done.stderr
    assert not marker.exists()


def test_transcriber_run_has_no_user_site_and_clean_env(monkeypatch, tmp_path):
    """Прогон transcriber — тоже дочерний Python движка: без user site и без PYTHON*/DYLD_*.

    `-I` здесь нельзя: `transcribe.py` берёт свой пакет из папки скрипта, а `-I` её убирает.
    """
    from mostik_engine import meeting

    command = meeting.build_command(tmp_path / "a.wav", tmp_path / "out", language="ru", diarize=False, speakers=None)
    script_at = next(i for i, part in enumerate(command) if part.endswith("transcribe.py"))
    assert command[script_at - 2:script_at] == ["-s", "-E"], command[:script_at]
    seen = _capture(monkeypatch)
    with pytest.raises(_Captured):
        meeting.run_track(["/py", "x"], track="mic", index=0, count=1, emit=lambda event: None)
    assert _unsafe(seen["env"]) == []
    assert seen["env"]["HF_HUB_OFFLINE"] == "1"


# --- Р2 Н2: внуки transcriber (worker, diarization_worker) — тоже без user site ---------------------

VENDOR = ENGINE / "vendor_transcriber"


def _plant_pth(python: str, tmp_path: Path) -> tuple[dict, Path]:
    """Временный HOME с `.pth` в user site: каждый процесс Python, который его прочтёт, оставит файл."""
    home = tmp_path / "home"
    marks = tmp_path / "marks"
    marks.mkdir()
    clean = {"PATH": "/usr/bin:/bin", "HOME": str(home), "MOSTIK_HOME": str(tmp_path / "m")}
    user_site = subprocess.run([python, "-c", "import site; print(site.getusersitepackages())"],
                               env=clean, capture_output=True, text=True, check=True).stdout.strip()
    assert user_site.startswith(str(home)), "user site должен лежать во временном HOME"
    Path(user_site).mkdir(parents=True)
    (Path(user_site) / "evil.pth").write_text(
        "import os, sys; open(os.path.join(%r, str(os.getpid())), 'w').write(' '.join(sys.argv))\n" % str(marks))
    return clean, marks


# Уровень 2 (transcribe.py) запускает уровень 3 своим `isolated._run_worker`, как в настоящем прогоне.
# Запрос пустой: воркер падает сразу, но user site обрабатывается до первого импорта — этого хватает.
_GRANDCHILDREN = r"""
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from audio_transcription import isolated
for module in ("audio_transcription.worker", "audio_transcription.diarization_worker"):
    try:
        isolated._run_worker(module, "probe", {}, Path(sys.argv[2]), stall_timeout_seconds=60)
    except BaseException as error:
        print(module, type(error).__name__, file=sys.stderr)
"""


@pytest.mark.skipif(_vendored_python() is None, reason="нет vendor/python")
def test_transcriber_grandchildren_skip_user_site(tmp_path):
    """Движок (-I) → transcriber (-s -E) → worker и diarization_worker: `.pth` не исполняет никто."""
    from mostik_engine import meeting, privacy

    python = str(_vendored_python())
    clean, marks = _plant_pth(python, tmp_path)

    # Проба работает: Python без флагов `.pth` исполняет.
    subprocess.run([python, "-c", "pass"], env=clean, check=True, timeout=60)
    assert len(list(marks.iterdir())) == 1
    for mark in marks.iterdir():
        mark.unlink()

    # Уровень 1 — движок, как его запускает приложение.
    subprocess.run(isolation.module_command(python, "mostik_engine.paths"), env=isolation.child_env(clean),
                   capture_output=True, check=True, timeout=60)
    # Уровни 2 и 3 — флаги transcribe.py из build_command и окружение из run_track.
    command = meeting.build_command(tmp_path / "a.wav", tmp_path / "out", language="ru", diarize=True, speakers=None)
    script_at = next(i for i, part in enumerate(command) if part.endswith("transcribe.py"))
    flags = command[command.index(meeting.transcriber_python()) + 1:script_at]
    env = isolation.child_env(privacy.offline_env(clean))
    done = subprocess.run([python, *flags, "-c", _GRANDCHILDREN, str(VENDOR), str(tmp_path)], env=env,
                          capture_output=True, text=True, timeout=180)
    assert "audio_transcription.diarization_worker" in done.stderr, done.stderr
    leaked = {mark.name: mark.read_text() for mark in marks.iterdir()}
    assert leaked == {}, f".pth исполнен в процессах: {leaked}"
