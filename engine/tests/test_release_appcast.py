"""scripts/appcast.py: <item> в ленту Sparkle из вывода sign_update (П8, пункт 3)."""
from __future__ import annotations

import importlib.util
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("mostik_appcast", ROOT / "scripts" / "appcast.py")
appcast = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(appcast)

SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SIG = 'sparkle:edSignature="VZ0rhmrMr2ByOcj5+/Arll==" length="5459896"'


def _release(feed: Path, version: str, build: str) -> None:
    assert appcast.main([str(feed), "--version", version, "--build", build,
                         "--url", f"https://downloads.mostik.app/Mostik-{version}.dmg", "--signature", SIG,
                         "--pub-date", "Sun, 11 Oct 2026 15:00:00 GMT"]) == 0


def test_template_gets_items_newest_first_and_stays_valid_xml(tmp_path):
    feed = tmp_path / "appcast.xml"
    feed.write_text((ROOT / "release" / "appcast.xml").read_text(encoding="utf-8"), encoding="utf-8")
    _release(feed, "0.1.0", "100")
    _release(feed, "0.2.0", "120")
    items = ET.parse(feed).getroot().find("channel").findall("item")
    assert [i.find(f"{SPARKLE_NS}version").text for i in items] == ["120", "100"]
    enclosure = items[0].find("enclosure")
    assert enclosure.get("url") == "https://downloads.mostik.app/Mostik-0.2.0.dmg"
    assert enclosure.get("length") == "5459896"
    assert enclosure.get(f"{SPARKLE_NS}edSignature") == "VZ0rhmrMr2ByOcj5+/Arll=="
    assert items[0].find(f"{SPARKLE_NS}minimumSystemVersion").text == "14.2"


def test_same_build_replaces_item(tmp_path):
    feed = tmp_path / "appcast.xml"
    feed.write_text((ROOT / "release" / "appcast.xml").read_text(encoding="utf-8"), encoding="utf-8")
    _release(feed, "0.1.0", "100")
    _release(feed, "0.1.0", "100")
    assert len(ET.parse(feed).getroot().find("channel").findall("item")) == 1


def test_rebuild_with_new_build_number_replaces_item_for_same_file(tmp_path):
    # Пересборка той же версии получает новый номер сборки, но .dmg лежит по тому же адресу:
    # старый <item> с чужой подписью указывал бы на новый файл.
    feed = tmp_path / "appcast.xml"
    feed.write_text((ROOT / "release" / "appcast.xml").read_text(encoding="utf-8"), encoding="utf-8")
    _release(feed, "0.1.0", "100")
    _release(feed, "0.1.0", "101")
    items = ET.parse(feed).getroot().find("channel").findall("item")
    assert [i.find(f"{SPARKLE_NS}version").text for i in items] == ["101"]


def test_rejects_garbage_signature_and_feed_without_marker(tmp_path):
    with pytest.raises(ValueError):
        appcast.parse_signature("error: no key in keychain")
    with pytest.raises(ValueError):
        appcast.add_item("<rss><channel></channel></rss>", "<item/>", "1")


def test_escapes_url():
    item = appcast.render_item(version="1.0", build="1", url="https://x.test/a?b=1&c=2", signature="s", length=1,
                               notes_url=None, min_system="14.2", pub_date="d")
    assert 'url="https://x.test/a?b=1&amp;c=2"' in item


MOSTIK_NS = "{urn:app.mostik:appcast}"
DR = 'designated => identifier "app.mostik.mac" and certificate leaf = H"4a1b2c3d4e5f60718293a4b5c6d7e8f901234567"'


def test_item_carries_designated_requirement(tmp_path):
    """Требование подписи в <item>: установленный Mostik сверяет его со своим до загрузки."""
    feed = tmp_path / "appcast.xml"
    feed.write_text((ROOT / "release" / "appcast.xml").read_text(encoding="utf-8"), encoding="utf-8")
    assert appcast.main([str(feed), "--version", "0.1.0", "--build", "100", "--url", "https://x.test/M.dmg",
                         "--signature", SIG, "--requirement", DR]) == 0
    [item] = ET.parse(feed).getroot().find("channel").findall("item")
    assert item.find(f"{MOSTIK_NS}designatedRequirement").text == DR


def test_old_feed_without_namespace_gets_it(tmp_path):
    """Лента из старого шаблона (без xmlns:mostik) остаётся корректным XML после новой записи."""
    feed = tmp_path / "appcast.xml"
    old = (ROOT / "release" / "appcast.xml").read_text(encoding="utf-8").replace(' xmlns:mostik="urn:app.mostik:appcast"', "")
    feed.write_text(old, encoding="utf-8")
    assert appcast.main([str(feed), "--version", "0.1.1", "--build", "101", "--url", "https://x.test/M.dmg",
                         "--signature", SIG, "--requirement", DR]) == 0
    root = ET.parse(feed).getroot()
    assert root.find("channel/item").find(f"{MOSTIK_NS}designatedRequirement").text == DR
