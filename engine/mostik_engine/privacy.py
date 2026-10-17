"""Приватность движка: без ведома пользователя ничего не уходит с компьютера.

Вторая линия после приложения (`Sources/MostikCore/Privacy.swift`):

- облачный бэкенд (`claude`) — только с полем `consent: true` в команде. Приложение
  ставит его само и только при действующем согласии на этот вид данных; без поля
  команда получает отказ `consent_required` (`refusal`). «Спросить» и чат архива
  (`ask`, `archive_ask`) проверяют согласие сами: без него модель не зовут,
  но найденные отрывки показывают — им отказ не нужен;
- бэкенд по умолчанию — `off`: команда без поля `backend` в облако не ходит;
- «чувствительная» встреча («никуда, кроме этого Mac», `meeting_folder.is_sensitive`)
  не уходит в облако ни сводкой, ни рецептом, ни отрывком для ответа «Спросить».
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Iterable

CLOUD_BACKENDS = frozenset({"claude"})

# Списки окружения ниже и в `isolation.py` сверяются с `docs/engine-environment.json` (его же сверяет приложение).
# Окружение движка и его подпроцессов (п. 5). Приложение ставит то же самое (`EngineEnvironment`);
# здесь — на случай запуска движка без приложения. Загрузку моделей по кнопке не ломает:
# `model_store.Downloader` ходит своим HTTP (urllib), а не через huggingface_hub.
OFFLINE_ENV = {
    "HF_HUB_OFFLINE": "1",
    "HF_HUB_DISABLE_TELEMETRY": "1",
    "TRANSCRIBER_NO_UPDATE_CHECK": "1",  # transcriber: проверка обновлений выключена и без --offline
}
# Переопределения для разработки (П10): свой манифест моделей, снятое закрепление ревизий transcriber,
# чужой код transcriber и чужой Python. Тот же список приложение вычищает в выпуске
# (`EngineEnvironment.debugOnlyOverrides`); движок внутри .app не берёт их из окружения и сам —
# `launchctl setenv` не должен уводить загрузку моделей или запуск кода в сторону.
DEV_ONLY_ENV = ("MOSTIK_MODELS_MANIFEST", "TRANSCRIBER_UNPIN", "MOSTIK_TRANSCRIBER", "MOSTIK_TRANSCRIBER_PYTHON",
                "MOSTIK_LLM_PYTHON")


def dev_overrides_allowed() -> bool:
    from . import paths

    return not paths.IN_APP_BUNDLE


# в выпуске движок и его дети ищут программы только в системных папках и в бандле, а кэш
# моделей — только в своём месте. Иначе `launchctl setenv PATH=…` или `TRANSCRIBER_FLUIDAUDIO_BIN`
# подсовывали бы ребёнку движка чужой бинарник с разрешениями Mostik (микрофон, экран).
from .isolation import SYSTEM_PATH  # noqa: E402  (один список с isolation)
RELEASE_DROP_PREFIXES = ("TRANSCRIBER_", "HF_")  # кроме OFFLINE_ENV
RELEASE_DROP_ENV = ("MOSTIK_CURATED_GLOSSARY", "XDG_CACHE_HOME")
# П10 р4 Р4-1: то, чем шимы `/usr/bin/*` (git, xcrun, python3, swift) и загрузчик уводят запуск в чужую папку, —
# снимается всегда, и в разработке тоже: движок без приложения (`mostik`, MCP) детям этого не передаёт.
TOOLCHAIN_ENV = ("DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS")


def release_path() -> str:
    """`PATH` выпуска: `Contents/Resources/bin` бандла и системные папки."""
    from . import paths

    return f"{paths.ENGINE_DIR.parent / 'bin'}:{SYSTEM_PATH}"


def scrub_dev_overrides(env: Any) -> None:
    """Движок из .app: убрать переопределения для разработки, задать свой `PATH` и кэш моделей.

    Из репозитория (разработка) снимаем только `TOOLCHAIN_ENV` и `DYLD_*`/`LD_*`/`PYTHON*`; в выпуске окружение
    движка — белый список (Р4-1), как у его детей.
    """
    from . import isolation

    for key in list(env):
        if key in TOOLCHAIN_ENV or key.startswith(isolation.UNSAFE_PREFIXES):
            env.pop(key, None)
    if dev_overrides_allowed():
        return
    keys = isolation.CHILD_KEYS | isolation.CLAUDE_KEYS
    prefixes = isolation.CHILD_PREFIXES + isolation.CLAUDE_PREFIXES
    for key in list(env):
        if not (key in keys or key.startswith(prefixes)):
            env.pop(key, None)
    for key in list(env):
        if key in DEV_ONLY_ENV or key in RELEASE_DROP_ENV or (
                key.startswith(RELEASE_DROP_PREFIXES) and key not in OFFLINE_ENV):
            env.pop(key, None)
    env["PATH"] = release_path()
    home = env.get("HOME")
    # Явно, а не по умолчанию huggingface_hub: умолчание зависит от XDG_CACHE_HOME.
    env["HF_HOME"] = str(Path(home) / ".cache" / "huggingface") if home else str(Path.home() / ".cache" / "huggingface")


CONSENT_MESSAGE = ("облачный бэкенд {name!r} без согласия пользователя: команда {cmd!r} пришла без consent: true. "
                   "Текст в облако не отправлен")
SENSITIVE_MESSAGE = "встреча помечена «никуда, кроме этого Mac»: в облачный бэкенд {name!r} она не уходит"


class SensitiveMeeting(Exception):
    """Облачная команда для «чувствительной» встречи."""

    code = "sensitive"

    def __init__(self, name: str) -> None:
        super().__init__(SENSITIVE_MESSAGE.format(name=name))


def offline_env(base: dict[str, str] | None = None) -> dict[str, str]:
    """Копия окружения с `OFFLINE_ENV` — для подпроцессов transcriber."""
    import os

    from . import fluid_offline

    env = dict(os.environ if base is None else base)
    env.update(OFFLINE_ENV)
    # П10 р3 Н-4: fluidaudiocli не знает HF_HUB_OFFLINE — его реестр моделей уводим на закрытый локальный порт.
    env.update(fluid_offline.OFFLINE_ENV)
    scrub_dev_overrides(env)
    return env


def is_cloud(name: Any) -> bool:
    return isinstance(name, str) and name in CLOUD_BACKENDS


def cloud_backend(command: dict) -> str | None:
    """Имя облачного бэкенда команды: поле `backend` или `polish.backend`; нет — None."""
    name = command.get("backend")
    if is_cloud(name):
        return name
    polish = command.get("polish")
    if isinstance(polish, dict) and is_cloud(polish.get("backend")):
        return polish["backend"]
    return None


def refusal(command: dict) -> str | None:
    """Текст отказа для облачной команды без согласия; None — можно выполнять."""
    name = cloud_backend(command)
    if name is None:
        return None
    if command.get("consent") is True:
        return None
    return CONSENT_MESSAGE.format(name=name, cmd=command.get("cmd"))


def check_meeting(folder: Path, backend_name: str) -> None:
    """Сводка или рецепт: облачный бэкенд и «чувствительная» встреча — отказ."""
    from .meeting_folder import is_sensitive

    if is_cloud(backend_name) and is_sensitive(Path(folder)):
        raise SensitiveMeeting(backend_name)


def meeting_folder_of(path: str | Path) -> Path | None:
    """Папка встречи для файла из индекса: `transcript.json` или `frames/*.ocr.txt`."""
    item = Path(path)
    for folder in (item.parent, item.parent.parent):
        if (folder / "manifest.json").is_file() or (folder / "meeting.md").is_file():
            return folder
    return None


def in_sensitive_meeting(path: str | Path, cache: dict[Path, bool] | None = None) -> bool:
    """Файл из индекса лежит в «чувствительной» встрече — реплика, кадр или что угодно в её папке (В1)."""
    from .meeting_folder import is_sensitive

    folder = meeting_folder_of(path or "")
    if folder is None:
        return False
    if cache is None:
        return is_sensitive(folder)
    if folder not in cache:
        cache[folder] = is_sensitive(folder)
    return cache[folder]


def drop_sensitive(hits: Iterable[Any]) -> list[Any]:
    """Отрывки для облачной модели: без реплик и кадров «чувствительных» встреч.

    Смотрит на путь любого отрывка, а не на его вид: кадры экрана (`frames/*.ocr.txt`)
    индексируются как источники, а принадлежат встрече.
    """
    cache: dict[Path, bool] = {}
    return [hit for hit in hits if not in_sensitive_meeting(getattr(hit, "path", ""), cache)]
