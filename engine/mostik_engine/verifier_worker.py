"""Модель в отдельном процессе и клиент к ней.

Чаще всего это проверяющая, но процесс не знает своей роли: его модель задаёт
`MOSTIK_WORKER_MODEL` — `whisper` (Whisper Turbo MLX) или `parakeet` (Parakeet TDT v3).
Маршруты как в transcriber: для `ru` основная GigaAM, проверяющая Whisper; для
`en` основная Whisper (через этот же процесс, см. `models.RemoteRecognizer`),
проверяющая Parakeet.

Отдельный процесс (§12.3): цикл декодирования Whisper держит GIL и не должен
тормозить протокол и GigaAM. Обмен — строки JSON:

    → {"window_id": "s1:3", "session": "s1", "pcm": "<b64 int16>", "language": "ru",
       "hotwords": [...]}          или "wav": путь вместо "pcm"
    → {"cancel": "s1"}             выбросить ещё не начатые окна сессии
    ← {"ready": true, "seconds": 2.1}   или {"ready": false, "error": "..."}
    ← {"window_id": "s1:3", "text": "...", "words": [...], "seconds": 0.4}

Окна не склеиваются: пары основная/проверяющая 1:1 по окнам.
"""
from __future__ import annotations

import base64
import collections
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable

from . import isolation

SAMPLE_RATE = 16_000
VERIFIER_IDLE_S = 180.0
HOTWORDS_LIMIT = 60
HOTWORDS_CHARS = 600


def _log(text: str) -> None:
    print(f"[mostik-verifier] {text}", file=sys.stderr, flush=True)


# --- дочерний процесс -------------------------------------------------------


WORKER_MODELS = ("whisper", "parakeet")


class _Parakeet:
    """Parakeet TDT v3 через onnx_asr с тем же `generate`, что у MLX-Whisper."""

    def __init__(self) -> None:
        import onnx_asr
        from . import paths  # noqa: F401
        from audio_transcription import catalog
        from audio_transcription.backends import force_hub_offline
        from audio_transcription.weights import fetch

        force_hub_offline()
        entry = catalog.PARAKEET_ENGLISH
        self.model = onnx_asr.load_model(
            entry.model, fetch(entry).path, quantization=entry.quantization, providers=["CPUExecutionProvider"]
        )

    def generate(self, audio: Any, **_: Any) -> Any:
        class Answer:
            text = str(self.model.recognize(audio, sample_rate=SAMPLE_RATE))

        return Answer()


def _load_model(kind: str = "whisper") -> Any:
    if kind == "parakeet":
        return _Parakeet()
    from . import paths  # noqa: F401
    from audio_transcription import catalog
    from audio_transcription.backends import force_hub_offline
    from audio_transcription.weights import fetch
    from mlx_audio.stt import utils

    force_hub_offline()
    # Path, а не str: по строке MLX узнаёт семейство модели из последнего
    # сегмента пути, а у снапшота это хэш коммита.
    return utils.load_model(Path(fetch(catalog.WHISPER_TURBO).path))


def _waveform(request: dict) -> Any:
    import numpy as np

    if request.get("pcm"):
        raw = base64.b64decode(request["pcm"])
        return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    import wave

    with wave.open(str(request["wav"]), "rb") as handle:
        frames = handle.readframes(handle.getnframes())
    return np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0


def _hotwords(words: list[str] | None) -> list[str] | None:
    from .whisper_hint import pick_terms

    return pick_terms(words, limit=HOTWORDS_LIMIT, chars=HOTWORDS_CHARS) or None


def _transcribe(model: Any, request: dict, *, hint: str = "phrase") -> dict:
    """Окно → текст. `hint="phrase"` (L4): громкость до −0,1 dBFS и подсказка «фраза-образец +
    термины»; `"legacy"` — как до L4, только термины через `hotwords` (для стенда)."""
    audio = _waveform(request)
    started = time.monotonic()
    if len(audio) < SAMPLE_RATE // 5:
        return {"window_id": request["window_id"], "text": "", "words": [], "seconds": 0.0}
    language = request.get("language") or None
    prompt_kwargs: dict[str, Any] = {"hotwords": _hotwords(request.get("hotwords"))}
    if hint == "phrase" and not isinstance(model, _Parakeet):
        from .whisper_hint import build_prompt, peak_normalize

        audio = peak_normalize(audio)
        prompt_kwargs = {"initial_prompt": build_prompt(language, request.get("hotwords"))}
    answer = model.generate(
        audio,
        language=language,
        **prompt_kwargs,
        word_timestamps=False,
        condition_on_previous_text=False,
        # Без повторов с температурой 0,2…1,0: на коротком окне они
        # замедляли ответ в разы, а проверяющей важен срок.
        temperature=0.0,
        verbose=None,
    )
    text = str(getattr(answer, "text", "") or "").strip()
    return {
        "window_id": request["window_id"],
        "text": text,
        "seconds": round(time.monotonic() - started, 3),
    }


def _detect(model: Any, request: dict) -> dict:
    """L5: вероятности языков по первым секундам окна — только у Whisper."""
    import mlx.core as mx
    from mlx_audio.stt.models.whisper.audio import N_FRAMES, log_mel_spectrogram, pad_or_trim

    from .language_detect import DETECT_SECONDS
    from .whisper_hint import peak_normalize

    started = time.monotonic()
    if isinstance(model, _Parakeet):
        return {"window_id": request["window_id"], "language": None, "error": "parakeet не определяет язык"}
    audio = peak_normalize(_waveform(request)[: int(DETECT_SECONDS * SAMPLE_RATE)])
    mel = log_mel_spectrogram(mx.array(audio), n_mels=model.dims.n_mels)
    segment = pad_or_trim(mel, N_FRAMES, axis=-2).astype(model.dtype)
    _, probs = model.detect_language(segment)
    allowed = [str(code) for code in request.get("detect") or []]
    picked = {code: round(float(probs.get(code, 0.0)), 4) for code in allowed} if allowed else {}
    return {"window_id": request["window_id"], "probs": picked, "seconds": round(time.monotonic() - started, 3)}


def worker_main() -> int:
    """Цикл процесса проверяющей: читатель stdin в потоке, декодер в главном."""
    try:
        os.nice(5)
    except OSError:
        pass
    out_lock = threading.Lock()

    def send(payload: dict) -> None:
        with out_lock:
            sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    started = time.monotonic()
    kind = os.environ.get("MOSTIK_WORKER_MODEL", "whisper")
    try:
        model = _load_model(kind)
    except Exception as error:  # noqa: BLE001 — нет MLX или весов: проверка выключена
        send({"ready": False, "error": f"{type(error).__name__}: {error}"})
        return 0
    send({"ready": True, "seconds": round(time.monotonic() - started, 2)})

    queue: collections.deque[dict] = collections.deque()
    ready = threading.Condition()
    closed = threading.Event()

    def reader() -> None:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
            except ValueError:
                continue
            with ready:
                if "cancel" in request:
                    session = request["cancel"]
                    kept = [item for item in queue if item.get("session") != session]
                    queue.clear()
                    queue.extend(kept)
                elif request.get("shutdown"):
                    break
                else:
                    queue.append(request)
                ready.notify()
        closed.set()
        with ready:
            ready.notify()

    threading.Thread(target=reader, name="verifier-stdin", daemon=True).start()
    while True:
        with ready:
            while not queue and not closed.is_set():
                ready.wait()
            if not queue:
                return 0
            request = queue.popleft()
        try:
            send(_detect(model, request) if request.get("detect") else _transcribe(model, request))
        except Exception as error:  # noqa: BLE001 — одно окно не роняет процесс
            send({"window_id": request.get("window_id"), "text": None, "error": str(error)})


# --- клиент в процессе движка ------------------------------------------------


class VerifierClient:
    """Держит дочерний процесс модели и раздаёт ответы по окнам.

    Процесс поднимается при первой нужде и гасится после 3 минут простоя
    (`sweep`) — это и есть выгрузка модели: память MLX уходит вместе с ним.
    """

    def __init__(
        self,
        idle_s: float = VERIFIER_IDLE_S,
        python: str | None = None,
        on_result: Callable[[dict], None] | None = None,
        model: str = "whisper",
    ) -> None:
        if model not in WORKER_MODELS:
            raise ValueError(f"модель процесса: {model!r}")
        self.model = model
        self.idle_s = idle_s
        self.python = python or sys.executable
        self.on_result = on_result
        self._lock = threading.RLock()
        self._process: subprocess.Popen | None = None
        self._ready = threading.Event()
        self._failed: str | None = None
        self._pending: set[str] = set()
        self._used = time.monotonic()
        self.enabled = True
        # Цена одного вызова (с), скользящее среднее по ответам: прогноз «успеет ли» на stop.
        self.call_ema_s: float | None = None

    @property
    def available(self) -> bool:
        return self.enabled and self._failed is None

    @property
    def failure(self) -> str | None:
        return self._failed

    def ensure(self) -> bool:
        """Запускает процесс, если его нет. Не ждёт загрузки модели."""
        if not self.available:
            return False
        with self._lock:
            if self._process is not None and self._process.poll() is None:
                return True
            engine_dir = str(Path(__file__).resolve().parent.parent)
            env = isolation.child_env()  # П10 С1: без PYTHON*, DYLD_*, LD_*
            env.setdefault("HF_HUB_OFFLINE", "1")
            env["MOSTIK_WORKER_MODEL"] = self.model
            self._ready.clear()
            self._pending.clear()
            self._process = subprocess.Popen(
                isolation.module_command(self.python, "mostik_engine.verifier_worker", engine_dir),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=None,  # stderr ребёнка — в stderr движка, то есть в лог
                text=True,
                bufsize=1,
                env=env,
                cwd=engine_dir,
            )
            self._used = time.monotonic()
            threading.Thread(
                target=self._read, args=(self._process,), name="verifier-reader", daemon=True
            ).start()
            _log(f"запущен процесс {self.model}, pid {self._process.pid}")
            return True

    def wait_ready(self, timeout: float) -> bool:
        return self._ready.wait(timeout)

    def _read(self, process: subprocess.Popen) -> None:
        assert process.stdout is not None
        for line in process.stdout:
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if "ready" in message:
                if message["ready"]:
                    _log(f"{self.model} загружен за {message.get('seconds')} с")
                    self._ready.set()
                else:
                    self._failed = str(message.get("error") or "unknown")
                    _log(f"{self.model} недоступен: {self._failed}")
                    self._ready.set()
                continue
            with self._lock:
                self._pending.discard(str(message.get("window_id")))
                self._used = time.monotonic()
                self._learn_cost(message)
            if self.on_result:
                self.on_result(message)
        with self._lock:
            if self._process is process:
                self._process = None
                self._pending.clear()
        self._ready.set()

    def _learn_cost(self, message: dict) -> None:
        if str(message.get("window_id", "")).endswith(":detect"):
            return  # определение языка — другой вызов, другая цена
        try:
            seconds = float(message.get("seconds") or 0.0)
        except (TypeError, ValueError):
            return
        if seconds <= 0:
            return
        self.call_ema_s = seconds if self.call_ema_s is None else 0.7 * self.call_ema_s + 0.3 * seconds

    def submit(
        self,
        window_id: str,
        session: str,
        pcm16: bytes,
        language: str,
        hotwords: list[str] | None = None,
    ) -> bool:
        if not self.ensure():
            return False
        request = {
            "window_id": window_id,
            "session": session,
            "pcm": base64.b64encode(pcm16).decode("ascii"),
            "language": language,
            "hotwords": hotwords or [],
        }
        return self._write(request, window_id)

    def submit_detect(self, window_id: str, session: str, pcm16: bytes, languages: list[str]) -> bool:
        """L5: определить язык окна среди `languages`; ответ придёт в `on_result` с `probs`."""
        if not self.ensure():
            return False
        request = {
            "window_id": window_id,
            "session": session,
            "pcm": base64.b64encode(pcm16).decode("ascii"),
            "detect": list(languages),
        }
        return self._write(request, window_id)

    def cancel(self, session: str) -> None:
        with self._lock:
            if self._process is not None and self._process.poll() is None:
                self._write({"cancel": session})

    def _write(self, payload: dict, window_id: str | None = None) -> bool:
        with self._lock:
            process = self._process
            if process is None or process.stdin is None:
                return False
            try:
                process.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
                process.stdin.flush()
            except (BrokenPipeError, OSError, ValueError):
                return False
            if window_id:
                self._pending.add(window_id)
            self._used = time.monotonic()
            return True

    def busy(self) -> bool:
        with self._lock:
            return bool(self._pending)

    def stop(self) -> None:
        """Выгрузка: процесс завершается, память MLX освобождается."""
        with self._lock:
            process, self._process = self._process, None
            self._pending.clear()
        if process is None:
            return
        try:
            if process.stdin:
                process.stdin.close()
            process.wait(timeout=3)
        except Exception:  # noqa: BLE001
            process.kill()
        _log(f"процесс {self.model} остановлен")

    def sweep(self, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        with self._lock:
            idle = self._process is not None and not self._pending and now - self._used > self.idle_s
        if idle:
            self.stop()
        return idle

    def running(self) -> bool:
        with self._lock:
            return self._process is not None and self._process.poll() is None


# Проверяющая по языку: для ru — Whisper, для en — Parakeet (как в transcriber).
VERIFIER_MODEL_BY_LANGUAGE = {"ru": "whisper", "en": "parakeet"}


class VerifierRouter:
    """Проверяющие по языкам; процесс каждой поднимается при первой нужде."""

    def __init__(self, on_result: Callable[[dict], None] | None = None) -> None:
        self.clients = {
            language: VerifierClient(on_result=on_result, model=model)
            for language, model in VERIFIER_MODEL_BY_LANGUAGE.items()
        }

    def for_language(self, language: str) -> VerifierClient:
        return self.clients[language]

    @property
    def available(self) -> bool:
        return any(client.available for client in self.clients.values())

    def ensure(self, language: str = "ru") -> bool:
        return self.for_language(language).ensure()

    def running(self) -> bool:
        return any(client.running() for client in self.clients.values())

    def stop(self) -> None:
        for client in self.clients.values():
            client.stop()

    def sweep(self, now: float | None = None) -> bool:
        return any([client.sweep(now) for client in self.clients.values()])


if __name__ == "__main__":
    sys.exit(worker_main())
