"""Стенд L4: подсказка Whisper «фраза + термины» и пиковая нормализация.

Сравниваются четыре варианта на одном и том же звуке:

- `legacy` — как до L4: термины через `hotwords`, звук как есть;
- `norm` — только нормализация до −0,1 dBFS;
- `prompt` — только подсказка «термины + фраза»;
- `both` — то, что теперь делает движок.

Синтетика: фразы с терминами, озвученные `say` (Milena для ru, Samantha для en),
каждая на трёх уровнях громкости: как есть, −30 дБ и −40 дБ. Эталон известен,
поэтому считаются WER, доля терминов, записанных верно, и доля окон с пунктуацией.

Записи Handy (`--handy N`): N диктовок, у которых есть текст Handy; меряется только
расхождение с ним (WER против Handy — не точность, а сдвиг) и пунктуация. Наружу —
только агрегаты: тексты не печатаются и не сохраняются.

    python bench/whisper_hint_bench.py --synthetic
    python bench/whisper_hint_bench.py --handy 20
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

ENGINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ENGINE))
sys.path.insert(0, str(ENGINE / "bench"))

import numpy as np  # noqa: E402

from mostik_engine import paths, verifier_worker  # noqa: E402,F401 — paths кладёт transcriber в sys.path
from mostik_engine.whisper_hint import build_prompt, peak_normalize  # noqa: E402

from audio_transcription.reconcile import normalize_text  # noqa: E402

OUT = ENGINE / "bench" / "out"
VARIANTS = ("legacy", "norm", "prompt", "both")
LEVELS_DB = (0.0, -30.0, -40.0)
VOICES = {"ru": "Milena", "en": "Samantha"}

TERMS = ["Mostik", "GigaAM", "Whisper", "Parakeet", "Claude Code", "Kubernetes", "PostgreSQL",
         "Jira", "Telegram", "GitHub", "Docker", "Python"]

SYNTHETIC = {
    "ru": [
        "Открой Mostik и проверь, как GigaAM распознаёт длинные фразы.",
        "Сравни Whisper и Parakeet на английских записях, а потом напиши мне.",
        "Попроси Claude Code поправить тесты и обновить документацию.",
        "В Kubernetes упал под с базой PostgreSQL, посмотри логи.",
        "Заведи задачу в Jira и скинь ссылку в Telegram.",
        "Выложи ветку на GitHub, собери образ Docker и запусти проверку.",
        "Перепиши скрипт на Python, чтобы он не падал на пустом файле.",
        "Завтра в десять созвон с командой, нужно подготовить три слайда.",
        "Проверь, что вставка работает в браузере и в терминале.",
        "Напомни мне купить молоко, хлеб и яблоки по дороге домой.",
        "Давай обсудим, почему тихие слова пропадают в начале диктовки.",
        "Сделай короткий отчёт: что готово, что сломано и что дальше.",
        "Mostik вставил текст не туда, проверь фокус поля.",
        "Модель GigaAM быстрее, чем Whisper, но хуже знает английский.",
        "Claude Code опять просит разрешение на запуск тестов.",
        "Обнови PostgreSQL до новой версии и перезапусти Docker.",
        "Найди в GitHub задачу про Parakeet и закрой её.",
        "Напиши в Telegram, что релиз переносится на пятницу.",
        "Кластер Kubernetes съел всю память, нужен ещё один узел.",
        "Скрипт на Python читает задачи из Jira и шлёт сводку.",
        "Перенеси встречу на завтра и предупреди всех участников.",
        "Посмотри, почему Whisper пишет английские слова кириллицей.",
        "В Docker не хватает места, почисти старые образы.",
        "Сравни, как Mostik и GigaAM справляются с тихой речью.",
    ],
    "en": [
        "Open Mostik and check how Whisper handles long sentences.",
        "Ask Claude Code to fix the failing tests and update the docs.",
        "The PostgreSQL pod in Kubernetes keeps restarting, check the logs.",
        "Create a Jira ticket and send the link to the team in Telegram.",
        "Push the branch to GitHub, build the Docker image and run the checks.",
        "Rewrite the Python script so it does not crash on an empty file.",
        "Tomorrow at ten we have a call with the team about the release.",
        "Remind me to buy milk, bread and apples on the way home.",
    ],
}


def synthesize(text: str, language: str, folder: Path, index: int) -> np.ndarray:
    path = folder / f"{language}-{index}.wav"
    if not path.exists():
        subprocess.run(
            ["say", "-v", VOICES[language], "-o", str(path), "--file-format=WAVE", "--data-format=LEI16@16000", text],
            check=True, timeout=60,
        )
    return read_wav(path)


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as handle:
        frames = handle.readframes(handle.getnframes())
        channels = handle.getnchannels()
        rate = handle.getframerate()
    audio = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        audio = audio.reshape(-1, channels).mean(axis=1)
    if rate != 16000:
        positions = np.linspace(0, len(audio) - 1, int(len(audio) * 16000 / rate))
        audio = np.interp(positions, np.arange(len(audio)), audio).astype(np.float32)
    return audio


def transcribe(model, audio: np.ndarray, language: str, terms: list[str], variant: str) -> tuple[str, float]:
    kwargs: dict = {"hotwords": verifier_worker._hotwords(terms)}
    if variant in ("norm", "both"):
        audio = peak_normalize(audio)
    if variant in ("prompt", "both"):
        kwargs = {"initial_prompt": build_prompt(language, terms)}
    started = time.monotonic()
    answer = model.generate(audio, language=language, word_timestamps=False, condition_on_previous_text=False,
                            temperature=0.0, verbose=None, **kwargs)
    return str(getattr(answer, "text", "") or "").strip(), time.monotonic() - started


def word_errors(hypothesis: str, reference: str) -> tuple[int, int]:
    a, b = normalize_text(hypothesis).split(), normalize_text(reference).split()
    previous = list(range(len(b) + 1))
    for i, word in enumerate(a, start=1):
        current = [i] + [0] * len(b)
        for j, other in enumerate(b, start=1):
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (word != other))
        previous = current
    return previous[-1], len(b)


def terms_hit(hypothesis: str, reference: str) -> tuple[int, int]:
    expected = [term for term in TERMS if term in reference]
    found = sum(1 for term in expected if re.search(rf"(?<!\w){re.escape(term)}(?!\w)", hypothesis, re.IGNORECASE))
    return found, len(expected)


def has_punctuation(text: str) -> bool:
    return bool(re.search(r"[,.!?]", text))


def summarize(rows: list[dict]) -> dict:
    out: dict = {}
    for variant in VARIANTS:
        picked = [row for row in rows if row["variant"] == variant]
        if not picked:
            continue
        errors = sum(row["errors"] for row in picked)
        words = sum(row["words"] for row in picked)
        hit = sum(row.get("terms_found", 0) for row in picked)
        expected = sum(row.get("terms_expected", 0) for row in picked)
        out[variant] = {
            "windows": len(picked),
            "wer": round(errors / max(1, words), 4),
            "terms": round(hit / expected, 3) if expected else None,
            "punctuated": round(sum(row["punctuated"] for row in picked) / len(picked), 3),
            "empty": sum(1 for row in picked if row["empty"]),
            "seconds_median": round(statistics.median(row["seconds"] for row in picked), 3),
        }
    return out


def run_synthetic(model) -> dict:
    folder = Path(tempfile.gettempdir()) / "mostik-l4-tts"
    folder.mkdir(exist_ok=True)
    rows: list[dict] = []
    for language, sentences in SYNTHETIC.items():
        for index, sentence in enumerate(sentences):
            clean = synthesize(sentence, language, folder, index)
            for level in LEVELS_DB:
                audio = (clean * 10 ** (level / 20)).astype(np.float32)
                for variant in VARIANTS:
                    text, seconds = transcribe(model, audio, language, TERMS, variant)
                    errors, words = word_errors(text, sentence)
                    found, expected = terms_hit(text, sentence)
                    rows.append({"language": language, "level_db": level, "variant": variant, "errors": errors,
                                 "words": words, "terms_found": found, "terms_expected": expected,
                                 "punctuated": has_punctuation(text), "empty": not text, "seconds": seconds})
    report = {"all": summarize(rows)}
    for language in SYNTHETIC:
        for level in LEVELS_DB:
            report[f"{language} {level:+.0f} dB"] = summarize(
                [row for row in rows if row["language"] == language and row["level_db"] == level])
    return report


def run_handy(model, count: int) -> dict:
    from run_bench import HANDY, handy_texts

    texts = handy_texts()
    # Только записи короче одного окна Whisper: текст Handy — за всю запись.
    files = [path for path in sorted((HANDY / "recordings").glob("handy-*.wav"))
             if path.name in texts and 2.0 <= len(read_wav(path)) / 16000 <= 28.0][-count:]
    rows: list[dict] = []
    peaks: list[float] = []
    for path in files:
        audio = read_wav(path)
        peaks.append(float(np.max(np.abs(audio))) if audio.size else 0.0)
        reference = texts[path.name]
        for variant in VARIANTS:
            text, seconds = transcribe(model, audio, "ru", [], variant)
            errors, words = word_errors(text, reference)
            rows.append({"variant": variant, "errors": errors, "words": words, "punctuated": has_punctuation(text),
                         "empty": not text, "seconds": seconds})
    peaks_db = [20 * np.log10(peak) for peak in peaks if peak > 0]
    return {"files": len(files), "peak_dbfs_median": round(float(np.median(peaks_db)), 1) if peaks_db else None,
            "vs_handy": summarize(rows)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--synthetic", action="store_true")
    parser.add_argument("--handy", type=int, default=0)
    args = parser.parse_args()
    started = time.monotonic()
    model = verifier_worker._load_model("whisper")
    print(f"Whisper загружен за {time.monotonic() - started:.1f} с", file=sys.stderr)
    report: dict = {}
    # Самая длинная подсказка в токенах: Whisper держит не больше 223.
    tokenizer = model.get_tokenizer(language="ru")
    longest = build_prompt("ru", [f"Термин{i}" for i in range(100)] + ["Jira Service Desk"] * 3)
    report["prompt_tokens_max"] = len(tokenizer.encode(" " + longest))
    if args.synthetic:
        report["synthetic"] = run_synthetic(model)
    if args.handy:
        report["handy"] = run_handy(model, args.handy)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "whisper-hint.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
