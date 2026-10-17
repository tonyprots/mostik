"""П10, прогон 3, низкие в движке: Н-2, Н-3, Н-4, Н-5, Н-6.

Только синтетика: бинарник fluidaudiocli — заглушка, модели — пустые файлы во временном доме.
Настоящий бинарник под `sandbox-exec` проверен пробой (`docs/release.md`, «Принятые риски»).
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

from mostik_engine import isolation, meeting as m, privacy, voices as v

ENGINE = Path(__file__).resolve().parent.parent
VENDOR = ENGINE / "vendor_transcriber"


# --- Н-2: векторы голосов во временной папке после SIGKILL -------------------------------------


def test_wipe_removes_stale_voice_scratch_but_not_running_one(tmp_path, monkeypatch, mostik_home):
    tmp = tmp_path / "tmp"
    tmp.mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(tmp))
    old = tmp / "mostik-voices-old"
    old.mkdir()
    (old / "fluid.json").write_text(json.dumps({"segments": [{"embedding": [0.1] * 256}]}))
    busy = tmp / "mostik-voices-busy"
    busy.mkdir()
    other = tmp / "mostik-tracks-x"
    other.mkdir()
    monkeypatch.setattr(v, "_ACTIVE_SCRATCH", {str(busy)}, raising=False)
    v.wipe(mostik_home / "meetings", v.VoiceStore(tmp_path / "voices"))
    assert not old.exists(), "«Стереть отпечатки» убирает векторы, брошенные убитым движком"
    assert busy.exists(), "идущий расчёт не трогаем"
    assert other.exists(), "чужие папки — не наши"


def test_embedder_scratch_is_registered_while_running(tmp_path, monkeypatch):
    seen = {}
    binary = tmp_path / "fluidaudiocli"
    binary.write_text("#!/bin/sh\n")

    def fake_run(command, **kwargs):
        output = Path(command[command.index("--output") + 1])
        seen["active"] = set(getattr(v, "_ACTIVE_SCRATCH", set()))
        seen["scratch"] = str(output.parent)
        output.write_text(json.dumps({"segments": []}))

    monkeypatch.setattr(v.subprocess, "run", fake_run)
    v.FluidAudioEmbedder(binary=binary).embed(tmp_path / "a.wav", {})
    assert seen["scratch"] in seen["active"], "wipe должен знать, какая папка занята"
    assert seen["scratch"] not in getattr(v, "_ACTIVE_SCRATCH", set())


# --- Н-3: рабочая папка внука transcriber не попадает в sys.path ---------------------------------


def test_child_env_sets_safe_path():
    env = isolation.child_env({"PATH": "/usr/bin", "PYTHONSAFEPATH": "0"})
    assert env["PYTHONSAFEPATH"] == "1"
    assert env["PYTHONNOUSERSITE"] == "1"


_SHADOW = r"""
import sys, tempfile
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from audio_transcription import isolated
job = Path(sys.argv[2])
tempfile.mkdtemp = lambda **kwargs: str(job)
try:
    isolated._run_worker("audio_transcription.worker", "probe", {}, job.parent, stall_timeout_seconds=60)
except BaseException as error:
    print(type(error).__name__, file=sys.stderr)
"""


def test_transcriber_grandchild_ignores_planted_package_in_job_dir(tmp_path):
    """Внук transcriber (`python -m audio_transcription.worker`, cwd=job_dir): подложенный в job_dir
    пакет не импортируется. Без `PYTHONSAFEPATH` cwd стоит в `sys.path` раньше `PYTHONPATH`."""
    job = tmp_path / "work" / "asr-job"
    (job / "audio_transcription").mkdir(parents=True)
    marker = tmp_path / "pwned"
    (job / "audio_transcription" / "__init__.py").write_text(
        f"import pathlib; pathlib.Path({str(marker)!r}).write_text('x')\n")
    clean = {"PATH": "/usr/bin:/bin", "HOME": str(tmp_path / "home")}
    # Уровень 2 — как transcribe.py: `-s -E`, окружение движка.
    subprocess.run([sys.executable, "-s", "-E", "-c", _SHADOW, str(VENDOR), str(job)],
                   env=isolation.child_env(privacy.offline_env(clean)), capture_output=True, text=True, timeout=180)
    assert not marker.exists(), "пакет из рабочей папки внука исполнен"


# --- Н-4, Н-5: fluidaudiocli без сети и с той же проверкой суммы ---------------------------------


def _models(home: Path, *, skip: str | None = None, folder: str = "speaker-diarization") -> Path:
    root = home / "Library" / "Application Support" / "FluidAudio" / "Models" / folder
    for name in ("Segmentation", "Embedding", "FBank", "PldaRho"):
        if name != skip:
            (root / f"{name}.mlmodelc").mkdir(parents=True)
            (root / f"{name}.mlmodelc" / "coremldata.bin").write_bytes(b"x")
    for name in ("config.json", "plda-parameters.json", "xvector-transform.json"):
        if name != skip:
            root.mkdir(parents=True, exist_ok=True)
            (root / name).write_text("{}")
    return root


def test_offline_models_need_the_full_set_fluidaudio_reads(tmp_path):
    from mostik_engine import fluid_offline

    assert fluid_offline.models_problem(_models(tmp_path / "full").parents[4]) is None
    assert "FBank" in fluid_offline.models_problem(_models(tmp_path / "fbank", skip="FBank").parents[4])
    assert "xvector" in fluid_offline.models_problem(_models(tmp_path / "x", skip="xvector-transform.json").parents[4])
    # transcriber ставит модели в `speaker-diarization-coreml` — бинарник с ними одними идёт в сеть.
    coreml = _models(tmp_path / "coreml", folder="speaker-diarization-coreml").parents[4]
    assert fluid_offline.models_problem(coreml) is not None


def test_offline_env_sends_model_registry_to_closed_local_port():
    env = privacy.offline_env({"PATH": "/usr/bin", "MODEL_REGISTRY_URL": "https://evil.example"})
    assert env["MODEL_REGISTRY_URL"] == "http://127.0.0.1:9"
    assert env["REGISTRY_URL"] == "http://127.0.0.1:9"
    assert env["HF_HUB_OFFLINE"] == "1"


def _fluid(monkeypatch, tmp_path, *, problem=None, home=None):
    from audio_transcription import catalog, fluid_models

    binary = tmp_path / "fluidaudiocli"
    binary.write_text("#!/bin/sh\n")
    binary.chmod(0o755)
    monkeypatch.setattr(catalog, "fluidaudio_binary_path", lambda *a, **k: binary)
    monkeypatch.setattr(catalog, "bundled_binary_problem", lambda *a, **k: problem)
    monkeypatch.setattr(fluid_models, "ready", lambda *a, **k: True)
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home or tmp_path / "home"))
    return binary


def test_meeting_diarization_needs_full_offline_models(tmp_path, monkeypatch):
    _fluid(monkeypatch, tmp_path, home=_models(tmp_path / "home", skip="FBank").parents[4])
    assert "FluidAudio" in (m.diarization_problem(offline=True) or "")
    _fluid(monkeypatch, tmp_path, home=_models(tmp_path / "home2").parents[4])
    assert m.diarization_problem(offline=True) is None


def test_voice_embedder_needs_full_offline_models(tmp_path, monkeypatch):
    _fluid(monkeypatch, tmp_path, home=_models(tmp_path / "home", skip="FBank").parents[4])
    ok, detail = v.FluidAudioEmbedder().available()
    assert not ok and "FluidAudio" in detail


def test_voice_embedder_checks_bundled_checksum(tmp_path, monkeypatch):
    _fluid(monkeypatch, tmp_path, problem="поставочный fluidaudiocli не совпал с опубликованной суммой",
           home=_models(tmp_path / "home").parents[4])
    ok, detail = v.FluidAudioEmbedder().available()
    assert not ok and "не совпал" in detail


def test_voice_embedder_runs_offline_in_clean_env(tmp_path, monkeypatch):
    binary = _fluid(monkeypatch, tmp_path, home=_models(tmp_path / "home").parents[4])
    monkeypatch.setenv("DYLD_INSERT_LIBRARIES", "/evil.dylib")
    monkeypatch.setenv("PYTHONPATH", "/evil")
    monkeypatch.setenv("MODEL_REGISTRY_URL", "https://evil.example")
    seen = {}

    def fake_run(command, **kwargs):
        seen["command"], seen["env"] = command, kwargs.get("env") or {}
        Path(command[command.index("--output") + 1]).write_text(json.dumps({"segments": []}))

    monkeypatch.setattr(v.subprocess, "run", fake_run)
    assert v.FluidAudioEmbedder().available()[0]
    v.FluidAudioEmbedder().embed(tmp_path / "a.wav", {"Собеседник 1": [(0.0, 1.0)]})
    command, env = seen["command"], seen["env"]
    assert "/usr/bin/sandbox-exec" in command and any("deny network" in part for part in command), command
    assert command.index("/usr/bin/sandbox-exec") < command.index(str(binary))
    assert "DYLD_INSERT_LIBRARIES" not in env and "PYTHONPATH" not in env
    assert env["MODEL_REGISTRY_URL"] == "http://127.0.0.1:9" and env["HF_HUB_OFFLINE"] == "1"


# --- Н-6: выпуск не берёт чужие бинарники Sparkle ------------------------------------------------


def test_release_refuses_sparkle_bin_override():
    source = (ENGINE.parent / "scripts" / "release.sh").read_text(encoding="utf-8")
    loop = next(line for line in source.splitlines() if line.startswith("for override in"))
    assert "MOSTIK_SPARKLE_BIN" in loop.replace(";", " ").split()


# --- Н-9: PRIVACY.md говорит правду о хранении и выходах ------------------------------------------


def test_privacy_lists_what_engine_keeps_and_every_exit():
    from mostik_engine import archive, index

    text = (ENGINE.parent / "PRIVACY.md").read_text(encoding="utf-8")
    ru, en = text.split("\n---\n", 1)
    stored = [index.index_path().name, "briefs/", "digests/", f"{archive.PEOPLE_DIR}/"]
    for half, label in ((ru, "RU"), (en, "EN")):
        for name in stored:
            assert name in half, f"{label}: нет {name}"
        assert "fluidaudiocli" in half, f"{label}: нет fluidaudiocli"
        assert "MOSTIK_MEETING_DIR" in half, f"{label}: нет хука встречи"
    # Обновления: Sparkle без SUEnableSystemProfiling шлёт адрес и версию Mostik, не версию macOS.
    assert "версия приложения и macOS" not in ru and "адрес компьютера" in ru
    assert "app and macOS version" not in en and "IP address" in en
    assert "ничего не собирает" in ru  # общий тон не сломан
