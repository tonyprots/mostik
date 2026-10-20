"""Словарь проекта на временном репозитории."""
from __future__ import annotations

import json
import os
import time

from mostik_engine import project_glossary as pg


def make_repo(root):
    (root / "src").mkdir(parents=True)
    (root / "node_modules" / "junk").mkdir(parents=True)
    (root / "src" / "engine_client.py").write_text(
        "class EngineClient:\n    def load_vad(self):\n        return EngineClient()\n\n"
        "def reconcile_windows():\n    pass\n",
        encoding="utf-8",
    )
    (root / "src" / "Paster.swift").write_text(
        "struct PasteOutcome {}\nfinal class ClipboardSnapshot {}\nfunc insertText() {}\n",
        encoding="utf-8",
    )
    (root / "node_modules" / "junk" / "index.js").write_text("function hiddenThing() {}\n")
    (root / "README.md").write_text("# Mostik Engine\n\n## Silero и GigaAM\n\ntext\n", encoding="utf-8")
    (root / "package.json").write_text(
        json.dumps({"dependencies": {"@tauri-apps/api": "1", "zustand": "4"}}), encoding="utf-8"
    )
    (root / "pyproject.toml").write_text(
        '[project]\nname = "x"\ndependencies = ["onnx-asr>=0.7", "mlx_audio"]\n', encoding="utf-8"
    )


def test_terms_from_code_headings_and_dependencies(tmp_path):
    make_repo(tmp_path)
    result = pg.build(tmp_path)
    terms = set(result["terms"])
    # Целые имена и их части.
    assert {"EngineClient", "load_vad", "reconcile_windows", "PasteOutcome", "ClipboardSnapshot"} <= terms
    assert {"vad", "Paste", "Outcome", "Clipboard", "Snapshot"} <= terms
    assert "engine_client" in terms  # имя файла-модуля
    # Заголовки и зависимости.
    assert {"Mostik", "Silero", "GigaAM"} <= terms
    assert {"zustand", "onnx-asr", "mlx_audio"} <= terms
    # Исключённые каталоги и общеупотребительные слова.
    assert "hiddenThing" not in terms
    assert not terms & {"load", "client", "engine", "text", "class", "self"}
    assert "reconcile" not in terms  # строчная часть имени — обычное английское слово
    assert result["count"] == len(result["terms"])


def test_frequency_order_and_limit(tmp_path):
    make_repo(tmp_path)
    result = pg.build(tmp_path, limit=3)
    assert result["count"] == 3
    assert "EngineClient" in result["terms"]


def test_cache_reuses_unchanged_files_and_sees_changes(tmp_path):
    make_repo(tmp_path)
    first = pg.build(tmp_path)
    assert first["reused"] == 0
    assert pg.cache_path(tmp_path.resolve()).is_file()
    second = pg.build(tmp_path)
    assert second["reused"] == first["files"]
    assert second["terms"] == first["terms"]
    target = tmp_path / "src" / "engine_client.py"
    target.write_text("class TranscriptMerger:\n    pass\n", encoding="utf-8")
    later = time.time() + 5
    os.utime(target, (later, later))
    third = pg.build(tmp_path)
    assert third["reused"] == first["files"] - 1
    assert "TranscriptMerger" in third["terms"]
    assert "EngineClient" not in third["terms"]


def test_speed_on_generated_50k_lines(tmp_path):
    for module in range(100):
        lines = []
        for index in range(100):
            lines.append(f"def handler_{module}_{index}(value):\n    return compute_{index}(value)\n")
            lines.append(f"class Model{module}x{index}:\n    pass\n")
        (tmp_path / f"module_{module}.py").write_text("\n".join(lines * 1), encoding="utf-8")
    started = time.monotonic()
    result = pg.build(tmp_path)
    assert time.monotonic() - started < 10
    assert result["count"] == pg.LIMIT


def test_project_glossaries_memory(tmp_path):
    make_repo(tmp_path)
    memory = pg.ProjectGlossaries()
    assert memory.terms(None) == []
    terms = memory.terms(str(tmp_path))
    assert "EngineClient" in terms
    assert memory.terms(str(tmp_path / "missing")) == []


def test_docs_folder_skips_code(tmp_path):
    """Папка документов: ни кода, ни репозиториев внутри, ни `спанов`, ни имён файлов."""
    (tmp_path / "Заметки.md").write_text(
        "# Встреча с Борисом про Альфу\n\n"
        "Обсудили релиз Телемоста, правим `load_vad` в app.js и main.py.\n"
        "Переименовать insertText и reconcile_windows, ClickHouse оставить.\n\n"
        "```python\nclass HiddenFence:\n    pass\n```\n",
        encoding="utf-8",
    )
    make_repo(tmp_path / "code" / "mostik")
    (tmp_path / "code" / "mostik" / "README.md").write_text("# RepoOnlyTitle\n", encoding="utf-8")
    terms = set(pg.build(tmp_path, kind="docs")["terms"])
    assert {"Борисом", "Альфу", "Телемоста"} & terms
    assert "ClickHouse" in terms
    assert not terms & {"load_vad", "app", "js", "main", "py", "insertText", "reconcile_windows",
                        "HiddenFence", "RepoOnlyTitle"}


def test_repo_markdown_keeps_code(tmp_path):
    """Режим разработчика: в Markdown репозитория код остаётся термином."""
    make_repo(tmp_path)
    (tmp_path / "docs.md").write_text("# Заметки\n\nПравим `load_vad` и EngineClient.\n", encoding="utf-8")
    assert "load_vad" in set(pg.build(tmp_path)["terms"])


def test_code_parts_skip_plain_english_but_keep_dependencies(tmp_path):
    make_repo(tmp_path)
    (tmp_path / "build_workbook.py").write_text("def add_row(frame):\n    pass\n\nclass VadRunner:\n    pass\n",
                                                encoding="utf-8")
    (tmp_path / "package.json").write_text('{"dependencies": {"react": "1", "whisper": "2"}}', encoding="utf-8")
    terms = set(pg.build(tmp_path)["terms"])
    assert {"add_row", "VadRunner", "react", "whisper"} <= terms
    assert not terms & {"row", "workbook", "frame", "build"}


def test_transcript_folders_are_skipped(tmp_path):
    (tmp_path / "PROJECT.md").write_text("# Альфа\n\nРаботаем с ClickHouse и Телемостом.\n", encoding="utf-8")
    rec = tmp_path / "meeting-transcripts" / "rec-17"
    rec.mkdir(parents=True)
    for name in ("segments.json", "manifest.json"):
        (rec / name).write_text("{}", encoding="utf-8")
    (rec / "readable.md").write_text("Говорили про Зюзюкин и Зюзюкин снова.\n", encoding="utf-8")
    terms = set(pg.build(tmp_path, kind="docs")["terms"])
    assert "ClickHouse" in terms
    assert "Зюзюкин" not in terms
