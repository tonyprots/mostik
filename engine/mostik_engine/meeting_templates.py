"""Шаблоны сводки (M16, W8, W22) и рецепты после встречи (W7) — файлами.

Встроенные лежат рядом с модулем: `templates/*.md` и `recipes/*.md`. Свои —
в `<MOSTIK_HOME>/templates/` и `<MOSTIK_HOME>/recipes/`; свой файл с тем же
`id` заменяет встроенный. Формат файла — Markdown с шапкой:

    ---
    id: standup
    name: Стендап
    name_en: Standup
    match: стендап, standup, дейли, daily
    layout: topics            # topics | people | protocol (только шаблоны)
    output: doc               # doc | email (только рецепты)
    order: 20
    ---
    Указания модели по-русски.

    ---en---
    Instructions in English (необязательно).

Текст шаблона — это указания модели, а не данные встречи: он добавляется в
системный промпт. Поэтому свои файлы читаются только из папки пользователя,
а не из папки встречи.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .paths import mostik_home

BUILTIN_TEMPLATES = Path(__file__).resolve().parent / "templates"
BUILTIN_RECIPES = Path(__file__).resolve().parent / "recipes"
LAYOUTS = ("topics", "people", "protocol")
DEFAULT_TEMPLATE = "general"
MAX_INSTRUCTIONS = 4000
EN_SPLIT = re.compile(r"^---en---\s*$", re.M)
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")

# Тип встречи по одному собеседнику: «1:1», «1-1», «один на один».
ONE_ON_ONE_RE = re.compile(r"(?<!\d)1\s*[:/xх×-]\s*1(?!\d)|one[\s-]on[\s-]one|один на один|тет-а-тет|\bo3\b", re.I)


@dataclass
class Template:
    id: str
    kind: str  # template | recipe
    name: str
    name_en: str
    instructions: str
    instructions_en: str = ""
    match: list[str] = field(default_factory=list)
    layout: str = "topics"
    output: str = "doc"
    order: int = 100
    source: str = "builtin"  # builtin | user
    path: str = ""

    def text(self, language: str) -> str:
        if language == "en" and self.instructions_en:
            return self.instructions_en
        return self.instructions

    def title(self, language: str) -> str:
        return self.name_en if language == "en" and self.name_en else self.name

    def as_json(self) -> dict[str, Any]:
        return {"id": self.id, "kind": self.kind, "name": self.name, "name_en": self.name_en,
                "layout": self.layout, "output": self.output, "match": self.match, "order": self.order,
                "source": self.source, "path": self.path}


def parse(text: str, *, kind: str, source: str, path: str = "", fallback_id: str = "") -> Template | None:
    """Файл шаблона → `Template`; битая шапка или пустые указания — None."""
    match = re.match(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", text, re.S)
    head: dict[str, str] = {}
    body = text
    if match:
        for line in match.group(1).splitlines():
            item = re.match(r"^([A-Za-z_][\w-]*):\s*(.*?)\s*(?:#.*)?$", line)
            if item:
                head[item.group(1).lower()] = item.group(2).strip().strip('"')
        body = match.group(2)
    template_id = (head.get("id") or fallback_id).strip().lower()
    if not ID_RE.match(template_id):
        return None
    parts = EN_SPLIT.split(body, maxsplit=1)
    ru = parts[0].strip()[:MAX_INSTRUCTIONS]
    en = parts[1].strip()[:MAX_INSTRUCTIONS] if len(parts) > 1 else ""
    if not ru and not en:
        return None
    layout = head.get("layout", "topics").lower()
    try:
        order = int(head.get("order") or 100)
    except ValueError:
        order = 100
    return Template(
        id=template_id, kind=kind, name=head.get("name") or template_id, name_en=head.get("name_en") or "",
        instructions=ru or en, instructions_en=en,
        match=[word.strip().casefold() for word in head.get("match", "").split(",") if word.strip()],
        layout=layout if layout in LAYOUTS else "topics",
        output="email" if head.get("output", "").lower() == "email" else "doc",
        order=order, source=source, path=path,
    )


def user_dir(kind: str) -> Path:
    return mostik_home() / ("recipes" if kind == "recipe" else "templates")


def _load_dir(folder: Path, kind: str, source: str) -> dict[str, Template]:
    found: dict[str, Template] = {}
    try:
        files = sorted(folder.glob("*.md"))
    except OSError:
        return found
    for path in files:
        if path.name.lower() == "readme.md" or path.name.startswith("."):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        item = parse(text, kind=kind, source=source, path=str(path), fallback_id=path.stem.lower())
        if item:
            found[item.id] = item
    return found


def load(kind: str = "template") -> dict[str, Template]:
    """Встроенные + свои (свои побеждают по `id`), по порядку `order`, затем по имени."""
    builtin = BUILTIN_RECIPES if kind == "recipe" else BUILTIN_TEMPLATES
    items = _load_dir(builtin, kind, "builtin")
    folder = user_dir(kind)
    if folder.is_dir():
        items.update(_load_dir(folder, kind, "user"))
    return dict(sorted(items.items(), key=lambda pair: (pair[1].order, pair[1].name.casefold())))


def get(template_id: str | None, kind: str = "template") -> Template | None:
    if not template_id:
        return None
    return load(kind).get(str(template_id).strip().lower())


def detect(title: str | None, attendees: int = 0) -> str:
    """Тип встречи по названию события: слова `match` шаблонов, «1:1»; два участника — один на один."""
    text = " ".join(str(title or "").split()).casefold()
    templates = load("template")
    if text:
        if ONE_ON_ONE_RE.search(text) and "one-on-one" in templates:
            return "one-on-one"
        # Свои шаблоны проверяются первыми: у пользователя могут быть свои слова.
        ordered = sorted(templates.values(), key=lambda item: (item.source != "user", item.order))
        for item in ordered:
            if item.layout == "protocol":
                continue  # протокол — по выбору, не по названию
            for word in item.match:
                if re.search(rf"(?<!\w){re.escape(word)}(?!\w)", text):
                    return item.id
    if attendees == 2 and "one-on-one" in templates:
        return "one-on-one"
    return DEFAULT_TEMPLATE


def ensure_user_dirs() -> dict[str, str]:
    """Папки своих шаблонов и рецептов с подсказкой по формату; существующее не трогаем."""
    result = {}
    for kind in ("template", "recipe"):
        folder = user_dir(kind)
        folder.mkdir(parents=True, exist_ok=True)
        readme = folder / "README.md"
        if not readme.exists():
            readme.write_text(_README[kind], encoding="utf-8")
        result[kind] = str(folder)
    return result


_README = {
    "template": """# Свои шаблоны сводки

Файл `<имя>.md` в этой папке — шаблон сводки встречи. Свой файл с тем же `id`, что у встроенного
(`general`, `standup`, `one-on-one`, `retro`, `client`, `protocol`, `exec`, `decisions`), заменяет его.

```
---
id: design-review
name: Дизайн-ревью
name_en: Design review
match: дизайн-ревью, design review
layout: topics
order: 50
---
Разбери макеты по экранам: что показали, какие замечания, что переделать и кто.
```

- `match` — слова в названии события календаря, по которым шаблон выбирается сам.
- `layout`: `topics` — разделы по темам разговора; `people` — по людям (как у 1:1);
  `protocol` — протокол «СЛУШАЛИ / РЕШИЛИ».
- Текст после шапки — указания модели. Английский вариант — после строки `---en---`.
""",
    "recipe": """# Свои рецепты после встречи

Файл `<имя>.md` — сохранённый промпт, который Mostik выполняет над сводкой и расшифровкой
встречи. Результат — черновик в папке встречи (`recipes/`), ничего никуда не отправляется.

```
---
id: weekly-update
name: Апдейт для команды
output: doc
---
Напиши короткий апдейт для командного чата: что решили, кто что делает, к какому сроку.
```

`output: email` — результат открывается как черновик письма (первая строка «Тема: …»).
""",
}
