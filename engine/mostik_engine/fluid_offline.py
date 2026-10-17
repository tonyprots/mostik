"""fluidaudiocli без сети (П10 р3 Н-4).

Бинарник FluidAudio сам качает модели с huggingface.co (ревизия `main`), если их нет или набор
неполон, а `HF_HUB_OFFLINE` на Swift-бинарник не действует. Офлайновому `process --mode offline`
нужен каталог `Models/speaker-diarization/` целиком; transcriber (`fluid_models.ready`) смотрит
другой — `speaker-diarization-coreml` — и только три файла. Проба 2026-10-12 (`docs/release.md`,
«Принятые риски П10»): с одним `-coreml` бинарник идёт в сеть, с полным `speaker-diarization`
под `sandbox-exec (deny network*)` отрабатывает.

Три линии:
1. Mostik не зовёт бинарник, пока полного набора нет (`models_problem`), — ни встреча, ни голосовая память.
2. Адрес реестра моделей — закрытый локальный порт (`OFFLINE_ENV`, через `privacy.offline_env`):
   бинарник читает `MODEL_REGISTRY_URL`, проба показала запрос на lo0, а не наружу.
3. Голосовая память запускает бинарник под `sandbox-exec` без сети (`no_network_prefix`).
"""
from __future__ import annotations

import os
from pathlib import Path

MODELS = ("Segmentation", "Embedding", "FBank", "PldaRho")
FILES = ("config.json", "plda-parameters.json", "xvector-transform.json")
# Закрытый порт (discard) на этой машине: загрузка, если до неё дойдёт, падает сразу и наружу не идёт.
CLOSED_REGISTRY = "http://127.0.0.1:9"
OFFLINE_ENV = {"MODEL_REGISTRY_URL": CLOSED_REGISTRY, "REGISTRY_URL": CLOSED_REGISTRY}
SANDBOX_EXEC = "/usr/bin/sandbox-exec"
NO_NETWORK_PROFILE = "(version 1)(allow default)(deny network*)"


def models_dir(home: Path | None = None) -> Path:
    """Каталог, который читает `fluidaudiocli process --mode offline`."""
    return (home or Path.home()) / "Library" / "Application Support" / "FluidAudio" / "Models" / "speaker-diarization"


def models_problem(home: Path | None = None) -> str | None:
    """Чего не хватает офлайновому набору; None — всё на месте и скачивать бинарнику нечего."""
    root = models_dir(home)
    missing = [f"{name}.mlmodelc" for name in MODELS if not (root / f"{name}.mlmodelc" / "coremldata.bin").is_file()]
    missing += [name for name in FILES if not (root / name).is_file()]
    if not missing:
        return None
    return f"нет моделей FluidAudio ({', '.join(missing)}) в {root}"


def no_network_prefix() -> list[str]:
    """`sandbox-exec` с запретом сети; нет его — пусто (остаются первые две линии)."""
    return [SANDBOX_EXEC, "-p", NO_NETWORK_PROFILE] if os.access(SANDBOX_EXEC, os.X_OK) else []
