"""Модели по кнопке (П8, пункт 5): локальный HTTP-сервер с синтетическими файлами, без сети."""
from __future__ import annotations

import hashlib
import http.server
import json
import os
import threading
from pathlib import Path

import pytest

from mostik_engine import model_store as ms


def _spec(key: str, files: dict[str, bytes], *, required: bool = True) -> ms.ModelSpec:
    return ms.ModelSpec(
        key=key, label=key.title(), repo=f"org/{key}", revision="a" * 40, purpose="ru", required=required,
        files=tuple(ms.ModelFile(name, len(data), hashlib.sha256(data).hexdigest()) for name, data in files.items()),
    )


class Server:
    """Отдаёт `/{repo}/resolve/{rev}/{path}` из словаря; Range — по флагу; обрыв — после N байт."""

    def __init__(self, blobs: dict[str, bytes], *, ranges: bool = True) -> None:
        self.blobs = blobs
        self.ranges = ranges
        self.cut_after: dict[str, int] = {}
        self.requests: list[tuple[str, str | None]] = []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):  # noqa: D401 — тихо
                pass

            def do_GET(self):  # noqa: N802
                rng = self.headers.get("Range")
                outer.requests.append((self.path, rng))
                name = self.path.split("/resolve/", 1)[-1].split("/", 1)[-1]
                data = outer.blobs.get(name)
                if data is None:
                    self.send_error(404)
                    return
                start = 0
                if rng and outer.ranges:
                    start = int(rng.split("=")[1].split("-")[0])
                    self.send_response(206)
                    self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
                else:
                    self.send_response(200)
                body = data[start:]
                if outer.cut_after and name in outer.cut_after:
                    body = body[: outer.cut_after.pop(name)]
                    self.send_header("Content-Length", str(len(data) - start))
                    self.end_headers()
                    self.wfile.write(body)
                    self.wfile.flush()
                    self.connection.shutdown(2)
                    return
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.httpd.shutdown()


@pytest.fixture
def blobs():
    return {"config.json": b'{"a": 1}', "model.onnx": os.urandom(3 * ms.CHUNK + 123)}


@pytest.fixture
def server(blobs):
    srv = Server(blobs)
    yield srv
    srv.close()


def test_manifest_is_valid():
    specs = ms.load_manifest()
    keys = [spec.key for spec in specs]
    assert {"silero-vad", "gigaam-v3", "whisper-turbo"} <= set(keys)
    assert len(keys) == len(set(keys))
    for spec in specs:
        assert len(spec.revision) == 40 and spec.files
        for item in spec.files:
            assert item.size > 0 and len(item.sha256) == 64 and not item.path.startswith("/") and ".." not in item.path
    assert all(spec.required for spec in specs if spec.purpose in {"vad", "ru", "en"})


def test_status_sees_hf_cache_layout_with_symlinks(tmp_path, blobs):
    spec = _spec("vad", blobs)
    snap = ms.snapshot_dir(spec, tmp_path)
    snap.mkdir(parents=True)
    store = tmp_path / ms.repo_dir(spec, tmp_path).name / "blobs"
    store.mkdir(parents=True)
    for name, data in blobs.items():
        (store / name).write_bytes(data)
        (snap / name).symlink_to(store / name)
    [row] = ms.status(tmp_path, [spec])
    assert row["installed"] and row["missing_bytes"] == 0


def test_download_verifies_and_installs(tmp_path, server, blobs):
    spec = _spec("vad", blobs)
    events = []
    dl = ms.Downloader(hub=tmp_path, base_url=server.url, specs=[spec])
    assert dl.download(["vad"], events.append) == ["vad"]
    snap = ms.snapshot_dir(spec, tmp_path)
    for name, data in blobs.items():
        assert (snap / name).read_bytes() == data
        assert not (snap / (name + ".part")).exists()
    assert (ms.repo_dir(spec, tmp_path) / "refs" / "main").read_text() == spec.revision
    # Список коммита для huggingface_hub: без него офлайн-загрузчик идёт в сеть.
    tree = json.loads((ms.repo_dir(spec, tmp_path) / "trees" / f"{spec.revision}.json").read_text())
    assert tree["format_version"] == 1 and set(tree["files"]) == set(blobs)
    data = blobs["config.json"]
    assert tree["files"]["config.json"]["blob_id"] == hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
    assert events[-1] == {"key": "vad", "done": spec.size, "total": spec.size, "installed": True}
    assert ms.status(tmp_path, [spec])[0]["installed"]
    # Второй раз — без запросов: всё на месте.
    before = len(server.requests)
    dl.download(["vad"])
    assert len(server.requests) == before


def test_cached_model_is_used_without_download(tmp_path, blobs):
    spec = _spec("vad", blobs)
    snap = ms.snapshot_dir(spec, tmp_path)
    snap.mkdir(parents=True)
    for name, data in blobs.items():
        (snap / name).write_bytes(data)

    def no_network(*args, **kwargs):
        raise AssertionError("в сеть ходить не должны")

    assert ms.Downloader(hub=tmp_path, specs=[spec], opener=no_network).download(["vad"]) == ["vad"]


def test_resume_with_range_after_broken_connection(tmp_path, server, blobs):
    spec = _spec("vad", blobs)
    dl = ms.Downloader(hub=tmp_path, base_url=server.url, specs=[spec])
    server.cut_after = {"model.onnx": ms.CHUNK + 10}
    with pytest.raises(ms.ModelDownloadError) as error:
        dl.download(["vad"])
    assert error.value.code == "network"
    assert "продолжится" in str(error.value)
    part = ms.snapshot_dir(spec, tmp_path) / "config.json.part"
    big = ms.snapshot_dir(spec, tmp_path) / "model.onnx.part"
    assert not part.exists()  # маленький файл докачан целиком
    have = big.stat().st_size
    assert 0 < have < len(blobs["model.onnx"])
    row = ms.status(tmp_path, [spec])[0]
    assert row["partial_bytes"] == have and not row["installed"]
    dl.download(["vad"])
    assert server.requests[-1][1] == f"bytes={have}-"
    assert (ms.snapshot_dir(spec, tmp_path) / "model.onnx").read_bytes() == blobs["model.onnx"]


def test_server_without_range_restarts_file(tmp_path, blobs):
    srv = Server(blobs, ranges=False)
    try:
        spec = _spec("vad", blobs)
        big = ms.snapshot_dir(spec, tmp_path) / "model.onnx.part"
        big.parent.mkdir(parents=True)
        big.write_bytes(blobs["model.onnx"][:1000])
        ms.Downloader(hub=tmp_path, base_url=srv.url, specs=[spec]).download(["vad"])
        assert (ms.snapshot_dir(spec, tmp_path) / "model.onnx").read_bytes() == blobs["model.onnx"]
    finally:
        srv.close()


def test_checksum_mismatch_is_clear_and_cleans_part(tmp_path, server, blobs):
    spec = _spec("vad", blobs)
    server.blobs = dict(blobs, **{"model.onnx": b"x" * len(blobs["model.onnx"])})
    with pytest.raises(ms.ModelDownloadError) as error:
        ms.Downloader(hub=tmp_path, base_url=server.url, specs=[spec]).download(["vad"])
    assert error.value.code == "checksum"
    assert "SHA256" in str(error.value)
    snap = ms.snapshot_dir(spec, tmp_path)
    assert not (snap / "model.onnx.part").exists() and not (snap / "model.onnx").exists()


def test_http_error_and_offline(tmp_path, server, blobs):
    spec = _spec("vad", blobs)
    server.blobs = {}
    with pytest.raises(ms.ModelDownloadError) as error:
        ms.Downloader(hub=tmp_path, base_url=server.url, specs=[spec]).download(["vad"])
    assert error.value.code == "http" and "404" in str(error.value)
    with pytest.raises(ms.ModelDownloadError) as error:
        ms.Downloader(hub=tmp_path, base_url="http://127.0.0.1:9", specs=[spec]).download(["vad"])
    assert error.value.code == "network"


def test_disk_space_checked_before_start(tmp_path, server, blobs):
    spec = _spec("vad", blobs)
    dl = ms.Downloader(hub=tmp_path, base_url=server.url, specs=[spec], free_bytes=lambda path: 10)
    with pytest.raises(ms.ModelDownloadError) as error:
        dl.download(["vad"])
    assert error.value.code == "disk_full"
    assert server.requests == []


def test_cancel_keeps_part_for_resume(tmp_path, server, blobs):
    spec = _spec("vad", blobs)
    dl = ms.Downloader(hub=tmp_path, base_url=server.url, specs=[spec])

    def progress(event):
        if event.get("file") == "model.onnx":
            dl.cancel()

    with pytest.raises(ms.ModelDownloadError) as error:
        dl.download(["vad"], progress)
    assert error.value.code == "cancelled"
    assert (ms.snapshot_dir(spec, tmp_path) / "model.onnx.part").exists()
    dl.download(["vad"])
    assert ms.status(tmp_path, [spec])[0]["installed"]


def test_unknown_model(tmp_path):
    with pytest.raises(ms.ModelDownloadError) as error:
        ms.Downloader(hub=tmp_path, specs=[]).download(["nope"])
    assert error.value.code == "unknown_model"


def test_hub_dir_rules(tmp_path):
    assert ms.hub_dir({"HF_HUB_CACHE": str(tmp_path)}) == tmp_path
    assert ms.hub_dir({"HF_HOME": str(tmp_path)}) == tmp_path / "hub"
    assert ms.hub_dir({"HOME": str(tmp_path)}) == tmp_path / ".cache" / "huggingface" / "hub"


def test_manifest_round_trip(tmp_path):
    path = tmp_path / "m.json"
    path.write_text(json.dumps({"version": 1, "models": [{
        "key": "k", "label": "K", "repo": "o/k", "revision": "b" * 40, "purpose": "llm", "required": False,
        "files": [{"path": "w.bin", "size": 3, "sha256": "A" * 64}]}]}))
    [spec] = ms.load_manifest(path)
    assert spec.size == 3 and spec.files[0].sha256 == "a" * 64 and not spec.required


def test_engine_commands_models_and_download(tmp_path, monkeypatch, server, blobs):
    """Протокол: `models` без сети, `models_download` с событиями хода и ответом, ошибка с кодом."""
    from test_protocol import Sink, send

    from mostik_engine.personal_glossary import PersonalGlossary
    from mostik_engine.server import Engine
    from conftest import FakePool, FakeVerifier

    spec = _spec("vad", blobs)
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({"version": 1, "models": [{
        "key": spec.key, "label": spec.label, "repo": spec.repo, "revision": spec.revision, "purpose": "vad",
        "required": True, "files": [{"path": f.path, "size": f.size, "sha256": f.sha256} for f in spec.files]}]}))
    monkeypatch.setattr(ms, "MANIFEST_PATH", manifest)
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path / "hub"))
    # Адрес зеркала из окружения движок не берёт — только из команды приложения (приватность, п. 8).
    monkeypatch.setenv("MOSTIK_MODELS_BASE_URL", "http://127.0.0.1:9")
    monkeypatch.setattr(ms, "PROGRESS_EVERY_S", 0.0)
    sink = Sink()
    eng = Engine(sink, pool=FakePool(), verifier=FakeVerifier(),
                 personal=PersonalGlossary(tmp_path / "g.yaml", import_transcriber=False))
    send(eng, cmd="models", id=1)
    reply = sink.wait(lambda m: m.get("id") == 1)
    assert reply["models"][0]["installed"] is False and reply["models"][0]["missing_bytes"] == spec.size
    send(eng, cmd="models_download", id=2, keys=[], base_url=server.url)  # пусто — обязательные недостающие
    done = sink.wait(lambda m: m.get("id") == 2)
    assert done["ok"] and done["installed"] == ["vad"] and done["models"][0]["installed"]
    assert any(m.get("event") == "models_progress" and m.get("key") == "vad" for m in sink.lines)
    send(eng, cmd="models_download", id=3, keys=["nope"])
    err = sink.wait(lambda m: m.get("id") == 3)
    assert err["ok"] is False and err["code"] == "models_unknown_model"


# --- Обновление приложения и смена ревизии модели -------------------------------------

def test_manifest_has_its_own_version():
    raw = json.loads(ms.MANIFEST_PATH.read_text(encoding="utf-8"))
    assert isinstance(raw["version"], int) and raw["version"] >= 1, "версия набора моделей — своя, целое число"


def test_new_revision_downloads_only_changed_files(tmp_path, server, blobs):
    """Ревизия сменилась, config.json тот же: качается только изменившийся файл, тот же — из старой ревизии."""
    old = _spec("vad", blobs)
    ms.Downloader(hub=tmp_path, base_url=server.url, specs=[old]).download(["vad"])
    changed = dict(blobs, **{"model.onnx": os.urandom(ms.CHUNK + 7)})
    server.blobs.update(changed)
    new = ms.ModelSpec(key=old.key, label=old.label, repo=old.repo, revision="b" * 40, purpose=old.purpose,
                       required=True, files=tuple(ms.ModelFile(name, len(data), hashlib.sha256(data).hexdigest())
                                                  for name, data in changed.items()))
    server.requests.clear()
    events = []
    assert ms.Downloader(hub=tmp_path, base_url=server.url, specs=[new]).download(["vad"], events.append) == ["vad"]
    fetched = [path.rsplit("/", 1)[-1] for path, _ in server.requests]
    assert fetched == ["model.onnx"], fetched
    snap = ms.snapshot_dir(new, tmp_path)
    assert (snap / "config.json").read_bytes() == blobs["config.json"]
    assert (snap / "model.onnx").read_bytes() == changed["model.onnx"]
    assert any(e.get("reused") and e.get("file") == "config.json" for e in events)
    assert ms.status(tmp_path, [new])[0]["installed"]


def test_reuse_checks_sha256_not_just_size(tmp_path, server, blobs):
    """Файл того же размера с другой суммой из старой ревизии не берётся — качается заново."""
    old = _spec("vad", blobs)
    ms.Downloader(hub=tmp_path, base_url=server.url, specs=[old]).download(["vad"])
    stale = ms.snapshot_dir(old, tmp_path) / "config.json"
    stale.write_bytes(b"x" * len(blobs["config.json"]))  # тот же размер, другая сумма
    new = ms.ModelSpec(key=old.key, label=old.label, repo=old.repo, revision="c" * 40, purpose=old.purpose,
                       required=True, files=old.files)
    server.requests.clear()
    ms.Downloader(hub=tmp_path, base_url=server.url, specs=[new]).download(["vad"])
    fetched = sorted(path.rsplit("/", 1)[-1] for path, _ in server.requests)
    assert fetched == ["config.json"], "испорченный config.json скачан заново, model.onnx взят из старой ревизии"
    assert (ms.snapshot_dir(new, tmp_path) / "config.json").read_bytes() == blobs["config.json"]


def test_reuse_from_hf_blob_store(tmp_path, blobs):
    """Кэш huggingface_hub: LFS-файл лежит в blobs/<sha256> — ставится без сети."""
    spec = _spec("vad", {"model.onnx": blobs["model.onnx"]})
    item = spec.files[0]
    store = ms.repo_dir(spec, tmp_path) / "blobs"
    store.mkdir(parents=True)
    (store / item.sha256).write_bytes(blobs["model.onnx"])
    assert ms.reuse_unchanged(spec, item, tmp_path)
    assert (ms.snapshot_dir(spec, tmp_path) / "model.onnx").read_bytes() == blobs["model.onnx"]


# --- модели FluidAudio ---------------------------------------------------


def _fluid_spec(files: dict[str, bytes]) -> ms.ModelSpec:
    spec = _spec("speaker-diarization", files, required=False)
    return ms.ModelSpec(spec.key, spec.label, spec.repo, spec.revision, "diarization", False, spec.files, "fluidaudio")


@pytest.fixture
def fluid_blobs():
    from mostik_engine import fluid_offline

    out = {f"{name}.mlmodelc/coremldata.bin": os.urandom(300) for name in fluid_offline.MODELS}
    out |= {f"{name}.mlmodelc/model.mil": os.urandom(200) for name in fluid_offline.MODELS}
    out |= {name: b"{}" for name in fluid_offline.FILES}
    # Проверка transcriber (`fluid_models.ready`) смотрит ещё две модели — их бинарнику не нужно.
    out |= {"pyannote_segmentation.mlmodelc/model.mil": b"p", "wespeaker_v2.mlmodelc/model.mil": b"w",
            "plda-parameters.json": b"{}"}
    return out


def test_fluid_models_land_where_binary_and_transcriber_look(tmp_path, fluid_blobs):
    from mostik_engine import fluid_offline, paths

    paths.setup_import_path()
    from audio_transcription import fluid_models  # type: ignore

    srv = Server(fluid_blobs)
    try:
        spec = _fluid_spec(fluid_blobs)
        fluid = tmp_path / "Library" / "Application Support" / "FluidAudio" / "Models"
        hub = tmp_path / "hub"
        assert ms.status(hub, [spec], fluid)[0]["installed"] is False
        assert ms.Downloader(hub=hub, base_url=srv.url, specs=[spec], fluid=fluid).download([spec.key]) == [spec.key]
    finally:
        srv.close()
    assert fluid_offline.models_problem(tmp_path) is None, "офлайновый набор бинарника на месте"
    assert fluid_models.ready(fluid / ms.FLUID_FULL), "проверка transcriber проходит"
    assert not (fluid / ms.FLUID_OFFLINE / "pyannote_segmentation.mlmodelc").exists(), "лишнего бинарнику не кладём"
    linked = fluid / ms.FLUID_OFFLINE / "config.json"
    assert linked.stat().st_ino == (fluid / ms.FLUID_FULL / "config.json").stat().st_ino, "жёсткая ссылка, без копии"
    assert not hub.exists() or not any(hub.iterdir()), "в кэш HF ничего не легло"
    assert ms.status(hub, [spec], fluid)[0]["installed"] is True


def test_fluid_offline_set_restored_without_download(tmp_path, fluid_blobs):
    """Полный набор есть, а офлайнового нет (стёрли руками) — «Скачать» досоздаёт ссылки без сети."""
    spec = _fluid_spec(fluid_blobs)
    fluid = tmp_path / "Models"
    for name, data in fluid_blobs.items():
        path = fluid / ms.FLUID_FULL / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    row = ms.status(tmp_path / "hub", [spec], fluid)[0]
    assert row["installed"] is False and row["missing_bytes"] == 0

    def no_network(*args, **kwargs):
        raise AssertionError("в сеть не ходим")

    ms.Downloader(hub=tmp_path / "hub", specs=[spec], fluid=fluid, opener=no_network).download([spec.key])
    assert ms.status(tmp_path / "hub", [spec], fluid)[0]["installed"] is True


def test_manifest_has_diarization_set():
    from mostik_engine import fluid_offline

    spec = next(s for s in ms.load_manifest() if s.key == "speaker-diarization")
    assert spec.install == "fluidaudio" and spec.required is False and spec.purpose == "diarization"
    paths_ = {item.path for item in spec.files}
    for name in fluid_offline.MODELS:
        assert f"{name}.mlmodelc/coremldata.bin" in paths_
    assert set(fluid_offline.FILES) <= paths_
    assert all(len(item.sha256) == 64 for item in spec.files)
    assert 20_000_000 < spec.size < 60_000_000
