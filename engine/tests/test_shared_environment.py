"""Списки окружения и изоляции движка против общего эталона `docs/engine-environment.json`.

Swift сверяет свою половину в `Sources/MostikCoreTests/SharedEnvironmentTests.swift`.
"""
from __future__ import annotations

import json
from pathlib import Path

from mostik_engine import fluid_offline, isolation, privacy, project_glossary

SPEC = json.loads((Path(__file__).resolve().parents[2] / "docs" / "engine-environment.json").read_text(encoding="utf-8"))


def test_offline_and_overrides():
    assert privacy.OFFLINE_ENV == SPEC["offline"]
    assert list(privacy.DEV_ONLY_ENV) == SPEC["dev_only_overrides"]
    assert list(privacy.RELEASE_DROP_PREFIXES) == SPEC["release_drop_prefixes"]
    assert list(privacy.RELEASE_DROP_ENV) == SPEC["release_drop"]
    assert list(privacy.TOOLCHAIN_ENV) == SPEC["toolchain"]
    assert list(isolation.UNSAFE_PREFIXES) == SPEC["unsafe_prefixes"]


def test_allowlists():
    assert isolation.SYSTEM_PATH == SPEC["system_path"]
    assert isolation.BASE_KEYS == set(SPEC["base_keys"])
    assert list(isolation.BASE_PREFIXES) == SPEC["base_prefixes"]
    engine_set = set(SPEC["engine_set_child_keys"]["keys"])
    assert set(fluid_offline.OFFLINE_ENV) == engine_set
    keys = (isolation.CHILD_KEYS | isolation.CLAUDE_KEYS) - isolation.BASE_KEYS - engine_set
    assert keys == set(SPEC["engine_keys"])
    prefixes = set(isolation.CHILD_PREFIXES + isolation.CLAUDE_PREFIXES) - set(isolation.BASE_PREFIXES)
    assert prefixes == set(SPEC["engine_prefixes"])


def test_app_only_keys_are_not_read_by_engine():
    root = Path(privacy.__file__).resolve().parent
    source = "\n".join(path.read_text(encoding="utf-8") for path in root.rglob("*.py"))
    for key in SPEC["app_only_address_overrides"]["keys"]:
        assert key not in source, f"{key} читает движок — уберите из app_only_address_overrides"


def test_safe_git():
    assert list(project_glossary.SAFE_GIT) == SPEC["safe_git"]
