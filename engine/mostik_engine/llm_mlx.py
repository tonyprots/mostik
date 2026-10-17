"""Локальная LLM полировщика и голосовой правки (MLX, §4 этапа B).

Модель живёт в отдельном процессе на интерпретаторе окружения `engine/.venv-llm`
(там mlx-lm; у движка его нет), как проверяющая в `verifier_worker`: процесс
поднимается при первой нужде, гасится после простоя — память уходит вместе с ним.

Выбор модели и замер — `docs/bench.md`, раздел «Выбор локальной LLM (§4)».
Модели качаются только по кнопке в приложении; движок ничего не качает. Нет
весов в кэше HF — `status()` отвечает «не установлена» с размером.

Обмен с процессом — строки JSON:

    → {"op": "complete", "id": 1, "system": "...", "user": "...", "closers": [...]}
    → {"op": "open", "stream": "s1", "system": "...", "user_head": "<transcript>\\n"}
    → {"op": "feed", "stream": "s1", "text": "кусок"}
    → {"op": "finish", "id": 2, "stream": "s1", "user": "...", "closers": [...]}
    → {"op": "cancel", "stream": "s1"}      → {"op": "abort", "id": 2}
    ← {"ready": true, "seconds": 4.1, "model": "..."}  или {"ready": false, "error": "..."}
    ← {"id": 1, "text": "...", "ttft_ms": 310, "ms": 2100, "tokens": 64, "reused": 412}
    ← {"id": 2, "error": "..."}

Потоковая полировка (§3, D3): на `open` модель сразу прогоняет инструкцию, на
каждом `feed` — новый кусок диктовки, и сохраняет снимок кэша. На `finish`
приходит итоговый текст (после словаря и правок проверяющей): берётся самый
длинный снимок, чьи токены — префикс итогового промпта, досчитывается остаток,
затем генерация. У Qwen3.5 часть слоёв — Gated DeltaNet с рекуррентным
состоянием, его кэш не обрезать, поэтому снимки, а не `trim`.

Термины и неприкосновенные фрагменты в потоковом режиме идут не в системный
промпт, а после диктовки в сообщении пользователя: на `open` их ещё нет, а
системный промпт без них одинаков у всех диктовок одного стиля — его снимок
переиспользуется между диктовками.
"""
from __future__ import annotations

import json
import re
import os
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from . import isolation
from . import polish as P

ENGINE_DIR = Path(__file__).resolve().parent.parent
LLM_IDLE_S = 300.0
LOAD_TIMEOUT_S = 60.0
HOLDBACK_TOKENS = 3  # хвост куска не прогоняем: токенизатор может склеить его со следующим
MAX_SNAPSHOTS = 48
SYSTEM_CACHE = 8
# Ответ полировщика начинается за модель: без этого малые модели в стиле «списком» часто
# сразу пишут «- …» без `<polished>` (замер, docs/bench.md), и ответ уходит в откат.
POLISH_PREFILL = P.OPEN + "\n"


@dataclass(frozen=True)
class LlmModel:
    key: str
    repo: str
    label: str
    size_gb: float


# По умолчанию Gemma 4 E2B: на синтетическом стенде (docs/bench.md, «Выбор локальной LLM»)
# она быстрее Qwen3.5 4B при той же памяти и лучше по автопроверкам на русском.
# Qwen — запасные строки каталога: веса не установлены, `status()` честно скажет об этом.
MODELS = {
    "gemma-4-e2b": LlmModel("gemma-4-e2b", "mlx-community/gemma-4-e2b-it-4bit", "Gemma 4 E2B", 3.3),
    "qwen3.5-4b": LlmModel("qwen3.5-4b", "mlx-community/Qwen3.5-4B-MLX-4bit", "Qwen3.5 4B", 2.9),
    "qwen3.5-2b": LlmModel("qwen3.5-2b", "mlx-community/Qwen3.5-2B-MLX-4bit", "Qwen3.5 2B", 1.6),
}
DEFAULT_MODEL = "gemma-4-e2b"


def _log(text: str) -> None:
    print(f"[mostik-llm] {text}", file=sys.stderr, flush=True)


# --- где что лежит -----------------------------------------------------------------

def hf_hub_dir(env: dict | None = None) -> Path:
    env = os.environ if env is None else env
    if env.get("HF_HUB_CACHE"):
        return Path(env["HF_HUB_CACHE"])
    if env.get("HF_HOME"):
        return Path(env["HF_HOME"]) / "hub"
    return Path(env.get("HOME") or Path.home()) / ".cache" / "huggingface" / "hub"


def pinned_revision(repo: str) -> str | None:
    """Ревизия модели из `models_manifest.json`; модели нет в манифесте — None."""
    from . import model_store

    try:
        specs = model_store.load_manifest()
    except (OSError, ValueError, KeyError):
        return None
    return next((spec.revision for spec in specs if spec.repo == repo), None)


def model_path(repo: str, hub: Path | None = None) -> Path | None:
    """Снапшот модели в кэше HF, если веса на месте; иначе None. Без сети и без huggingface_hub.

    Только ревизия из манифеста (П10): общий кэш `~/.cache/huggingface/hub` пишут и другие
    инструменты, `refs/main` и самый свежий снапшот могут оказаться чужими. Модели без
    закреплённой ревизии не грузятся.
    """
    revision = pinned_revision(repo)
    if not revision:
        return None
    root = (hub or hf_hub_dir()) / ("models--" + repo.replace("/", "--"))
    candidates = [root / "snapshots" / revision]
    for snap in candidates:
        if not (snap / "config.json").is_file():
            continue
        index = snap / "model.safetensors.index.json"
        if index.is_file():
            try:
                shards = set(json.loads(index.read_text())["weight_map"].values())
            except (ValueError, KeyError):
                continue
            if shards and all((snap / shard).is_file() for shard in shards):
                return snap
        elif (snap / "model.safetensors").is_file():
            return snap
    return None


def llm_python(env: dict | None = None) -> str | None:
    from . import paths

    env = os.environ if env is None else env
    if env.get("MOSTIK_LLM_PYTHON") and not paths.IN_APP_BUNDLE:  # в .app — только свой Python (П10)
        return env["MOSTIK_LLM_PYTHON"]
    candidate = ENGINE_DIR / ".venv-llm" / "bin" / "python"
    if candidate.exists():
        return str(candidate)
    # Встроенный Python .app несёт mlx-lm в своём site-packages: отдельного venv нет.
    import importlib.util

    return sys.executable if importlib.util.find_spec("mlx_lm") is not None else None


# --- раскладка потокового промпта -------------------------------------------------------

def stream_system(language: str, style: str) -> str:
    """Системный промпт потока: тот же, что у `claude -p`, но без терминов и фрагментов."""
    return P.system_prompt(language, style)


def stream_notes(language: str, terms: list[str], keep: list[str], vocabulary: list[str] = ()) -> str:
    return P.notes(language, terms, keep, vocabulary).strip()


def stream_user(text: str, language: str, terms: list[str], keep: list[str],
                vocabulary: list[str] = ()) -> str:
    notes = stream_notes(language, terms, keep, vocabulary)
    return P.user_message(text) + ("\n" + notes if notes else "")


# --- дочерний процесс ----------------------------------------------------------------------

def _freeze(value):
    """Независимая копия состояния кэша для снимка.

    `ArraysCache.state` отдаёт свой живой список, и слой Gated DeltaNet правит его на
    месте (`cache[i] = …`): без копии «снимок» менялся бы вместе с кэшем.
    """
    if isinstance(value, list):
        return [_freeze(item) for item in value]
    if isinstance(value, tuple):
        return tuple(_freeze(item) for item in value)
    if type(value).__name__ == "array" and hasattr(value, "shape"):
        # Новый объект массива: `RotatingKVCache` (скользящее окно Gemma) пишет в свой массив
        # на месте (`keys[..., i:j, :] = …`), и общий с кэшем объект поменялся бы вместе с ним.
        import mlx.core as mx

        return mx.array(value)
    return value


class _Worker:
    """Модель, кэши потоков и генерация. Работает в процессе `.venv-llm`."""

    def __init__(self, path: str, draft_path: str | None = None, spec_k: int = 3) -> None:
        from mlx_lm import load

        self.model, self.tokenizer = load(path)
        self.draft = load(draft_path)[0] if draft_path else None
        self.spec_k = spec_k
        self.streams: dict[str, dict] = {}
        self.system_snaps: dict[str, tuple[list[int], Any]] = {}
        self.aborted: set = set()
        # P6: куски ответа по ходу генерации — `worker_main` подставляет отправку в stdout.
        self.emit = None
        eos = getattr(self.tokenizer, "eos_token_ids", None) or [self.tokenizer.eos_token_id]
        self.eos = {int(t) for t in eos if t is not None}
        # Конец реплики — тоже конец: у Gemma 4 в eos только `<eos>`, а реплика кончается `<turn|>`.
        for marker in ("<turn|>", "<end_of_turn>", "<|im_end|>", "<|endoftext|>"):
            ids = self.tokenizer.encode(marker, add_special_tokens=False)
            if len(ids) == 1:
                self.eos.add(int(ids[0]))

    # промпт
    def template(self, system: str, user: str) -> str:
        messages = [{"role": "system", "content": system}, {"role": "user", "content": user}]
        try:
            return self.tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False,
                                                      enable_thinking=False)
        except TypeError:
            return self.tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)

    def head(self, system: str, user_head: str) -> str:
        """Начало промпта до конца `user_head`: шаблон с меткой на месте сообщения, обрезанный по метке."""
        marker = "⁣MOSTIK⁣"
        text = self.template(system, user_head + marker)
        return text[: text.index(marker)]

    def encode(self, text: str) -> list[int]:
        return list(self.tokenizer.encode(text, add_special_tokens=False))

    # кэш
    def new_cache(self):
        from mlx_lm.models.cache import make_prompt_cache

        return make_prompt_cache(self.model)

    @staticmethod
    def snapshot(cache) -> list:
        import mlx.core as mx

        states = [(_freeze(c.state), getattr(c, "meta_state", None)) for c in cache]
        mx.eval([s for s, _ in states])
        return states

    @staticmethod
    def restore(cache, states) -> None:
        for c, (state, meta) in zip(cache, states):
            c.state = _freeze(state)  # снова копия: живой кэш не должен править снимок
            if meta is not None:
                c.meta_state = meta

    def prefill(self, cache, tokens: list[int]) -> None:
        import mlx.core as mx

        step = 512
        for start in range(0, len(tokens), step):
            self.model(mx.array(tokens[start : start + step])[None], cache=cache)
            mx.eval([c.state for c in cache])

    # поток
    def open(self, stream: str, system: str, user_head: str) -> None:
        tokens = self.encode(self.head(system, user_head))[:-HOLDBACK_TOKENS]
        cache = self.new_cache()
        cached = self.system_snaps.get(system)
        if cached and tokens[: len(cached[0])] == cached[0]:
            done = list(cached[0])
            self.restore(cache, cached[1])
        else:
            done = []
        self.prefill(cache, tokens[len(done):])
        snap = (list(tokens), self.snapshot(cache))
        if not cached:
            if len(self.system_snaps) >= SYSTEM_CACHE:
                self.system_snaps.pop(next(iter(self.system_snaps)))
            self.system_snaps[system] = snap
        while len(self.streams) >= 4:  # брошенные потоки (пустой итог, сбой сессии) не копятся
            self.streams.pop(next(iter(self.streams)))
        self.streams[stream] = {"system": system, "head": user_head, "fed": [], "cache": cache,
                                "done": list(tokens), "snaps": [snap]}

    def feed(self, stream: str, text: str) -> None:
        state = self.streams.get(stream)
        if state is None or not text.strip():
            return
        state["fed"].append(text.strip())
        prefix = self.head(state["system"], state["head"] + " ".join(state["fed"]))
        tokens = self.encode(prefix)[:-HOLDBACK_TOKENS]
        done = state["done"]
        if tokens[: len(done)] != done:
            # Токенизация разошлась раньше прогнанного: откат к последнему подходящему снимку.
            snap = self._best(state["snaps"], tokens)
            self.restore(state["cache"], snap[1])
            done = list(snap[0])
        self.prefill(state["cache"], tokens[len(done):])
        state["done"] = list(tokens)
        state["snaps"].append((list(tokens), self.snapshot(state["cache"])))
        if len(state["snaps"]) > MAX_SNAPSHOTS:
            del state["snaps"][1]

    @staticmethod
    def _best(snaps: list, tokens: list[int]):
        best = None
        for snap in snaps:
            n = len(snap[0])
            if n <= len(tokens) and tokens[:n] == snap[0] and (best is None or n > len(best[0])):
                best = snap
        return best

    def start_cache(self, tokens: list[int], stream: str | None) -> tuple[Any, int]:
        """Кэш, уже прогнавший самый длинный подходящий префикс `tokens`, и длину префикса."""
        state = self.streams.pop(stream, None) if stream else None
        cache = self.new_cache()
        snaps = list(state["snaps"]) if state else []
        snaps.extend(self.system_snaps.values())
        best = self._best(snaps, tokens[:-1]) if snaps else None
        if best is None:
            return cache, 0
        self.restore(cache, best[1])
        return cache, len(best[0])

    # генерация
    def steps(self, request: dict):
        """Генерация шагами: `yield` между кусками префилла и токенами — фоновую задачу можно
        поставить на паузу и продолжить (диктовка не ждёт конца длинной генерации встречи)."""
        import mlx.core as mx

        started = time.perf_counter()
        prompt = self.template(request["system"], request["user"])
        prefill = str(request.get("prefill") or "")
        tokens = self.encode(prompt + prefill)
        cache, reused = self.start_cache(tokens, request.get("stream"))
        for start in range(reused, len(tokens) - 1, 512):
            self.prefill(cache, tokens[start : min(start + 512, len(tokens) - 1)])
            yield
        closers = tuple(request.get("closers") or ())
        user_tokens = len(self.encode(request["user"]))
        budget = int(request.get("max_tokens") or min(2048, int(user_tokens * 2.2) + 96))
        rid = request.get("id")
        out: list[int] = []
        first = None
        y = tokens[-1]
        dcache = None
        if self.draft is not None:
            from mlx_lm.models.cache import make_prompt_cache

            dcache = make_prompt_cache(self.draft)
            self.draft(mx.array(tokens[:-1])[None], cache=dcache)
        pending = [y]
        partials = bool(request.get("partials")) and self.emit is not None
        sentences = 0
        while len(out) < budget:
            if rid in self.aborted:
                self.aborted.discard(rid)
                raise RuntimeError("aborted")
            if dcache is None:
                logits = self.model(mx.array([y])[None], cache=cache)
                emitted = [int(mx.argmax(logits[0, -1]).item())]
            else:
                emitted, pending = self._speculate(cache, dcache, y, pending)
            if first is None:
                first = time.perf_counter()
            stop = False
            for token in emitted:
                if token in self.eos:
                    stop = True
                    break
                out.append(token)
            y = emitted[-1]
            if stop:
                break
            if closers and any(c in self.tokenizer.decode(out[-16:]) for c in closers):
                break
            if partials and len(out) % 4 == 0:
                sentences = self._partial(rid, prefill, out, sentences)
            yield
        ended = time.perf_counter()
        text = prefill + self.tokenizer.decode(out)
        repaired = False
        if prefill and closers and not any(c in text for c in closers) and len(out) < budget:
            # Починка (§3): модель закончила ответ без закрывающего маркера — закрываем сами.
            text += closers[0]
            repaired = True
        return {"text": text, "tokens": len(out), "reused": reused, "repaired": repaired,
                "prompt_tokens": len(tokens), "ttft_ms": round(((first or ended) - started) * 1000, 1),
                "ms": round((ended - started) * 1000, 1)}

    def _partial(self, rid, prefill: str, out: list[int], sentences: int) -> int:
        """Кусок ответа — только когда закончилось новое предложение: приложению вставлять целыми фразами."""
        text = prefill + self.tokenizer.decode(out)
        count = len(re.findall(r"[.!?…](?:\s|$)|\n", text))
        if count > sentences:
            self.emit({"id": rid, "partial": text})
        return max(count, sentences)

    def generate(self, request: dict) -> dict:
        return run_steps(self.steps(request))

    def _speculate(self, cache, dcache, y: int, pending: list[int]) -> tuple[list[int], list[int]]:
        """Один шаг спекулятивного декодирования с откатом по снимкам (кэш не обрезается)."""
        import mlx.core as mx

        k = self.spec_k
        snap_d = self.snapshot(dcache)
        guess: list[int] = []
        feed = pending
        for _ in range(k):
            logits = self.draft(mx.array(feed)[None], cache=dcache)
            token = int(mx.argmax(logits[0, -1]).item())
            guess.append(token)
            feed = [token]
        snap_m = self.snapshot(cache)
        greedy = mx.argmax(self.model(mx.array([y] + guess)[None], cache=cache)[0], axis=-1).tolist()
        n = 0
        while n < k and guess[n] == greedy[n]:
            n += 1
        if n == k:
            return guess + [greedy[k]], [guess[-1], greedy[k]]
        self.restore(cache, snap_m)
        self.model(mx.array([y] + guess[:n])[None], cache=cache)
        self.restore(dcache, snap_d)
        return guess[:n] + [greedy[n]], pending + guess[:n] + [greedy[n]]

    def handle(self, request: dict) -> dict | None:
        """Запрос переднего плана целиком: поток диктовки или короткая генерация."""
        op = request.get("op")
        if op == "open":
            self.open(str(request["stream"]), request["system"], request.get("user_head") or "")
            return None
        if op == "feed":
            self.feed(str(request["stream"]), request.get("text") or "")
            return None
        if op == "cancel":
            self.streams.pop(str(request.get("stream")), None)
            return None
        if op in ("complete", "finish"):
            return {"id": request.get("id"), **self.generate(request)}
        return {"id": request.get("id"), "error": f"неизвестная операция {op!r}"}


def run_steps(steps) -> dict:
    while True:
        try:
            next(steps)
        except StopIteration as done:
            return done.value


def set_background(on: bool) -> None:
    """Фоновый приоритет всего процесса (как `taskpolicy -b`): CPU, ввод-вывод и GPU уступают."""
    try:
        os.setpriority(os.PRIO_DARWIN_PROCESS, 0, os.PRIO_DARWIN_BG if on else 0)
    except (AttributeError, OSError):
        pass


HOLD_TTL_S = 300.0


class Scheduler:
    """Очередь процесса модели: одна модель на все роли.

    - передний план (`open`/`feed`/`cancel`, полировка, голосовая правка) — по порядку, сразу;
    - фон (`priority: "background"`: ИИ встреч, «Спросить») — шагами генератора, с фоновым
      приоритетом процесса; перед каждым шагом смотрим, не пришёл ли запрос переднего плана;
    - `hold` (идёт диктовка) ставит фон на паузу до `release` или истечения `ttl`.
    """

    def __init__(self, worker: Any, send, *, background=set_background, clock=time.monotonic) -> None:
        self.worker = worker
        self.send = send
        self.set_background = background
        self.clock = clock
        self.cv = threading.Condition()
        self.front: list[dict] = []
        self.back: list[dict] = []
        self.tasks: list[tuple[dict, Any]] = []  # фоновые генерации в работе
        self.holds: dict[str, float] = {}
        self.closed = False
        self.is_background = False

    # поток чтения
    def put(self, request: dict) -> None:
        with self.cv:
            op = request.get("op")
            if op == "abort":
                rid = request.get("id")
                self.worker.aborted.add(rid)
                self.front = [r for r in self.front if r.get("id") != rid]
                self.back = [r for r in self.back if r.get("id") != rid]
            elif op == "hold":
                self.holds[str(request.get("key"))] = self.clock() + float(request.get("ttl") or HOLD_TTL_S)
            elif op == "release":
                self.holds.pop(str(request.get("key")), None)
            elif op == "shutdown":
                self.closed = True
            elif op == "complete" and request.get("priority") == "background":
                self.back.append(request)
            else:
                self.front.append(request)
            self.cv.notify_all()

    def close(self) -> None:
        with self.cv:
            self.closed = True
            self.cv.notify_all()

    def held(self) -> bool:
        now = self.clock()
        for key in [k for k, until in self.holds.items() if until <= now]:
            del self.holds[key]
        return bool(self.holds)

    def _priority(self, background: bool) -> None:
        if background != self.is_background:
            self.set_background(background)
            self.is_background = background

    def _answer(self, request: dict, work) -> None:
        try:
            answer = work()
        except Exception as error:  # noqa: BLE001 — один запрос не роняет процесс
            if request.get("op") in ("open", "feed"):
                self.worker.streams.pop(str(request.get("stream")), None)
                return
            answer = {"id": request.get("id"), "error": f"{type(error).__name__}: {error}"}
        if answer is not None:
            self.send(answer)

    def run_once(self, wait: float = 0.5) -> bool:
        """Один шаг цикла. False — очередь закрыта и пуста."""
        with self.cv:
            while True:
                if self.front:
                    request, kind = self.front.pop(0), "front"
                    break
                if self.closed:
                    return False
                if (self.back or self.tasks) and not self.held():
                    request, kind = (self.back.pop(0), "new") if self.back else (None, "step")
                    break
                self.cv.wait(wait)
        if kind == "front":
            self._priority(False)
            self._answer(request, lambda: self.worker.handle(request))
            return True
        self._priority(True)
        if kind == "new":
            self.tasks.append((request, self.worker.steps(request)))
        request, steps = self.tasks[0]
        try:
            next(steps)
        except StopIteration as done:
            self.tasks.pop(0)
            self.send({"id": request.get("id"), **done.value})
        except Exception as error:  # noqa: BLE001
            self.tasks.pop(0)
            self.send({"id": request.get("id"), "error": f"{type(error).__name__}: {error}"})
        return True

    def run(self) -> None:
        while self.run_once():
            pass


def worker_main() -> int:
    out_lock = threading.Lock()

    def send(payload: dict) -> None:
        with out_lock:
            sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    started = time.monotonic()
    path = os.environ.get("MOSTIK_LLM_MODEL_PATH", "")
    draft = os.environ.get("MOSTIK_LLM_DRAFT_PATH") or None
    try:
        worker = _Worker(path, draft, int(os.environ.get("MOSTIK_LLM_SPEC_K", "3")))
        # Прогрев: первый проход компилирует ядра Metal.
        worker.generate({"system": P.system_prompt("ru", "plain"), "user": P.user_message("ну проверка"),
                         "max_tokens": 4})
    except Exception as error:  # noqa: BLE001 — нет mlx-lm или весов: бэкенд недоступен
        send({"ready": False, "error": f"{type(error).__name__}: {error}"})
        return 0
    send({"ready": True, "seconds": round(time.monotonic() - started, 2), "model": Path(path).parent.parent.name})
    scheduler = Scheduler(worker, send)
    worker.emit = send

    def reader() -> None:
        for line in sys.stdin:
            try:
                scheduler.put(json.loads(line))
            except ValueError:
                continue
        scheduler.close()

    threading.Thread(target=reader, name="llm-stdin", daemon=True).start()
    scheduler.run()
    return 0


# --- клиент в процессе движка ------------------------------------------------------------

class LlmClient:
    """Держит процесс модели, раздаёт ответы по id, гасит процесс после простоя."""

    def __init__(self, model: LlmModel, *, python: str | None = None, draft: LlmModel | None = None,
                 idle_s: float = LLM_IDLE_S, command: list[str] | None = None, hub: Path | None = None) -> None:
        self.model = model
        self.draft = draft
        self.python = python
        self.idle_s = idle_s
        self.command = command  # тесты подставляют фейковый процесс
        self.hub = hub
        self._lock = threading.RLock()
        self._process: subprocess.Popen | None = None
        self._ready = threading.Event()
        self._failed: str | None = None
        self._waiters: dict[int, tuple[threading.Event, dict]] = {}
        self._partials: dict[int, Any] = {}
        self._next = 0
        self._used = time.monotonic()

    @property
    def failure(self) -> str | None:
        return self._failed

    def running(self) -> bool:
        with self._lock:
            return self._process is not None and self._process.poll() is None

    def ready(self) -> bool:
        return self.running() and self._ready.is_set() and self._failed is None

    def wait_ready(self, timeout: float) -> bool:
        """Дождаться загрузки модели в процессе; False — не загрузилась за `timeout` или упала."""
        self._ready.wait(timeout)
        return self.ready()

    @property
    def pid(self) -> int | None:
        with self._lock:
            return self._process.pid if self._process is not None else None

    def ensure(self) -> bool:
        with self._lock:
            if self._process is not None and self._process.poll() is None:
                return True
            if self.command is not None:
                command = list(self.command)
            else:
                python = self.python or llm_python()
                path = model_path(self.model.repo, self.hub)
                if python is None or path is None:
                    return False
                # П10 С1: -I и путь к движку аргументом, а не PYTHONPATH.
                command = isolation.module_command(python, "mostik_engine.llm_mlx", ENGINE_DIR)
            env = isolation.child_env()  # без PYTHON*, DYLD_*, LD_*
            env["HF_HUB_OFFLINE"] = "1"
            env["TOKENIZERS_PARALLELISM"] = "false"
            if self.command is None:
                env["MOSTIK_LLM_MODEL_PATH"] = str(model_path(self.model.repo, self.hub))
                draft = model_path(self.draft.repo, self.hub) if self.draft else None
                if draft:
                    env["MOSTIK_LLM_DRAFT_PATH"] = str(draft)
            self._ready.clear()
            self._failed = None
            try:
                self._process = subprocess.Popen(
                    command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=None, text=True,
                    bufsize=1, env=env, cwd=str(ENGINE_DIR),
                )
            except OSError as error:
                self._failed = str(error)
                return False
            self._used = time.monotonic()
            threading.Thread(target=self._read, args=(self._process,), name="llm-reader", daemon=True).start()
            _log(f"запущен процесс {self.model.label}, pid {self._process.pid}")
            return True

    def _read(self, process: subprocess.Popen) -> None:
        assert process.stdout is not None
        for line in process.stdout:
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if "ready" in message:
                if not message["ready"]:
                    self._failed = str(message.get("error") or "unknown")
                    _log(f"{self.model.label} недоступна: {self._failed}")
                else:
                    _log(f"{self.model.label} загружена за {message.get('seconds')} с")
                self._ready.set()
                continue
            if "partial" in message:  # P6: кусок ответа, сам ответ ещё впереди
                callback = self._partials.get(message.get("id"))
                if callback is not None:
                    try:
                        callback(str(message["partial"]))
                    except Exception:  # noqa: BLE001
                        pass
                continue
            with self._lock:
                waiter = self._waiters.pop(message.get("id"), None)
                self._partials.pop(message.get("id"), None)
                self._used = time.monotonic()
            if waiter:
                waiter[1].update(message)
                waiter[0].set()
        with self._lock:
            if self._process is process:
                self._process = None
            waiters, self._waiters = self._waiters, {}
        for event, box in waiters.values():
            box["error"] = "процесс модели завершился"
            event.set()
        self._ready.set()

    def send(self, payload: dict) -> bool:
        with self._lock:
            process = self._process
            if process is None or process.stdin is None:
                return False
            try:
                process.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
                process.stdin.flush()
            except (BrokenPipeError, OSError, ValueError):
                return False
            self._used = time.monotonic()
            return True

    def request(self, payload: dict, timeout: float, on_partial=None) -> dict:
        """Запрос с ответом. Таймаут считает и загрузку модели; по нему — `abort`."""
        deadline = time.monotonic() + timeout
        if not self.ensure():
            raise P.PolishUnavailable(self._failed or "локальная модель не установлена")
        if not self._ready.wait(max(0.0, deadline - time.monotonic())):
            raise P.PolishTimeout(f"модель не загрузилась за {timeout:.0f} с")
        if self._failed:
            raise P.PolishUnavailable(self._failed)
        with self._lock:
            self._next += 1
            rid = self._next
            event, box = threading.Event(), {}
            self._waiters[rid] = (event, box)
            if on_partial is not None:
                self._partials[rid] = on_partial
        if not self.send({**payload, "id": rid}):
            with self._lock:
                self._waiters.pop(rid, None)
            raise P.PolishError("процесс модели не принимает запросы", "failed")
        if not event.wait(max(0.0, deadline - time.monotonic())):
            with self._lock:
                self._waiters.pop(rid, None)
                self._partials.pop(rid, None)
            self.send({"op": "abort", "id": rid})
            raise P.PolishTimeout(f"нет ответа за {timeout:.0f} с")
        if "error" in box:
            raise P.PolishError(str(box["error"]), "failed")
        return box

    def busy(self) -> bool:
        with self._lock:
            return bool(self._waiters)

    def hold(self, key: str, ttl: float = HOLD_TTL_S) -> None:
        """Идёт диктовка: фоновая генерация в процессе встаёт на паузу. Процесс ради этого не поднимаем."""
        if self.running():
            self.send({"op": "hold", "key": key, "ttl": ttl})

    def release(self, key: str) -> None:
        if self.running():
            self.send({"op": "release", "key": key})

    def stop(self) -> None:
        with self._lock:
            process, self._process = self._process, None
        if process is None:
            return
        try:
            if process.stdin:
                process.stdin.close()
            process.wait(timeout=3)
        except Exception:  # noqa: BLE001
            process.kill()
        _log(f"процесс {self.model.label} остановлен")

    def sweep(self, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        with self._lock:
            idle = self._process is not None and not self._waiters and now - self._used > self.idle_s
        if idle:
            self.stop()
        return idle


# --- бэкенд ------------------------------------------------------------------------------------

class MlxStream(P.PolishStream):
    """Поток D3: инструкция уходит модели на `open`, куски — по мере готовности окон."""

    def __init__(self, backend: "MlxBackend", request: P.PolishRequest, stream_id: str) -> None:
        super().__init__(backend, request)
        self.stream_id = stream_id
        self.system = P.stream_system_for(request)
        self.opened = backend.client.ensure() and backend.client.send(
            {"op": "open", "stream": stream_id, "system": self.system, "user_head": P.INPUT_OPEN + "\n"})

    def feed(self, chunk: str) -> None:
        super().feed(chunk)
        if self.opened and chunk and chunk.strip():
            self.backend.client.send({"op": "feed", "stream": self.stream_id, "text": chunk.strip()})

    def finish(self, text: str | None = None, timeout: float = P.DEFAULT_TIMEOUT_S) -> P.PolishOutcome:
        full = text if text is not None else " ".join(self.chunks)
        request = self.request
        terms, keep = list(request.terms), list(request.keep)
        if request.style == "dev":
            vocabulary = list(request.vocabulary)
        else:  # словарь пакета стиля (P4) — в сообщении, системный промпт потока его не содержит
            vocabulary = list(request.pack.terms) if request.pack is not None else []
        stream = self

        class _Call(P.PolishBackend):
            name = "mlx"
            resolve_corrections = True
            partials = True

            def complete(self, system: str, user: str, timeout: float, on_partial=None) -> str:
                lang = stream.request.language
                payload = {"op": "finish" if stream.opened else "complete", "stream": stream.stream_id,
                           "system": stream.system, "user": user + _notes_suffix(lang, terms, keep, vocabulary),
                           "closers": [P.CLOSE, P.REFUSAL], "prefill": POLISH_PREFILL}
                if on_partial is not None:
                    payload["partials"] = True
                stream.opened = False
                return stream.backend.client.request(payload, timeout, on_partial=on_partial)["text"]

        return P.polish(_Call(), replace(request, text=full), timeout=timeout)

    def cancel(self) -> None:
        super().cancel()
        if self.opened:
            self.backend.client.send({"op": "cancel", "stream": self.stream_id})
            self.opened = False


def _notes_suffix(language: str, terms: list[str], keep: list[str], vocabulary: list[str] = ()) -> str:
    notes = stream_notes(language, terms, keep, vocabulary)
    return "\n" + notes if notes else ""


class MlxBackend(P.PolishBackend):
    """Локальная модель (MLX) в отдельном процессе; `streaming` — сессия подаёт ей окна по ходу речи."""

    name = "mlx"
    streaming = True
    # Однозначные самоисправления снимаются до модели: Gemma 4 E2B путает их и с примерами (docs/bench.md).
    resolve_corrections = True

    def __init__(self, model: str | None = None, *, client: LlmClient | None = None,
                 hub: Path | None = None) -> None:
        self.spec = MODELS[model or os.environ.get("MOSTIK_LLM_MODEL") or DEFAULT_MODEL]
        self.hub = hub
        self.client = client or LlmClient(self.spec, hub=hub)
        self._streams = 0
        self._lock = threading.Lock()

    @property
    def model(self) -> str:
        return self.spec.label

    def status(self) -> dict:
        size = f"{self.spec.size_gb:.1f}".replace(".", ",")
        info = {"model": self.spec.label, "repo": self.spec.repo, "size_gb": self.spec.size_gb}
        if self.client.command is None and model_path(self.spec.repo, self.hub) is None:
            return {"available": False, "reason": "model_missing", **info,
                    "message": f"не установлена: {self.spec.label}, {size} ГБ"}
        if self.client.command is None and llm_python() is None:
            return {"available": False, "reason": "runtime_missing", **info,
                    "message": "нет окружения engine/.venv-llm с mlx-lm"}
        if self.client.failure:
            return {"available": False, "reason": "failed", **info, "message": self.client.failure}
        return {"available": True, **info, "loaded": self.client.ready()}

    def warm(self) -> bool:
        """Прогрев при включении: поднять процесс заранее, не дожидаясь первой диктовки."""
        return self.status()["available"] and self.client.ensure()

    def complete(self, system: str, user: str, timeout: float) -> str:
        if not self.status()["available"]:
            raise P.PolishUnavailable(self.status().get("message") or "локальная модель недоступна")
        payload = {"op": "complete", "system": system, "user": user}
        # Роль — по рамке: у полировки и ИИ встреч вход в одном и том же теге `<transcript>`,
        # поэтому полировку узнаём по маркеру ответа в системном промпте.
        if user.startswith(P.INPUT_OPEN) and P.OPEN in system:  # полировка: ответ сразу начинается с маркера
            payload.update(closers=[P.CLOSE, P.REFUSAL], prefill=POLISH_PREFILL)
        elif user.startswith("<instruction>"):  # голосовая правка: человек ждёт, передний план
            payload["closers"] = ["</edited>", "<cannot_edit/>"]
        elif user.startswith("<voice_command>"):  # команда-намерение (D6): человек ждёт карточку
            payload["closers"] = ["</intent>"]
        else:  # ИИ встреч, «Спросить»: фон — пониженный приоритет, пауза на время диктовки
            payload["priority"] = "background"
        return self.client.request(payload, timeout)["text"]

    def hold(self, key: str) -> "callable":
        """Диктовка началась: фон модели ждёт. Возвращает функцию «диктовка закончилась»."""
        self.client.hold(key)
        return lambda: self.client.release(key)

    def open_stream(self, request: P.PolishRequest) -> P.PolishStream:
        if not self.status()["available"]:
            return P.PolishStream(self, request)
        with self._lock:
            self._streams += 1
            stream_id = f"p{self._streams}"
        return MlxStream(self, request, stream_id)

    def sweep(self, now: float | None = None) -> bool:
        return self.client.sweep(now)

    def stop(self) -> None:
        self.client.stop()


if __name__ == "__main__":
    sys.exit(worker_main())
