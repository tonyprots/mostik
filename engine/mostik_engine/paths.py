"""Пути движка: дом Mostik и пакет transcriber, из которого берём готовые модули."""
from __future__ import annotations

import os
import sys
from pathlib import Path

ENGINE_DIR = Path(__file__).resolve().parent.parent
# Скрипты transcriber (пакет `audio_transcription` и `transcribe.py`) — копия в репозитории,
# `engine/vendor_transcriber` (откуда и какой коммит — её SOURCE.md, П10 С11). В .app она едет
# внутри движка. Соседний проект transcriber движок больше не ищет.
VENDORED_TRANSCRIBER = ENGINE_DIR / "vendor_transcriber"
# Движок внутри .app (выпуск): переопределения для разработки из окружения не действуют (П10).
IN_APP_BUNDLE = ".app/Contents/" in str(ENGINE_DIR)


def mostik_home() -> Path:
    """`MOSTIK_HOME` или `~/Library/Application Support/Mostik`; каталог создаётся."""
    raw = os.environ.get("MOSTIK_HOME")
    home = Path(raw).expanduser() if raw else Path.home() / "Library" / "Application Support" / "Mostik"
    home.mkdir(parents=True, exist_ok=True)
    return home


def projects_dir() -> Path:
    path = mostik_home() / "projects"
    path.mkdir(parents=True, exist_ok=True)
    return path


def personal_glossary_path() -> Path:
    return mostik_home() / "glossary.yaml"


def transcriber_scripts() -> Path:
    """Копия в репозитории; `MOSTIK_TRANSCRIBER` — только для разработки, в .app не действует."""
    raw = os.environ.get("MOSTIK_TRANSCRIBER")
    if raw and not IN_APP_BUNDLE:
        return Path(raw).expanduser()
    return VENDORED_TRANSCRIBER


def transcriber_repo() -> Path | None:
    """Корень репозитория transcriber, если `MOSTIK_TRANSCRIBER` указывает в него (разработка)."""
    scripts = transcriber_scripts()
    if scripts.name == "scripts" and scripts.parent.parent.name == "skills":
        return scripts.parents[2]
    return None


def setup_import_path() -> Path:
    """Кладёт каталог скриптов transcriber в `sys.path` (один раз)."""
    scripts = transcriber_scripts()
    text = str(scripts)
    if text not in sys.path:
        sys.path.insert(0, text)
    return scripts


setup_import_path()
