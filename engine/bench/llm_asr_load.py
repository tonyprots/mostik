"""Локальная LLM рядом с прогретыми ASR: память и взаимное торможение (§4).

Поднимает движок Mostik (интерпретатор transcriber), прогревает GigaAM и Whisper
(`warmup ru`), меряет их RSS, затем гоняет `transcribe_file` синтетического WAV
по кругу и одновременно стенд LLM (`llm_bench.py` в `.venv-llm`). Звук — `say -v
Milena`, не записи пользователя.

    python engine/bench/llm_asr_load.py --wav /tmp/speech.wav \
        --bench "--model mlx-community/Qwen3.5-4B-MLX-4bit --prefill --limit 10 --styles plain --no-edits"
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import threading
import time
from pathlib import Path

ENGINE = Path(__file__).resolve().parent.parent
# Интерпретатор с зависимостями движка (venv transcriber); по умолчанию — текущий.
TRANSCRIBER_PY = Path(os.environ.get("MOSTIK_PYTHON", sys.executable))
LLM_PY = ENGINE / ".venv-llm" / "bin" / "python"


def rss_mb(pid: int) -> float:
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out) / 1024 if out else 0.0


def tree(pid: int) -> list[int]:
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
    pids = [pid]
    for child in out:
        pids.extend(tree(int(child)))
    return pids


def phys_footprint_mb(pid: int) -> float:
    """`footprint` учитывает память Metal/IOSurface, которой нет в RSS."""
    out = subprocess.run(["footprint", str(pid)], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "phys_footprint:" in line:
            value, unit = line.split("phys_footprint:")[1].split()[:2]
            return float(value) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}.get(unit, 1)
    return 0.0


class Engine:
    def __init__(self) -> None:
        self.proc = subprocess.Popen([str(TRANSCRIBER_PY), "-m", "mostik_engine"], cwd=str(ENGINE),
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     text=True, bufsize=1)
        self.lines: list[dict] = []
        self.cv = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        for line in self.proc.stdout:
            try:
                item = json.loads(line)
            except ValueError:
                continue
            with self.cv:
                self.lines.append(item)
                self.cv.notify_all()

    def send(self, **cmd) -> None:
        self.proc.stdin.write(json.dumps(cmd, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

    def wait(self, pred, timeout=300.0) -> dict:
        deadline = time.monotonic() + timeout
        with self.cv:
            while True:
                for item in self.lines:
                    if pred(item):
                        self.lines.remove(item)
                        return item
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError
                self.cv.wait(left)


def transcribe(engine: Engine, wav: str, n: int) -> dict:
    started = time.monotonic()
    engine.send(cmd="transcribe_file", id=1000 + n, session=f"f{n}", path=wav, language="ru", verify=True,
                wait_verifier_ms=60000)
    final = engine.wait(lambda e: e.get("event") == "final" and e.get("session") == f"f{n}")
    return {"wall_s": round(time.monotonic() - started, 2), "verifier": final.get("verifier"),
            "primary_ms": final["timings"].get("primary_ms"), "verifier_ms": final["timings"].get("verifier_ms")}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wav", required=True)
    parser.add_argument("--bench", required=True)
    args = parser.parse_args()
    engine = Engine()
    engine.send(cmd="hello", id=1)
    engine.wait(lambda e: e.get("id") == 1)
    engine.send(cmd="warmup", id=2, language="ru", verify=True)
    engine.wait(lambda e: e.get("id") == 2)
    time.sleep(1)
    baseline = [transcribe(engine, args.wav, n) for n in range(2)]
    pids = tree(engine.proc.pid)
    asr = {"pids": pids, "rss_mb": round(sum(rss_mb(p) for p in pids), 1),
           "footprint_mb": round(sum(phys_footprint_mb(p) for p in pids), 1)}
    print(json.dumps({"asr_loaded": asr, "asr_alone": baseline}, ensure_ascii=False), flush=True)

    bench = subprocess.Popen([str(LLM_PY), str(ENGINE / "bench" / "llm_bench.py"), *shlex.split(args.bench)],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    loaded: list[dict] = []
    llm_peak = {"footprint_mb": 0.0}

    def watch() -> None:
        while bench.poll() is None:
            llm_peak["footprint_mb"] = max(llm_peak["footprint_mb"], phys_footprint_mb(bench.pid))
            time.sleep(1)

    threading.Thread(target=watch, daemon=True).start()
    n = 10
    while bench.poll() is None:
        loaded.append(transcribe(engine, args.wav, n))
        n += 1
    out = bench.stdout.read()
    asr_after = round(sum(phys_footprint_mb(p) for p in tree(engine.proc.pid)), 1)
    print(out.strip().splitlines()[-1] if out.strip() else "", flush=True)
    print(json.dumps({"asr_under_llm": loaded, "llm_footprint_peak_mb": round(llm_peak["footprint_mb"], 1),
                      "asr_footprint_after_mb": asr_after,
                      "sum_peak_mb": round(asr_after + llm_peak["footprint_mb"], 1)}, ensure_ascii=False), flush=True)
    engine.proc.stdin.close()
    engine.proc.wait(timeout=20)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
