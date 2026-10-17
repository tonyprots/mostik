"""Замер производительности движка (П8, пункт 8): холодный старт, память, нагрев.

Движок запускается напрямую (`python -m mostik_engine`), без приложения и микрофона.
Дом, журнал и отчёты о сбоях — во временной папке: настоящий
`~/Library/Application Support/Mostik` и `~/Library/Logs/Mostik` не трогаются.
Модели берутся из обычного кэша Hugging Face, в сеть движок не ходит.

    python engine/bench/perf_bench.py --wav /tmp/synth-60s.wav [--idle 30] [--runs 2]

Синтетический WAV (16 кГц моно int16) делает `say` из придуманного текста, например:
`say -v Milena -o /tmp/s.wav --data-format=LEI16@16000 "…"`.

Что меряется (по дереву процессов движка — сам движок и его worker'ы):
- холодный старт: запуск процесса → ответ `hello` → ответ `warmup` (в приложении после этого «Готов»);
- Память (`phys_footprint` и RSS) в простое через `--idle` секунд после прогрева;
- диктовка: звук кадрами по 100 мс в реальном времени, footprint раз в секунду (максимум) и пик за жизнь процессов,
  CPU-время дерева за время звука и за весь цикл до `final`.
Load average печатается до и после каждого шага.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path

ENGINE = Path(__file__).resolve().parents[1]


def loadavg() -> str:
    return " ".join(f"{x:.1f}" for x in os.getloadavg())


def tree(pid: int) -> list[int]:
    """pid и все потомки (по `ps`)."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout
    children: dict[int, list[int]] = {}
    for line in out.splitlines():
        a, b = line.split()
        children.setdefault(int(b), []).append(int(a))
    result, stack = [], [pid]
    while stack:
        p = stack.pop()
        result.append(p)
        stack.extend(children.get(p, []))
    return result


def cputime(text: str) -> float:
    """`ps -o time` → секунды: `[[dd-]hh:]mm:ss.ss`."""
    days = 0
    if "-" in text:
        d, text = text.split("-", 1)
        days = int(d)
    parts = [float(x) for x in text.split(":")]
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + part
    return days * 86400 + seconds


UNITS = {"B": 1 / 2**20, "KB": 1 / 1024, "MB": 1.0, "GB": 1024.0}


def footprint(pids: list[int]) -> tuple[float, float]:
    """Сумма `phys_footprint` и `phys_footprint_peak` (МБ) по `footprint(1)`.

    RSS на macOS под давлением памяти врёт вниз: сжатые и выгруженные страницы в него не
    входят, память Metal (MLX) тоже. `phys_footprint` — то, что показывает Activity Monitor.
    """
    args = ["footprint"]
    for p in pids:
        args += ["-p", str(p)]
    out = subprocess.run(args, capture_output=True, text=True).stdout
    now = peak = 0.0
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] in ("phys_footprint:", "phys_footprint_peak:"):
            value = float(parts[1]) * UNITS.get(parts[2], 1.0)
            if parts[0] == "phys_footprint:":
                now += value
            else:
                peak += value
    return now, peak


def per_process(procs: list) -> dict:
    """footprint каждого процесса дерева: `pid имя` → МБ."""
    result = {}
    for p, name, _ in procs:
        args = subprocess.run(["ps", "-o", "args=", "-p", str(p)], capture_output=True, text=True).stdout.split()
        label = next((a for a in args[1:] if not a.startswith("-") and ("mostik" in a or "worker" in a or a.endswith(".py"))),
                     " ".join(args[1:3]) or name)
        result[f"{p} {Path(label).name}"] = round(footprint([p])[0])
    return result


def sample(pid: int) -> dict:
    """RSS и footprint (МБ), CPU-время (с) по дереву; по процессам — имя и RSS."""
    pids = tree(pid)
    out = subprocess.run(["ps", "-o", "pid=,rss=,time=,comm=", "-p", ",".join(map(str, pids))],
                         capture_output=True, text=True).stdout
    total_rss, total_cpu, procs = 0.0, 0.0, []
    for line in out.splitlines():
        fields = line.split(None, 3)
        if len(fields) < 4:
            continue
        rss = int(fields[1]) / 1024
        total_rss += rss
        total_cpu += cputime(fields[2])
        procs.append((int(fields[0]), Path(fields[3]).name, round(rss)))
    foot, foot_peak = footprint([p for p, _, _ in procs])
    return {"rss": total_rss, "cpu": total_cpu, "procs": procs, "foot": foot, "foot_peak": foot_peak}


class Engine:
    def __init__(self, python: str, home: Path):
        env = dict(os.environ)
        env.update(MOSTIK_HOME=str(home / "home"), MOSTIK_LOG_DIR=str(home / "logs"),
                   MOSTIK_CRASH_DIR=str(home / "logs" / "crashes"), PYTHONUNBUFFERED="1")
        self.started = time.monotonic()
        self.stderr = open(home / "engine.log", "w")
        self.proc = subprocess.Popen([python, "-m", "mostik_engine"], cwd=ENGINE, env=env,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
                                     text=True, bufsize=1)
        self.replies: queue.Queue[dict] = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        for line in self.proc.stdout:
            try:
                self.replies.put(json.loads(line))
            except json.JSONDecodeError:
                pass

    def send(self, cmd: str, **fields) -> None:
        self.proc.stdin.write(json.dumps({"cmd": cmd, **fields}) + "\n")
        self.proc.stdin.flush()

    def wait(self, command_id: str, timeout: float) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError(command_id)
            message = self.replies.get(timeout=left)
            if message.get("id") == command_id:
                if message.get("event") == "error" or "error" in message and "code" in message:
                    raise RuntimeError(json.dumps(message, ensure_ascii=False)[:300])
                return message

    def close(self) -> None:
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=20)
        except Exception:  # noqa: BLE001
            self.proc.kill()
        self.stderr.close()


def read_pcm(path: Path) -> bytes:
    with wave.open(str(path)) as wav:
        if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) != (16000, 1, 2):
            raise SystemExit("нужен WAV 16 кГц моно int16")
        return wav.readframes(wav.getnframes())


def dictation(engine: Engine, pcm: bytes, n: int, language: str) -> dict:
    session = f"bench-{n}"
    pid = engine.proc.pid
    before = sample(pid)
    t0 = time.monotonic()
    engine.send("start", id=f"s{n}", session=session, language=language, project=None,
                verify=True, agent=False, sources=[])
    peak, procs_at_peak = before["foot"], before["procs"]
    chunk = 3200  # 100 мс
    next_tick, last_sample = t0, t0
    for offset in range(0, len(pcm), chunk):
        engine.send("audio", session=session, pcm=base64.b64encode(pcm[offset:offset + chunk]).decode())
        next_tick += 0.1
        now = time.monotonic()
        if now - last_sample >= 1.0:
            s = sample(pid)
            if s["foot"] > peak:
                peak, procs_at_peak = s["foot"], s["procs"]
            last_sample = now
        delay = next_tick - time.monotonic()
        if delay > 0:
            time.sleep(delay)
    audio_end = time.monotonic()
    during = sample(pid)
    engine.send("stop", id=f"e{n}", session=session, wait_verifier_ms=1200)
    final = engine.wait(f"e{n}", timeout=300)
    done = time.monotonic()
    after = sample(pid)
    return {
        "audio_s": round(len(pcm) / 32000, 1),
        "wall_audio_s": round(audio_end - t0, 1),
        "tail_ms": round((done - audio_end) * 1000),
        "cpu_audio_s": round(during["cpu"] - before["cpu"], 1),
        "cpu_total_s": round(after["cpu"] - before["cpu"], 1),
        "cpu_load_pct": round(100 * (during["cpu"] - before["cpu"]) / (audio_end - t0)),
        "foot_peak_sampled_mb": round(peak),
        "foot_peak_lifetime_mb": round(after["foot_peak"]),
        "foot_after_mb": round(after["foot"]),
        "rss_after_mb": round(after["rss"]),
        "procs_at_peak": procs_at_peak,
        "chars": len(final.get("text") or ""),
        "verifier": final.get("verifier"),
        "load": loadavg(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wav", required=True, type=Path)
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--language", default="ru")
    parser.add_argument("--idle", type=float, default=30)
    parser.add_argument("--runs", type=int, default=2)
    args = parser.parse_args()
    pcm = read_pcm(args.wav)

    with tempfile.TemporaryDirectory(prefix="mostik-perf-") as tmp:
        home = Path(tmp)
        report: dict = {"load_start": loadavg()}
        engine = Engine(args.python, home)
        try:
            engine.send("hello", id="h")
            hello = engine.wait("h", timeout=120)
            report["hello_s"] = round(time.monotonic() - engine.started, 2)
            report["models"] = hello.get("models")
            engine.send("warmup", id="w", language=args.language)
            warm = engine.wait("w", timeout=600)
            report["ready_s"] = round(time.monotonic() - engine.started, 2)
            report["warmup_reply"] = {k: warm.get(k) for k in ("loaded", "seconds", "verifier")}
            report["load_ready"] = loadavg()
            ready = sample(engine.proc.pid)
            report["ready_mem_mb"] = {"foot": round(ready["foot"]), "foot_peak": round(ready["foot_peak"]),
                                      "rss": round(ready["rss"])}
            idle0 = sample(engine.proc.pid)
            time.sleep(args.idle)
            idle = sample(engine.proc.pid)
            report["idle"] = {"after_s": args.idle, "foot_mb": round(idle["foot"]), "rss_mb": round(idle["rss"]),
                              "cpu_s": round(idle["cpu"] - idle0["cpu"], 2), "procs": idle["procs"],
                              "load": loadavg()}
            report["dictations"] = [dictation(engine, pcm, n, args.language) for n in range(args.runs)]
            time.sleep(5)  # хвост проверяющей после final
            calm = sample(engine.proc.pid)
            time.sleep(args.idle)
            last = sample(engine.proc.pid)
            report["idle_after"] = {"after_s": args.idle, "foot_mb": round(last["foot"]), "rss_mb": round(last["rss"]),
                                    "cpu_s": round(last["cpu"] - calm["cpu"], 2),
                                    "per_process_foot_mb": per_process(last["procs"]), "load": loadavg()}
        finally:
            engine.close()
        report["load_end"] = loadavg()
    print(json.dumps(report, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
