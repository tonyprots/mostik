"""Пул моделей: каждая грузится один раз и живёт в памяти до простоя.

Классы `backends` из transcriber грузят модель на каждый вызов — для диктовки
это секунды на каждое окно (§12.1). Здесь модели держит сам движок: GigaAM v3
E2E (ru) в процессе, Whisper Turbo (en) — в отдельном процессе MLX, как
откалибровано в transcriber, и Silero VAD; всё офлайн из кэша HF.
"""
from __future__ import annotations

import sys
import threading
import time
from typing import Any

from . import paths  # noqa: F401 — кладёт transcriber в sys.path

from audio_transcription import catalog  # noqa: E402
from audio_transcription.audio import gain_for_vad  # noqa: E402
from audio_transcription.backends import force_hub_offline  # noqa: E402

SAMPLE_RATE = 16_000
PRIMARY_IDLE_S = 600.0
# Как в transcriber: для английского Whisper точнее Parakeet (4,0% WER против 6,3%).
PRIMARY_BY_LANGUAGE = {"ru": catalog.GIGAAM_RUSSIAN, "en": catalog.WHISPER_TURBO}
REMOTE_TIMEOUT_S = 120.0


class ModelMissing(RuntimeError):
    """Весов нет в кэше Hugging Face. Сам движок не качает: загрузка — по кнопке (`model_store`)."""


def log(text: str) -> None:
    # Со временем: engine.log общий на сутки, и без него не понять, когда что шло.
    print(f"[mostik {time.strftime('%H:%M:%S')}] {text}", file=sys.stderr, flush=True)


def is_cached(entry: catalog.ModelEntry) -> bool:
    """Есть ли в кэше снапшот закреплённой ревизии (или хоть какой-то)."""
    if not entry.cache_dir:
        return False
    snapshots = catalog.hf_cache_dir() / entry.cache_dir / "snapshots"
    if not snapshots.is_dir():
        return False
    if entry.revision and (snapshots / entry.revision).is_dir():
        return True
    return any(snapshots.iterdir())


def _local_path(entry: catalog.ModelEntry):
    from audio_transcription.weights import fetch

    force_hub_offline()
    if not is_cached(entry):
        raise ModelMissing(f"{entry.label}: модель не установлена ({entry.repo}, ~{entry.download_gb} ГБ) — скачайте в Настройках → Модели")
    return fetch(entry).path


class RemoteRecognizer:
    """Основная модель в дочернем процессе (Whisper MLX) с синхронным `recognize`."""

    def __init__(self, model: str = "whisper") -> None:
        from .verifier_worker import VerifierClient

        self._lock = threading.Lock()
        self._results: dict[str, dict] = {}
        self._done = threading.Condition()
        self._counter = 0
        # Выгрузку решает ModelPool.sweep, у самого процесса таймера простоя нет.
        self.client = VerifierClient(idle_s=float("inf"), on_result=self._on_result, model=model)

    def _on_result(self, message: dict) -> None:
        with self._done:
            self._results[str(message.get("window_id"))] = message
            self._done.notify_all()

    def load(self) -> None:
        if not self.client.ensure() or not self.client.wait_ready(REMOTE_TIMEOUT_S):
            raise RuntimeError(f"{self.client.model}: процесс не запустился")
        if self.client.failure:
            raise ModelMissing(f"{self.client.model}: {self.client.failure}")

    def recognize(self, waveform: Any, sample_rate: int = SAMPLE_RATE, hotwords: list[str] | None = None,
                  language: str = "en") -> str:
        import numpy as np

        self.load()
        with self._lock:
            self._counter += 1
            window_id = f"primary:{self._counter}"
        pcm = (np.clip(np.asarray(waveform, dtype=np.float32), -1.0, 1.0) * 32767).astype("<i2").tobytes()
        if not self.client.submit(window_id, "primary", pcm, language, hotwords):
            raise RuntimeError(f"{self.client.model}: окно не отправлено")
        deadline = time.monotonic() + REMOTE_TIMEOUT_S
        with self._done:
            while window_id not in self._results:
                left = deadline - time.monotonic()
                if left <= 0 or not self.client.running():
                    raise RuntimeError(f"{self.client.model}: нет ответа на окно")
                self._done.wait(min(left, 0.5))
            message = self._results.pop(window_id)
        if message.get("error"):
            raise RuntimeError(f"{self.client.model}: {message['error']}")
        return str(message.get("text") or "")

    def stop(self) -> None:
        self.client.stop()


class ModelPool:
    """Основная модель на язык и VAD; выгрузка по простою через `sweep()`."""

    def __init__(self, idle_s: float = PRIMARY_IDLE_S) -> None:
        self.idle_s = idle_s
        self._lock = threading.RLock()
        self._primary: dict[str, Any] = {}
        self._vad: Any = None
        self._used: dict[str, float] = {}

    # --- загрузка ---------------------------------------------------------

    def vad(self) -> Any:
        with self._lock:
            if self._vad is None:
                import onnx_asr

                started = time.monotonic()
                self._vad = onnx_asr.load_vad(
                    "silero", _local_path(catalog.SILERO_VAD), providers=["CPUExecutionProvider"]
                )
                log(f"Silero VAD загружен за {time.monotonic() - started:.2f} с")
            self._used["vad"] = time.monotonic()
            return self._vad

    def primary(self, language: str) -> Any:
        entry = PRIMARY_BY_LANGUAGE.get(language)
        if entry is None:
            raise ValueError(f"Язык {language!r} не поддерживается: ru или en")
        with self._lock:
            model = self._primary.get(language)
            if model is None:
                started = time.monotonic()
                if entry is catalog.WHISPER_TURBO:
                    if not is_cached(entry):
                        raise ModelMissing(f"{entry.label}: модель не установлена ({entry.repo}, ~{entry.download_gb} ГБ) — скачайте в Настройках → Модели")
                    model = RemoteRecognizer("whisper")
                    model.load()
                else:
                    import onnx_asr

                    model = onnx_asr.load_model(
                        entry.model,
                        _local_path(entry),
                        quantization=entry.quantization,
                        providers=["CPUExecutionProvider"],
                    )
                self._primary[language] = model
                log(f"{entry.label} загружена за {time.monotonic() - started:.2f} с")
            self._used[language] = time.monotonic()
            return model

    def has_primary(self, language: str) -> bool:
        """Основная модель языка уже в памяти: `start` не будет её грузить."""
        with self._lock:
            return language in self._primary

    def warmup(self, language: str) -> list[str]:
        """Грузит VAD и основную модель языка, прогоняет секунду тишины."""
        import numpy as np

        self.vad()
        model = self.primary(language)
        model.recognize(np.zeros(SAMPLE_RATE, dtype=np.float32), sample_rate=SAMPLE_RATE)
        return [catalog.SILERO_VAD.label, PRIMARY_BY_LANGUAGE[language].label]

    def close(self) -> None:
        """Останавливает дочерние процессы основных моделей."""
        with self._lock:
            for model in self._primary.values():
                if isinstance(model, RemoteRecognizer):
                    model.stop()

    def loaded(self) -> list[str]:
        with self._lock:
            names = [PRIMARY_BY_LANGUAGE[lang].label for lang in self._primary]
            if self._vad is not None:
                names.append(catalog.SILERO_VAD.label)
            return names

    # --- работа -----------------------------------------------------------

    def recognize(self, waveform: Any, language: str, hotwords: list[str] | None = None) -> str:
        """Текст окна: float32 16 кГц моно в памяти, без файлов.

        `hotwords` получает только Whisper; CTC/TDT-модели их не принимают.
        """
        model = self.primary(language)
        if len(waveform) < SAMPLE_RATE // 10:
            return ""
        if isinstance(model, RemoteRecognizer):
            # Процесс сам ставит окна в очередь; замок пула не держим, чтобы VAD не ждал.
            return model.recognize(waveform, SAMPLE_RATE, hotwords=hotwords, language=language).strip()
        with self._lock:
            return str(model.recognize(waveform, sample_rate=SAMPLE_RATE)).strip()

    def speech_spans(
        self,
        waveform: Any,
        *,
        max_seconds: float = 20.0,
        min_silence_ms: int = 300,
    ) -> list[tuple[int, int]]:
        """Интервалы речи (в сэмплах от начала `waveform`) по Silero VAD.

        Тихая речь поднимается тем же скользящим усилением, что в transcriber
        (`gain_for_vad`): модели получают звук без изменений.
        """
        import numpy as np

        if len(waveform) < SAMPLE_RATE // 4:
            return []
        vad = self.vad()
        gained = gain_for_vad(np.asarray(waveform, dtype=np.float32))[None, :]
        lengths = np.array([gained.shape[1]], dtype=np.int64)
        with self._lock:
            spans = next(
                vad.segment_batch(
                    gained,
                    lengths,
                    SAMPLE_RATE,
                    threshold=0.5,
                    min_speech_duration_ms=250,
                    max_speech_duration_s=max_seconds,
                    min_silence_duration_ms=min_silence_ms,
                    speech_pad_ms=0,
                )
            )
            return [(int(start), int(end)) for start, end in spans]

    # --- простой ----------------------------------------------------------

    def sweep(self, now: float | None = None) -> list[str]:
        """Выгружает то, чем не пользовались дольше `idle_s`."""
        now = time.monotonic() if now is None else now
        dropped: list[str] = []
        with self._lock:
            for language in list(self._primary):
                if now - self._used.get(language, now) > self.idle_s:
                    model = self._primary.pop(language)
                    if isinstance(model, RemoteRecognizer):
                        model.stop()
                    dropped.append(PRIMARY_BY_LANGUAGE[language].label)
            if self._vad is not None and not self._primary and now - self._used.get("vad", now) > self.idle_s:
                self._vad = None
                dropped.append(catalog.SILERO_VAD.label)
        if dropped:
            import gc

            gc.collect()
            log("выгружено по простою: " + ", ".join(dropped))
        return dropped


def cached_models() -> dict[str, bool]:
    entries = (catalog.SILERO_VAD, catalog.GIGAAM_RUSSIAN, catalog.PARAKEET_ENGLISH, catalog.WHISPER_TURBO)
    return {entry.label: is_cached(entry) for entry in entries}
