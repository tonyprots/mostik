"""Собирает engine/mostik_engine/models_manifest.json из проверенного локального кэша Hugging Face.

Запуск (разработка, нужен venv с transcriber и onnx-asr/mlx-audio):
    PYTHONPATH=engine <python> scripts/models_manifest.py [--hub ~/.cache/huggingface/hub]

Файлы модели — те, что берёт её загрузчик (`audio_transcription.weights.allow_patterns`),
для LLM — снапшот без README и .gitattributes. Размер и SHA256 считаются по самим файлам
закреплённой ревизии; в сеть скрипт не ходит.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))

from mostik_engine import paths  # noqa: E402,F401 — кладёт transcriber в sys.path
from mostik_engine import llm_mlx, model_store  # noqa: E402
from audio_transcription import catalog, fluid_models  # noqa: E402
from audio_transcription.weights import allow_patterns  # noqa: E402

# key, запись каталога, назначение, обязательна ли для первого запуска
ASR = [
    ("silero-vad", catalog.SILERO_VAD, "vad", True),
    ("gigaam-v3", catalog.GIGAAM_RUSSIAN, "ru", True),
    ("whisper-turbo", catalog.WHISPER_TURBO, "en", True),
    ("parakeet-v3", catalog.PARAKEET_ENGLISH, "verifier-en", False),
]
LLM_SKIP = {"README.md", ".gitattributes"}
# Модели разделения по голосам: тот же отбор, что у `fluid_models.ensure` (офлайновый набор бинарника
# и то, что проверяет `fluid_models.ready`), из каталога FluidAudio, а не из кэша HF.
FLUID_PATTERNS = [*fluid_models.FILES, *(f"{name}.mlmodelc/*" for name in fluid_models.MODELS)]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1 << 22):
            digest.update(chunk)
    return digest.hexdigest()


def git_blob_id(path: Path) -> str:
    digest = hashlib.sha1(f"blob {path.stat().st_size}\0".encode())
    digest.update(path.read_bytes())
    return digest.hexdigest()


def files_of(snap: Path, patterns: list[str] | None, skip: set[str] = frozenset()) -> list[dict]:
    """Файлы снапшота; `blob_id` и признак LFS — из закэшированного списка коммита (`trees/<rev>.json`)."""
    tree_file = snap.parent.parent / "trees" / f"{snap.name}.json"
    tree = json.loads(tree_file.read_text())["files"] if tree_file.is_file() else {}
    out = []
    for path in sorted(p for p in snap.rglob("*") if p.is_file()):
        rel = path.relative_to(snap).as_posix()
        if rel in skip:
            continue
        if patterns is not None and not any(fnmatch.fnmatch(rel, pat) for pat in patterns):
            continue
        item = {"path": rel, "size": path.stat().st_size, "sha256": sha256(path)}
        meta = tree.get(rel, {})
        item["blob_id"] = meta.get("blob_id") or git_blob_id(path)
        if meta.get("lfs_sha256"):
            if meta["lfs_sha256"] != item["sha256"]:
                raise SystemExit(f"{rel}: SHA256 в кэше не совпадает со списком коммита")
            item["lfs"] = True
        out.append(item)
    return out


def check_fluid_tree(files: list[dict], entry) -> None:
    """Суммы локальной копии FluidAudio — против списка файлов ревизии на Hub (единственный поход в сеть).

    Каталог FluidAudio не кэш HF: `trees/<rev>.json` рядом нет, а файлы мог положить и сам бинарник с `main`.
    """
    import urllib.request

    url = f"https://huggingface.co/api/models/{entry.repo}/tree/{entry.revision}?recursive=true"
    with urllib.request.urlopen(url, timeout=60) as response:
        tree = {item["path"]: item for item in json.load(response) if item.get("type") == "file"}
    for item in files:
        remote = tree.get(item["path"])
        if remote is None or remote["size"] != item["size"]:
            raise SystemExit(f"FluidAudio {item['path']}: нет в ревизии {entry.revision} или другой размер")
        item["blob_id"] = remote["oid"]
        lfs = remote.get("lfs")
        if lfs:
            if lfs["oid"] != item["sha256"]:
                raise SystemExit(f"FluidAudio {item['path']}: SHA256 не совпадает с ревизией")
            item["lfs"] = True
        elif git_blob_id_of(item) != remote["oid"]:
            raise SystemExit(f"FluidAudio {item['path']}: git-объект не совпадает с ревизией")


def git_blob_id_of(item: dict) -> str:
    return git_blob_id(fluid_models.default_target() / item["path"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hub", type=Path, default=model_store.hub_dir())
    parser.add_argument("--out", type=Path, default=model_store.MANIFEST_PATH)
    args = parser.parse_args()
    models = []
    for key, entry, purpose, required in ASR:
        snap = args.hub / ("models--" + entry.repo.replace("/", "--")) / "snapshots" / entry.revision
        if not snap.is_dir():
            print(f"нет в кэше: {entry.repo}@{entry.revision}", file=sys.stderr)
            return 1
        files = files_of(snap, allow_patterns(entry))
        models.append({"key": key, "label": entry.label, "repo": entry.repo, "revision": entry.revision,
                       "purpose": purpose, "required": required, "files": files})
    llm = llm_mlx.MODELS[llm_mlx.DEFAULT_MODEL]
    snap = llm_mlx.model_path(llm.repo, args.hub)
    if snap is None:
        print(f"нет в кэше: {llm.repo}", file=sys.stderr)
        return 1
    models.append({"key": llm.key, "label": llm.label, "repo": llm.repo, "revision": snap.name,
                   "purpose": "llm", "required": False, "files": files_of(snap, None, LLM_SKIP)})
    fluid = fluid_models.default_target()
    if not fluid_models.ready(fluid):
        print(f"нет моделей FluidAudio: {fluid}", file=sys.stderr)
        return 1
    files = files_of(fluid, FLUID_PATTERNS)
    check_fluid_tree(files, catalog.FLUIDAUDIO)
    models.append({"key": "speaker-diarization", "label": "FluidAudio Community-1", "repo": catalog.FLUIDAUDIO.repo,
                   "revision": catalog.FLUIDAUDIO.revision, "purpose": "diarization", "required": False,
                   "install": "fluidaudio", "files": files})
    # `version` — версия набора моделей, отдельно от версии приложения: растёт на 1, когда меняется
    # хоть одна модель, ревизия или файл. Тот же набор — та же версия.
    version = 1
    if args.out.is_file():
        previous = json.loads(args.out.read_text(encoding="utf-8"))
        version = int(previous.get("version", 1)) + (previous.get("models") != models)
    payload = {"version": version, "models": models}
    args.out.write_text(json.dumps(payload, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    for model in models:
        size = sum(f["size"] for f in model["files"])
        print(f"{model['key']}: {len(model['files'])} файлов, {size / 1e9:.2f} ГБ")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
