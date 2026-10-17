"""Цикл протокола движка (§2): строки JSON в stdin → ответы и события в stdout.

stdout — контракт: в него пишет только `emit`. Всё прочее, включая печать
библиотек на уровне C, уходит в stderr: файловый дескриптор 1 подменяется
дескриптором 2 ещё до загрузки моделей.

Потоки:
- главный — читает stdin и разбирает команды, никогда не распознаёт сам;
- рабочий — одна очередь с приоритетом: всё, что трогает модели (окна сессий,
  `stop`, `warmup`, `transcribe_file` кусками), строго по одному;
- встречи — своя очередь; встреча ждёт, пока нет диктовки, и перед запуском
  выгружает проверяющую (§12.12);
- уборка — раз в 15 с выгружает простаивающие модели.
"""
from __future__ import annotations

import base64
import binascii
import itertools
import json
import os
import platform
import queue
import sys
import threading
import time
import uuid
import wave
from pathlib import Path
from typing import Any, Callable, TextIO

from . import crash_report
from . import __version__
from . import calendar_terms
from . import model_store
from . import polish as polish_mod
from . import privacy
from . import sources as sources_mod
from . import speech_rules
from . import style_packs
from .doubts import DEFAULT_LIMIT, TermIndex, rejected_keys
from .models import ModelMissing, ModelPool, cached_models, log
from .personal_glossary import PersonalGlossary
from .power import PowerState
from .project_glossary import ProjectGlossaries, build as build_project_glossary
from .session import SAMPLE_RATE, Session
from .verifier_worker import VerifierRouter

PRIORITY_SESSION = 0
PRIORITY_BACKGROUND = 1
FILE_SLICE_S = 10.0
FRAME_S = 0.1
SWEEP_EVERY_S = 15.0
DEFAULT_FILE_WAIT_MS = 120_000


def diarization_status() -> dict:
    """Для «Проверки»: разделит ли этот Mac встречу по голосам (`fluidaudiocli` и модели FluidAudio)."""
    try:
        from .meeting import diarization_problem

        problem = diarization_problem()
    except Exception as error:  # noqa: BLE001
        problem = f"{type(error).__name__}: {error}"
    return {"available": problem is None, "detail": problem or ""}


class EngineError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def protect_stdout() -> TextIO:
    """Свой дескриптор для протокола; fd 1 отныне — stderr."""
    sys.stdout.flush()
    real = os.dup(1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return os.fdopen(real, "w", encoding="utf-8", buffering=1)


def parse_command(line: str) -> dict:
    """Строка stdin → команда. Ошибка формата — EngineError('internal')."""
    try:
        payload = json.loads(line)
    except ValueError as error:
        raise EngineError("internal", f"не JSON: {error}") from error
    if not isinstance(payload, dict):
        raise EngineError("internal", "команда должна быть объектом JSON")
    if not isinstance(payload.get("cmd"), str):
        raise EngineError("internal", "нет поля cmd")
    return payload


def decode_pcm(text: Any) -> bytes:
    if not isinstance(text, str):
        raise EngineError("bad_audio", "pcm должен быть строкой base64")
    try:
        raw = base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError) as error:
        raise EngineError("bad_audio", f"pcm не base64: {error}") from error
    if len(raw) % 2:
        raise EngineError("bad_audio", "pcm int16: нечётное число байт")
    return raw


def read_wav_pcm16(path: str | Path) -> bytes:
    """WAV → int16 LE 16 кГц моно; чужой формат приводится numpy."""
    import numpy as np

    try:
        with wave.open(str(path), "rb") as handle:
            channels = handle.getnchannels()
            width = handle.getsampwidth()
            rate = handle.getframerate()
            frames = handle.readframes(handle.getnframes())
    except (OSError, EOFError, wave.Error) as error:
        raise EngineError("bad_audio", f"не читается WAV {path}: {error}") from error
    if width == 2:
        data = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    elif width == 4:
        data = np.frombuffer(frames, dtype="<i4").astype(np.float32) / 2**31
    elif width == 1:
        data = (np.frombuffer(frames, dtype=np.uint8).astype(np.float32) - 128) / 128.0
    else:
        raise EngineError("bad_audio", f"неподдерживаемая разрядность WAV: {width * 8} бит")
    if channels > 1:
        data = data.reshape(-1, channels).mean(axis=1)
    if rate != SAMPLE_RATE and len(data):
        target = int(round(len(data) * SAMPLE_RATE / rate))
        data = np.interp(
            np.linspace(0, len(data) - 1, target), np.arange(len(data)), data
        ).astype(np.float32)
    if width == 2 and channels == 1 and rate == SAMPLE_RATE:
        return frames
    return (np.clip(data, -1.0, 1.0) * 32767).astype("<i2").tobytes()


class Engine:
    def __init__(
        self,
        out: TextIO | None = None,
        *,
        pool: Any = None,
        verifier: Any = None,
        personal: PersonalGlossary | None = None,
        polishers: dict[str, Any] | None = None,
    ) -> None:
        self.out = out or sys.stdout
        # Бэкенды полировщика (D3, G7): `claude`, `mlx`; тесты подставляют свои.
        self.polishers = polish_mod.default_backends() if polishers is None else polishers
        self._out_lock = threading.Lock()
        self.pool = pool or ModelPool()
        self.verifier = verifier or VerifierRouter(on_result=self._on_verifier)
        self.personal = personal or PersonalGlossary()
        self.projects = ProjectGlossaries()
        self.power = PowerState()
        self.sessions: dict[str, Session] = {}
        self._sessions_lock = threading.Lock()
        self._live: dict[str, Session] = {}  # включая остановленные, ждущие проверяющую
        self._terms: dict[tuple, tuple[TermIndex, list[str]]] = {}
        # «Скрыть термин» во вкладке «Словарь»: найденный термин не идёт в подсказку распознаванию.
        self.hidden_terms: frozenset[str] = frozenset()
        self._jobs: queue.PriorityQueue = queue.PriorityQueue()
        self._seq = itertools.count()
        self._busy = threading.Event()
        self._meetings: queue.Queue = queue.Queue()
        self.meeting_running = threading.Event()
        self._stopping = threading.Event()
        threading.Thread(target=self._worker, name="mostik-worker", daemon=True).start()
        threading.Thread(target=self._meeting_lane, name="mostik-meetings", daemon=True).start()
        threading.Thread(target=self._sweeper, name="mostik-sweeper", daemon=True).start()

    # --- вывод ------------------------------------------------------------

    def emit(self, payload: dict) -> None:
        line = json.dumps(payload, ensure_ascii=False)
        with self._out_lock:
            self.out.write(line + "\n")
            self.out.flush()

    def reply(self, command_id: Any, **fields: Any) -> None:
        self.emit({"id": command_id, "ok": True, **fields})

    def error(self, code: str, message: str, *, command_id: Any = None, session: str | None = None) -> None:
        payload: dict[str, Any] = {"event": "error", "ok": False, "code": code, "message": message}
        if command_id is not None:
            payload["id"] = command_id
        if session is not None:
            payload["session"] = session
        self.emit(payload)

    # --- очереди ----------------------------------------------------------

    def submit(self, priority: int, job: Callable[[], None]) -> None:
        self._jobs.put((priority, next(self._seq), job))

    def _worker(self) -> None:
        while True:
            _, _, job = self._jobs.get()
            self._busy.set()
            try:
                job()
            except Exception:  # noqa: BLE001 — задача сама сообщает об ошибке
                log("сбой задачи:\n" + crash_report.safe_traceback())
            finally:
                if self._jobs.empty():
                    self._busy.clear()

    def idle(self) -> bool:
        with self._sessions_lock:
            active = bool(self.sessions)
        return not active and not self._busy.is_set() and self._jobs.empty()

    def _sweeper(self) -> None:
        while not self._stopping.wait(SWEEP_EVERY_S):
            if self.idle():
                self.pool.sweep()
                self.verifier.sweep()
                for backend in self.polishers.values():  # локальная LLM выгружается по простою
                    sweep = getattr(backend, "sweep", None)
                    if sweep:
                        sweep()

    # --- проверяющая ------------------------------------------------------

    def _verifier_for(self, language: str) -> Any:
        """Своя проверяющая у каждого языка; подставленный в тестах клиент — общий."""
        router = getattr(self.verifier, "for_language", None)
        return router(language) if router else self.verifier

    def verifier_allowed(self, language: str | None = None) -> bool:
        verifier = self._verifier_for(language) if language else self.verifier
        return self.power.verifier_enabled and not self.meeting_running.is_set() and verifier.available

    def _on_verifier(self, message: dict) -> None:
        session_id = str(message.get("window_id", "")).rsplit(":", 1)[0]
        with self._sessions_lock:
            session = self._live.get(session_id)
        if session is not None:
            session.on_verifier(message)

    # --- словари ----------------------------------------------------------

    def _terms_for(
        self, project: str | None, language: str, folders: list[str] | None = None
    ) -> tuple[TermIndex, list[str]]:
        """Словарь сессии = проект + папки документов + календарь + личный.

        Ключ кэша учитывает всё, что меняет набор: папки, время записи
        календаря и личного словаря, размер и голову каждого списка.
        """
        folders = list(folders or [])
        try:
            mtime = self.personal.path.stat().st_mtime
        except OSError:
            mtime = 0.0
        project_terms, doc_terms, calendar = sources_mod.session_terms(self.projects, project, folders)
        hidden = self.hidden_terms
        if hidden:
            project_terms = [term for term in project_terms if term not in hidden]
            doc_terms = [term for term in doc_terms if term not in hidden]
            calendar = [term for term in calendar if term not in hidden]
        key = (
            project, tuple(folders), language, mtime, calendar_terms.mtime(), hidden,
            len(project_terms), tuple(project_terms[:5]),
            len(doc_terms), tuple(doc_terms[:5]),
            len(calendar), tuple(calendar[:5]),
        )
        cached = self._terms.get(key)
        if cached is None:
            index = TermIndex([*project_terms, *doc_terms, *calendar], self.personal.trusted(language))
            hotwords: list[str] = []
            for term in [*project_terms[:30], *calendar[:15], *doc_terms[:15],
                         *self.personal.hotwords(language, limit=30)]:
                if term not in hotwords:
                    hotwords.append(term)
            cached = (index, hotwords)
            self._terms = {key: cached}
        return cached

    def _new_session(self, session_id: str, payload: dict, verify: bool) -> Session:
        language = payload.get("language") or "ru"
        if language not in ("ru", "en"):
            raise EngineError("internal", f"язык {language!r} не поддерживается: ru или en")
        session = Session(
            session_id,
            language,
            pool=self.pool,
            verifier=self._verifier_for(language),
            verify=verify and self.verifier_allowed(language),
            personal=[],
            emit=self.emit,
            limit=int(payload.get("doubts_limit") or DEFAULT_LIMIT),
        )
        session.polish = self._polish_config(payload)
        # Правила речи (P3, V4) и контекст из приложения (P1, команда `context`).
        session.rules = speech_rules.parse_rules(payload.get("rules"))
        session.polish_context = polish_mod.clean_context(payload.get("context"))
        self._setup_language_detection(session, payload)
        for llm in self.polishers.values():  # фоновая генерация локальной LLM ждёт конца диктовки
            hold = getattr(llm, "hold", None)
            if hold:
                session.llm_releases.append(hold(session_id))
        backend = self.polishers.get(session.polish["backend"]) if session.polish else None
        if getattr(backend, "streaming", False) or getattr(backend, "prespawn", False):
            # MLX: инструкция уходит модели сразу, окна — по ходу речи (D3). claude -p: процесс
            # поднимается сейчас, текст — одним сообщением на отпускании (шаг 1, п. 6).
            session.polish_stream = backend.open_stream(self._polish_request(session.polish, "", language))
        return session

    @staticmethod
    def _polish_config(payload: dict) -> dict | None:
        """Поле `polish: {backend, style}` команды; `off` или его отсутствие — None."""
        raw = payload.get("polish")
        if raw is None:
            return None
        if not isinstance(raw, dict):
            raise EngineError("internal", "polish должен быть объектом {backend, style}")
        backend = raw.get("backend") or "off"
        style = raw.get("style") or "plain"
        if backend not in polish_mod.BACKENDS:
            raise EngineError("internal", f"polish.backend {backend!r}: ожидается off, claude или mlx")
        if style not in polish_mod.STYLES:
            raise EngineError("internal", f"polish.style {style!r}: ожидается {', '.join(polish_mod.STYLES)}")
        if backend == "off":
            return None
        timeout = raw.get("timeout_s")
        try:
            timeout = float(timeout) if timeout is not None else polish_mod.DEFAULT_TIMEOUT_S
        except (TypeError, ValueError):
            timeout = polish_mod.DEFAULT_TIMEOUT_S
        config = {"backend": backend, "style": style, "timeout_s": max(1.0, min(timeout, 60.0))}
        # P4: пакет стиля из файлов; не найден — обычный стиль, это не ошибка протокола.
        pack_id = raw.get("pack")
        if pack_id:
            pack = style_packs.load(str(pack_id))
            if pack is None:
                log(f"пакет стиля {pack_id!r} не найден — стиль {style}")
            config["pack"] = pack
        # V3: «диктуешь по-русски — вставляется по-английски».
        translate = raw.get("translate")
        if isinstance(translate, str):
            translate = {"to": translate}
        if isinstance(translate, dict) and translate.get("to"):
            target, tone = translate.get("to"), translate.get("tone") or "plain"
            if target not in polish_mod.TRANSLATE_TO or tone not in polish_mod.TONES:
                raise EngineError("internal", f"polish.translate {translate!r}: ожидается to en|ru, tone plain|business|dev")
            config["translate"] = {"to": target, "tone": tone}
        # P6: куски причёсанного текста событиями `polish_partial` (только потоковый бэкенд).
        config["stream"] = bool(raw.get("stream"))
        return config

    @staticmethod
    def _polish_request(config: dict, text: str, language: str, **extra: Any) -> polish_mod.PolishRequest:
        translate = config.get("translate") or {}
        return polish_mod.PolishRequest(
            text, language, config["style"], pack=config.get("pack"),
            translate_to=translate.get("to") if translate.get("to") != language else None,
            tone=translate.get("tone"), **extra)

    # --- автоопределение языка (L5) ----------------------------------------

    def _whisper_client(self) -> Any:
        """Процесс Whisper, который уже держим ради проверки русского; в тестах — подставной."""
        clients = getattr(self.verifier, "clients", None)
        if isinstance(clients, dict):
            return next((c for c in clients.values() if getattr(c, "model", "") == "whisper"), None)
        return self.verifier if hasattr(self.verifier, "submit_detect") else None

    def _setup_language_detection(self, session: Session, payload: dict) -> None:
        from .language_detect import allowed_languages

        languages = allowed_languages(payload.get("languages"))
        if len(languages) < 2 or session.language not in languages:
            return
        client = self._whisper_client()
        if client is None or not self.power.verifier_enabled or self.meeting_running.is_set():
            return
        session.languages = languages
        session.detector = client.submit_detect
        verify = session.verifier is not None

        def changed(current: Session) -> None:
            index, hotwords = self._terms_for(getattr(current, "project_root", None), current.language,
                                              getattr(current, "folders", None))
            current.terms, current.hotwords = index, hotwords
            current.personal = self.personal.entries(current.language)
            if verify:
                current.verifier = (self._verifier_for(current.language)
                                    if self.verifier_allowed(current.language) else None)
                if current.verifier is not None:
                    current.verifier.ensure()
            self.pool.primary(current.language)

        session.on_language = changed

    def _prepare(self, session: Session, project: str | None, folders: list[str] | None = None) -> None:
        """В рабочем потоке: словари, модель, проверяющая."""
        prepared = time.monotonic()
        session.project_root, session.folders = project, folders
        if session.detector is not None:
            client = self._whisper_client()
            if client is not None:
                client.ensure()
        index, hotwords = self._terms_for(project, session.language, folders)
        session.terms = index
        session.hotwords = hotwords
        session.personal = self.personal.entries(session.language)
        session.rejected_doubts = rejected_keys(self._learning_store().rejected_doubts())
        if session.verifier is not None:
            session.verifier.ensure()
        # Шаг 0: сколько ушло на подготовку и была ли загрузка модели (первая диктовка после простоя).
        has_primary = getattr(self.pool, "has_primary", None)
        cold = has_primary is not None and not has_primary(session.language)
        loading = time.monotonic()
        self.pool.primary(session.language)
        session.model_load_ms = (time.monotonic() - loading) * 1000 if cold else 0.0
        self.pool.vad()
        session.prepare_ms = (time.monotonic() - prepared) * 1000

    # --- команды ----------------------------------------------------------

    def handle_line(self, line: str) -> bool:
        """Одна строка stdin. False — пора выходить."""
        line = line.strip()
        if not line:
            return True
        try:
            command = parse_command(line)
        except EngineError as error:
            self.error(error.code, str(error))
            return True
        name = command["cmd"]
        handler = getattr(self, f"cmd_{name}", None)
        command_id = command.get("id")
        if handler is None:
            self.error("internal", f"неизвестная команда {name!r}", command_id=command_id)
            return True
        # Приватность: облачный бэкенд — только с согласием, которое приложение передало в команде.
        refused = privacy.refusal(command)
        if refused:
            log(f"отказ: {refused}")
            self.error("consent_required", refused, command_id=command_id, session=command.get("session"))
            return True
        try:
            return handler(command) is not False
        except EngineError as error:
            self.error(error.code, str(error), command_id=command_id, session=command.get("session"))
        except Exception as error:  # noqa: BLE001
            log(crash_report.safe_traceback())
            self.error("internal", f"{type(error).__name__}: {error}", command_id=command_id,
                       session=command.get("session"))
        return True

    def run(self, stream: TextIO | None = None) -> int:
        stream = stream or sys.stdin
        for line in stream:
            if not self.handle_line(line):
                break
        self._stopping.set()
        polish_mod.kill_all()
        self.verifier.stop()
        close = getattr(self.pool, "close", None)
        if close:
            close()
        return 0

    def cmd_hello(self, command: dict) -> None:
        """Версия и состояние: модели, бэкенды причёсывания, разделение встреч по голосам."""
        self.reply(
            command.get("id"),
            version=__version__,
            python=platform.python_version(),
            models=cached_models(),
            verifier_enabled=self.verifier_allowed(),
            polish={name: backend.status() for name, backend in self.polishers.items()},
            home=str(self.personal.path.parent),
            diarization=diarization_status(),
        )

    # --- модели по кнопке (П8, пункт 5) -------------------------------------

    def cmd_models(self, command: dict) -> None:
        """Манифест и что из него уже стоит в кэше HF; в сеть не ходит."""
        self.reply(command.get("id"), models=model_store.status(), hub=str(model_store.hub_dir()),
                   downloading=getattr(self, "_downloader", None) is not None)

    def cmd_models_download(self, command: dict) -> None:
        """Качает `keys` в своём потоке: события `models_progress`, в конце ответ на `id`.

        Начинает только приложение по кнопке пользователя; одна загрузка за раз.
        """
        command_id = command.get("id")
        keys = [str(key) for key in command.get("keys") or []]
        if getattr(self, "_downloader", None) is not None:
            self.error("busy", "Загрузка моделей уже идёт.", command_id=command_id)
            return
        if not keys:
            keys = [row["key"] for row in model_store.status() if row["required"] and not row["installed"]]
        base_url = command.get("base_url")
        if base_url is not None and not (isinstance(base_url, str) and base_url.startswith(("https://", "http://"))):
            self.error("internal", f"base_url {base_url!r}: ожидается http(s)-адрес", command_id=command_id)
            return
        downloader = model_store.Downloader(base_url=base_url)
        self._downloader = downloader

        def progress(event: dict) -> None:
            self.emit({"event": "models_progress", **event})

        def run() -> None:
            try:
                installed = downloader.download(keys, progress)
            except model_store.ModelDownloadError as error:
                self.error(f"models_{error.code}", str(error), command_id=command_id)
                return
            except Exception as error:  # noqa: BLE001
                log(crash_report.safe_traceback())
                self.error("internal", f"{type(error).__name__}: {error}", command_id=command_id)
                return
            finally:
                self._downloader = None
            self.reply(command_id, installed=installed, models=model_store.status())

        threading.Thread(target=run, name="mostik-models", daemon=True).start()

    def cmd_models_cancel(self, command: dict) -> None:
        downloader = getattr(self, "_downloader", None)
        if downloader is not None:
            downloader.cancel()
        self.reply(command.get("id"), cancelled=downloader is not None)

    def cmd_warmup(self, command: dict) -> None:
        language = command.get("language") or "ru"
        command_id = command.get("id")
        polish = command.get("polish") if isinstance(command.get("polish"), dict) else {}
        warm = getattr(self.polishers.get(polish.get("backend") or ""), "warm", None)
        if warm:
            warm()  # локальная LLM грузится в своём процессе, заранее (§4)

        def job() -> None:
            started = time.monotonic()
            try:
                loaded = self.pool.warmup(language)
            except ModelMissing as error:
                self.error("model_missing", str(error), command_id=command_id)
                return
            except Exception as error:  # noqa: BLE001
                self.error("internal", f"{type(error).__name__}: {error}", command_id=command_id)
                return
            verifier = self._verifier_for(language)
            if self.verifier_allowed(language) and command.get("verify", True):
                verifier.ensure()
            self.reply(command_id, loaded=loaded, seconds=round(time.monotonic() - started, 2),
                       verifier=verifier.running())

        self.submit(PRIORITY_BACKGROUND, job)

    def cmd_start(self, command: dict) -> None:
        session_id = str(command.get("session") or "")
        if not session_id:
            raise EngineError("internal", "нет поля session")
        with self._sessions_lock:
            previous = self.sessions.pop(session_id, None)
            # Новая запись при недосказанной старой: старую приложение
            # потеряло (перезапуск, сбой) — её звук уже никому не нужен.
            stale = list(self.sessions.values())
            self.sessions.clear()
        for old in [previous, *stale]:
            if old is not None:
                log(f"сессия {old.id} брошена: пришёл start {session_id}")
                old.cancel()
        folders = self._folders(command)
        session = self._new_session(session_id, command, bool(command.get("verify", True)))
        with self._sessions_lock:
            self.sessions[session_id] = session
            self._live[session_id] = session
        project = command.get("project")

        def prepare() -> None:
            try:
                self._prepare(session, project, folders)
            except ModelMissing as error:
                self.error("model_missing", str(error), session=session_id)

        self.submit(PRIORITY_SESSION, prepare)
        self.reply(command.get("id"), verifier=session.verifier is not None)

    def cmd_audio(self, command: dict) -> None:
        session_id = str(command.get("session") or "")
        with self._sessions_lock:
            session = self.sessions.get(session_id)
        if session is None:
            return  # звук после cancel/stop — молча мимо
        session.append(decode_pcm(command.get("pcm")))
        if session.due() and not session.step_queued:
            session.step_queued = True

            def step() -> None:
                session.step_queued = False
                if not session.cancelled:
                    session.step()

            self.submit(PRIORITY_SESSION, step)

    def cmd_stop(self, command: dict) -> None:
        stop_at = time.monotonic()
        session_id = str(command.get("session") or "")
        with self._sessions_lock:
            session = self.sessions.pop(session_id, None)
        if session is None:
            raise EngineError("internal", f"нет сессии {session_id!r}")
        wait_ms = float(command.get("wait_verifier_ms", 500) or 0)
        self.submit(PRIORITY_SESSION, lambda: self._finish(session, wait_ms, stop_at, command.get("id")))

    def cmd_skip_verifier(self, command: dict) -> None:
        """«Вставить быструю версию»: остановленная сессия перестаёт ждать проверяющую.

        Идёт мимо очереди работ — finish этой сессии как раз занимает её поток.
        """
        session_id = str(command.get("session") or "")
        with self._sessions_lock:
            session = self._live.get(session_id)
        if session is not None:
            session.skip_wait()

    def _finish(self, session: Session, wait_ms: float, stop_at: float, command_id: Any) -> None:
        def on_wait(done: int, total: int) -> None:
            self.emit({"event": "progress", "task": "dictation", "session": session.id,
                       "stage": "verify", "done": done, "total": total})

        try:
            result = session.finish(wait_ms, stop_at, on_wait=on_wait)
        except ModelMissing as error:
            self._close_polish_stream(session)
            self.error("model_missing", str(error), command_id=command_id, session=session.id)
            return
        except Exception as error:  # noqa: BLE001
            self._close_polish_stream(session)
            log(crash_report.safe_traceback())
            self.error("internal", f"{type(error).__name__}: {error}", command_id=command_id,
                       session=session.id)
            return
        finally:
            with self._sessions_lock:
                self._live.pop(session.id, None)
        if command_id is not None:
            result["id"] = command_id
        rules = getattr(session, "rules", None)
        if rules and result.get("text"):
            # P3, V4: однозначное — по словам, до модели и без неё.
            result["text"], applied = speech_rules.apply(result["text"], session.language, rules)
            if applied:
                result["rules"] = applied
        config = getattr(session, "polish", None)
        if not config or not result.get("text"):
            self._close_polish_stream(session)  # заранее поднятый `claude -p` не ждёт зря (шаг 1, п. 6)
            result["polished"] = False
            self.emit(result)
            return
        # Полировка ждёт сеть до 20 с — не в рабочем потоке: следующая диктовка не стоит в очереди.
        threading.Thread(
            target=self._polish_and_emit, args=(session, result, config, stop_at),
            name=f"mostik-polish-{session.id}", daemon=True,
        ).start()

    @staticmethod
    def _close_polish_stream(session: Session) -> None:
        stream = getattr(session, "polish_stream", None)
        if stream is not None:
            try:
                stream.cancel()
            except Exception:  # noqa: BLE001
                pass

    def _polish_and_emit(self, session: Session, result: dict, config: dict, stop_at: float) -> None:
        """Стадия «причёсывания» после словаря и отбора сомнений (D3, D4).

        Сомнения уже отобраны по тексту до полировки: пары основная/проверяющая
        живут в нём. Их «услышанное» передаётся полировщику как неприкосновенное,
        чтобы блок сомнений для агента ссылался на слова, которые есть в тексте;
        `in_text` у сомнения говорит, удалось ли это.
        """
        try:
            result.update(self.polish_result(session, result, config))
        except Exception:  # noqa: BLE001 — сбой стадии не теряет диктовку
            log("сбой полировки:\n" + crash_report.safe_traceback())
            result["polished"] = False
            self._close_polish_stream(session)
        result["timings"]["tail_ms"] = round((time.monotonic() - stop_at) * 1000, 1)
        self.emit(result)

    def polish_result(self, session: Session, result: dict, config: dict) -> dict:
        backend = self.polishers.get(config["backend"])
        before = result["text"]
        candidates = [*session.hotwords, *(entry.canonical for entry in session.personal),
                      *(hit.canonical for hit in getattr(session.terms, "exact", {}).values())]
        keep = [doubt["heard"] for doubt in result.get("doubts", []) if doubt.get("heard")]
        # Режим разработчика (V1): локальной модели — словарь проекта целиком, а не только найденное
        # в тексте: распознавание слышит термины по-русски, и в тексте их ещё нет. В облако (claude)
        # весь словарь проекта не уходит — только термины, которые уже встретились в тексте (приватность).
        cloud_only_in = before if privacy.is_cloud(config["backend"]) else None
        vocabulary = (polish_mod.dev_vocabulary(session.hotwords, only_in=cloud_only_in)
                      if config["style"] == "dev" else [])
        request = self._polish_request(
            config, before, session.language,
            terms=polish_mod.pick_terms(before, candidates), keep=keep, vocabulary=vocabulary,
            context=dict(getattr(session, "polish_context", None) or {}), rules=getattr(session, "rules", None),
        )
        if config.get("stream"):
            def partial(text: str, sid: str = session.id) -> None:
                self.emit({"event": "polish_partial", "session": sid, "text": text})
            request.on_partial = partial
        if backend is None:
            outcome = polish_mod.PolishOutcome(before, False, "unavailable", detail="нет такого бэкенда")
        elif getattr(session, "polish_stream", None) is not None:
            stream = session.polish_stream
            stream.request = request
            outcome = stream.finish(before, timeout=config["timeout_s"])
        else:
            outcome = polish_mod.polish(backend, request, timeout=config["timeout_s"])
        lowered = outcome.text.lower()
        doubts = [{**doubt, "in_text": str(doubt.get("heard", "")).lower() in lowered}
                  for doubt in result.get("doubts", [])]
        timings = dict(result.get("timings") or {})
        timings["polish_ms"] = outcome.ms
        log(f"{session.id}: полировка {config['backend']}/{config['style']} — {outcome.status}, "
            f"{outcome.ms:.0f} мс")
        return {
            "text": outcome.text,
            "polished": outcome.polished,
            "unpolished_text": before,
            "doubts": doubts,
            "timings": timings,
            "polish": {"backend": config["backend"], "style": config["style"], "status": outcome.status,
                       "ms": outcome.ms, **({"detail": outcome.detail} if outcome.detail else {}),
                       **({"pack": config["pack"].id} if config.get("pack") else {}),
                       **({"translate": config["translate"]["to"]} if config.get("translate") else {}),
                       **({"context": sorted(request.context)} if request.context else {})},
        }

    # --- контекст, пакеты стилей, проба причёсывания (P1, P2, P4) ----------------------------

    def cmd_context(self, command: dict) -> None:
        """P1: контекст из приложения приходит, пока идёт запись (приложение читает его параллельно)."""
        session_id = str(command.get("session") or "")
        with self._sessions_lock:
            session = self.sessions.get(session_id) or self._live.get(session_id)
        if session is not None:
            session.polish_context = polish_mod.clean_context(command)
        if command.get("id") is not None:
            self.reply(command.get("id"), attached=session is not None)

    def cmd_styles(self, command: dict) -> None:
        if command.get("example"):
            style_packs.write_example()
        self.reply(command.get("id"), packs=style_packs.list_packs(), folder=str(style_packs.styles_dir()))

    def cmd_polish_text(self, command: dict) -> None:
        """Причесать готовый текст (превью тона P2, эталонные пары P5): своя нить, очередь не держит."""
        config = self._polish_config({"polish": command.get("polish")})
        text = str(command.get("text") or "")
        language = command.get("language") or "ru"
        rules = speech_rules.parse_rules(command.get("rules"))
        if config is None:
            raise EngineError("internal", "polish_text: нужен polish.backend claude или mlx")
        command_id = command.get("id")

        def run() -> None:
            given, applied = speech_rules.apply(text, language, rules)
            request = self._polish_request(config, given, language, rules=rules,
                                           context=polish_mod.clean_context(command.get("context")))
            outcome = polish_mod.polish(self.polishers.get(config["backend"]), request, timeout=config["timeout_s"])
            self.reply(command_id, text=outcome.text, polished=outcome.polished, status=outcome.status,
                       ms=outcome.ms, rules=applied, **({"detail": outcome.detail} if outcome.detail else {}))

        threading.Thread(target=run, name="mostik-polish-text", daemon=True).start()

    def cmd_cancel(self, command: dict) -> None:
        session_id = str(command.get("session") or "")
        with self._sessions_lock:
            session = self.sessions.pop(session_id, None)
            self._live.pop(session_id, None)
        if session is not None:
            session.cancel()
        self.reply(command.get("id"))

    def cmd_transcribe_file(self, command: dict) -> None:
        """WAV через тот же конвейер: кадры по 100 мс, шаг VAD каждые 1,5 с.

        Работа режется на куски по 10 с звука, и каждый кусок — отдельная
        задача фоновой очереди: диктовка, начатая посреди, не ждёт весь файл.
        """
        path = command.get("path")
        if not path:
            raise EngineError("internal", "нет поля path")
        folders = self._folders(command)
        pcm = read_wav_pcm16(path)
        session_id = str(command.get("session") or f"file-{uuid.uuid4().hex[:12]}")
        session = self._new_session(session_id, command, bool(command.get("verify", True)))
        with self._sessions_lock:
            self._live[session_id] = session
        command_id = command.get("id")
        wait_ms = float(command.get("wait_verifier_ms", DEFAULT_FILE_WAIT_MS))
        frame = int(FRAME_S * SAMPLE_RATE) * 2
        slice_bytes = int(FILE_SLICE_S * SAMPLE_RATE) * 2
        state = {"offset": 0, "prepared": False}

        def chunk() -> None:
            if session.cancelled:
                return
            try:
                if not state["prepared"]:
                    self._prepare(session, command.get("project"), folders)
                    state["prepared"] = True
                end = min(len(pcm), state["offset"] + slice_bytes)
                for at in range(state["offset"], end, frame):
                    session.append(pcm[at : min(at + frame, end)])
                    if session.due():
                        session.step()
                state["offset"] = end
            except ModelMissing as error:
                with self._sessions_lock:
                    self._live.pop(session_id, None)
                self.error("model_missing", str(error), command_id=command_id, session=session_id)
                return
            if state["offset"] < len(pcm):
                self.submit(PRIORITY_BACKGROUND, chunk)
            else:
                self._finish(session, wait_ms, time.monotonic(), command_id)

        self.submit(PRIORITY_BACKGROUND, chunk)

    def cmd_project_glossary(self, command: dict) -> None:
        path = command.get("path")
        if not path:
            raise EngineError("internal", "нет поля path")
        command_id = command.get("id")

        def job() -> None:
            try:
                result = build_project_glossary(path)
            except (OSError, ValueError) as error:
                self.error("internal", str(error), command_id=command_id)
                return
            self.projects.forget(str(path))
            self.reply(command_id, **result)

        threading.Thread(target=job, name="mostik-project-glossary", daemon=True).start()

    @staticmethod
    def _folders(command: dict) -> list[str]:
        try:
            return sources_mod.clean_paths(command.get("sources"))
        except ValueError as error:
            raise EngineError("internal", str(error)) from error

    def cmd_hidden_terms(self, command: dict) -> None:
        """Скрытые термины словаря: список целиком заменяет прошлый; личный словарь не трогается."""
        terms = command.get("terms")
        if not isinstance(terms, list) or not all(isinstance(term, str) for term in terms):
            raise EngineError("internal", "terms — список строк")
        self.hidden_terms = frozenset(term.strip() for term in terms if term.strip())
        self._terms = {}
        self.reply(command.get("id"), count=len(self.hidden_terms))

    def cmd_calendar(self, command: dict) -> None:
        """События EventKit → `<home>/calendar.json` (целиком), ответ — термины календаря."""
        try:
            kept = calendar_terms.store(command.get("events"))
        except ValueError as error:
            raise EngineError("internal", str(error)) from error
        self._terms = {}
        self.reply(command.get("id"), events=len(kept), terms=calendar_terms.terms(kept))

    def cmd_sources(self, command: dict, *, force: bool = False) -> None:
        """Сводка источников; обход — в своём потоке, протокол не ждёт."""
        folders = self._folders(command)
        project = command.get("project") or None
        command_id = command.get("id")

        def job() -> None:
            try:
                result = sources_mod.collect(self.projects, self.personal, project, folders, force=force)
            except Exception as error:  # noqa: BLE001
                log(crash_report.safe_traceback())
                self.error("internal", f"{type(error).__name__}: {error}", command_id=command_id)
                return
            if force:
                self._terms = {}
            self.reply(command_id, **result)

        threading.Thread(target=job, name="mostik-sources", daemon=True).start()

    def cmd_rescan(self, command: dict) -> None:
        self.cmd_sources(command, force=True)

    def cmd_remember(self, command: dict) -> None:
        heard = str(command.get("heard") or "")
        canonical = str(command.get("canonical") or "")
        if not canonical.strip():
            raise EngineError("internal", "пустой canonical")
        self.personal.remember(heard, canonical, command.get("language"))
        self.reply(command.get("id"))

    def cmd_glossary_list(self, command: dict) -> None:
        self.reply(command.get("id"), entries=self.personal.list())

    def cmd_forget(self, command: dict) -> None:
        canonical = str(command.get("canonical") or "")
        removed = self.personal.forget(canonical)
        self.reply(command.get("id"), removed=removed)

    # --- обучение на правках (L1) и импорт словаря (L6) -----------------

    def _learning_store(self) -> Any:
        store = getattr(self, "_learning", None)
        if store is None:
            from .edit_learning import LearningStore

            store = self._learning = LearningStore(self.personal.path.parent / "learning.json")
        return store

    def _known_pairs(self) -> set[str]:
        return {
            str(alias).casefold() + "→" + item["canonical"]
            for item in self.personal.list()
            for alias in item["aliases"]
        }

    def cmd_learn_edit(self, command: dict) -> None:
        """Пара «вставлено → стало» после правки в поле: фильтры, накопление, предложения."""
        from .edit_learning import candidates, verdicts_to_dict

        verdicts, skipped = candidates(str(command.get("inserted") or ""), str(command.get("edited") or ""))
        language = command.get("language") or None
        suggestions = self._learning_store().observe(verdicts, language, known=self._known_pairs())
        self.reply(command.get("id"), verdicts=verdicts_to_dict(verdicts), skipped=skipped,
                   suggestions=suggestions)

    def cmd_learn_suggestions(self, command: dict) -> None:
        self.reply(command.get("id"), suggestions=self._learning_store().suggestions())

    def cmd_learn_decide(self, command: dict) -> None:
        """Пользователь ответил на предложение: «Запомнить» кладёт пару в словарь, «Нет» — отказ на 7 дней."""
        heard = str(command.get("heard") or "").strip()
        canonical = str(command.get("canonical") or "").strip()
        if not heard or not canonical:
            raise EngineError("internal", "нужны heard и canonical")
        accept = bool(command.get("accept"))
        if accept:
            self.personal.remember(heard, canonical, command.get("language") or None)
        suggestions = self._learning_store().decide(heard, canonical, accept)
        self.reply(command.get("id"), suggestions=suggestions)

    def cmd_doubt_reject(self, command: dict) -> None:
        """«Отклонить» у слова под вопросом: пара больше не предлагается ни сомнением, ни из правок."""
        heard = str(command.get("heard") or "").strip()
        if not heard:
            raise EngineError("internal", "нужен heard")
        self._learning_store().reject_doubt(heard, str(command.get("suggestion") or ""))
        self.reply(command.get("id"))

    def cmd_glossary_import(self, command: dict) -> None:
        """L6: `source` ∈ handy, wispr, csv, lines; без `apply` — только просмотр."""
        from . import vocab_import

        source = str(command.get("source") or "")
        if source == "detect":
            self.reply(command.get("id"), detected=vocab_import.detect())
            return
        try:
            entries = vocab_import.load(source, path=command.get("path"), text=command.get("text"))
        except (vocab_import.VocabImportError, OSError) as error:
            raise EngineError("import_failed", str(error)) from None
        fresh, duplicates = vocab_import.split_new(entries, self.personal.list())
        added = 0
        if command.get("apply"):
            added = self.personal.remember_many([(entry.heard, entry.canonical) for entry in fresh])
        self.reply(command.get("id"), source=source, total=len(entries), duplicates=duplicates,
                   new=[entry.to_dict() for entry in fresh[:500]], new_count=len(fresh), added=added)

    def cmd_power(self, command: dict) -> None:
        self.power = PowerState.from_payload(command)
        enabled = self.power.verifier_enabled
        if not enabled:
            self.verifier.stop()
        self.reply(command.get("id"), verifier_enabled=enabled)

    def cmd_meeting(self, command: dict) -> None:
        self._meetings.put(command)

    def _meeting_lane(self) -> None:
        while True:
            command = self._meetings.get()
            command_id = command.get("id")
            # Диктовка главнее: встреча ждёт, пока сессий нет и очередь пуста.
            while not self.idle():
                time.sleep(0.5)
            self.meeting_running.set()
            try:
                self.verifier.stop()
                try:
                    from .meeting import run_meeting
                except Exception as error:  # noqa: BLE001
                    self.error("internal", f"модуль встреч недоступен: {error}", command_id=command_id)
                    continue
                payload = {key: value for key, value in command.items() if key not in ("cmd",)}
                # Голосовая память (M14): включает приложение командой `voices_config`, после согласия.
                from . import voices

                # Р2 Н7: эпоха памяти на старте встречи — до чтения флага, чтобы стирание между ними
                # тоже отменило запись отпечатков.
                payload["voice_epoch"] = voices.epoch()
                payload.setdefault("voice_memory", getattr(self, "voice_memory", False))
                try:
                    result = run_meeting(payload, self.emit)
                except Exception as error:  # noqa: BLE001
                    log(crash_report.safe_traceback())
                    # Свой код (например, `diarization_memory`) — приложение предложит действие.
                    code = getattr(error, "code", None)
                    if isinstance(code, str) and code:
                        self.error(code, str(error), command_id=command_id)
                    else:
                        self.error("internal", f"{type(error).__name__}: {error}", command_id=command_id)
                    continue
                event = {"event": "meeting_done", **(result or {})}
                if command_id is not None:
                    event["id"] = command_id
                self.emit(event)
            finally:
                self.meeting_running.clear()

    def cmd_meetings_migrate(self, command: dict) -> None:
        """Папка встречи (M10): старые встречи получают manifest.json и meeting.md; файлы не переписываются."""
        from . import meeting_folder
        from .paths import mostik_home

        root = Path(str(command.get("root") or "")).expanduser() if command.get("root") else mostik_home() / "meetings"

        def job() -> None:
            stats = meeting_folder.migrate_all(root)
            self.reply(command.get("id"), **stats)

        self.submit(PRIORITY_BACKGROUND, job)

    def cmd_edit(self, command: dict) -> None:
        """Голосовая правка выделенного (D5): `docs/polish-contract.md`, раздел «Голосовая правка»."""
        from . import voice_edit

        voice_edit.handle(self, command)

    def cmd_intent(self, command: dict) -> None:
        """Голосовая команда-намерение (D6): разбор в черновик события, напоминания или письма."""
        from . import intents

        intents.handle(self, command)

    def cmd_meeting_ai(self, command: dict) -> None:
        """ИИ встречи (M5–M7): своя очередь, ждёт простоя; `docs/polish-contract.md`, «ИИ встреч»."""
        from . import meeting_ai

        meeting_ai.submit(self, command)

    def cmd_meeting_recipe(self, command: dict) -> None:
        """Рецепт после встречи (W7): та же очередь, что у ИИ встреч; ответ — `{id, ok, status, path, text}`."""
        from . import meeting_ai

        meeting_ai.submit(self, command)

    def cmd_meeting_templates(self, command: dict) -> None:
        """Шаблоны сводки и рецепты (M16, W7): встроенные и свои; `folder` — какой шаблон выбрался бы сам."""
        from . import meeting_ai, meeting_templates

        dirs = meeting_templates.ensure_user_dirs() if command.get("ensure") else {
            kind: str(meeting_templates.user_dir(kind)) for kind in ("template", "recipe")}
        detected = None
        if command.get("folder"):
            title, attendees, _ = meeting_ai.meeting_context(Path(str(command["folder"])).expanduser())
            detected = meeting_templates.detect(title, attendees)
        self.reply(command.get("id"),
                   templates=[item.as_json() for item in meeting_templates.load("template").values()],
                   recipes=[item.as_json() for item in meeting_templates.load("recipe").values()],
                   detected=detected, dirs=dirs)

    # --- вопросы и подсказки по ходу встречи (M19, M9): meeting_questions.py, meeting_hints.py ---

    def cmd_meeting_question(self, command: dict) -> None:
        from . import meeting_questions

        meeting_questions.service(self).question(command)

    def cmd_meeting_questions(self, command: dict) -> None:
        from . import meeting_questions

        meeting_questions.service(self).list(command)

    def cmd_meeting_questions_finalize(self, command: dict) -> None:
        from . import meeting_questions

        meeting_questions.service(self).finalize(command)

    def cmd_meeting_hint(self, command: dict) -> None:
        from . import meeting_hints

        meeting_hints.service(self).hint(command)

    # --- архив встреч (M18, W1, W3, W6): mostik_engine/archive_service.py ---

    def _archive(self, op: str, command: dict) -> None:
        from . import archive_service

        archive_service.handle(self, op, command)

    def cmd_archive_brief(self, command: dict) -> None:
        self._archive("brief", command)

    def cmd_archive_people(self, command: dict) -> None:
        self._archive("people", command)

    def cmd_archive_digest(self, command: dict) -> None:
        self._archive("digest", command)

    def cmd_archive_cards(self, command: dict) -> None:
        self._archive("cards", command)

    # --- говорящие встречи (M14, M15): docs/voice-memory.md ------------------

    def cmd_voices_config(self, command: dict) -> None:
        """Голосовая память вкл/выкл. Приложение шлёт `enabled: true` только после экрана согласия."""
        self.voice_memory = bool(command.get("enabled"))
        if not self.voice_memory:
            from . import voices

            # Р2 Н7: выключили посреди расшифровки — её отпечатки не пишутся.
            voices.revoke()
        self.reply(command.get("id"), enabled=self.voice_memory)

    def cmd_voices_status(self, command: dict) -> None:
        from . import voices

        embedder = voices.default_embedder()
        available, detail = embedder.available()
        self.reply(command.get("id"), enabled=bool(getattr(self, "voice_memory", False)), available=available,
                   detail=detail, model=embedder.model_id, people=voices.VoiceStore().people())

    def cmd_voices_rename(self, command: dict) -> None:
        """Переименовать человека; имя другого человека — слияние образцов."""
        from . import voices

        try:
            result = voices.VoiceStore().rename(str(command.get("person_id") or ""), str(command.get("name") or ""))
        except (KeyError, ValueError) as error:
            raise EngineError("speaker", f"не переименовать: {error}") from error
        self.reply(command.get("id"), **result, people=voices.VoiceStore().people())

    def cmd_voices_forget(self, command: dict) -> None:
        """«Забыть этого» (`person_id`) или «забыть всех» (`all: true`): образцы, векторы встреч, подсказки."""
        from . import voices
        from .paths import mostik_home

        store = voices.VoiceStore()
        meetings = mostik_home() / "meetings"
        if command.get("all"):
            forgotten = store.forget_all()
            voices.drop_person_suggestions(meetings, None)
        else:
            person_id = str(command.get("person_id") or "")
            forgotten = int(store.forget(person_id))
            voices.drop_person_suggestions(meetings, person_id)
        self.reply(command.get("id"), forgotten=forgotten, people=store.people())

    def cmd_voices_wipe(self, command: dict) -> None:
        """«Стереть отпечатки» (П10 С8, экран при выключении памяти): люди, образцы, нерешённые
        векторы встреч и подсказки в `transcript.json`. Включённость памяти не меняет — это `voices_config`."""
        from . import voices
        from .paths import mostik_home

        # Р2 Н7: под замком и с новой эпохой — идущая расшифровка отпечатков уже не допишет.
        forgotten, cleaned = voices.wipe(mostik_home() / "meetings")
        self.reply(command.get("id"), forgotten=forgotten, meetings=cleaned, people=[])

    def _speaker_edit(self, command: dict, action: Callable[[Path], dict]) -> None:
        from . import meeting_speakers

        folder = Path(str(command.get("folder") or "")).expanduser()
        if not folder.is_dir():
            raise EngineError("speaker", f"нет папки встречи: {folder}")
        try:
            result = action(folder)
        except meeting_speakers.SpeakerEditError as error:
            raise EngineError("speaker", str(error)) from error
        self.reply(command.get("id"), **result)

    def cmd_speaker_rename(self, command: dict) -> None:
        """Назвать говорящего встречи; при включённой памяти — образец голоса этому человеку."""
        from . import meeting_speakers

        remember = bool(getattr(self, "voice_memory", False))
        self._speaker_edit(command, lambda folder: meeting_speakers.rename(
            folder, str(command.get("label") or ""), str(command.get("name") or ""), remember=remember))

    def cmd_speaker_confirm(self, command: dict) -> None:
        from . import meeting_speakers

        remember = bool(getattr(self, "voice_memory", False))
        self._speaker_edit(command, lambda folder: meeting_speakers.confirm(
            folder, str(command.get("label") or ""), remember=remember))

    def cmd_speaker_reject(self, command: dict) -> None:
        from . import meeting_speakers

        self._speaker_edit(command, lambda folder: meeting_speakers.reject(folder, str(command.get("label") or "")))

    def cmd_speaker_turn(self, command: dict) -> None:
        """Реплику на проверке (M15) — другому говорящему или «верно» (`label` пустой)."""
        from . import meeting_speakers

        turn = int(command.get("turn", -1))
        label = str(command.get("label") or "")
        name = str(command.get("name") or "")
        if label or name:
            self._speaker_edit(command, lambda folder: meeting_speakers.set_turn(folder, turn, label, name=name or None))
        else:
            self._speaker_edit(command, lambda folder: meeting_speakers.mark_reviewed(folder, turn))

    def cmd_speaker_merge(self, command: dict) -> None:
        """Ремонт говорящих (W17): все реплики метки `source` — метке `target`."""
        from . import meeting_speakers

        remember = bool(getattr(self, "voice_memory", False))
        self._speaker_edit(command, lambda folder: meeting_speakers.merge_label(
            folder, str(command.get("source") or ""), str(command.get("target") or ""), remember=remember))

    def cmd_speaker_unname(self, command: dict) -> None:
        """«Убрать имя» (E1): метка снова «Собеседник N», образец этой встречи снимается с человека."""
        from . import meeting_speakers

        remember = bool(getattr(self, "voice_memory", False))
        self._speaker_edit(command, lambda folder: meeting_speakers.unname(
            folder, str(command.get("label") or ""), remember=remember))

    def cmd_shutdown(self, command: dict) -> bool:
        self.reply(command.get("id"))
        return False


def main() -> int:
    out = protect_stdout()
    from . import crash_report
    from .power import lower_priority

    crash_report.enable_faulthandler()
    lower_priority(5)
    try:
        engine = Engine(out)
        log(f"движок {__version__} готов, pid {os.getpid()}")
        return engine.run(sys.stdin)
    except Exception as error:
        # Локальный отчёт о сбое (П8, пункт 6), затем обычное падение с traceback в engine.log.
        path = crash_report.write(error, __version__)
        if path is not None:
            log(f"отчёт о сбое: {path.name}")
        raise
