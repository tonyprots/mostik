"""Отчёт о сбое движка (П8, пункт 6): только локально, без текста диктовки."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from mostik_engine import crash_report

ENGINE_DIR = Path(__file__).resolve().parents[1]


def _boom(text: str) -> None:
    secret = text  # noqa: F841 — локальная переменная не должна попасть в отчёт
    raise ValueError(f"не разобрал фразу '{text}' в окне 3")


PHRASE = "купить молоко и позвонить маме"


def test_report_has_frames_but_no_dictation_text(tmp_path: Path) -> None:
    # Строки кода в отчёте есть, поэтому фраза приходит переменной, как из диктовки.
    try:
        _boom(PHRASE)
    except ValueError as error:
        path = crash_report.write(error, "0.1", directory=tmp_path, when=1_791_741_600)
    assert path is not None and path.name.startswith("engine-2026-10-") and path.suffix == ".txt"
    text = path.read_text(encoding="utf-8")
    assert "никуда не отправляется" in text
    assert "builtins.ValueError" in text
    assert "_boom" in text and "test_crash_report.py" in text
    assert "молоко" not in text, "текст в кавычках из сообщения вырезан"
    assert "«…»" in text and "в окне 3" in text


def test_redact_and_limit() -> None:
    assert crash_report.redact('нет "секрет" и «тайна»\nдальше') == "нет «…» и «…» дальше"
    assert len(crash_report.redact("x" * 1000)) == 301


def test_prune_keeps_latest(tmp_path: Path) -> None:
    for day in range(1, 26):
        (tmp_path / f"engine-2026-10-{day:02d}-120000-pid1.txt").write_text("x")
    (tmp_path / "notes.md").write_text("чужое")
    crash_report.prune(tmp_path, keep=20)
    left = sorted(p.name for p in tmp_path.iterdir())
    assert len(left) == 21 and "notes.md" in left
    assert "engine-2026-10-01-120000-pid1.txt" not in left
    assert "engine-2026-10-25-120000-pid1.txt" in left


def test_no_dir_no_report(monkeypatch) -> None:
    monkeypatch.delenv("MOSTIK_CRASH_DIR", raising=False)
    assert crash_report.write(RuntimeError("x"), "0.1") is None


def test_engine_crash_writes_report(tmp_path: Path) -> None:
    """Сквозной: исключение в главном цикле движка → отчёт в MOSTIK_CRASH_DIR, код выхода ≠ 0."""
    crashes = tmp_path / "crashes"
    script = (
        "import sys\n"
        "from mostik_engine import server\n"
        "import os\n"
        "def boom(self, stream):\n"
        "    raise RuntimeError(f\"сломалось на '{os.environ['PHRASE']}'\")\n"
        "server.Engine.run = boom\n"
        "sys.exit(server.main())\n"
    )
    env = dict(os.environ, PHRASE="секретной фразе", MOSTIK_CRASH_DIR=str(crashes), MOSTIK_HOME=str(tmp_path / "home"),
               PYTHONPATH=str(ENGINE_DIR))
    proc = subprocess.run([sys.executable, "-c", script], env=env, input="", capture_output=True,
                          text=True, timeout=120, cwd=ENGINE_DIR)
    assert proc.returncode != 0
    reports = list(crashes.glob("engine-*.txt"))
    assert len(reports) == 1, proc.stderr[-2000:]
    text = reports[0].read_text(encoding="utf-8")
    assert "boom" in text and "секретной" not in text
    assert "отчёт о сбое" in proc.stderr


# --- П10 С6: в engine.log нет текста пользователя ------------------------------------------

def test_safe_traceback_keeps_frames_and_hides_quoted_text() -> None:
    try:
        try:
            _boom(PHRASE)
        except ValueError as inner:
            raise RuntimeError(f"сбой правки «{PHRASE}»") from inner
    except RuntimeError:
        text = crash_report.safe_traceback()
    assert PHRASE not in text
    assert "_boom" in text and "ValueError" in text and "RuntimeError" in text
    assert crash_report.describe(ValueError(f"'{PHRASE}'")) == "ValueError: «…»"


def test_engine_modules_never_log_raw_traceback() -> None:
    """Сырой `traceback.format_exc()` несёт сообщение исключения целиком — с текстом диктовки."""
    offenders = []
    for path in sorted((ENGINE_DIR / "mostik_engine").glob("*.py")):
        if path.name == "crash_report.py":
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if "format_exc(" in line or "print_exc(" in line or "format_exception(" in line:
                offenders.append(f"{path.name}:{number}")
    assert offenders == []


def test_ask_logs_status_and_length_not_the_answer(capsys) -> None:
    from mostik_engine import ask, index as ix
    from test_ask import FakeBackend

    secret = "Иван получит премию в 300 тысяч"
    hit = ix.Hit(chunk_id=1, kind=ix.KIND_SOURCE, ref="a.md:1", title="a", text="премия", context="",
                 path="/tmp/a.md", root="/tmp", file_title="a", date=None, line=1, turn=None, speaker=None, at=None)

    class Fixed:
        def search(self, query, *, scope="all", k=8):
            return [hit]

    for backend in (FakeBackend(f"Ответ без тегов: {secret}"),
                    FakeBackend(error=ValueError(f"не разобрал '{secret}'"))):
        ask.answer("Какая премия?", retriever=Fixed(), backend=backend, consent=True)
        assert secret not in capsys.readouterr().err
