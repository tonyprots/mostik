"""П10 С11: код transcriber — копия в репозитории (engine/vendor_transcriber), полная и с источником."""
from __future__ import annotations

import ast
import re
from pathlib import Path

from mostik_engine import paths

ENGINE = Path(__file__).resolve().parent.parent
VENDOR = ENGINE / "vendor_transcriber"
PKG = VENDOR / "audio_transcription"
# Модули, которые isolated.py запускает дочерними процессами через `-m`, а не импортом.
SUBPROCESS_MODULES = {"audio_transcription.worker", "audio_transcription.diarization_worker"}


def _imports(path: Path) -> tuple[set[str], set[str]]:
    """`audio_transcription.*` из файла, включая ленивые импорты внутри функций и относительные.

    Возвращает (модули, которые обязаны быть; имена из `from M import N` — модуль или атрибут).
    """
    modules: set[str] = set()
    names: set[str] = set()
    for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
        if isinstance(node, ast.Import):
            modules |= {a.name for a in node.names if a.name.split(".")[0] == "audio_transcription"}
        elif isinstance(node, ast.ImportFrom):
            base = node.module or ""
            if node.level:
                if not path.resolve().is_relative_to(PKG.resolve()):
                    continue  # `from . import paths` в mostik_engine — свой пакет
                base = "audio_transcription" + (f".{base}" if base else "")
            if base.split(".")[0] != "audio_transcription":
                continue
            modules.add(base)
            names |= {f"{base}.{a.name}" for a in node.names}
    return modules, names


def _module_file(name: str) -> Path | None:
    parts = name.split(".")[1:]
    if not parts:
        return PKG / "__init__.py"
    for candidate in (PKG.joinpath(*parts).with_suffix(".py"), PKG.joinpath(*parts, "__init__.py")):
        if candidate.is_file():
            return candidate
    return None


def _defined_names(file: Path) -> set[str]:
    out: set[str] = set()
    for node in ast.parse(file.read_text(encoding="utf-8")).body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            out.add(node.name)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            out |= {(a.asname or a.name).split(".")[0] for a in node.names}
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            out |= {t.id for t in targets if isinstance(t, ast.Name)}
    return out


def test_engine_imports_the_vendored_copy():
    import audio_transcription

    assert paths.transcriber_scripts() == VENDOR
    assert Path(audio_transcription.__file__).resolve().is_relative_to(VENDOR.resolve())


def test_vendored_copy_is_import_complete():
    modules = set(SUBPROCESS_MODULES) | {"audio_transcription"}
    names: set[str] = set()
    files = list((ENGINE / "mostik_engine").rglob("*.py")) + [VENDOR / "transcribe.py"]
    missing, done = [], set()
    while files:
        for path in files:
            found_modules, found_names = _imports(path)
            modules |= found_modules
            names |= found_names
        files = []
        for name in sorted(names - done):
            done.add(name)
            parent = name.rsplit(".", 1)[0]
            if _module_file(name) is not None:
                modules.add(name)
            elif _module_file(parent) is not None and name.rsplit(".", 1)[1] in _defined_names(_module_file(parent)):
                continue  # класс или функция из модуля
            else:
                missing.append(name)
        for name in sorted(modules - done):
            done.add(name)
            file = _module_file(name)
            if file is None:
                missing.append(name)
            else:
                files.append(file)
    assert missing == [], f"нет в engine/vendor_transcriber: {missing}"


def test_source_records_commit_and_license():
    source = (VENDOR / "SOURCE.md").read_text(encoding="utf-8")
    assert re.search(r"\b[0-9a-f]{40}\b", source), "в SOURCE.md нет коммита transcriber"
    assert "skills/transcriber/scripts" in source
    assert (VENDOR / "LICENSE").read_text(encoding="utf-8").startswith("MIT License")


def test_no_sibling_transcriber_lookup_left():
    text = (ENGINE / "mostik_engine" / "paths.py").read_text(encoding="utf-8")
    assert "SIBLING_TRANSCRIBER" not in text and "03_code" not in text
