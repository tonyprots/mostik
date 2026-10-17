"""Потоковая сессия диктовки: PCM → VAD-окна → основная модель → final.

Звук копится в буфере. Каждые ~1,5 с нового звука Silero VAD смотрит только
хвост после последнего разреза (§12.2) — стоимость не растёт с длиной
диктовки. Законченное окно (после речи ≥300 мс тишины или 20 с речи) сразу
распознаётся основной моделью и уходит проверяющей. На `stop` досчитывается
остаток, применяется личный словарь, проверяющей даётся `wait_verifier_ms`, и
отбираются сомнения.
"""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Iterable

from . import crash_report
from . import paths  # noqa: F401 — кладёт transcriber в sys.path
from .doubts import DEFAULT_LIMIT, TermIndex, analyze
from .models import log as _log
from .replace_rules import apply_rules
from .seams import join_windows

from audio_transcription.fillers import fix_punctuation_spacing, strip_fillers  # noqa: E402
from audio_transcription.glossary import GlossaryEntry  # noqa: E402
from audio_transcription.models import Segment  # noqa: E402

SAMPLE_RATE = 16_000
STEP_S = 1.5
MIN_SILENCE_S = 0.3
MAX_WINDOW_S = 20.0
PAD_S = 0.2
# Сколько хвоста тишины оставлять перед разрезом, если речи нет вовсе: начало
# фразы может уже идти, а VAD ещё не набрал 250 мс речи.
KEEP_SILENCE_S = 1.0
IDLE_TAIL_S = 3.0
# Пачка для проверяющей: уходит, набрав 8 с, и не длиннее 24 с.
PACK_MIN_S = 8.0
# Длинная диктовка ждёт проверяющую до конца: на минутах речи быстрый текст одной модели
# заметно хуже, а ждать 20–60 с ради него не жалко. Пользователь может не ждать — skip_wait().
LONG_DICTATION_S = 30.0
LONG_WAIT_CAP_S = 180.0
PACK_MAX_S = 24.0


def plan_windows(
    spans: list[tuple[int, int]],
    tail_len: int,
    *,
    final: bool,
    sr: int = SAMPLE_RATE,
    min_silence_s: float = MIN_SILENCE_S,
    max_window_s: float = MAX_WINDOW_S,
    pad_s: float = PAD_S,
) -> tuple[list[tuple[int, int]], int]:
    """Законченные окна хвоста и новый разрез — всё в сэмплах от начала хвоста.

    Интервал речи закончен, если после него ≥`min_silence_s` тишины, если за
    ним идёт следующий интервал (VAD развёл их паузой или порезал по 20 с) или
    если он сам почти 20 с длиной. Соседние законченные интервалы пакуются в
    одно окно до `max_window_s`: короткая фраза распознаётся лучше в
    контексте, а проверяющая платит за каждый вызов.
    """
    spans = sorted((max(0, s), min(tail_len, e)) for s, e in spans if e > s)
    finished: list[tuple[int, int]] = []
    for index, (start, end) in enumerate(spans):
        is_last = index == len(spans) - 1
        done = (
            final
            or not is_last
            or tail_len - end >= min_silence_s * sr
            or end - start >= (max_window_s - 0.5) * sr
        )
        if not done:
            break
        finished.append((start, end))

    if not finished:
        if final:
            return [], tail_len
        if not spans and tail_len > IDLE_TAIL_S * sr:
            # Долгая тишина: выбрасываем её, чтобы VAD не гонял её снова.
            return [], tail_len - int(KEEP_SILENCE_S * sr)
        return [], 0

    pad = int(pad_s * sr)
    limit = int(max_window_s * sr)
    groups: list[list[tuple[int, int]]] = []
    for span in finished:
        if groups and span[1] - groups[-1][0][0] + 2 * pad <= limit:
            groups[-1].append(span)
        else:
            groups.append([span])

    windows: list[tuple[int, int]] = []
    boundary = 0
    following = spans[len(finished)][0] if len(finished) < len(spans) else tail_len
    for number, group in enumerate(groups):
        after = groups[number + 1][0][0] if number + 1 < len(groups) else following
        last = group[-1][1]
        start = max(boundary, group[0][0] - pad)
        # Разрез — не дальше `pad` за речью и не дальше середины паузы.
        end = min(last + pad, max(last, (last + after) // 2), tail_len)
        windows.append((start, end))
        boundary = end
    cut = tail_len if final else boundary
    return windows, cut


@dataclass
class Window:
    index: int
    start: int
    end: int
    text: str = ""
    primary_ms: float = 0.0
    pack: int | None = None

    @property
    def start_s(self) -> float:
        return self.start / SAMPLE_RATE

    @property
    def end_s(self) -> float:
        return self.end / SAMPLE_RATE


@dataclass
class Pack:
    """Пачка соседних окон для проверяющей (отступление от §12.3).

    Whisper платит за каждый вызов: на коротких окнах проверяющая не успевала
    к концу большинства диктовок (`late`). Пачка от 8 до 24 с уходит, как только
    набралась; остаток — одной пачкой на `stop`. Пара основная/проверяющая
    теперь 1:1 по пачкам: текст окон пачки против текста пачки.
    """

    index: int
    windows: list[int]
    start: int
    end: int
    sent: bool = False
    text: str | None = None
    seconds: float = 0.0
    sent_final: bool = False
    submitted: bool = False
    # Когда пачка ушла проверяющей (monotonic): для прогноза «успеет ли» на stop.
    submitted_at: float | None = None

    @property
    def start_s(self) -> float:
        return self.start / SAMPLE_RATE

    @property
    def end_s(self) -> float:
        return max(self.end, self.start) / SAMPLE_RATE

    @property
    def length_s(self) -> float:
        return (self.end - self.start) / SAMPLE_RATE


class Session:
    """Одна диктовка. `append` зовёт поток протокола, остальное — рабочий поток."""

    def __init__(
        self,
        session_id: str,
        language: str,
        *,
        pool: Any,
        verifier: Any = None,
        verify: bool = True,
        hotwords: Iterable[str] = (),
        terms: TermIndex | None = None,
        personal: list[GlossaryEntry] | None = None,
        emit: Callable[[dict], None] | None = None,
        limit: int = DEFAULT_LIMIT,
        step_s: float = STEP_S,
    ) -> None:
        self.id = session_id
        self.language = language
        self.pool = pool
        self.verifier = verifier if verify else None
        self.hotwords = list(hotwords)
        self.terms = terms or TermIndex()
        self.personal = personal or []
        self.emit = emit or (lambda _event: None)
        self.limit = limit
        # Пары «услышано → вариант», отклонённые пользователем (`doubts.rejected_keys`). Ставит сервер.
        self.rejected_doubts: frozenset[tuple[str, str]] = frozenset()
        self.step_samples = int(step_s * SAMPLE_RATE)
        self.started_at = time.monotonic()
        self._buffer = bytearray()
        self._lock = threading.Lock()
        self._verifier_done = threading.Condition()
        self._skip_wait = False
        self._cut = 0  # сэмпл, до которого окна уже нарезаны
        self._checked = 0  # длина буфера (в сэмплах) на прошлом прогоне VAD
        self.windows: list[Window] = []
        self.packs: list[Pack] = []
        self.vad_ms = 0.0
        self.cancelled = False
        self.step_queued = False
        # Причёсывание после `final` (D3): {backend, style, timeout_s} или None. Ставит сервер.
        self.polish: dict | None = None
        # Потоковая полировка (D3, §3): у потоковых бэкендов (MLX) — `PolishStream`, сюда
        # по мере готовности уходят окна; инструкцию модель прогнала ещё на старте. Ставит сервер.
        self.polish_stream: Any = None
        # «Диктовка закончилась» для локальной LLM: её фоновые задачи (встречи, «Спросить») ждут.
        self.llm_releases: list[Callable[[], None]] = []
        # Автоопределение языка (L5): ставит сервер. `languages` — список пользователя (≥2);
        # `detector(window_id, session, pcm16, languages)` отправляет окно Whisper;
        # `on_language(session)` — язык сменился, словари и проверяющую пора взять под него.
        self.languages: list[str] = []
        self.detector: Callable[[str, str, bytes, list[str]], bool] | None = None
        self.on_language: Callable[["Session"], None] | None = None
        self.language_info: dict | None = None
        self._detected: dict | None = None
        # Раскладка хвоста для `final.timings` (шаг 0): ставит сервер в `_prepare`.
        self.prepare_ms: float | None = None
        self.model_load_ms: float | None = None

    # --- поток протокола --------------------------------------------------

    def append(self, pcm: bytes) -> None:
        if len(pcm) % 2:
            raise ValueError("PCM int16: нечётное число байт")
        with self._lock:
            self._buffer.extend(pcm)

    @property
    def samples(self) -> int:
        with self._lock:
            return len(self._buffer) // 2

    def due(self) -> bool:
        return self.samples - self._checked >= self.step_samples

    # --- рабочий поток ----------------------------------------------------

    def _pcm(self, start: int, end: int | None = None) -> bytes:
        with self._lock:
            return bytes(self._buffer[start * 2 : None if end is None else end * 2])

    def step(self, final: bool = False) -> list[Window]:
        """VAD по хвосту после разреза; законченные окна — в распознавание."""
        import numpy as np

        if self.cancelled:
            return []
        total = self.samples
        self._checked = total
        tail = self._pcm(self._cut, total)
        planned: list[tuple[int, int]] = []
        cut = 0
        waveform = None
        if tail:
            waveform = np.frombuffer(tail, dtype="<i2").astype(np.float32) / 32768.0
            started = time.monotonic()
            spans = self.pool.speech_spans(waveform)
            self.vad_ms += (time.monotonic() - started) * 1000
            planned, cut = plan_windows(spans, len(waveform), final=final)
            if final and not planned and not self.windows and len(waveform) >= SAMPLE_RATE // 2:
                # VAD не нашёл речи во всей диктовке: всё равно даём модели шанс
                # на тихую фразу — пустой ответ ничего не стоит.
                planned = [(0, min(len(waveform), int(MAX_WINDOW_S * SAMPLE_RATE)))]
        if planned and self.languages and self.language_info is None:
            start, end = planned[0]
            self._resolve_language(waveform[start:end])
        made: list[Window] = []
        for number, (start, end) in enumerate(planned):
            window = Window(len(self.windows), self._cut + start, self._cut + end)
            self.windows.append(window)
            made.append(window)
            self._pack(window, flush=final and number == len(planned) - 1)
            self._recognize(window, waveform[start:end])
        if final and not planned:
            self._flush()
        self._cut += cut
        return made

    # --- пачки проверяющей ------------------------------------------------

    def _pack(self, window: Window, *, flush: bool) -> None:
        """Окно в открытую пачку; набралось ≥8 с (или stop) — пачка уходит."""
        current = self.packs[-1] if self.packs and not self.packs[-1].sent else None
        if current is not None and (window.end - current.start) / SAMPLE_RATE > PACK_MAX_S:
            self._send(current)
            current = None
        if current is None:
            current = Pack(len(self.packs), [], window.start, window.end)
            self.packs.append(current)
        current.windows.append(window.index)
        current.end = window.end
        window.pack = current.index
        if flush or current.length_s >= PACK_MIN_S:
            self._send(current, final=flush)

    def _flush(self) -> None:
        if self.packs and not self.packs[-1].sent:
            self._send(self.packs[-1], final=True)

    def _send(self, pack: Pack, *, final: bool = False) -> None:
        pack.sent_final = final
        if self.verifier is None or not self.verifier.available:
            pack.sent = True  # закрыта, но не отправлена: сравнивать не с чем
            return
        pack.sent = True
        submitted = self.verifier.submit(
            f"{self.id}:{pack.index}", self.id, self._pcm(pack.start, pack.end),
            self.language, self.hotwords,
        )
        pack.submitted = bool(submitted)
        if pack.submitted:
            pack.submitted_at = time.monotonic()

    def _recognize(self, window: Window, waveform: Any) -> None:
        started = time.monotonic()
        window.text = self.pool.recognize(waveform, self.language, hotwords=self.hotwords)
        window.primary_ms = (time.monotonic() - started) * 1000
        _log(
            f"{self.id}: окно {window.index} {window.start_s:.1f}–{window.end_s:.1f} с, "
            f"основная {window.primary_ms:.0f} мс"
        )
        if window.text and self.polish_stream is not None:
            # Та же чистка, что у итога в `finish`: тогда поданное — префикс итогового текста,
            # и модель переиспользует уже прогнанный кэш.
            try:
                self.polish_stream.feed(fix_punctuation_spacing(strip_fillers(window.text)[0]))
            except Exception as error:  # noqa: BLE001 — полировка не роняет диктовку
                _log(f"{self.id}: подача окна полировщику: {crash_report.describe(error)}")
        if window.text:
            self.emit(
                {
                    "event": "partial",
                    "session": self.id,
                    "text": self.live_text(),
                    "window": window.index,
                    "window_text": window.text,
                }
            )

    def live_text(self) -> str:
        return " ".join(window.text for window in self.windows if window.text).strip()

    def _resolve_language(self, waveform: Any) -> None:
        """L5: язык по первому окну среди `languages`; не вышло — остаётся язык по умолчанию."""
        import numpy as np

        from .language_detect import TIMEOUT_S, pick_language

        started = time.monotonic()
        default = self.language
        probs: dict | None = None
        submitted = False
        if self.detector is not None:
            pcm = (np.clip(np.asarray(waveform, dtype=np.float32), -1.0, 1.0) * 32767).astype("<i2").tobytes()
            try:
                submitted = bool(self.detector(f"{self.id}:detect", self.id, pcm, list(self.languages)))
            except Exception as error:  # noqa: BLE001 — без определения диктовка идёт как раньше
                _log(f"{self.id}: определение языка: {crash_report.describe(error)}")
        if submitted:
            deadline = started + TIMEOUT_S
            with self._verifier_done:
                while self._detected is None and not self.cancelled:
                    left = deadline - time.monotonic()
                    if left <= 0:
                        break
                    self._verifier_done.wait(min(left, 0.05))
                probs = self._detected
        language, share = pick_language(probs, self.languages, default)
        self.language_info = {
            "detected": language, "share": share, "probs": probs or {}, "from": list(self.languages),
            "fallback": probs is None, "ms": round((time.monotonic() - started) * 1000, 1),
        }
        _log(f"{self.id}: язык {language} (доля {share}, {self.language_info['ms']:.0f} мс)")
        if language != self.language:
            self.language = language
            if self.on_language is not None:
                self.on_language(self)

    def on_verifier(self, message: dict) -> None:
        """Ответ проверяющей на пачку (поток чтения клиента)."""
        if str(message.get("window_id", "")).endswith(":detect"):
            with self._verifier_done:
                probs = message.get("probs")
                self._detected = probs if isinstance(probs, dict) and probs else {}
                self._verifier_done.notify_all()
            return
        try:
            index = int(str(message.get("window_id", "")).rsplit(":", 1)[1])
        except (IndexError, ValueError):
            return
        with self._verifier_done:
            if 0 <= index < len(self.packs):
                pack = self.packs[index]
                pack.text = str(message.get("text") or "")
                pack.seconds = float(message.get("seconds") or 0.0)
            self._verifier_done.notify_all()

    def _submitted(self) -> list[Pack]:
        return [pack for pack in self.packs if pack.submitted]

    def skip_wait(self) -> None:
        """«Вставить быструю версию»: перестать ждать проверяющую, взять то, что уже готово."""
        with self._verifier_done:
            self._skip_wait = True
            self._verifier_done.notify_all()

    def _wait_verifier(self, deadline: float, on_progress: Callable[[int, int], None] | None = None) -> bool:
        reported = -1
        with self._verifier_done:
            while True:
                submitted = self._submitted()
                waiting = [pack for pack in submitted if pack.text is None]
                if not waiting:
                    return True
                if on_progress is not None and len(submitted) - len(waiting) != reported:
                    reported = len(submitted) - len(waiting)
                    on_progress(reported, len(submitted))
                left = deadline - time.monotonic()
                if self._skip_wait or left <= 0 or (self.verifier is not None and not self.verifier.running()):
                    return False
                self._verifier_done.wait(min(left, 0.05))

    def verifier_forecast_s(self, now: float | None = None) -> float | None:
        """Сколько ещё проверяющей до ответа на все ушедшие пачки (шаг 1, п. 4).

        Пачки она считает по одной: оставшееся от самой старой + цена вызова на каждую
        следующую. Цена — скользящее среднее клиента (`call_ema_s`); её ещё нет — None.
        """
        now = time.monotonic() if now is None else now
        with self._verifier_done:
            waiting = [pack for pack in self._submitted() if pack.text is None]
        if not waiting:
            return 0.0
        cost = getattr(self.verifier, "call_ema_s", None)
        if not cost:
            return None
        oldest = min(pack.submitted_at or now for pack in waiting)
        return max(0.0, cost - (now - oldest)) + cost * (len(waiting) - 1)

    def finish(self, wait_verifier_ms: float = 0.0, stop_at: float | None = None,
               on_wait: Callable[[int, int], None] | None = None) -> dict:
        """Остаток → словарь → проверяющая (с ожиданием) → сомнения → `final`.

        Диктовка от `LONG_DICTATION_S` ждёт проверяющую до конца (не дольше `LONG_WAIT_CAP_S`),
        сообщая `on_wait(проверено пачек, всего)`; `skip_wait()` прерывает ожидание.
        """
        stop_at = time.monotonic() if stop_at is None else stop_at
        queued_ms = (time.monotonic() - stop_at) * 1000
        self.step(final=True)
        self._flush()
        remainder_ms = (time.monotonic() - stop_at) * 1000 - queued_ms
        raw_text = self.live_text()

        # Сегмент — пачка целиком: текст её окон против текста проверяющей.
        auto = [entry for entry in self.personal if entry.auto_apply]
        segments: list[Segment] = []
        glossary_fixes = []
        pack_of_segment: list[Pack] = []
        for pack in self.packs:
            # Стыки окон без ложных точек: «у Acme. И у Globex» → «у Acme и у Globex».
            text = join_windows(self.windows[i].text for i in pack.windows if self.windows[i].text)
            if not text:
                continue
            fixed, fixes = apply_rules([Segment(pack.start_s, pack.end_s, text)], auto)
            segments.extend(fixed)
            glossary_fixes.extend(fixes)
            pack_of_segment.append(pack)

        used = self._submitted()
        verifier_wait_ms = 0.0
        forecast_ms: float | None = None
        if self.verifier is None or not used:
            status = "off"
            if self.verifier is not None and self.verifier.available and not self.windows:
                status = "done"
        else:
            long = self.samples / SAMPLE_RATE >= LONG_DICTATION_S
            wait_s = max(0.0, wait_verifier_ms) / 1000
            deadline = stop_at + (max(wait_s, LONG_WAIT_CAP_S) if long else wait_s)
            forecast = self.verifier_forecast_s()
            forecast_ms = None if forecast is None else round(forecast * 1000, 1)
            waited = time.monotonic()
            if not long and forecast is not None and forecast > 0 and time.monotonic() + forecast > deadline:
                # Заведомо не успеет: сомнения по уже готовым пачкам, без ожидания (было 1,2 с впустую).
                complete = False
            else:
                complete = self._wait_verifier(deadline, on_wait if long else None)
            verifier_wait_ms = (time.monotonic() - waited) * 1000
            status = "done" if complete else "late"
            if not complete:
                self.verifier.cancel(self.id)

        verifier_segments = None
        compared = segments
        if status in ("done", "late") and used:
            with self._verifier_done:
                answered = {pack.index: pack.text for pack in self.packs if pack.text is not None}
            verifier_segments = [
                Segment(pack.start_s, pack.end_s, answered[pack.index])
                for pack in self.packs
                if (answered.get(pack.index) or "").strip()
            ]
            # Опоздавшие пачки в сравнение не идут: без пары основная дала бы
            # пункт «нет соответствующего сегмента».
            compared = [
                segment
                for segment, pack in zip(segments, pack_of_segment)
                if pack.index in answered
            ]

        started = time.monotonic()
        analysis = analyze(
            compared,
            verifier_segments,
            language=self.language,
            personal=self.personal,
            limit=self.limit,
            terms=self.terms,
            rejected=self.rejected_doubts,
        )
        analysis_ms = (time.monotonic() - started) * 1000
        fixed_map = {(s.start, s.end): s for s in analysis.segments}
        final_segments = [fixed_map.get((s.start, s.end), s) for s in segments]
        text = join_windows(segment.text for segment in final_segments)
        text = fix_punctuation_spacing(strip_fillers(text)[0])

        corrections = [
            {"from": fix.before, "to": fix.after} for fix in [*glossary_fixes, *analysis.corrections]
        ]
        primary_ms = sum(window.primary_ms for window in self.windows)
        verifier_ms = sum(pack.seconds for pack in self.packs) * 1000
        self.release_llm()
        now = time.monotonic()
        _log(
            f"{self.id}: хвост {(now - stop_at) * 1000:.0f} мс = очередь {queued_ms:.0f} + "
            f"остаток {remainder_ms:.0f} + проверяющая {verifier_wait_ms:.0f} + сомнения; проверяющая {status}"
            + (f" (прогноз {forecast_ms:.0f} мс)" if forecast_ms is not None else "")
        )
        return {
            "event": "final",
            "session": self.id,
            "text": text,
            "raw_text": raw_text,
            "doubts": [doubt.to_dict() for doubt in analysis.doubts],
            "corrections": corrections,
            "language": self.language,
            **({"language_detect": self.language_info} if self.language_info else {}),
            "timings": {
                "audio_s": round(self.samples / SAMPLE_RATE, 3),
                "tail_ms": round((now - stop_at) * 1000, 1),
                "primary_ms": round(primary_ms, 1),
                "verifier_ms": round(verifier_ms, 1),
                "total_ms": round(self.vad_ms + primary_ms + analysis_ms, 1),
                "vad_ms": round(self.vad_ms, 1),
                "analysis_ms": round(analysis_ms, 1),
                # Раскладка хвоста (шаг 0): очередь рабочего потока к stop, остаток, ожидание проверяющей.
                "queued_ms": round(queued_ms, 1),
                "remainder_ms": round(remainder_ms, 1),
                "verifier_wait_ms": round(verifier_wait_ms, 1),
                **({"verifier_forecast_ms": forecast_ms} if forecast_ms is not None else {}),
                **({"prepare_ms": round(self.prepare_ms, 1)} if self.prepare_ms is not None else {}),
                **({"model_load_ms": round(self.model_load_ms, 1)} if self.model_load_ms is not None else {}),
            },
            "verifier": status,
            "stats": {
                "windows": len(self.windows),
                "packs": len(self.packs),
                "verified": sum(1 for pack in self.packs if pack.text is not None),
                "review_items": analysis.review_items,
                "doubt_candidates": analysis.candidates,
            },
        }

    def release_llm(self) -> None:
        releases, self.llm_releases = self.llm_releases, []
        for release in releases:
            try:
                release()
            except Exception:  # noqa: BLE001
                pass

    def cancel(self) -> None:
        self.cancelled = True
        self.release_llm()
        if self.polish_stream is not None:
            try:
                self.polish_stream.cancel()
            except Exception:  # noqa: BLE001
                pass
        if self.verifier is not None:
            self.verifier.cancel(self.id)
