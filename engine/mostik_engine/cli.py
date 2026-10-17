"""CLI `mostik` для агентов (G1): `python -m mostik_engine.cli <команда>`.

Ответ всегда JSON в одном конверте:
`{"ok": true, "data": …, "meta": {"schemaVersion": 1, "command": …}}`;
ошибка — `{"ok": false, "error": {"code", "message", "fix"}, "meta": …}`, где
`fix` — следующая команда. Код выхода: 0 — успех, 1 — ошибка, 2 — неверные
аргументы. Флаг `--json` принимается для совместимости (вывод и так JSON),
`--pretty` — с отступами.

Особые команды: `mcp` — MCP-сервер по stdio (G2), `hook session-start` —
хук Claude Code (G4), он печатает только JSON хука и всегда выходит с кодом 0.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Sequence

from . import agent_api as api


class UsageError(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # type: ignore[override]
        raise UsageError(message)


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="вывод JSON (по умолчанию и так)")
    common.add_argument("--pretty", action="store_true", help="JSON с отступами")

    parser = _Parser(prog="mostik", description="Mostik для агентов: история, встречи, словарь, поиск.",
                     parents=[common])
    sub = parser.add_subparsers(dest="command", parser_class=_Parser)

    p = sub.add_parser("history", parents=[common], help="последние диктовки")
    p.add_argument("--limit", type=int, default=20)
    p.add_argument("--days", type=float)
    p.add_argument("--agent", action="store_true", help="только диктовки в агентные приложения")

    p = sub.add_parser("doubts", parents=[common], help="сомнения последних диктовок")
    p.add_argument("--limit", type=int, default=20)
    p.add_argument("--days", type=float, default=7)

    meetings = sub.add_parser("meetings", parents=[common], help="встречи")
    msub = meetings.add_subparsers(dest="action", parser_class=_Parser)
    p = msub.add_parser("list", parents=[common])
    p.add_argument("--limit", type=int, default=20)
    p = msub.add_parser("get", parents=[common])
    p.add_argument("id")
    p.add_argument("--no-transcript", action="store_true")
    p.add_argument("--offset", type=int, default=0)
    p.add_argument("--max-turns", type=int, default=400)
    p = msub.add_parser("actions", parents=[common])
    p.add_argument("--days", type=float, default=30)
    p.add_argument("--assignee")
    p.add_argument("--all", action="store_true", help="и закрытые")
    p = msub.add_parser("note", parents=[common])
    p.add_argument("id")
    p.add_argument("text", nargs="?", help="текст; без него — из stdin")
    p.add_argument("--author")
    p = msub.add_parser("card", parents=[common])
    p.add_argument("id")

    p = sub.add_parser("people", parents=[common], help="собеседники и карточка человека")
    p.add_argument("name", nargs="*")
    p = sub.add_parser("brief", parents=[common], help="бриф к ближайшей встрече")
    p.add_argument("--event-id")
    p.add_argument("--hours", type=float, default=24)
    sub.add_parser("series", parents=[common], help="серии встреч")
    p = sub.add_parser("digest", parents=[common], help="сводка за неделю или по серии")
    p.add_argument("kind", choices=["week", "series"])
    p.add_argument("series_key", nargs="?")
    p.add_argument("--days", type=float, default=7)
    p = sub.add_parser("topics", parents=[common], help="где звучали слова-триггеры")
    p.add_argument("topics", nargs="+")
    p.add_argument("--days", type=float)
    p.add_argument("--limit", type=int, default=20)

    p = sub.add_parser("search", parents=[common], help="поиск по встречам и источникам")
    p.add_argument("query", nargs="+")
    p.add_argument("--scope", default="meetings", choices=["meetings", "sources", "all"])
    p.add_argument("--limit", type=int, default=10)

    p = sub.add_parser("glossary", parents=[common], help="личный словарь и словарь проекта")
    p.add_argument("--project")
    p.add_argument("--scan", action="store_true", help="собрать словарь проекта, если кэша нет или он старый")
    p.add_argument("--limit", type=int, default=200)

    p = sub.add_parser("calendar", parents=[common], help="встречи календаря на ближайшие часы")
    p.add_argument("--hours", type=float, default=24)

    p = sub.add_parser("context", parents=[common], help="текст для агента на старте сессии")
    p.add_argument("--cwd")
    p.add_argument("--any-time", action="store_true", help="не смотреть на рабочие часы")

    sub.add_parser("spec", parents=[common], help="контракт CLI")
    sub.add_parser("mcp", help="MCP-сервер по stdio")
    p = sub.add_parser("hook", help="хуки агентов")
    p.add_argument("event", choices=["session-start"])
    return parser


def envelope_ok(command: str, data: Any) -> dict[str, Any]:
    return {"ok": True, "data": data, "untrusted_content": dict(api.UNTRUSTED_CONTENT),
            "meta": {"schemaVersion": api.SCHEMA_VERSION, "command": command}}


def envelope_error(command: str, code: str, message: str, fix: str | None) -> dict[str, Any]:
    return {"ok": False, "error": {"code": code, "message": message, "fix": fix},
            "meta": {"schemaVersion": api.SCHEMA_VERSION, "command": command}}


def dispatch(args: argparse.Namespace, stdin: Any = None) -> Any:
    command = args.command
    if command == "history":
        return api.history(args.limit, args.days, args.agent)
    if command == "doubts":
        return api.recent_doubts(args.limit, args.days)
    if command == "meetings":
        action = args.action
        if action == "list":
            return api.meetings_list(args.limit)
        if action == "get":
            return api.meeting_get(args.id, not args.no_transcript, args.offset, args.max_turns)
        if action == "actions":
            return api.open_actions(args.days, args.assignee, args.all)
        if action == "note":
            text = args.text if args.text is not None else (stdin or sys.stdin).read()
            return api.add_note(args.id, text, args.author)
        if action == "card":
            return api.meeting_card(args.id)
        raise UsageError("meetings: list | get <id> | actions | note <id> <текст> | card <id>")
    if command == "people":
        return api.person_get(" ".join(args.name)) if args.name else api.people_list()
    if command == "brief":
        return api.brief_get(args.event_id, args.hours)
    if command == "series":
        return api.series_get()
    if command == "digest":
        return api.digest_get(args.kind, args.series_key, args.days)
    if command == "topics":
        return api.topics_get(args.topics, args.days, args.limit)
    if command == "search":
        return api.search(" ".join(args.query), args.scope, args.limit)
    if command == "glossary":
        return api.glossary(args.project, args.scan, args.limit)
    if command == "calendar":
        return api.upcoming_events(args.hours)
    if command == "context":
        return api.session_context(args.cwd, respect_hours=not args.any_time)
    if command == "spec":
        return api.spec()
    raise UsageError("нужна команда; список — mostik spec")


def hook_session_start(stdin: Any, stdout: Any) -> int:
    """Хук SessionStart Claude Code: только на старте сессии, молча при любом сбое."""
    try:
        raw = stdin.read() if stdin is not None else ""
        payload = json.loads(raw) if raw.strip() else {}
    except (OSError, ValueError):
        payload = {}
    payload = payload if isinstance(payload, dict) else {}
    if payload.get("source") not in (None, "startup"):
        return 0
    try:
        context = api.session_context(payload.get("cwd"))
    except Exception:  # noqa: BLE001 — хук не должен мешать старту сессии
        return 0
    if context.get("text"):
        stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                                        "additionalContext": context["text"]}},
                                ensure_ascii=False) + "\n")
    return 0


def main(argv: Sequence[str] | None = None, stdin: Any = None, stdout: Any = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    stdout = stdout or sys.stdout
    stdin = stdin if stdin is not None else sys.stdin
    pretty = "--pretty" in argv
    try:
        args = build_parser().parse_args(argv)
    except UsageError as error:
        out = envelope_error(argv[0] if argv else "", "bad_request", str(error), "mostik spec")
        stdout.write(json.dumps(out, ensure_ascii=False, indent=2 if pretty else None) + "\n")
        return 2
    if args.command == "mcp":
        from .mcp import serve

        return serve(stdin, stdout)
    if args.command == "hook":
        return hook_session_start(stdin, stdout)
    name = " ".join(filter(None, [args.command, getattr(args, "action", None)]))
    code = 0
    try:
        out = envelope_ok(name, dispatch(args, stdin))
    except UsageError as error:
        out, code = envelope_error(name, "bad_request", str(error), "mostik spec"), 2
    except api.store.MeetingError as error:
        out, code = envelope_error(name, error.code, error.message, error.fix), 1
    except Exception as error:  # noqa: BLE001 — агент получает конверт, а не трейсбек
        out, code = envelope_error(name, "internal", f"{type(error).__name__}: {error}", None), 1
    stdout.write(json.dumps(out, ensure_ascii=False, indent=2 if pretty else None, default=str) + "\n")
    return code


if __name__ == "__main__":
    os.umask(0o077)  # П10: notes.md и кэш словаря — только владельцу
    sys.exit(main())
