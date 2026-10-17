"""Стенд «лучше Handy» (§9): задержка, сомнения, правки, расхождение с Handy.

Записи — WAV из Handy, у которых есть текст Handy (`history.db` Handy или
`*-handy-*.txt` в папке `MOSTIK_BENCH_INBOX`). Каждая гоняется через ту же `Session`, что и в движке, кадрами
по 100 мс, но быстрее реального времени; стоимость каждого шага VAD и окна
меряется, а хвост (stop → final) пересчитывается по таймлайну, как если бы
звук шёл в реальном времени. Проверяющая ждётся до конца — сомнения считаются
на полной паре; отдельно моделируется, успела бы она за 1200 мс.

Наружу — только числа: тексты диктовок приватны и в файлы не пишутся.

    python bench/run_bench.py --list
    python bench/run_bench.py --batch 0:3       # файлы 0..2, JSON в bench/out/
    python bench/run_bench.py --report          # сводка → bench/out/report.md
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import statistics
import sys
import threading
import time
import wave
from pathlib import Path

ENGINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ENGINE))

from mostik_engine.doubts import TermIndex  # noqa: E402
from mostik_engine.models import ModelPool  # noqa: E402
from mostik_engine.personal_glossary import PersonalGlossary  # noqa: E402
from mostik_engine.session import SAMPLE_RATE, Session  # noqa: E402
from mostik_engine.verifier_worker import VerifierClient  # noqa: E402

from audio_transcription.reconcile import MINOR_KINDS, normalize_text  # noqa: E402

HANDY = Path.home() / "Library" / "Application Support" / "com.pais.handy"
# Своя папка с текстами Handy и разборами transcriber — необязательна.
INBOX = Path(os.environ["MOSTIK_BENCH_INBOX"]).expanduser() if os.environ.get("MOSTIK_BENCH_INBOX") else None
OUT = ENGINE / "bench" / "out"
# Отчёт по своим записям остаётся на этой машине: в docs/ он не пишется.
REPORT = OUT / "report.md"
FRAME = int(0.1 * SAMPLE_RATE) * 2
AGENT_WAIT_S = 1.2


def handy_texts() -> dict[str, str]:
    """Имя WAV → текст Handy. Сначала файлы во входящих, потом история Handy."""
    texts: dict[str, str] = {}
    db = HANDY / "history.db"
    if db.exists():
        with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as connection:
            for name, text in connection.execute(
                "select file_name, transcription_text from transcription_history"
            ):
                if text and text.strip():
                    texts[name] = text
    for path in INBOX.glob("*-handy-*.txt") if INBOX else ():
        match = re.search(r"(handy-\d+)\.txt$", path.name)
        if match:
            texts[match.group(1) + ".wav"] = path.read_text(encoding="utf-8")
    return texts


def old_queue(name: str, limit_s: float | None) -> int | None:
    """Сколько мест показала очередь проверки transcriber на этой записи."""
    stem = name.removesuffix(".wav")
    for folder in INBOX.glob(f"*-{stem}") if INBOX else ():
        segments = folder / "segments.json"
        if not segments.is_file():
            continue
        items = json.loads(segments.read_text(encoding="utf-8")).get("review_items", [])
        return sum(
            1
            for item in items
            if item.get("kind") not in MINOR_KINDS | {"verifier_canonical"}
            and (limit_s is None or float(item.get("start", 0)) < limit_s)
        )
    return None


def recordings() -> list[tuple[str, float]]:
    texts = handy_texts()
    found = []
    for path in sorted((HANDY / "recordings").glob("handy-*.wav")):
        if path.name not in texts:
            continue
        with wave.open(str(path), "rb") as handle:
            seconds = handle.getnframes() / handle.getframerate()
        if seconds >= 3:
            found.append((path.name, seconds))
    return found[:32]


def word_distance(left: str, right: str) -> tuple[int, int]:
    """Пословная правка (Левенштейн) и число слов эталона."""
    a = normalize_text(left).split()
    b = normalize_text(right).split()
    previous = list(range(len(b) + 1))
    for i, word in enumerate(a, start=1):
        current = [i] + [0] * len(b)
        for j, other in enumerate(b, start=1):
            current[j] = min(
                previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (word != other)
            )
        previous = current
    return previous[-1], len(b)


def simulate(
    steps: list[dict], packs: list[dict], audio_s: float, final_cost_s: float
) -> dict:
    """Таймлайн при подаче в реальном времени по измеренным стоимостям.

    Шаг VAD становится возможен, когда звук дошёл до его позиции; рабочий
    поток один, поэтому шаги встают в очередь. Проверяющая — отдельный
    процесс со своей очередью: пачка попадает к ней в момент начала шага,
    в котором набрала 8 с; остаток — в начале финального шага после stop.
    """
    worker_free = 0.0
    verifier_free = 0.0
    sent: set[int] = set()
    for step in steps:
        start = max(step["at_s"], worker_free)
        for index in step["packs"]:
            verifier_free = max(start, verifier_free) + packs[index]["verifier_s"]
            sent.add(index)
        worker_free = start + step["cost_s"]
    final_start = max(audio_s, worker_free)
    for index, pack in enumerate(packs):
        if index not in sent and pack["submitted"]:
            verifier_free = max(final_start, verifier_free) + pack["verifier_s"]
    final_end = final_start + final_cost_s
    tail = final_end - audio_s
    agent_end = max(final_end, min(verifier_free, audio_s + AGENT_WAIT_S))
    return {
        "tail_ms": round(tail * 1000, 1),
        "tail_agent_ms": round((agent_end - audio_s) * 1000, 1),
        "verifier_in_time": verifier_free <= audio_s + AGENT_WAIT_S,
        "verifier_after_stop_ms": round(max(0.0, verifier_free - audio_s) * 1000, 1),
        "backlog_ms": round(max(0.0, worker_free - audio_s) * 1000, 1),
    }


class Recorder(Session):
    """Сессия, которая записывает стоимость каждого шага для таймлайна."""

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.steps: list[dict] = []

    def step(self, final: bool = False):
        before = len(self.windows)
        submitted = {pack.index for pack in self.packs if pack.submitted}
        at = self.samples / SAMPLE_RATE
        started = time.monotonic()
        made = super().step(final=final)
        if not final:
            self.steps.append(
                {
                    "at_s": at,
                    "cost_s": time.monotonic() - started,
                    "windows": list(range(before, len(self.windows))),
                    "packs": [p.index for p in self.packs if p.submitted and p.index not in submitted],
                }
            )
        return made


def run_one(name: str, seconds: float, args, pool, verifier, personal, texts) -> dict:
    path = HANDY / "recordings" / name
    with wave.open(str(path), "rb") as handle:
        pcm = handle.readframes(handle.getnframes())
    limit_s = args.max_seconds if seconds > args.max_seconds else None
    if limit_s:
        pcm = pcm[: int(limit_s * SAMPLE_RATE) * 2]
    entries = personal.entries("ru")
    session = Recorder(
        f"bench-{name}",
        "ru",
        pool=pool,
        verifier=verifier,
        verify=not args.no_verify,
        hotwords=personal.hotwords("ru"),
        terms=TermIndex([], personal.trusted("ru")),
        personal=entries,
    )
    verifier.on_result = session.on_verifier
    for at in range(0, len(pcm), FRAME):
        session.append(pcm[at : at + FRAME])
        if session.due():
            session.step()
    stop = time.monotonic()
    # Полная пара: ждём проверяющую до конца, чтобы сомнения были честными.
    result = session.finish(wait_verifier_ms=600_000, stop_at=stop)
    wait_s = max(
        0.0,
        (time.monotonic() - stop) - result["timings"]["analysis_ms"] / 1000,
    )
    final_window_cost = sum(
        w.primary_ms for w in session.windows[sum(len(s["windows"]) for s in session.steps) :]
    ) / 1000
    final_cost = final_window_cost + result["timings"]["analysis_ms"] / 1000 + 0.05
    packs = [
        {"seconds": p.length_s, "verifier_s": p.seconds, "submitted": p.submitted}
        for p in session.packs
    ]
    windows = [
        {"seconds": w.end_s - w.start_s, "primary_s": w.primary_ms / 1000}
        for w in session.windows
    ]
    pairs_dir = os.environ.get("MOSTIK_BENCH_PAIRS")
    if pairs_dir:
        # Только для отладки фильтра и только вне репозитория: тексты приватны.
        Path(pairs_dir).mkdir(parents=True, exist_ok=True)
        (Path(pairs_dir) / f"{name}.json").write_text(
            json.dumps(
                [
                    {"start": p.start_s, "end": p.end_s, "verifier": p.text,
                     "primary": " ".join(session.windows[i].text for i in p.windows)}
                    for p in session.packs
                ],
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
    audio_s = result["timings"]["audio_s"]
    sim = simulate(session.steps, packs, audio_s, final_cost)
    record = {
        "name": name,
        "audio_s": audio_s,
        "truncated": bool(limit_s),
        "max_seconds": args.max_seconds,
        "windows": len(windows),
        "packs": len(packs),
        "final_pack_s": round(packs[-1]["seconds"], 2) if packs else 0,
        "final_pack_verifier_s": round(packs[-1]["verifier_s"], 3) if packs else 0,
        "mean_pack_s": round(statistics.mean([p["seconds"] for p in packs]), 2) if packs else 0,
        "mean_window_s": round(statistics.mean([w["seconds"] for w in windows]), 2) if windows else 0,
        "primary_rtf": round(result["timings"]["primary_ms"] / 1000 / audio_s, 4) if audio_s else 0,
        "verifier_rtf": round(result["timings"]["verifier_ms"] / 1000 / audio_s, 4) if audio_s else 0,
        "vad_ms": result["timings"]["vad_ms"],
        "final_window_s": round(final_window_cost, 3),
        "analysis_ms": result["timings"]["analysis_ms"],
        "verifier": result["verifier"],
        "doubts": len(result["doubts"]),
        "doubt_kinds": [d["kind"] for d in result["doubts"]],
        "doubt_candidates": result["stats"]["doubt_candidates"],
        "review_items": result["stats"]["review_items"],
        "corrections": len(result["corrections"]),
        "old_queue": old_queue(name, limit_s),
        "verifier_wait_s": round(wait_s, 2),
        **sim,
    }
    if not limit_s:
        edits, reference = word_distance(texts[name], result["text"])
        record["handy_words"] = reference
        record["word_diff"] = edits
        record["word_diff_rate"] = round(edits / reference, 4) if reference else None
        raw_edits, _ = word_distance(texts[name], result["raw_text"])
        record["raw_word_diff_rate"] = round(raw_edits / reference, 4) if reference else None
    return record


def batch(spec: str, args) -> None:
    start, _, end = spec.partition(":")
    items = recordings()[int(start) : int(end) if end else None]
    OUT.mkdir(parents=True, exist_ok=True)
    texts = handy_texts()
    pool = ModelPool()
    pool.warmup("ru")
    verifier = VerifierClient()
    personal = PersonalGlossary()
    if not args.no_verify:
        verifier.ensure()
        verifier.wait_ready(300)
    load = os.getloadavg()[0]
    for name, seconds in items:
        target = OUT / f"{name.removesuffix('.wav')}.json"
        if target.exists() and not args.force:
            print(f"{name}: уже есть", file=sys.stderr)
            continue
        started = time.monotonic()
        record = run_one(name, seconds, args, pool, verifier, personal, texts)
        record["load_avg"] = round((load + os.getloadavg()[0]) / 2, 1)
        record["wall_s"] = round(time.monotonic() - started, 1)
        target.write_text(json.dumps(record, ensure_ascii=False, indent=1), encoding="utf-8")
        print(
            f"{name}: {record['audio_s']:.0f} с, хвост {record['tail_ms']:.0f} мс, "
            f"сомнений {record['doubts']}, правок {record['corrections']}, {record['wall_s']} с",
            file=sys.stderr,
        )
    verifier.stop()


def _median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def _mean(values):
    values = [v for v in values if v is not None]
    return statistics.mean(values) if values else None


def _p90(values):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    return values[min(len(values) - 1, int(round(0.9 * (len(values) - 1))))]


def _fmt(value, digits=0, suffix=""):
    if value is None:
        return "—"
    text = f"{value:,.{digits}f}".replace(",", " ").replace(".", ",")
    return text + suffix


def report() -> str:
    records = [json.loads(p.read_text(encoding="utf-8")) for p in sorted(OUT.glob("*.json"))]
    if not records:
        raise SystemExit("нет результатов в bench/out/")
    full = [r for r in records if "word_diff_rate" in r]
    audio = sum(r["audio_s"] for r in records)
    kinds: dict[str, int] = {}
    for r in records:
        for kind in r["doubt_kinds"]:
            kinds[kind] = kinds.get(kind, 0) + 1
    old = [r["old_queue"] for r in records if r["old_queue"] is not None]
    lines = [
        "# Стенд Mostik на своих записях",
        "",
        f"Записей: {len(records)} диктовок Handy с текстом Handy, звука {_fmt(audio / 60, 1)} мин. "
        f"Длинные записи обрезаны до первых {_fmt(records[0].get('max_seconds', 120))} с "
        f"({sum(r['truncated'] for r in records)} из {len(records)}); расхождение с Handy "
        f"считается только по целым ({len(full)}).",
        "",
        "Запуск: `engine/bench/run_bench.py --batch A:B`, затем `--report`. Звук идёт "
        "кадрами по 100 мс через ту же `Session`, что в движке, быстрее реального "
        "времени; хвост пересчитан по таймлайну реального времени из измеренной "
        "стоимости каждого шага VAD и окна. Проверяющая ждётся до конца, поэтому "
        "сомнения — на полной паре. Проверяющая получает пачки соседних окон "
        "от 8 до 24 с (отступление от §12.3), остаток — одной пачкой на stop.",
        "",
        f"Средняя нагрузка машины во время прогона (load average): "
        f"{_fmt(_mean([r.get('load_avg') for r in records]), 0)} — при высокой загрузке "
        "абсолютные миллисекунды завышены; RTF и хвост на свободной машине будут ниже.",
        "",
        "## Задержка",
        "",
        "| Метрика | Медиана | p90 | Максимум |",
        "|---|---|---|---|",
    ]
    for label, key in (
        ("Хвост stop → final, обычное приложение (мс)", "tail_ms"),
        ("Хвост stop → final, агентное (ждём проверяющую ≤1200 мс)", "tail_agent_ms"),
        ("Отставание рабочего потока к моменту stop (мс)", "backlog_ms"),
        ("Проверяющая закончила после stop через (мс)", "verifier_after_stop_ms"),
        ("Последнее окно основной моделью (с)", "final_window_s"),
        ("Последняя пачка: длина звука (с)", "final_pack_s"),
        ("Последняя пачка: время проверяющей (с)", "final_pack_verifier_s"),
    ):
        values = [r[key] for r in records]
        digits = 2 if key.startswith("final_") else 0
        lines.append(
            f"| {label} | {_fmt(_median(values), digits)} | {_fmt(_p90(values), digits)} | "
            f"{_fmt(max(values), digits)} |"
        )
    in_time = sum(1 for r in records if r["verifier_in_time"])
    lines += [
        "",
        f"RTF основной (GigaAM v3 E2E, CPU): медиана {_fmt(_median([r['primary_rtf'] for r in records]), 3)}; "
        f"проверяющей (Whisper Turbo MLX): {_fmt(_median([r['verifier_rtf'] for r in records]), 3)}. "
        f"Окон на запись в среднем {_fmt(_mean([r['windows'] for r in records]), 1)}, пачек проверяющей "
        f"{_fmt(_mean([r.get('packs', 0) for r in records]), 1)} средней длиной "
        f"{_fmt(_mean([r.get('mean_pack_s', 0) for r in records]), 1)} с. "
        f"**Проверяющая закончила в пределах 1200 мс после stop в {in_time} из {len(records)} диктовок**; "
        "в остальных `final` уйдёт с `verifier: \"late\"`.",
        "",
        "Почему проверяющая не успевает: срок съедает один вызов Whisper на последнюю "
        f"пачку — медиана {_fmt(_median([r.get('final_pack_verifier_s') for r in records]), 2)} с "
        f"даже для пачки около секунды, а очередь перед ней — медиана "
        f"{_fmt(_median([max(0.0, r.get('verifier_after_stop_ms', 0) - r.get('final_pack_verifier_s', 0) * 1000) for r in records]), 0)} мс. "
        "Whisper дополняет любой вызов до 30 с звука, поэтому цена вызова почти не "
        "зависит от длины пачки. Цель «≤1200 мс в 80% диктовок» достижима, только если "
        "вызов на свободной машине стоит меньше секунды.",
        "",
        "## Сомнения и правки",
        "",
        "| Метрика | Среднее | Медиана | Максимум |",
        "|---|---|---|---|",
    ]
    for label, key in (
        ("Сомнений на диктовку (лимит 5)", "doubts"),
        ("Кандидатов после фильтра терминов (до обрезки)", "doubt_candidates"),
        ("Расхождений основной и проверяющей всего", "review_items"),
        ("Правок словаря на диктовку", "corrections"),
    ):
        values = [r[key] for r in records]
        lines.append(
            f"| {label} | {_fmt(_mean(values), 1)} | {_fmt(_median(values), 1)} | {_fmt(max(values), 0)} |"
        )
    lines += [
        "",
        f"Старая очередь проверки transcriber на тех же записях (и тех же отрезках): "
        f"в среднем {_fmt(_mean(old), 1)} мест на запись ({len(old)} записей с `segments.json`).",
        "",
        "Виды сомнений: " + ", ".join(f"{k} — {v}" for k, v in sorted(kinds.items(), key=lambda x: -x[1])) + ".",
        "",
        "## Расхождение с текстом Handy",
        "",
        "Пословная правка (Левенштейн по нормализованным словам) между итогом Mostik и "
        "текстом, который вставил Handy, на долю слов Handy. Это не WER: эталона "
        "нет, Handy тоже ошибается. Показывает, насколько Mostik меняет привычный текст.",
        "",
        f"- итог Mostik (словарь, правки проверяющей, без паразитов): медиана "
        f"{_fmt(_median([r['word_diff_rate'] * 100 for r in full]), 1, '%')}, "
        f"среднее {_fmt(_mean([r['word_diff_rate'] * 100 for r in full]), 1, '%')};",
        f"- сырой текст основной модели: медиана "
        f"{_fmt(_median([r['raw_word_diff_rate'] * 100 for r in full]), 1, '%')}.",
        "",
        "## По записям",
        "",
        "| Запись | Звук, с | Окон | Хвост, мс | Хвост агент, мс | Сомнений | Правок | Старая очередь | Расхождение с Handy |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for number, r in enumerate(records, 1):
        diff = _fmt(r["word_diff_rate"] * 100, 1, "%") if "word_diff_rate" in r else "обрезана"
        lines.append(
            f"| rec-{number:02d} | {_fmt(r['audio_s'])} | {r['windows']} | "
            f"{_fmt(r['tail_ms'])} | {_fmt(r['tail_agent_ms'])} | {r['doubts']} | "
            f"{r['corrections']} | {r['old_queue'] if r['old_queue'] is not None else '—'} | {diff} |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--batch", help="срез списка записей, например 0:3")
    parser.add_argument("--report", action="store_true")
    parser.add_argument("--max-seconds", type=float, default=120.0)
    parser.add_argument("--no-verify", action="store_true")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if args.list:
        for index, (name, seconds) in enumerate(recordings()):
            print(f"{index:2d} {name} {seconds:.0f} с")
    if args.batch:
        batch(args.batch, args)
    if args.report:
        OUT.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(report(), encoding="utf-8")
        print(f"отчёт: {REPORT}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
