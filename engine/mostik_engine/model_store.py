"""Модели по кнопке (П8, пункт 5): манифест, проверка кэша, загрузка с докачкой и проверкой суммы.

Движок сам ничего не качает: загрузку начинает только команда `models_download`,
её посылает приложение по кнопке пользователя. Веса кладутся в кэш Hugging Face
той же раскладкой, что у `huggingface_hub` (`models--org--name/snapshots/<ревизия>/<файл>`),
поэтому модели, уже лежащие в кэше, берутся без загрузки, а загруженные видят и
transcriber, и `llm_mlx`.

Манифест — `models_manifest.json` рядом с модулем: имя, репозиторий и ревизия на
Hugging Face, файлы с размером и SHA256. Собирает его `scripts/models_manifest.py`
из проверенного локального кэша. `version` манифеста — версия набора моделей, своя,
не версия приложения: растёт, когда меняется модель, ревизия или файл.

Обновление приложения ничего не перекачивает само: модель с той же ревизией уже стоит.
Сменилась ревизия — качаются только изменившиеся файлы: файл с тем же SHA256 из прежней
ревизии (или из `blobs/` кэша Hugging Face) сверяется по сумме и ставится жёсткой ссылкой.

Загрузка файла:
- недокачанное лежит в `<снапшот>/<файл>.part`; повторный запуск просит `Range: bytes=N-`
  и дописывает, сервер без поддержки Range (ответ 200) — качаем заново;
- после загрузки — размер и SHA256; не совпало — `.part` удаляется, ошибка `checksum`;
- перед началом — место на диске: нужно недостающее плюс запас.

Модели FluidAudio (разделение по голосам, `install: "fluidaudio"`) ложатся не в кэш HF, а туда, где
их ищут transcriber и `fluidaudiocli`: `~/Library/Application Support/FluidAudio/Models/` —
весь набор в `speaker-diarization-coreml/` (его проверяет `fluid_models.ready`), а офлайновый —
жёсткими ссылками в `speaker-diarization/` (его читает бинарник, `fluid_offline.models_problem`).
Бинарнику сеть по-прежнему закрыта: качает Mostik, по кнопке, с закреплённой ревизии и с суммами.

Ошибки — `ModelDownloadError(code, message)`; коды: `network`, `http`, `checksum`,
`disk_full`, `cancelled`, `unknown_model`. Сообщения — для человека, с тем, что делать.
"""
from __future__ import annotations

import hashlib
import http.client
import json
import os
import shutil
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

MANIFEST_PATH = Path(__file__).with_name("models_manifest.json")
DEFAULT_BASE_URL = "https://huggingface.co"
CHUNK = 1 << 20
DISK_MARGIN = 512 * 1024 * 1024
PROGRESS_EVERY_S = 0.25
TIMEOUT_S = 30.0


class ModelDownloadError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class ModelFile:
    path: str
    size: int
    sha256: str
    blob_id: str = ""
    lfs: bool = False


@dataclass(frozen=True)
class ModelSpec:
    key: str
    label: str
    repo: str
    revision: str
    purpose: str
    required: bool
    files: tuple[ModelFile, ...]
    # "hub" — кэш Hugging Face; "fluidaudio" — каталог моделей FluidAudio (`fluid_root`).
    install: str = "hub"

    @property
    def size(self) -> int:
        return sum(item.size for item in self.files)


def load_manifest(path: Path | None = None) -> list[ModelSpec]:
    # MOSTIK_MODELS_MANIFEST — свой манифест (проверки на синтетике, зеркала моделей); только при
    # разработке: в .app манифест всегда встроенный (П10).
    from .privacy import dev_overrides_allowed

    override = os.environ.get("MOSTIK_MODELS_MANIFEST") if dev_overrides_allowed() else None
    path = path or Path(override or MANIFEST_PATH)
    raw = json.loads(path.read_text(encoding="utf-8"))
    specs = []
    for item in raw["models"]:
        files = tuple(ModelFile(f["path"], int(f["size"]), f["sha256"].lower(), f.get("blob_id", ""),
                                bool(f.get("lfs"))) for f in item["files"])
        specs.append(ModelSpec(item["key"], item["label"], item["repo"], item["revision"],
                               item.get("purpose", ""), bool(item.get("required")), files,
                               item.get("install", "hub")))
    return specs


def hub_dir(env: dict | None = None) -> Path:
    """Кэш Hugging Face тем же правилом, что у `huggingface_hub`: HF_HUB_CACHE → HF_HOME/hub → ~/.cache."""
    env = os.environ if env is None else env
    if env.get("HF_HUB_CACHE"):
        return Path(env["HF_HUB_CACHE"]).expanduser()
    if env.get("HF_HOME"):
        return Path(env["HF_HOME"]).expanduser() / "hub"
    return Path(env.get("HOME") or Path.home()) / ".cache" / "huggingface" / "hub"


def fluid_root(env: dict | None = None) -> Path:
    """`~/Library/Application Support/FluidAudio/Models` — там модели ищут transcriber и fluidaudiocli."""
    env = os.environ if env is None else env
    return Path(env.get("HOME") or Path.home()) / "Library" / "Application Support" / "FluidAudio" / "Models"


FLUID_FULL = "speaker-diarization-coreml"  # весь набор: `audio_transcription.fluid_models.default_target`
FLUID_OFFLINE = "speaker-diarization"  # офлайновый, для `process --mode offline`: `fluid_offline.models_dir`


def _offline_part(path: str) -> bool:
    """Файл офлайнового набора fluidaudiocli (`fluid_offline.MODELS`/`FILES`)."""
    from . import fluid_offline

    head = path.split("/", 1)[0]
    return path in fluid_offline.FILES or head in {f"{name}.mlmodelc" for name in fluid_offline.MODELS}


def target_dir(spec: ModelSpec, hub: Path, fluid: Path | None = None) -> Path:
    """Куда ложатся файлы модели: снапшот кэша HF или каталог FluidAudio."""
    if spec.install == "fluidaudio":
        return (fluid or fluid_root()) / FLUID_FULL
    return snapshot_dir(spec, hub)


def offline_missing(spec: ModelSpec, fluid: Path | None = None) -> list[ModelFile]:
    """Файлы офлайнового набора, которых нет в `speaker-diarization/` (их туда ставит `link_offline_set`)."""
    if spec.install != "fluidaudio":
        return []
    root = (fluid or fluid_root()) / FLUID_OFFLINE
    return [item for item in spec.files if _offline_part(item.path) and not _present(root / item.path, item.size)]


def link_offline_set(spec: ModelSpec, fluid: Path | None = None) -> None:
    """Офлайновый набор — жёсткими ссылками из полного: место не тратится, суммы те же."""
    fluid = fluid or fluid_root()
    for item in offline_missing(spec, fluid):
        source = fluid / FLUID_FULL / item.path
        target = fluid / FLUID_OFFLINE / item.path
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.name + ".link")
        tmp.unlink(missing_ok=True)
        try:
            os.link(source, tmp)
        except OSError:
            shutil.copyfile(source, tmp)
        os.replace(tmp, target)


def repo_dir(spec: ModelSpec, hub: Path) -> Path:
    return hub / ("models--" + spec.repo.replace("/", "--"))


def snapshot_dir(spec: ModelSpec, hub: Path) -> Path:
    return repo_dir(spec, hub) / "snapshots" / spec.revision


def _present(path: Path, size: int) -> bool:
    try:
        return path.stat().st_size == size  # stat идёт по симлинку в blobs/
    except OSError:
        return False


def missing_files(spec: ModelSpec, hub: Path, fluid: Path | None = None) -> list[ModelFile]:
    snap = target_dir(spec, hub, fluid)
    return [item for item in spec.files if not _present(snap / item.path, item.size)]


def status(hub: Path | None = None, specs: Iterable[ModelSpec] | None = None,
           fluid: Path | None = None) -> list[dict]:
    """Что стоит и чего не хватает; без сети и без чтения весов (только размеры)."""
    hub = hub or hub_dir()
    out = []
    for spec in specs if specs is not None else load_manifest():
        missing = missing_files(spec, hub, fluid)
        partial = 0
        for item in missing:
            part = target_dir(spec, hub, fluid) / (item.path + ".part")
            if part.is_file():
                partial += min(part.stat().st_size, item.size)
        out.append({
            "key": spec.key, "label": spec.label, "repo": spec.repo, "purpose": spec.purpose,
            "required": spec.required, "size": spec.size,
            "installed": not missing and not offline_missing(spec, fluid),
            "missing_bytes": sum(item.size for item in missing) - partial, "partial_bytes": partial,
        })
    return out


def _url(base: str, spec: ModelSpec, item: ModelFile) -> str:
    from urllib.parse import quote

    return f"{base.rstrip('/')}/{spec.repo}/resolve/{spec.revision}/{quote(item.path)}"


def _hash_file(path: Path, digest) -> None:
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK):
            digest.update(chunk)


class Downloader:
    """Качает модели по одной; прогресс — колбэком, отмена — `cancel()` из другого потока."""

    def __init__(self, *, hub: Path | None = None, base_url: str | None = None,
                 specs: Iterable[ModelSpec] | None = None,
                 opener: Callable[..., object] = urllib.request.urlopen,
                 free_bytes: Callable[[Path], int] | None = None,
                 fluid: Path | None = None) -> None:
        self.hub = hub or hub_dir()
        self.fluid = fluid or fluid_root()
        # Адрес зеркала — только явно от приложения (debug-сборка, поле `base_url` команды), не из окружения:
        # переменная в окружении процесса не должна уводить загрузку на чужой адрес (приватность, п. 8).
        self.base_url = base_url or DEFAULT_BASE_URL
        self.specs = {spec.key: spec for spec in (specs if specs is not None else load_manifest())}
        self.opener = opener
        self.free_bytes = free_bytes or (lambda path: shutil.disk_usage(path).free)
        self._cancel = threading.Event()

    def cancel(self) -> None:
        self._cancel.set()

    def download(self, keys: Iterable[str], progress: Callable[[dict], None] | None = None) -> list[str]:
        """Докачивает недостающее; возвращает ключи, которые теперь стоят целиком."""
        self._cancel.clear()
        report = progress or (lambda payload: None)
        specs = []
        for key in keys:
            if key not in self.specs:
                raise ModelDownloadError("unknown_model", f"Нет такой модели в манифесте: {key}")
            specs.append(self.specs[key])
        # Место — без учёта файлов, которые возьмутся из прежней ревизии (`reuse_unchanged`): запас в безопасную сторону.
        need = sum(item.size for spec in specs for item in missing_files(spec, self.hub, self.fluid))
        self.hub.mkdir(parents=True, exist_ok=True)
        free = self.free_bytes(self.hub)
        if need and free < need + DISK_MARGIN:
            raise ModelDownloadError(
                "disk_full",
                f"Не хватает места: нужно {_gb(need + DISK_MARGIN)}, свободно {_gb(free)}. "
                "Освободите место на диске и нажмите «Скачать» ещё раз.")
        done_keys = []
        for spec in specs:
            total = spec.size
            done = total - sum(item.size for item in missing_files(spec, self.hub, self.fluid))
            for item in missing_files(spec, self.hub, self.fluid):
                if spec.install == "hub" and reuse_unchanged(spec, item, self.hub):
                    done += item.size
                    report({"key": spec.key, "file": item.path, "done": done, "total": total, "reused": True})
                    continue
                done = self._file(spec, item, done, total, report)
            if spec.install == "fluidaudio":
                link_offline_set(spec, self.fluid)
            else:
                ref = repo_dir(spec, self.hub) / "refs" / "main"
                if not ref.exists():
                    ref.parent.mkdir(parents=True, exist_ok=True)
                    ref.write_text(spec.revision)
                write_tree(spec, self.hub)
            report({"key": spec.key, "done": total, "total": total, "installed": True})
            done_keys.append(spec.key)
        return done_keys

    def _file(self, spec: ModelSpec, item: ModelFile, done: int, total: int,
              report: Callable[[dict], None]) -> int:
        target = target_dir(spec, self.hub, self.fluid) / item.path
        part = target.with_name(target.name + ".part")
        part.parent.mkdir(parents=True, exist_ok=True)
        have = part.stat().st_size if part.is_file() else 0
        if have > item.size:
            part.unlink()
            have = 0
        digest = hashlib.sha256()
        if have:
            _hash_file(part, digest)
        if have < item.size:
            request = urllib.request.Request(_url(self.base_url, spec, item), headers={"User-Agent": "Mostik"})
            if have:
                request.add_header("Range", f"bytes={have}-")
            try:
                response = self.opener(request, timeout=TIMEOUT_S)
            except urllib.error.HTTPError as error:
                if error.code == 416 and have:  # уже всё есть — сервер не даёт дальше
                    response = None
                else:
                    raise ModelDownloadError(
                        "http", f"{spec.label}: сервер ответил {error.code} на {item.path}. "
                        "Попробуйте позже; если повторяется — модель переехала, нужна новая версия Mostik.") from error
            except (urllib.error.URLError, OSError, http.client.HTTPException) as error:
                raise _network(spec, error) from error
            if response is not None:
                with response:
                    status_code = getattr(response, "status", 200)
                    if have and status_code != 206:
                        # Range не поддержан — начинаем файл заново.
                        have = 0
                        digest = hashlib.sha256()
                        mode = "wb"
                    else:
                        mode = "ab" if have else "wb"
                    base = done
                    last = 0.0
                    try:
                        with part.open(mode) as out:
                            while True:
                                if self._cancel.is_set():
                                    raise ModelDownloadError("cancelled", "Загрузка остановлена. Нажмите «Скачать» — продолжится с того же места.")
                                chunk = response.read(CHUNK)
                                if not chunk:
                                    break
                                out.write(chunk)
                                digest.update(chunk)
                                have += len(chunk)
                                now = time.monotonic()
                                if now - last >= PROGRESS_EVERY_S:
                                    last = now
                                    report({"key": spec.key, "file": item.path, "done": base + have, "total": total})
                    except (urllib.error.URLError, OSError, TimeoutError, http.client.HTTPException) as error:
                        raise _network(spec, error) from error
        if have < item.size:
            # Поток кончился раньше времени (обрыв без исключения): недокачанное остаётся для Range.
            raise _network(spec, ConnectionError(f"получено {have} из {item.size} байт"))
        if have != item.size or digest.hexdigest() != item.sha256:
            got = have
            part.unlink(missing_ok=True)
            raise ModelDownloadError(
                "checksum", f"{spec.label}: файл {item.path} пришёл повреждённым "
                f"({got} из {item.size} байт или не та сумма SHA256). Он удалён; нажмите «Скачать» ещё раз.")
        os.replace(part, target)
        return done + item.size


def _sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    _hash_file(path, digest)
    return digest.hexdigest()


def reuse_unchanged(spec: ModelSpec, item: ModelFile, hub: Path) -> bool:
    """Поставить файл без загрузки, если он уже лежит в кэше с тем же размером и SHA256.

    Ищем в `blobs/<sha256>` репозитория (раскладка `huggingface_hub` для LFS) и под тем же путём в
    других ревизиях. Сумма сверяется по самому файлу — размер и имя ничего не доказывают.
    """
    target = snapshot_dir(spec, hub) / item.path
    repo = repo_dir(spec, hub)
    candidates = [repo / "blobs" / item.sha256]
    snapshots = repo / "snapshots"
    if snapshots.is_dir():
        candidates += [other / item.path for other in sorted(snapshots.iterdir())
                       if other.name != spec.revision and other.is_dir()]
    for candidate in candidates:
        try:
            source = candidate.resolve(strict=True)
            if not source.is_file() or source.stat().st_size != item.size or _sha256_of(source) != item.sha256:
                continue
        except OSError:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.name + ".reuse")
        tmp.unlink(missing_ok=True)
        try:
            os.link(source, tmp)  # тот же том: место не тратится
        except OSError:
            shutil.copyfile(source, tmp)
        os.replace(tmp, target)
        return True
    return False


def write_tree(spec: ModelSpec, hub: Path) -> None:
    """Список файлов коммита для `huggingface_hub` (`trees/<ревизия>.json`).

    Без него `snapshot_download` в офлайне идёт в сеть за списком даже при закреплённой
    ревизии и полном снапшоте. Уже лежащий список (настоящий, от Hub) не трогаем.
    """
    path = repo_dir(spec, hub) / "trees" / f"{spec.revision}.json"
    if path.exists():
        return
    files = {}
    for item in spec.files:
        entry: dict = {"size": item.size, "blob_id": item.blob_id or _git_blob_id(snapshot_dir(spec, hub) / item.path)}
        if item.lfs:
            entry.update(lfs_sha256=item.sha256, lfs_size=item.size)
        files[item.path] = entry
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps({"format_version": 1, "files": files}, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def _git_blob_id(path: Path) -> str:
    digest = hashlib.sha1(f"blob {path.stat().st_size}\0".encode())
    _hash_file(path, digest)
    return digest.hexdigest()


def _network(spec: ModelSpec, error: BaseException) -> ModelDownloadError:
    reason = getattr(error, "reason", None) or error
    return ModelDownloadError(
        "network", f"{spec.label}: нет связи с сервером моделей ({reason}). "
        "Проверьте интернет и нажмите «Скачать» — загрузка продолжится с места остановки.")


def _gb(value: int) -> str:
    return f"{value / 1e9:.1f} ГБ".replace(".", ",")
