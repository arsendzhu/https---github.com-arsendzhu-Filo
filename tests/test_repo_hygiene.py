"""Cheap repository checks that run under pytest (scripts/verify.sh)."""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent


def test_config_example_is_valid_json():
    json.loads((ROOT / "config.example.json").read_text())


def test_no_api_keys_in_tracked_text_files():
    key = re.compile(r"nvapi-[A-Za-z0-9_-]{20,}")
    for path in list(ROOT.glob("*.md")) + list(ROOT.glob("*.json")) + list((ROOT / "scripts").glob("*")) + list((ROOT / "docs").glob("*")):
        if path.is_file():
            assert not key.search(path.read_text(errors="ignore")), f"key-like string in {path}"
