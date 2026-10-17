"""Архив для агентов: `mostik people|brief|series|digest|topics|meetings card` и те же инструменты MCP.

Только чтение: CLI и MCP не пишут ни `card.md`, ни `people/`, ни `digests/`; чувствительных встреч не отдают.
"""
from __future__ import annotations

import hashlib
import io
import json

from mostik_engine import calendar_terms, cli, mcp
from test_archive import make


def run(argv):
    out = io.StringIO()
    code = cli.main(argv, stdin=io.StringIO(""), stdout=out)
    return code, json.loads(out.getvalue())


def tree(home):
    return {str(path.relative_to(home)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(home.rglob("*")) if path.is_file()}


def setup(home):
    home.mkdir(parents=True, exist_ok=True)
    make(home, "2026-10-07-100000", title="Синк по бюджету", event="ABC@1", overview="Обсудили бюджет.")
    make(home, "2026-10-14-100000", title="Синк по бюджету", event="ABC@2", overview="Смета почти готова.",
         turns=[{"speaker": "Иван Петров", "start": 1.0, "text": "У конкурента цена ниже."},
                {"speaker": "Я", "start": 4.0, "text": "Договорились, смету доделаем."}])
    make(home, "2026-10-15-100000", title="Тайна", people=("Секретный Человек",), sensitive=True,
         turns=[{"speaker": "Секретный Человек", "start": 1.0, "text": "Конкурент сливает цену."}])
    calendar_terms.store([{"id": "ABC@3", "title": "Синк по бюджету", "start": "2099-10-21T10:00:00+03:00",
                           "end": "2099-10-21T11:00:00+03:00", "attendees": ["Антон", "Иван Петров"]}])


def test_cli_archive_commands_read_only(mostik_home):
    setup(mostik_home)
    before = tree(mostik_home)

    code, out = run(["people"])
    assert code == 0 and [item["name"] for item in out["data"]["items"]] == ["Иван Петров"]
    code, out = run(["people", "Иван", "Петров"])
    assert out["data"]["name"] == "Иван Петров" and len(out["data"]["meetings"]) == 2
    code, out = run(["people", "Секретный", "Человек"])
    assert code == 1 and out["error"]["code"] == "not_found"

    code, out = run(["brief", "--event-id", "ABC@3"])
    assert code == 0 and out["data"]["series"] == "cal:ABC"
    assert out["data"]["points"][0]["text"].startswith("В прошлый раз (14.10, «Синк по бюджету»)")
    code, out = run(["brief", "--event-id", "нет"])
    assert out["error"]["code"] == "not_found" and out["error"]["fix"] == "mostik calendar"

    code, out = run(["series"])
    assert [item["key"] for item in out["data"]["items"]] == ["cal:ABC"]
    code, out = run(["digest", "series", "cal:ABC"])
    assert out["data"]["title"] == "Серия: Синк по бюджету"
    code, out = run(["digest", "week", "--days", "100000"])
    assert "Тайна" not in out["data"]["text"]

    code, out = run(["topics", "конкурент", "цена", "--days", "100000"])
    counts = {item["topic"]: item["count"] for item in out["data"]["items"]}
    assert counts == {"конкурент": 1, "цена": 1}  # чувствительная встреча не в счёт

    code, out = run(["meetings", "card", "2026-10-14-100000"])
    assert code == 0 and out["data"]["prompt_version"] == "rules-1"
    code, out = run(["meetings", "card", "2026-10-15-100000"])
    assert out["error"]["code"] == "not_found"

    assert tree(mostik_home) == before  # ничего не записано


def test_mcp_archive_tools(mostik_home):
    setup(mostik_home)
    reply = mcp.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                        "params": {"name": "get_brief", "arguments": {"event_id": "ABC@3"}}})
    result = reply["result"]
    assert result["isError"] is False and result["structuredContent"]["data"]["event"]["title"] == "Синк по бюджету"
    reply = mcp.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                        "params": {"name": "get_person", "arguments": {}}})
    assert [p["name"] for p in reply["result"]["structuredContent"]["data"]["items"]] == ["Иван Петров"]
    reply = mcp.handle({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                        "params": {"name": "track_topics", "arguments": {"topics": []}}})
    assert reply["result"]["isError"] is True
    reply = mcp.handle({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                        "params": {"name": "get_meeting_card", "arguments": {"id": "2026-10-15-100000"}}})
    assert reply["result"]["structuredContent"]["error"]["code"] == "not_found"


# --- протокол движка ---------------------------------------------------------------------

def test_engine_archive_commands(mostik_home, tmp_path):
    from conftest import FakePool, FakeVerifier
    from mostik_engine.personal_glossary import PersonalGlossary
    from mostik_engine.server import Engine
    from test_protocol import Sink

    setup(mostik_home)
    sink = Sink()
    eng = Engine(sink, pool=FakePool(), verifier=FakeVerifier(),
                 personal=PersonalGlossary(tmp_path / "glossary.yaml", import_transcriber=False))

    def send(**command):
        eng.handle_line(json.dumps(command, ensure_ascii=False))
        return sink.wait(lambda line: line.get("id") == command["id"], timeout=30)

    reply = send(cmd="archive_brief", id="b1", event_id="ABC@3", write=True)
    assert reply["brief"]["points"] and reply["path"].endswith(".md")
    reply = send(cmd="archive_people", id="p1", write=True)
    assert reply["written"]["written"] == 1
    reply = send(cmd="archive_digest", id="d1", kind="series", series="cal:ABC", write=True)
    assert reply["path"].endswith(".md")
    reply = send(cmd="archive_cards", id="c1")
    # чувствительная в список карточек не попала
    assert reply["fresh"] + reply["written"] == 2 and reply["skipped"] == 0
    reply = send(cmd="archive_digest", id="d2", kind="nope")
    assert reply["ok"] is False and reply["code"] == "bad_request"
