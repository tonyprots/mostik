"""Пакеты стилей (P4): стиль причёсывания как файлы в `<MOSTIK_HOME>/styles/<id>/`.

- `prompt.md` — первая строка `# Название`, дальше — указания модели о стиле (как строка стиля D4:
  тон, форма, что сохранить). Остальной промпт — общий: самоисправления, защита от инъекции,
  рамка ответа. Пакет не может отменить защиту: его текст встаёт на место стиля, метки рамки
  из него вычищаются.
- `dictionary.txt` — по строке: термин («Kubernetes») или замена «как слышится → как пишется»
  («кубер → Kubernetes»); `#` — комментарий. Термины уходят модели как словарь, замены
  применяются детерминированно до модели и после неё.

Папку создаёт приложение («Открыть папку стилей», «Добавить пример»); движок только читает.
"""
from __future__ import annotations

import re
from pathlib import Path

from . import paths
from .polish import StylePack

PROMPT_LIMIT = 2000
TERMS_LIMIT = 60
_ID = re.compile(r"^[\w.-]{1,64}$", re.U)
_ARROW = re.compile(r"\s*(?:→|->|=>)\s*")

EXAMPLE_ID = "pismo-kollegam"
EXAMPLE_PROMPT = """# Письмо коллегам
Дружелюбный рабочий тон, обращение на «ты». Короткие абзацы по одной мысли.
Не добавляй приветствие и подпись, если их не было в речи. Сроки и имена — как сказано.
"""
EXAMPLE_DICTIONARY = """# Термины и замены пакета: термин или «как слышится → как пишется»
Яндекс 360
кубер → Kubernetes
"""


def styles_dir(home: Path | None = None) -> Path:
    return (home or paths.mostik_home()) / "styles"


def _read(path: Path, limit: int) -> str:
    try:
        return path.read_text(encoding="utf-8")[:limit]
    except (OSError, UnicodeDecodeError):
        return ""


def load(pack_id: str, home: Path | None = None) -> StylePack | None:
    """Пакет по id (имени папки); нет папки или `prompt.md` — None."""
    if not pack_id or not _ID.match(pack_id) or pack_id in (".", ".."):
        return None
    folder = styles_dir(home) / pack_id
    text = _read(folder / "prompt.md", PROMPT_LIMIT * 2).strip()
    if not text:
        return None
    lines = text.splitlines()
    name = pack_id
    if lines and lines[0].startswith("#"):
        name = lines[0].lstrip("#").strip() or pack_id
        lines = lines[1:]
    prompt = "\n".join(lines).strip()[:PROMPT_LIMIT]
    terms: list[str] = []
    replacements: list[tuple[str, str]] = []
    for line in _read(folder / "dictionary.txt", 20_000).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = _ARROW.split(line, maxsplit=1)
        if len(parts) == 2 and parts[0] and parts[1]:
            replacements.append((parts[0], parts[1]))
            target = parts[1]
        else:
            target = line
        if target not in terms:
            terms.append(target)
    return StylePack(pack_id, name, prompt or name, terms[:TERMS_LIMIT], replacements)


def list_packs(home: Path | None = None) -> list[dict]:
    """Пакеты для настроек и переключения хоткеем: id, имя, число терминов и замен, путь."""
    root = styles_dir(home)
    if not root.is_dir():
        return []
    packs = []
    for folder in sorted(root.iterdir(), key=lambda p: p.name.lower()):
        if not folder.is_dir():
            continue
        pack = load(folder.name, home)
        if pack is None:
            continue
        packs.append({"id": pack.id, "name": pack.name, "terms": len(pack.terms),
                      "replacements": len(pack.replacements), "path": str(folder)})
    return packs


def write_example(home: Path | None = None) -> Path:
    """Пример пакета для «Добавить пример»; существующие файлы не перезаписываются."""
    folder = styles_dir(home) / EXAMPLE_ID
    folder.mkdir(parents=True, exist_ok=True)
    for name, text in (("prompt.md", EXAMPLE_PROMPT), ("dictionary.txt", EXAMPLE_DICTIONARY)):
        target = folder / name
        if not target.exists():
            target.write_text(text, encoding="utf-8")
    return folder
