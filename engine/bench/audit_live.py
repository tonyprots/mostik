"""Живая проверка находок ревью 2026-11-14 на настоящих моделях.

Поднимает настоящий процесс движка (свой `MOSTIK_HOME` во временной папке — личные словари,
история и встречи пользователя не читаются) и гоняет через протокол синтетический звук:
фразы озвучивает `say` (Milena — ru, Samantha — en), вслух ничего не играет, в 16 кГц
переводит ffmpeg. Модели берутся из кэша Hugging Face, как у приложения; сеть не нужна.

Нужен Python с `onnx_asr` и `mlx_audio` — venv разработки или встроенный Python выпуска:

    /Applications/Mostik.app/Contents/Resources/python/bin/python3 -B -I engine/bench/audit_live.py all
    .venv/bin/python bench/audit_live.py t15 t16          # выборочно

Сценарии (номер — находка отчёта): t10 стык окон, t13 короткое слово в конце, t14 тишина и шум
в английском, t15 автоязык при холодном Whisper, t16 число процессов Whisper, e11 миграция встреч
и диктовка, e12 `hello` и чтение WAV не держат команды, e18 фон локальной модели под диктовкой.
Каждый печатает цифры и итог `ok`/`FAIL`; код возврата — число проваленных.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path

ENGINE = Path(__file__).resolve().parent.parent
BOOTSTRAP = ("import sys, runpy; d, m = sys.argv[1], sys.argv[2]; del sys.argv[1:3]; "
             "sys.path.insert(0, d); runpy.run_module(m, run_name='__main__', alter_sys=True)")
SR = 16_000
FRAME = SR // 10  # 100 мс
VOICES = {"ru": "Milena", "en": "Samantha"}
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
WORK = Path(tempfile.gettempdir()) / "mostik-audit-live"


# --- звук ------------------------------------------------------------------------------------

def speak(text: str, language: str, rate: int | None = None, trim: bool = False) -> bytes:
    """Фраза → PCM int16 16 кГц моно. Файл кэшируется во временной папке; вслух не играется.

    `rate` — слов в минуту (быстро брошенное слово), `trim` — без тишины по краям."""
    WORK.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha1(f"{VOICES[language]}|{rate}|{text}".encode()).hexdigest()[:16]
    target = WORK / f"say-{key}.wav"
    if not target.exists():
        aiff = target.with_suffix(".aiff")
        subprocess.run(["say", "-v", VOICES[language], *(["-r", str(rate)] if rate else []), "-o", str(aiff), text],
                       check=True)
        subprocess.run([FFMPEG, "-loglevel", "error", "-y", "-i", str(aiff), "-ar", str(SR), "-ac", "1",
                        "-c:a", "pcm_s16le", str(target)], check=True)
        aiff.unlink()
    with wave.open(str(target), "rb") as handle:
        pcm = handle.readframes(handle.getnframes())
    if trim:
        samples = struct.unpack(f"<{len(pcm) // 2}h", pcm)
        loud = [index for index, value in enumerate(samples) if abs(value) > 650]
        pcm = pcm[max(0, loud[0] - 800) * 2: loud[-1] * 2] if loud else pcm
    return pcm


def silence(seconds: float) -> bytes:
    return bytes(int(seconds * SR) * 2)


def noise(seconds: float, amplitude: float, seed: int = 7) -> bytes:
    rng = random.Random(seed)
    peak = int(amplitude * 32767)
    return struct.pack(f"<{int(seconds * SR)}h", *(rng.randint(-peak, peak) for _ in range(int(seconds * SR))))


def clicks(seconds: float, every: float = 0.7, amplitude: float = 0.5) -> bytes:
    """Щелчки клавиш: по 4 мс затухающего шума на тишине."""
    rng = random.Random(3)
    samples = [0] * int(seconds * SR)
    at = int(0.3 * SR)
    while at + 64 < len(samples):
        for offset in range(64):
            samples[at + offset] = int(rng.uniform(-1, 1) * amplitude * 32767 * (1 - offset / 64))
        at += int(every * SR)
    return struct.pack(f"<{len(samples)}h", *samples)


def seconds_of(pcm: bytes) -> float:
    return len(pcm) / 2 / SR


# --- процесс движка ----------------------------------------------------------------------------

class Engine:
    def __init__(self, name: str, env: dict | None = None) -> None:
        self.home = Path(tempfile.mkdtemp(prefix=f"home-{name}-", dir=str(WORK)))
        self.log_path = self.home / "engine.stderr.log"
        self._log = open(self.log_path, "w", encoding="utf-8")
        full_env = dict(os.environ, MOSTIK_HOME=str(self.home), MOSTIK_IMPORT_TRANSCRIBER="0", **(env or {}))
        self.process = subprocess.Popen(
            [sys.executable, "-B", "-I", "-u", "-c", BOOTSTRAP, str(ENGINE), "mostik_engine"],
            cwd=str(ENGINE), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self._log,
            text=True, bufsize=1, env=full_env,
        )
        self.events: list[tuple[float, dict]] = []
        self._ids = 0
        self._write = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        for line in self.process.stdout:
            try:
                self.events.append((time.monotonic(), json.loads(line)))
            except ValueError:
                pass

    def send(self, **command) -> int | None:
        with self._write:
            self.process.stdin.write(json.dumps(command, ensure_ascii=False) + "\n")
            self.process.stdin.flush()
        return command.get("id")

    def call(self, cmd: str, **fields) -> int:
        self._ids += 1
        self.send(cmd=cmd, id=self._ids, **fields)
        return self._ids

    def wait(self, predicate, timeout: float = 120.0) -> tuple[float, dict]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for at, event in list(self.events):
                if predicate(event):
                    return at, event
            if self.process.poll() is not None:
                break
            time.sleep(0.01)
        raise AssertionError(f"нет события за {timeout:.0f} с; последние: {[e for _, e in self.events[-4:]]}")

    def answer(self, command_id: int, timeout: float = 120.0) -> tuple[float, dict]:
        return self.wait(lambda event: event.get("id") == command_id, timeout)

    def stream(self, session: str, pcm: bytes, *, realtime: bool = True) -> None:
        """Звук кадрами по 100 мс, в темпе речи: окна и определение языка идут как при диктовке."""
        step = FRAME * 2
        started = time.monotonic()
        for number, at in enumerate(range(0, len(pcm), step)):
            self.send(cmd="audio", session=session, pcm=base64.b64encode(pcm[at:at + step]).decode("ascii"))
            if realtime:
                time.sleep(max(0.0, started + (number + 1) * 0.1 - time.monotonic()))

    def dictate(self, session: str, pcm: bytes, *, language: str = "ru", realtime: bool = True,
                wait_ms: int = 500, **start) -> dict:
        """Одна диктовка целиком; к `final` добавлено `wall_s` — от `stop` до ответа."""
        self.answer(self.call("start", session=session, language=language, **start))
        self.stream(session, pcm, realtime=realtime)
        stopped = time.monotonic()
        stop_id = self.call("stop", session=session, wait_verifier_ms=wait_ms)
        at, final = self.wait(lambda e: e.get("id") == stop_id or (e.get("session") == session and e.get("event") in ("final", "error")))
        final["wall_s"] = round(at - stopped, 2)
        return final

    def log(self) -> str:
        self._log.flush()
        return self.log_path.read_text(encoding="utf-8", errors="replace")

    def workers(self) -> dict[str, list[int]]:
        """Живые дочерние процессы моделей по журналу запуска: {'whisper': [pid…], 'parakeet': […]}."""
        alive: dict[str, list[int]] = {}
        for model, pid in re.findall(r"запущен процесс (\w+), pid (\d+)", self.log()):
            try:
                os.kill(int(pid), 0)
            except OSError:
                continue
            alive.setdefault(model, []).append(int(pid))
        return alive

    def rss_mb(self) -> dict[int, int]:
        pids = [self.process.pid, *(pid for group in self.workers().values() for pid in group)]
        out = subprocess.run(["ps", "-o", "pid=,rss=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
        return {int(line.split()[0]): int(line.split()[1]) // 1024 for line in out.splitlines() if line.strip()}

    def close(self) -> None:
        try:
            self.call("shutdown")
            self.process.wait(timeout=20)
        except Exception:  # noqa: BLE001
            self.process.kill()
        self._log.close()


# --- сценарии ----------------------------------------------------------------------------------

RESULTS: list[tuple[str, bool, str]] = []


def report(name: str, ok: bool, detail: str) -> None:
    RESULTS.append((name, ok, detail))
    print(f"[{'ok' if ok else 'FAIL'}] {name}: {detail}", flush=True)


def words(text: str) -> list[str]:
    return re.findall(r"[0-9a-zа-яё]+", text.lower())


def t10() -> None:
    """Стык окон: пауза между предложениями — настоящая граница, точка остаётся."""
    engine = Engine("t10")
    try:
        cases = [
            (["Я отправил отчёт.", "Его посмотрит Маша."], 0.8, ["отчёт. Его"]),
            (["Сделаем это завтра.", "Если не получится, перенесём на пятницу."], 0.8, ["завтра. Если"]),
            (["Мы обсудили бюджет.", "Их предложение лучше нашего."], 0.8, ["бюджет. Их"]),
        ]
        for number, (phrases, pause, expected) in enumerate(cases):
            pcm = silence(0.3) + silence(pause).join(speak(p, "ru") for p in phrases) + silence(0.5)
            final = engine.dictate(f"t10-{number}", pcm, verify=False)
            text = final.get("text", "")
            ok = final.get("stats", {}).get("windows", 0) >= 2 and all(part in text for part in expected)
            report(f"t10 стык {number}", ok, f"окон {final.get('stats', {}).get('windows')}, текст: {text!r}")
    finally:
        engine.close()


def t13() -> None:
    """Короткое слово после паузы в самом конце записи доходит до текста."""
    engine = Engine("t13")
    try:
        for number, (head, tail, language) in enumerate([
            ("Отправь отчёт завтра утром.", "Да.", "ru"),
            ("Проверь почту и календарь на сегодня.", "Всё.", "ru"),
            ("Send the report tomorrow morning.", "Yes.", "en"),
        ]):
            # Окно с первой фразой успевает закрыться (пауза 2 с), короткое слово — прямо перед stop.
            pcm = silence(0.3) + speak(head, language) + silence(2.0) + speak(tail, language) + silence(0.15)
            final = engine.dictate(f"t13-{number}", pcm, language=language, verify=False)
            text = final.get("text", "")
            ok = words(tail)[0] in words(text)
            report(f"t13 хвост {number}", ok, f"слово {tail!r} в тексте: {text!r} (окон {final.get('stats', {}).get('windows')})")
        # Слово брошено быстро, и клавишу отпустили сразу: VAD его не видит (короче 250 мс речи).
        for number, (head, tail, language, pause) in enumerate([
            ("Отправь отчёт завтра утром.", "Да.", "ru", 2.0),
            ("Проверь почту и календарь на сегодня.", "Нет.", "ru", 0.9),
            ("Отправь отчёт завтра утром.", "Всё.", "ru", 3.5),
            ("Send the report tomorrow morning.", "Yes.", "en", 2.0),
        ]):
            pcm = silence(0.3) + speak(head, language) + silence(pause) + speak(tail, language, rate=340, trim=True)
            final = engine.dictate(f"t13-fast-{number}", pcm, language=language, verify=False)
            text = final.get("text", "")
            ok = words(tail)[0] in words(text)
            report(f"t13 быстрое слово {number}", ok,
                   f"слово {tail!r} после паузы {pause} с в тексте: {text!r} (окон {final.get('stats', {}).get('windows')})")
        # Контроль: после фразы только тишина или щелчок клавиши — лишнего текста нет.
        for number, (label, tail) in enumerate([("тишина", silence(1.0)), ("щелчок", clicks(0.5, every=5.0))]):
            pcm = silence(0.3) + speak("Отправь отчёт завтра утром.", "ru") + silence(1.5) + tail
            final = engine.dictate(f"t13-ctl-{number}", pcm, language="ru", verify=False)
            text = final.get("text", "")
            report(f"t13 контроль: {label} в конце", words(text) == words("Отправь отчёт завтра утром."), f"текст: {text!r}")
    finally:
        engine.close()


def t14() -> None:
    """Английский (основная — Whisper): тишина, шум и щелчки не дают текста."""
    engine = Engine("t14")
    try:
        engine.answer(engine.call("warmup", language="en", verify=False), 180)
        sounds = {
            "тишина 3 с": silence(3.0),
            "шум -50 дБ 3 с": noise(3.0, 0.003),
            "шум -30 дБ 4 с": noise(4.0, 0.03),
            "щелчки клавиш 4 с": clicks(4.0),
            "гул 100 Гц 4 с": struct.pack(f"<{4 * SR}h", *(int(3000 * __import__('math').sin(2 * 3.14159 * 100 * i / SR)) for i in range(4 * SR))),
        }
        for number, (label, pcm) in enumerate(sounds.items()):
            final = engine.dictate(f"t14-{number}", pcm, language="en", verify=False)
            text = final.get("text", "")
            report(f"t14 {label}", not text.strip(), f"текст: {text!r}, окон {final.get('stats', {}).get('windows')}")
        # Контроль: настоящая речь, в том числе тихая (−30 дБ), не теряется.
        phrase = speak("Please check the calendar and send me the report.", "en")
        quiet = struct.pack(f"<{len(phrase) // 2}h", *(int(s * 0.03) for s in struct.unpack(f"<{len(phrase) // 2}h", phrase)))
        for label, pcm in (("речь", phrase), ("тихая речь −30 дБ", quiet)):
            final = engine.dictate(f"t14-{label}", silence(0.3) + pcm + silence(0.5), language="en", verify=False)
            text = final.get("text", "")
            ok = {"calendar", "report"} <= set(words(text))
            report(f"t14 контроль: {label}", ok, f"текст: {text!r}")
    finally:
        engine.close()


def t15() -> None:
    """Автоязык: Whisper холодный (процесс поднимается на `start`), язык по умолчанию — другой."""
    cases = [
        ("en-длинная", "en", "ru", "Please check the calendar and send me the report by Friday."),
        ("en-короткая", "en", "ru", "Send the report."),
        ("ru-длинная", "ru", "en", "Проверь, пожалуйста, календарь и пришли мне отчёт до пятницы."),
        ("ru-короткая", "ru", "en", "Пришли отчёт."),
    ]
    for label, spoken, default, phrase in cases:
        engine = Engine("t15")  # каждый раз новый движок: Whisper не загружен
        try:
            pcm = silence(0.2) + speak(phrase, spoken) + silence(0.4)
            final = engine.dictate(f"t15-{label}", pcm, language=default, languages=["ru", "en"], verify=True)
            info = final.get("language_detect") or {}
            load = re.findall(r"whisper загружен за ([\d.]+) с", engine.log())
            expected = set(words(phrase))
            got = set(words(final.get("text", "")))
            overlap = len(expected & got) / max(1, len(expected))
            ok = final.get("language") == spoken and overlap >= 0.6
            report(f"t15 холодный {label}", ok,
                   f"язык {final.get('language')} (ждали {spoken}), звук {seconds_of(pcm):.1f} с, загрузка Whisper {load or '—'} с, "
                   f"detect {json.dumps(info, ensure_ascii=False)}, хвост {final.get('wall_s')} с, текст: {final.get('text', '')!r}")
            # Тот же движок, Whisper уже в памяти: тёплый путь не должен стать медленнее.
            final = engine.dictate(f"t15-{label}-warm", pcm, language=default, languages=["ru", "en"], verify=True)
            info = final.get("language_detect") or {}
            report(f"t15 тёплый {label}", final.get("language") == spoken,
                   f"язык {final.get('language')}, detect {info.get('ms')} мс, откат {info.get('fallback')}, хвост {final.get('wall_s')} с")
        finally:
            engine.close()


def t16() -> None:
    """Двуязычная работа: русская диктовка с проверяющей и определением языка, затем английская."""
    engine = Engine("t16")
    try:
        ru = silence(0.2) + speak("Проверь, пожалуйста, календарь и пришли мне отчёт до пятницы.", "ru") + silence(0.4)
        en = silence(0.2) + speak("Please check the calendar and send me the report by Friday.", "en") + silence(0.4)
        first = engine.dictate("t16-ru", ru, language="ru", languages=["ru", "en"], verify=True, wait_ms=5000)
        second = engine.dictate("t16-en", en, language="ru", languages=["ru", "en"], verify=True, wait_ms=5000)
        third = engine.dictate("t16-ru2", ru, language="ru", languages=["ru", "en"], verify=True, wait_ms=5000)
        alive = engine.workers()
        rss = engine.rss_mb()
        whisper = alive.get("whisper", [])
        detail = (f"процессов Whisper {len(whisper)}, Parakeet {len(alive.get('parakeet', []))}; память МБ: "
                  f"движок {rss.get(engine.process.pid)}, Whisper {[rss.get(pid) for pid in whisper]}, "
                  f"Parakeet {[rss.get(pid) for pid in alive.get('parakeet', [])]}; "
                  f"языки {first.get('language')}/{second.get('language')}/{third.get('language')}, "
                  f"проверяющая {first.get('verifier')}/{second.get('verifier')}/{third.get('verifier')}, "
                  f"хвост {first.get('wall_s')}/{second.get('wall_s')}/{third.get('wall_s')} с")
        ok = (len(whisper) == 1 and (first.get("language"), second.get("language"), third.get("language")) == ("ru", "en", "ru")
              and "report" in words(second.get("text", "")) and "отчёт" in words(third.get("text", "")))
        report("t16 один Whisper на все роли", ok, detail)
        print(f"    тексты: {first.get('text')!r} | {second.get('text')!r} | {third.get('text')!r}")
    finally:
        engine.close()


def e11() -> None:
    """Миграция встреч (сотни папок с расшифровками) не задерживает диктовку."""
    root = Path(tempfile.mkdtemp(prefix="meetings-", dir=str(WORK)))
    engine = Engine("e11")
    try:
        # Синтетические «старые встречи»: расшифровка ~1 МБ, манифеста нет — миграции есть что читать и писать.
        segments = [{"start": i * 4.0, "end": i * 4.0 + 3.5, "speaker": "Собеседник 1",
                     "text": "Синтетическая реплика для проверки миграции, номер " + str(i)} for i in range(7000)]
        blob = json.dumps({"title": "Синтетическая встреча", "language": "ru", "duration_seconds": 28000,
                           "attendees": ["Проверка"], "segments": segments}, ensure_ascii=False)
        count = 300
        for number in range(count):
            folder = root / f"2026-01-{number % 28 + 1:02d}-{100000 + number}"
            folder.mkdir()
            (folder / "transcript.json").write_text(blob, encoding="utf-8")
        pcm = silence(0.3) + speak("Проверь почту и календарь на сегодня.", "ru") + silence(0.5)
        baseline = engine.dictate("e11-base", pcm, verify=False)  # заодно модели в памяти
        migrate_at = time.monotonic()
        migrate_id = engine.call("meetings_migrate", root=str(root))
        final = engine.dictate("e11-busy", pcm, verify=False)
        final_at = time.monotonic()
        done_at, stats = engine.answer(migrate_id, 600)
        seconds = done_at - migrate_at
        ok = final["wall_s"] <= baseline["wall_s"] + 1.0 and stats.get("migrated") == count
        report("e11 диктовка во время миграции", ok,
               f"миграция {count} встреч ({len(blob) // 1024} КБ каждая) — {seconds:.1f} с; хвост диктовки {final['wall_s']} с "
               f"(без миграции {baseline['wall_s']} с); final пришёл {'до' if final_at < done_at else 'после'} конца миграции; "
               f"итог миграции {({k: v for k, v in stats.items() if k in ('scanned', 'migrated', 'errors')})}")
    finally:
        engine.close()
        shutil.rmtree(root, ignore_errors=True)


def e12() -> None:
    """`hello` (статус `claude`) и чтение большого WAV не держат цикл команд."""
    engine = Engine("e12")
    big = WORK / "e12-big-48k-stereo.wav"
    try:
        sent = time.monotonic()
        hello_id = engine.call("hello")
        next_id = engine.call("glossary_list")
        next_at, _ = engine.answer(next_id, 60)
        hello_at, hello = engine.answer(hello_id, 60)
        polish = {name: status.get("available") for name, status in (hello.get("polish") or {}).items()}
        report("e12 hello не держит следующую команду", next_at - sent < 0.5,
               f"hello ответил через {hello_at - sent:.2f} с, команда следом — через {next_at - sent:.2f} с; причёсывание {polish}")
        if not big.exists():  # 20 минут 48 кГц стерео: чтение и пересчёт частоты — заметные секунды
            subprocess.run([FFMPEG, "-loglevel", "error", "-y", "-f", "lavfi", "-i", "anoisesrc=r=48000:a=0.0005:d=1200",
                            "-ac", "2", "-c:a", "pcm_s16le", str(big)], check=True)
        sent = time.monotonic()
        file_id = engine.call("transcribe_file", path=str(big), session="e12-file", language="ru", verify=False)
        next_id = engine.call("glossary_list")
        next_at, _ = engine.answer(next_id, 120)
        pcm = silence(0.3) + speak("Проверь почту и календарь на сегодня.", "ru") + silence(0.5)
        final = engine.dictate("e12-live", pcm, verify=False)
        read = re.findall(r"e12-file: WAV прочитан за ([\d.]+) с", engine.log())
        report("e12 чтение WAV не держит следующую команду", next_at - sent < 0.5,
               f"файл {big.stat().st_size // 2**20} МБ; команда следом ответила через {next_at - sent:.2f} с"
               + (f", чтение файла заняло {read[0]} с" if read else "")
               + f"; диктовка поверх: {final.get('text', '')!r}, хвост {final['wall_s']} с")
        file_at, file_final = engine.answer(file_id, 900)
        report("e12 файл дочитан и расшифрован", file_final.get("event") == "final",
               f"final через {file_at - sent:.1f} с, звук {file_final.get('timings', {}).get('audio_s')} с, текст {file_final.get('text', '')!r}")
    finally:
        engine.close()


def e13() -> None:
    """Перевод на английский: старт на en, человек говорит по-русски — текст всё равно переводится."""
    engine = Engine("e13")
    try:
        _, hello = engine.answer(engine.call("hello"), 60)
        mlx = (hello.get("polish") or {}).get("mlx") or {}
        if not mlx.get("available"):
            report("e13 перевод после смены языка", False, f"локальная модель недоступна: {mlx}")
            return
        engine.answer(engine.call("warmup", language="ru", verify=False, polish={"backend": "mlx"}), 180)
        pcm = silence(0.2) + speak("Проверь, пожалуйста, календарь и пришли мне отчёт до пятницы.", "ru") + silence(0.5)
        polish = {"backend": "mlx", "style": "plain", "translate": {"to": "en"}, "timeout_s": 60}
        for label in ("первая (модель грузится)", "вторая"):
            final = engine.dictate(f"e13-{label[:6]}", pcm, language="en", languages=["ru", "en"], verify=False, polish=polish)
            text = final.get("text", "")
            latin = len(re.findall(r"[A-Za-z]", text))
            cyrillic = len(re.findall(r"[А-Яа-яЁё]", text))
            ok = final.get("language") == "ru" and final.get("polished") is True and latin > 5 * max(1, cyrillic)
            report(f"e13 перевод после смены языка, {label}", ok,
                   f"язык {final.get('language')}, причёсывание {(final.get('polish') or {}).get('status')}, "
                   f"до: {final.get('unpolished_text', '')!r}, после: {text!r}, хвост {final['wall_s']} с")
    finally:
        engine.close()


def e18() -> None:
    """Фоновый запрос локальной модели (кусок сводки встречи) переживает паузу под диктовку."""
    os.environ["MOSTIK_HOME"] = tempfile.mkdtemp(prefix="home-e18-", dir=str(WORK))
    sys.path.insert(0, str(ENGINE))
    from mostik_engine import llm_mlx
    from mostik_engine import polish as P

    backend = llm_mlx.MlxBackend()
    try:
        status = backend.status()
        if not status.get("available"):
            report("e18 фон под паузой диктовки", False, f"локальная модель недоступна: {status}")
            return
        backend.warm()
        if not backend.client.wait_ready(180):
            report("e18 фон под паузой диктовки", False, "модель не загрузилась за 180 с")
            return
        system = "Перескажи встречу одним коротким предложением."
        user = "<transcript>\nМаша: релиз переносим на пятницу. Петя: согласен, тесты допишу к четвергу.\n</transcript>"
        started = time.monotonic()
        plain = backend.complete(system, user, 60)
        cost = time.monotonic() - started
        timeout, hold_s = max(4.0, cost * 3), max(4.0, cost * 3) + 4.0
        release = backend.hold("e18-dictation")  # идёт диктовка: фон процесса стоит
        threading.Timer(hold_s, release).start()
        started = time.monotonic()
        try:
            answer = backend.complete(system, user, timeout)
            outcome = f"ответ через {time.monotonic() - started:.1f} с: {answer.strip()[:80]!r}"
            ok = time.monotonic() - started >= hold_s
        except P.PolishError as error:
            outcome = f"{type(error).__name__} через {time.monotonic() - started:.1f} с: {error}"
            ok = False
        report("e18 фон под паузой диктовки", ok,
               f"без паузы запрос занял {cost:.1f} с ({plain.strip()[:60]!r}); срок {timeout:.1f} с, пауза {hold_s:.1f} с → {outcome}")
    finally:
        backend.stop()


SCENARIOS = {"t10": t10, "t13": t13, "t14": t14, "t15": t15, "t16": t16, "e11": e11, "e12": e12, "e13": e13, "e18": e18}


def main(argv: list[str]) -> int:
    names = argv or ["all"]
    if names == ["all"]:
        names = list(SCENARIOS)
    unknown = [name for name in names if name not in SCENARIOS]
    if unknown:
        print(f"нет сценария: {', '.join(unknown)}; есть: {', '.join(SCENARIOS)}")
        return 2
    WORK.mkdir(parents=True, exist_ok=True)
    for name in names:
        print(f"--- {name}: {SCENARIOS[name].__doc__.strip().splitlines()[0]}", flush=True)
        try:
            SCENARIOS[name]()
        except Exception as error:  # noqa: BLE001 — один сценарий не отменяет остальные
            report(name, False, f"сценарий упал: {type(error).__name__}: {error}")
    failed = [name for name, ok, _ in RESULTS if not ok]
    print(f"\nитог: {len(RESULTS) - len(failed)} из {len(RESULTS)} ok" + (f"; провалы: {', '.join(failed)}" if failed else ""))
    return len(failed)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
