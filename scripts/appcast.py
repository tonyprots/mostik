#!/usr/bin/env python3
"""Добавить версию в ленту Sparkle (appcast.xml): <item> с подписью EdDSA из sign_update.

    python3 -I scripts/appcast.py <appcast.xml> --version 0.2.0 --build 123 \
        --url https://.../Mostik-0.2.0.dmg --signature '<вывод sign_update>' [--notes-url URL] [--min-system 14.2] \
        [--requirement 'designated => identifier "app.mostik.mac" and …']

`--signature` — строка `sparkle:edSignature="…" length="…"`, которую печатает `sign_update`.
`--requirement` — требование подписи собранного приложения (`codesign -d -r-`). Оно ложится в
`<mostik:designatedRequirement>`, и установленный Mostik сверяет его со своим до загрузки: другое
требование значит, что macOS забудет разрешения, такое обновление молча не ставится (`UpdatePolicy`).
Повторный выпуск той же сборки или того же файла .dmg заменяет его <item>, а не дублирует. Ничего не публикует.
"""
from __future__ import annotations

import argparse
import re
import sys
from email.utils import formatdate
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

MARKER = "<!-- items -->"
MOSTIK_NS = "urn:app.mostik:appcast"
MOSTIK_XMLNS = f'xmlns:mostik="{MOSTIK_NS}"'
SIGNATURE_RE = re.compile(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"\s+length="(\d+)"')


def parse_signature(text: str) -> tuple[str, int]:
    match = SIGNATURE_RE.search(text)
    if not match:
        raise ValueError(f"не похоже на вывод sign_update: {text!r}")
    return match.group(1), int(match.group(2))


def render_item(*, version: str, build: str, url: str, signature: str, length: int,
                notes_url: str | None, min_system: str, pub_date: str, requirement: str | None = None) -> str:
    notes = f"\n            <sparkle:releaseNotesLink>{escape(notes_url)}</sparkle:releaseNotesLink>" if notes_url else ""
    if requirement:
        notes += f"\n            <mostik:designatedRequirement>{escape(requirement)}</mostik:designatedRequirement>"
    return (
        f"<item>\n"
        f"            <title>{escape('Mostik ' + version)}</title>\n"
        f"            <pubDate>{pub_date}</pubDate>\n"
        f"            <sparkle:version>{escape(build)}</sparkle:version>\n"
        f"            <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>\n"
        f"            <sparkle:minimumSystemVersion>{escape(min_system)}</sparkle:minimumSystemVersion>{notes}\n"
        f"            <enclosure url={quoteattr(url)} length=\"{length}\" type=\"application/octet-stream\""
        f" sparkle:edSignature={quoteattr(signature)} />\n"
        f"        </item>"
    )


def add_item(feed: str, item: str, build: str, url: str | None = None) -> str:
    if MARKER not in feed:
        raise ValueError(f"в ленте нет метки {MARKER}")
    if "<mostik:" in item and MOSTIK_XMLNS not in feed:
        # Лента из старого шаблона: объявить пространство имён mostik в <rss>.
        feed, n = re.subn(r"<rss\b", "<rss " + MOSTIK_XMLNS, feed, count=1)
        if not n:
            raise ValueError("в ленте нет <rss>")
    head, tail = feed.split(MARKER, 1)
    # Та же сборка уже есть — заменяем. Ищем только среди <item> под меткой, не в комментариях шапки.
    same = re.compile(r"\s*<item>(?:(?!</item>).)*?<sparkle:version>" + re.escape(escape(build))
                      + r"</sparkle:version>(?:(?!</item>).)*</item>", re.S)
    tail = same.sub("", tail)
    if url:
        # Пересборка той же версии — новый номер сборки, но тот же адрес .dmg: старый <item> с чужой
        # подписью указывал бы на новый файл.
        same_file = re.compile(r"\s*<item>(?:(?!</item>).)*?<enclosure url=" + re.escape(quoteattr(url))
                               + r"(?:(?!</item>).)*</item>", re.S)
        tail = same_file.sub("", tail)
    # Новые версии сверху: сразу под меткой.
    return head + MARKER + "\n        " + item + tail


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("appcast", type=Path)
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--signature", required=True)
    ap.add_argument("--notes-url")
    ap.add_argument("--min-system", default="14.2")
    ap.add_argument("--requirement", help="требование подписи приложения (codesign -d -r-)")
    ap.add_argument("--pub-date", default=formatdate(usegmt=True))
    args = ap.parse_args(argv)

    signature, length = parse_signature(args.signature)
    item = render_item(version=args.version, build=args.build, url=args.url, signature=signature, length=length,
                       notes_url=args.notes_url, min_system=args.min_system, pub_date=args.pub_date,
                       requirement=args.requirement)
    feed = add_item(args.appcast.read_text(encoding="utf-8"), item, args.build, args.url)
    args.appcast.write_text(feed, encoding="utf-8")
    print(f"appcast: {args.appcast} ← {args.version} ({args.build})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
