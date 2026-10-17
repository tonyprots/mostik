"""П8, пункт 1: движок находит transcriber и Python без абсолютных путей к машине разработчика."""
from __future__ import annotations

from pathlib import Path

from mostik_engine import llm_mlx, meeting, paths

ENGINE = Path(__file__).resolve().parent.parent


def test_no_developer_paths_in_engine_sources():
    banned = str(Path.home()) + "/"
    offenders = [
        str(path.relative_to(ENGINE))
        for path in (ENGINE / "mostik_engine").rglob("*")
        if path.is_file() and path.suffix in {".py", ".json", ".yaml", ".md"} and banned in path.read_text(errors="ignore")
    ]
    assert offenders == []


def test_transcriber_env_wins(monkeypatch, tmp_path):
    monkeypatch.setenv("MOSTIK_TRANSCRIBER", str(tmp_path))
    assert paths.transcriber_scripts() == tmp_path
    assert paths.transcriber_repo() is None


def test_vendored_transcriber_is_default(monkeypatch):
    # П10 С11: копия в репозитории, соседний проект не ищется.
    monkeypatch.delenv("MOSTIK_TRANSCRIBER", raising=False)
    assert paths.transcriber_scripts() == ENGINE / "vendor_transcriber"
    assert (paths.transcriber_scripts() / "audio_transcription" / "__init__.py").is_file()
    assert (paths.transcriber_scripts() / "transcribe.py").is_file()
    assert paths.transcriber_repo() is None


def test_transcriber_env_ignored_inside_app(monkeypatch, tmp_path):
    monkeypatch.setenv("MOSTIK_TRANSCRIBER", str(tmp_path))
    monkeypatch.setattr(paths, "IN_APP_BUNDLE", True)
    assert paths.transcriber_scripts() == ENGINE / "vendor_transcriber"


def test_dev_override_to_sibling_repo_layout(monkeypatch, tmp_path):
    scripts = tmp_path / "transcriber" / "skills" / "transcriber" / "scripts"
    (scripts / "audio_transcription").mkdir(parents=True)
    monkeypatch.setenv("MOSTIK_TRANSCRIBER", str(scripts))
    assert paths.transcriber_scripts() == scripts
    assert paths.transcriber_repo() == tmp_path / "transcriber"


def test_meeting_python_falls_back_to_own_interpreter(monkeypatch, tmp_path):
    import sys

    monkeypatch.delenv("MOSTIK_TRANSCRIBER_PYTHON", raising=False)
    monkeypatch.setenv("MOSTIK_TRANSCRIBER", str(tmp_path))
    assert meeting.transcriber_python() == sys.executable
    monkeypatch.setenv("MOSTIK_TRANSCRIBER_PYTHON", "/opt/py")
    assert meeting.transcriber_python() == "/opt/py"


def test_llm_python_env_and_venv(monkeypatch, tmp_path):
    assert llm_mlx.llm_python({"MOSTIK_LLM_PYTHON": "/x/py"}) == "/x/py"
    monkeypatch.setattr(llm_mlx, "ENGINE_DIR", tmp_path)
    venv = tmp_path / ".venv-llm" / "bin"
    venv.mkdir(parents=True)
    (venv / "python").write_text("")
    assert llm_mlx.llm_python({}) == str(venv / "python")


def test_python_overrides_ignored_inside_app_even_if_env_reaches_engine(monkeypatch):
    """Р2, инфо: окружение в .app вычищает импорт пакета, а здесь — вторая линия в самих функциях."""
    from mostik_engine import llm_mlx, meeting

    monkeypatch.setattr(paths, "IN_APP_BUNDLE", True)
    monkeypatch.setenv("MOSTIK_TRANSCRIBER_PYTHON", "/evil/py")
    assert meeting.transcriber_python() != "/evil/py"
    assert llm_mlx.llm_python({"MOSTIK_LLM_PYTHON": "/evil/py"}) != "/evil/py"
