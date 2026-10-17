"""Стенд локальной LLM для причёсывания и голосовой правки (§4 этапа B).

Запуск — интерпретатором отдельного окружения с mlx-lm, модели берутся только из
кэша HF (сеть не нужна, `HF_HUB_OFFLINE=1`):

    engine/.venv-llm/bin/python engine/bench/llm_bench.py --model mlx-community/Qwen3.5-2B-MLX-4bit
    engine/.venv-llm/bin/python engine/bench/llm_bench.py --model mlx-community/Qwen3.5-4B-MLX-4bit \
        --spec-draft mlx-community/Qwen3.5-2B-MLX-4bit --spec-k 3
    engine/.venv-llm/bin/python engine/bench/llm_bench.py --model mlx-community/gemma-4-e2b-it-4bit --prefill \
        --only selfcorr --no-edits            # только самоисправления; --no-resolve — без снятия поправок до модели
    engine/.venv-llm/bin/python engine/bench/llm_bench.py --model mlx-community/gemma-4-e2b-it-4bit --prefill \
        --only dev --no-edits                 # режим разработчика (стиль dev)
    python engine/bench/llm_bench.py --claude --only selfcorr   # тот же набор через `claude -p` (облако)
    engine/.venv-llm/bin/python engine/bench/llm_bench.py --model mlx-community/gemma-4-e2b-it-4bit --prefill \
        --only selfcorr --no-edits --rules    # правила речи P3 до модели, как в приложении
    engine/.venv-llm/bin/python engine/bench/llm_bench.py --model mlx-community/gemma-4-e2b-it-4bit --prefill \
        --golden [--tags lists,numbers]       # эталонные пары P5 (`polish_golden.py`)
    engine/bench/llm_bench.py --report engine/bench/out/llm/*.jsonl

Тексты — синтетика из `llm_cases.py`. Промпты — ровно те, что уходят в `claude -p`
(`polish.system_prompt`, `voice_edit.system_prompt`).

Что меряется на каждый вызов: время до первого токена, полное время, токены
промпта и ответа, скорость генерации; по процессу — пиковая память MLX и пиковый
RSS, тепловое состояние (NSProcessInfo.thermalState через ctypes и `pmset -g therm`).
Качество — автоматические проверки (`check_polish`, `check_edit`).
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import json
import os
import re
import resource
import subprocess
import sys
import time
import types
from pathlib import Path

ENGINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ENGINE))
sys.path.insert(0, str(Path(__file__).resolve().parent))

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

# voice_edit тянет models → transcriber; стенду от models нужны только log и ModelMissing.
_stub = types.ModuleType("mostik_engine.models")
_stub.log = lambda text: print(f"[mostik] {text}", file=sys.stderr)
_stub.ModelMissing = type("ModelMissing", (Exception,), {})
sys.modules.setdefault("mostik_engine.models", _stub)

from mostik_engine import polish as P  # noqa: E402
from mostik_engine import speech_rules as R  # noqa: E402
from mostik_engine import voice_edit as VE  # noqa: E402
import llm_cases as C  # noqa: E402
import polish_golden as G  # noqa: E402

OUT = ENGINE / "bench" / "out" / "llm"


# --- окружение ------------------------------------------------------------------

def thermal_state() -> str:
    """NSProcessInfo.processInfo.thermalState без pyobjc: 0 nominal … 3 critical."""
    try:
        objc = ctypes.cdll.LoadLibrary(ctypes.util.find_library("objc"))
        ctypes.cdll.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation")
        objc.objc_getClass.restype = ctypes.c_void_p
        objc.sel_registerName.restype = ctypes.c_void_p
        objc.objc_msgSend.restype = ctypes.c_void_p
        objc.objc_msgSend.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        info = objc.objc_msgSend(objc.objc_getClass(b"NSProcessInfo"), objc.sel_registerName(b"processInfo"))
        state = objc.objc_msgSend(info, objc.sel_registerName(b"thermalState")) or 0
        return ("nominal", "fair", "serious", "critical")[int(state)]
    except Exception as error:  # noqa: BLE001
        return f"unknown ({error})"


def pmset_therm() -> str:
    try:
        out = subprocess.run(["pmset", "-g", "therm"], capture_output=True, text=True, timeout=5).stdout
    except Exception as error:  # noqa: BLE001
        return f"unknown ({error})"
    return " | ".join(line.strip() for line in out.splitlines() if line.strip())


def peak_rss_mb() -> float:
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024 / 1024  # macOS: байты


def mx_peak_mb(mx) -> float:
    getter = getattr(mx, "get_peak_memory", None) or mx.metal.get_peak_memory
    return getter() / 1024 / 1024


# --- генерация ---------------------------------------------------------------------

def chat_prompt(tokenizer, system: str, user: str) -> str:
    messages = [{"role": "system", "content": system}, {"role": "user", "content": user}]
    try:
        return tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False,
                                             enable_thinking=False)
    except TypeError:
        return tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)


def stop_marker(text: str, closers: tuple[str, ...]) -> bool:
    return any(closer in text for closer in closers)


def generate_stream(model, tokenizer, prompt: str, max_tokens: int, closers: tuple[str, ...]) -> dict:
    """Штатный `stream_generate` mlx-lm, жадно; останов по закрывающему маркеру."""
    from mlx_lm import stream_generate

    started = time.perf_counter()
    first = None
    text = ""
    last = None
    for response in stream_generate(model, tokenizer, prompt, max_tokens=max_tokens):
        if first is None:
            first = time.perf_counter()
        text += response.text
        last = response
        if stop_marker(text, closers):
            break
    total = time.perf_counter() - started
    return {"text": text, "ttft_ms": round(((first or time.perf_counter()) - started) * 1000, 1),
            "total_ms": round(total * 1000, 1), "prompt_tokens": last.prompt_tokens if last else 0,
            "gen_tokens": last.generation_tokens if last else 0,
            "prompt_tps": round(last.prompt_tps, 1) if last else 0,
            "gen_tps": round(last.generation_tps, 1) if last else 0}


# Ручной цикл: базовый жадный и спекулятивный с откатом по снимкам кэша.
# Штатный speculative_generate_step mlx-lm требует обрезаемый кэш, а у Qwen3.5
# слои Gated DeltaNet держат ArraysCache (рекуррентное состояние), его не обрезать.

def freeze(value):
    """Копия структуры (списки, кортежи) без копирования массивов: ArraysCache правит свой список на месте."""
    if isinstance(value, list):
        return [freeze(item) for item in value]
    if isinstance(value, tuple):
        return tuple(freeze(item) for item in value)
    return value


def snapshot(cache) -> list:
    import mlx.core as mx

    states = [(freeze(c.state), getattr(c, "meta_state", None)) for c in cache]
    mx.eval([s for s, _ in states])
    return states


def restore(cache, states) -> None:
    for c, (state, meta) in zip(cache, states):
        c.state = freeze(state)
        if meta is not None:
            c.meta_state = meta


def manual_generate(model, tokenizer, prompt: str, max_tokens: int, closers: tuple[str, ...],
                    draft=None, k: int = 3) -> dict:
    import mlx.core as mx
    from mlx_lm.models.cache import make_prompt_cache

    tokens = tokenizer.encode(prompt, add_special_tokens=False) if hasattr(tokenizer, "encode") else prompt
    eos = set(getattr(tokenizer, "eos_token_ids", None) or [tokenizer.eos_token_id])
    started = time.perf_counter()
    cache = make_prompt_cache(model)
    model(mx.array(tokens[:-1])[None], cache=cache)
    dcache = None
    if draft is not None:
        dcache = make_prompt_cache(draft)
        draft(mx.array(tokens[:-1])[None], cache=dcache)
    mx.eval([c.state for c in cache])
    prefill_done = time.perf_counter()
    y = tokens[-1]
    out: list[int] = []
    first = None
    proposed = accepted = rounds = 0
    pending_d = [y]
    while len(out) < max_tokens:
        if draft is None:
            logits = model(mx.array([y])[None], cache=cache)
            nxt = int(mx.argmax(logits[0, -1]).item())
            emitted = [nxt]
        else:
            rounds += 1
            snap_d = snapshot(dcache)
            guess: list[int] = []
            feed = pending_d
            for _ in range(k):
                logits = draft(mx.array(feed)[None], cache=dcache)
                t = int(mx.argmax(logits[0, -1]).item())
                guess.append(t)
                feed = [t]
            snap_m = snapshot(cache)
            logits = model(mx.array([y] + guess)[None], cache=cache)
            greedy = mx.argmax(logits[0], axis=-1).tolist()
            n = 0
            while n < k and guess[n] == greedy[n]:
                n += 1
            proposed += k
            accepted += n
            emitted = guess[:n] + [greedy[n]]
            if n < k:
                restore(cache, snap_m)
                model(mx.array([y] + guess[:n])[None], cache=cache)
                restore(dcache, snap_d)
                pending_d = pending_d + guess[:n] + [greedy[n]]
            else:
                pending_d = [guess[-1], greedy[k]]
        if first is None:
            first = time.perf_counter()
        stop = False
        for t in emitted:
            if t in eos:
                stop = True
                break
            out.append(t)
        y = emitted[-1]
        if stop:
            break
        if stop_marker(tokenizer.decode(out[-12:]), closers) and stop_marker(tokenizer.decode(out), closers):
            break
    end = time.perf_counter()
    gen_s = max(end - prefill_done, 1e-6)
    return {"text": tokenizer.decode(out), "ttft_ms": round(((first or end) - started) * 1000, 1),
            "total_ms": round((end - started) * 1000, 1), "prompt_tokens": len(tokens),
            "gen_tokens": len(out), "gen_tps": round(len(out) / gen_s, 1),
            "accept_rate": round(accepted / proposed, 3) if proposed else None,
            "rounds": rounds or None}


# --- проверки качества ----------------------------------------------------------------

def norm(text: str) -> str:
    return text.casefold().replace("ё", "е")


NUMBER = re.compile(r"\d+(?:[.,:]\d+)?")
FILLERS = {
    "ru": re.compile(r"(?<!\w)(э|ээ|эм|ну|типа|короче|как бы)(?!\w)", re.I),
    "en": re.compile(r"(?<!\w)(um|uh|you know)(?!\w)", re.I),
}


def selected_cases(only: str | None) -> list[tuple[str, dict]]:
    """`selfcorr` — категория самоисправлений, `dev` — режим разработчика, иначе весь набор."""
    if only == "selfcorr":
        return [("ru", c) for c in C.RU if c["id"] in C.SELFCORR]
    if only == "dev":
        return [("ru", c) for c in C.DEV]
    return [("ru", c) for c in C.RU] + [("en", c) for c in C.EN]


def check_polish(case: dict, language: str, style: str, raw_output: str) -> dict:
    result = {"status": "done", "text": ""}
    try:
        text = P.parse_response(raw_output)
    except P.PolishError as error:
        return {"status": error.status, "text": raw_output.strip()[:400], "ok": False}
    if not P.plausible(case["text"], text, style):
        result["status"] = "suspicious"
    text = P.restore_terms(text, case.get("terms") or [])
    result["text"] = text
    low = norm(text)
    excluded = set()
    for bad in case.get("must_not") or []:
        excluded.update(NUMBER.findall(bad))
    numbers = [n for n in NUMBER.findall(case["text"]) if n not in excluded]
    result["terms_ok"] = all(norm(t) in low for t in case.get("terms") or [])
    result["numbers_ok"] = all(n in text for n in numbers)
    result["must_ok"] = all(any(norm(alt) in low for alt in m.split("|")) for m in case.get("must") or [])
    result["must_not_ok"] = not any(norm(m) in low for m in case.get("must_not") or [])
    result["no_answer"] = not any(norm(a) in low for a in case.get("answer") or [])
    cyr = sum(1 for ch in text if "а" <= ch.lower() <= "я" or ch.lower() == "ё")
    lat = sum(1 for ch in text if "a" <= ch.lower() <= "z")
    result["lang_ok"] = (cyr >= lat) if language == "ru" else (cyr == 0)
    result["fillers_ok"] = style == "brief" or not FILLERS[language].search(text)
    if style == "list":
        result["list_ok"] = sum(1 for line in text.splitlines() if line.lstrip().startswith(("- ", "• ", "* "))) >= 1
    checks = [v for k, v in result.items() if k.endswith("_ok") or k == "no_answer"]
    result["ok"] = result["status"] == "done" and all(checks)
    return result


def check_edit(case: dict, raw_output: str) -> dict:
    try:
        understood, body = VE.parse_response(raw_output)
    except P.PolishError as error:
        return {"status": error.status, "text": raw_output.strip()[:400], "ok": False}
    low = norm(body)
    result = {"status": "done", "text": body, "understood": understood,
              "must_ok": all(norm(m) in low for m in case["must"])}
    if case["kind"] == "list":
        items = [line for line in body.splitlines() if re.match(r"\s*([-*•]|\d+[.)])\s+", line)]
        result["kind_ok"] = len(items) >= 2
    else:
        cyr = sum(1 for ch in body if "а" <= ch.lower() <= "я")
        result["kind_ok"] = cyr <= max(2, len(body) // 50)
    result["ok"] = result["must_ok"] and result["kind_ok"]
    return result


# --- эталонные пары (P5) ---------------------------------------------------------------

# Правила речи для `--rules` на обычном наборе: всё, кроме чисел (набор проверяет числа как есть).
BENCH_RULES = {"commands": True, "scratch": True, "lists": True, "numbers": False}


def golden_cases(tags: str | None) -> list[dict]:
    wanted = {t.strip() for t in (tags or "").split(",") if t.strip()}
    return [case for case in G.GOLDEN if not wanted or wanted & set(case["tags"])]


def golden_request(case: dict, resolve: bool) -> tuple[P.PolishRequest, str]:
    """Запрос как в движке: правила речи → снятие поправок (MLX) → промпт стиля/перевода с контекстом."""
    translate = case.get("translate") or {}
    rules = case.get("rules")
    given, _ = R.apply(case["raw"], case["language"], rules)
    request = P.PolishRequest(given, case["language"], case["style"], vocabulary=case.get("vocabulary") or [],
                              context=P.clean_context(case.get("context")), rules=rules,
                              translate_to=translate.get("to"), tone=translate.get("tone"))
    if resolve:
        given = P.resolve_self_corrections(given, case["language"])
    return request, given


def golden_prompt(case: dict, resolve: bool) -> tuple[str, str, P.PolishRequest]:
    request, given = golden_request(case, resolve)
    return P.system_for(request), P.user_message(given) + P.request_notes(request, given), request


def similarity(a: str, b: str) -> float:
    import difflib

    words = lambda text: re.findall(r"\w+", norm(text))  # noqa: E731
    return round(difflib.SequenceMatcher(None, words(a), words(b)).ratio(), 3)


def check_golden(case: dict, request: P.PolishRequest, raw_output: str) -> dict:
    try:
        text = P.parse_response(raw_output)
    except P.PolishError as error:
        return {"status": error.status, "text": raw_output.strip()[:400], "ok": False, "similarity": 0.0}
    status = "done"
    if not P.plausible(request.text, text, request.style):
        status = "suspicious"
    elif not request.translate_to and R.answered_question(request.text, text, request.language):
        status = "answered"
    text = P.finish_text(text, request)
    low = norm(text)
    must_ok = all(any(norm(alt) in low for alt in m.split("|")) for m in case.get("must") or [])
    must_not_ok = not any(norm(m) in low for m in case.get("must_not") or [])
    return {"status": status, "text": text, "must_ok": must_ok, "must_not_ok": must_not_ok,
            "similarity": similarity(text, case["expected"]),
            "ok": status == "done" and must_ok and must_not_ok}


def run_golden(args, gen) -> list[dict]:
    rows = []
    for case in golden_cases(args.tags):
        if case.get("deterministic"):
            text, _ = R.apply(case["raw"], case["language"], case.get("rules"))
            row = {"kind": "golden", "id": case["id"], "tags": case["tags"], "status": "rules", "text": text,
                   "ok": text == case["expected"], "similarity": similarity(text, case["expected"]),
                   "total_ms": 0, "ttft_ms": 0, "gen_tps": 0}
        else:
            system, user, request = golden_prompt(case, not args.no_resolve)
            g = gen(system, user, case)
            row = {"kind": "golden", "id": case["id"], "tags": case["tags"], "style": case["style"],
                   "input": case["raw"], **{k: v for k, v in g.items() if k != "text"}, "raw": g["text"],
                   **check_golden(case, request, g["text"])}
        rows.append(row)
        print(f"{case['id']:<22} {row['status']:<10} ok={row['ok']!s:<5} sim={row['similarity']:.2f} "
              f"total={row.get('total_ms', 0):>6.0f} | {row['text'][:90]!r}", flush=True)
    return rows


# --- прогон ----------------------------------------------------------------------------

def run(args) -> int:
    import mlx.core as mx
    from mlx_lm import load

    OUT.mkdir(parents=True, exist_ok=True)
    label = args.label or (args.model.split("/")[-1] + ("+prefill" if args.prefill else "")
                           + ("" if args.no_resolve else "+resolve")
                           + (f"+spec{args.spec_k}" if args.spec_draft else ""))
    out_path = OUT / f"{label}.jsonl"
    rows: list[dict] = []
    meta = {"label": label, "model": args.model, "draft": args.spec_draft, "k": args.spec_k, "resolve": not args.no_resolve,
            "thermal_before": thermal_state(), "pmset_before": pmset_therm(), "load_avg_before": os.getloadavg()}
    started = time.perf_counter()
    model, tokenizer = load(args.model)
    meta["load_s"] = round(time.perf_counter() - started, 2)
    meta["mx_after_load_mb"] = round(mx_peak_mb(mx), 1)
    draft = None
    if args.spec_draft:
        draft, dtok = load(args.spec_draft)
        assert dtok.encode("Проверка токенайзера: Parakeet, 12:30") == tokenizer.encode(
            "Проверка токенайзера: Parakeet, 12:30"), "токенайзеры различаются"
        meta["mx_after_draft_mb"] = round(mx_peak_mb(mx), 1)

    def gen(system: str, user: str, closers: tuple[str, ...], budget: int, prefill: str = "") -> dict:
        """`prefill` — начало ответа ассистента (маркер `<polished>`), как в `llm_mlx`."""
        prompt = chat_prompt(tokenizer, system, user) + prefill
        if args.manual or draft is not None:
            g = manual_generate(model, tokenizer, prompt, budget, closers, draft=draft, k=args.spec_k)
        else:
            g = generate_stream(model, tokenizer, prompt, budget, closers)
        if prefill:
            g["text"] = prefill + g["text"]
            # Починка (§3): модель закончила ответ без закрывающего маркера — закрываем сами.
            if not any(c in g["text"] for c in closers) and g["gen_tokens"] < budget:
                g["text"] += closers[0]
                g["repaired"] = True
        return g

    # Прогрев: первый вызов компилирует ядра Metal, в замер не идёт.
    gen(P.system_prompt("ru", "plain"), P.user_message("ну проверка связи"), (P.CLOSE,), 24)
    meta["warm_s"] = round(time.perf_counter() - started, 2)

    cases = [] if args.golden else selected_cases(args.only)
    if args.limit:
        cases = cases[: args.limit]
    styles = ["dev"] if args.only == "dev" else args.styles.split(",")
    with out_path.open("w") as handle:
        handle.write(json.dumps({"meta": meta}, ensure_ascii=False) + "\n")
        if args.golden:
            def golden_gen(system: str, user: str, case: dict) -> dict:
                budget = min(1024, int(len(tokenizer.encode(case["raw"])) * 2.2) + 80
                             + (200 if case["style"] == "task" else 0))
                return gen(system, user, (P.CLOSE, P.REFUSAL), budget, P.OPEN + "\n" if args.prefill else "")

            for row in run_golden(args, golden_gen):
                rows.append(row)
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        for language, case in cases:
            for style in styles:
                system = P.system_prompt(language, style, case.get("terms") or [],
                                         vocabulary=case.get("vocabulary") if style == "dev" else ())
                # Как в MLX-бэкенде: однозначные самоисправления снимаются до модели (`--no-resolve` — без этого).
                given = R.apply(case["text"], language, BENCH_RULES)[0] if args.rules else case["text"]
                given = given if args.no_resolve else P.resolve_self_corrections(given, language)
                user = P.user_message(given)
                budget = min(1024, int(len(tokenizer.encode(case["text"])) * 2.2) + 80)
                g = gen(system, user, (P.CLOSE, P.REFUSAL), budget, P.OPEN + "\n" if args.prefill else "")
                row = {"kind": "polish", "id": case["id"], "language": language, "style": style,
                       "input": case["text"], **{k: v for k, v in g.items() if k != "text"},
                       "raw": g["text"], **check_polish(case, language, style, g["text"])}
                rows.append(row)
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
                handle.flush()
                print(f"{case['id']:<22} {style:<8} {row['status']:<10} ok={row['ok']!s:<5} "
                      f"ttft={row['ttft_ms']:>6.0f} total={row['total_ms']:>6.0f} tps={row['gen_tps']:>5} "
                      f"| {row['text'][:90]!r}", flush=True)
        if not args.no_edits and not args.golden:
            for case in C.EDITS:
                g = gen(VE.system_prompt(case["language"]), VE.user_message(case["command"], case["selection"]),
                        (VE.OUT_CLOSE, VE.REFUSAL), 400)
                row = {"kind": "edit", "id": case["id"], "language": case["language"], "style": case["command"],
                       "input": case["selection"], **{k: v for k, v in g.items() if k != "text"},
                       "raw": g["text"], **check_edit(case, g["text"])}
                rows.append(row)
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
                print(f"{case['id']:<22} {row['status']:<10} ok={row['ok']!s:<5} total={row['total_ms']:>6.0f} "
                      f"| {row['text'][:120]!r}", flush=True)
        meta_end = {"mx_peak_mb": round(mx_peak_mb(mx), 1), "rss_peak_mb": round(peak_rss_mb(), 1),
                    "thermal_after": thermal_state(), "pmset_after": pmset_therm(),
                    "load_avg_after": os.getloadavg(), "wall_s": round(time.perf_counter() - started, 1)}
        handle.write(json.dumps({"meta_end": meta_end}, ensure_ascii=False) + "\n")
    print(json.dumps({**meta, **meta_end}, ensure_ascii=False))
    return 0


def run_claude(args) -> int:
    """Тот же набор и те же проверки через `claude -p` (как в приложении: без размышлений, без
    инструментов и настроек). Каждый вызов уходит в облако Anthropic — запуск только вручную."""
    OUT.mkdir(parents=True, exist_ok=True)
    backend = P.ClaudeCliBackend(model=args.claude_model)
    label = args.label or f"claude-{args.claude_model}" + (f"-{args.only}" if args.only else "") \
        + ("-golden" if args.golden else "")
    meta = {"label": label, "model": f"claude -p --model {args.claude_model}", "status": backend.status(),
            "load_avg_before": os.getloadavg()}
    if args.golden:
        def claude_gen(system: str, user: str, case: dict) -> dict:
            started = time.perf_counter()
            try:
                raw = backend.complete(system, user, 40)
            except P.PolishError as error:
                raw = f"[{error.status}] {error}"
            total = round((time.perf_counter() - started) * 1000, 1)
            return {"text": raw, "ttft_ms": total, "total_ms": total, "gen_tps": 0}

        args.no_resolve = True  # облачной модели поправки не снимаются, как в приложении
        with (OUT / f"{label}.jsonl").open("w") as handle:
            handle.write(json.dumps({"meta": meta}, ensure_ascii=False) + "\n")
            for row in run_golden(args, claude_gen):
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        return 0
    cases = selected_cases(args.only)
    if args.limit:
        cases = cases[: args.limit]
    styles = ["dev"] if args.only == "dev" else args.styles.split(",")
    with (OUT / f"{label}.jsonl").open("w") as handle:
        handle.write(json.dumps({"meta": meta}, ensure_ascii=False) + "\n")
        for language, case in cases:
            for style in styles:
                system = P.system_prompt(language, style, case.get("terms") or [],
                                         vocabulary=case.get("vocabulary") if style == "dev" else ())
                started = time.perf_counter()
                try:
                    raw = backend.complete(system, P.user_message(case["text"]), 40)
                except P.PolishError as error:
                    raw = f"[{error.status}] {error}"
                total = round((time.perf_counter() - started) * 1000, 1)
                row = {"kind": "polish", "id": case["id"], "language": language, "style": style,
                       "input": case["text"], "ttft_ms": total, "total_ms": total, "gen_tps": 0,
                       "raw": raw, **check_polish(case, language, style, raw)}
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
                handle.flush()
                print(f"{case['id']:<22} {style:<8} {row['status']:<10} ok={row['ok']!s:<5} total={total:>6.0f} "
                      f"| {row['text'][:90]!r}", flush=True)
        handle.write(json.dumps({"meta_end": {"load_avg_after": os.getloadavg()}}, ensure_ascii=False) + "\n")
    return 0


# --- отчёт --------------------------------------------------------------------------------

def median(values: list[float]) -> float:
    values = sorted(values)
    if not values:
        return float("nan")
    mid = len(values) // 2
    return values[mid] if len(values) % 2 else (values[mid - 1] + values[mid]) / 2


def p90(values: list[float]) -> float:
    values = sorted(values)
    return values[min(len(values) - 1, int(round(0.9 * (len(values) - 1))))] if values else float("nan")


def report(paths: list[str]) -> int:
    for path in paths:
        rows, meta, meta_end = [], {}, {}
        for line in Path(path).read_text().splitlines():
            item = json.loads(line)
            meta = item.get("meta", meta)
            meta_end = item.get("meta_end", meta_end)
            if "kind" in item:
                rows.append(item)
        def share(items, key="ok"):
            return f"{sum(1 for r in items if r.get(key, True))}/{len(items)}"

        polish = [r for r in rows if r["kind"] == "polish"]
        ru = [r for r in polish if r["language"] == "ru"]
        en = [r for r in polish if r["language"] == "en"]
        edits = [r for r in rows if r["kind"] == "edit"]
        selfcorr = [r for r in polish if r["id"] in C.SELFCORR]
        golden = [r for r in rows if r["kind"] == "golden"]
        if golden:
            tags = sorted({t for r in golden for t in r["tags"]})
            print(json.dumps({"label": meta.get("label"), "golden": share(golden),
                              "similarity_med": median([r["similarity"] for r in golden]),
                              "total_med_ms": median([r["total_ms"] for r in golden if r["status"] != "rules"]),
                              "by_tag": {t: share([r for r in golden if t in r["tags"]]) for t in tags}},
                             ensure_ascii=False))
            continue
        dev = [r for r in polish if r["id"].startswith("dev-")]

        def share(items, key="ok"):
            return f"{sum(1 for r in items if r.get(key, True))}/{len(items)}"

        summary = {
            "label": meta.get("label"), "load_s": meta.get("load_s"),
            "ttft_med_ms": median([r["ttft_ms"] for r in polish]),
            "total_med_ms": median([r["total_ms"] for r in polish]),
            "total_p90_ms": p90([r["total_ms"] for r in polish]),
            "gen_tps_med": median([r["gen_tps"] for r in polish]),
            "ok_ru": share(ru), "ok_en": share(en), "edits_ok": share(edits),
            "selfcorr": share(selfcorr), "dev": share(dev),
            "done": share(polish, "status") if False else f"{sum(1 for r in polish if r['status'] == 'done')}/{len(polish)}",
            "terms": share(polish, "terms_ok"), "numbers": share(polish, "numbers_ok"),
            "must": share(polish, "must_ok"), "must_not": share(polish, "must_not_ok"),
            "no_answer": share(polish, "no_answer"), "lang": share(polish, "lang_ok"),
            "fillers": share(polish, "fillers_ok"),
            "by_style": {s: share([r for r in polish if r["style"] == s]) for s in (*C.STYLES, "dev")},
            "accept_rate": median([r["accept_rate"] for r in polish if r.get("accept_rate") is not None]),
            **{k: meta_end.get(k) for k in ("mx_peak_mb", "rss_peak_mb", "thermal_after", "pmset_after", "wall_s")},
            "thermal_before": meta.get("thermal_before"),
        }
        print(json.dumps(summary, ensure_ascii=False))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model")
    parser.add_argument("--label")
    parser.add_argument("--styles", default=",".join(C.STYLES))
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--no-edits", action="store_true")
    parser.add_argument("--manual", action="store_true", help="ручной жадный цикл (база для сравнения со спекулятивным)")
    parser.add_argument("--prefill", action="store_true", help="ответ начинается с <polished> (как в бэкенде)")
    parser.add_argument("--spec-draft")
    parser.add_argument("--spec-k", type=int, default=3)
    parser.add_argument("--only", choices=("selfcorr", "dev"), help="только категория самоисправлений или режим dev")
    parser.add_argument("--no-resolve", action="store_true",
                        help="не снимать однозначные самоисправления до модели (только промпт)")
    parser.add_argument("--claude", action="store_true",
                        help="вместо MLX — `claude -p` (ClaudeCliBackend, модель --claude-model); текст уходит в облако")
    parser.add_argument("--claude-model", default=P.CLAUDE_MODEL)
    parser.add_argument("--report", nargs="*")
    parser.add_argument("--golden", action="store_true", help="эталонные пары P5 (`polish_golden.py`)")
    parser.add_argument("--tags", help="только пары с этими тегами, через запятую")
    parser.add_argument("--rules", action="store_true",
                        help="правила речи P3 (абзацы, «зачеркни», списки) до модели, как в приложении")
    args = parser.parse_args()
    if args.report is not None:
        return report(args.report)
    if args.claude:
        return run_claude(args)
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
