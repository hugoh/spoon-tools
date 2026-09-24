"""Tests for generate_docs.py."""

import json
import re
import subprocess
from pathlib import Path

import pytest

from generate_docs import (
    _repo_url,
    extract_blocks,
    extract_version,
    parse_module,
    to_html,
    to_json,
)


def _git_repo_with_origin(tmp_path: Path, url: str) -> Path:
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "remote", "add", "origin", url], cwd=tmp_path, check=True)
    return tmp_path


@pytest.mark.parametrize(
    ("origin_url", "expected"),
    [
        (
            "https://x-access-token:ghs_abc123@github.com/hugoh/TeamsControl.spoon",
            "https://github.com/hugoh/TeamsControl.spoon",
        ),
        (
            "https://x-access-token:ghs_abc123@github.com/hugoh/TeamsControl.spoon.git",
            "https://github.com/hugoh/TeamsControl.spoon",
        ),
        (
            "git@github.com:hugoh/TeamsControl.spoon.git",
            "https://github.com/hugoh/TeamsControl.spoon",
        ),
        (
            "https://github.com/hugoh/TeamsControl.spoon.git",
            "https://github.com/hugoh/TeamsControl.spoon",
        ),
    ],
)
def test_repo_url_strips_credentials(
    tmp_path: Path, origin_url: str, expected: str
) -> None:
    repo = _git_repo_with_origin(tmp_path, origin_url)
    assert _repo_url(repo) == expected


def test_repo_url_returns_empty_without_origin(tmp_path: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    assert _repo_url(tmp_path) == ""


# ---------------------------------------------------------------------------
# Parsing and rendering
# ---------------------------------------------------------------------------

FIXTURE = """\
--- === Demo ===
---
--- A Spoon that does
--- demo things.
---
--- Download: https://example.com/Demo.spoon.zip

local obj = {}
obj.version = "dev"

----------------------------------------
---@type number

--- Demo.delay
--- Variable
--- Seconds to wait, or `false` (default: 1).
obj.delay = 1

--- Demo:bind(mods, mappings) -> Demo
--- Method
--- Binds hotkeys.
---
--- Second paragraph.
---
--- Parameters:
---  * mods - modifier keys
---  * mappings - a list of tables:
---    * `app` - an app to focus; set `force = true`
---      to always launch it
---    * `func` - a function
---
--- Returns:
---  * The Demo object
---
--- Notes:
---  * Call `start` first.
function obj:bind(mods, mappings) end

--- Demo:untyped()
--- Does something.
function obj:untyped() end

--- not a signature
"""


def _module() -> dict:
    module = parse_module(extract_blocks(FIXTURE))
    module["version"] = extract_version(FIXTURE)
    return module


def _item(module: dict, name: str) -> dict:
    return next(i for i in module["items"] if i["name"] == name)


def test_module_desc_is_full_first_paragraph() -> None:
    module = _module()
    assert module["name"] == "Demo"
    assert module["desc"] == "A Spoon that does demo things."
    assert module["doc"].endswith("Download: https://example.com/Demo.spoon.zip")


def test_rules_and_annotations_are_not_docstrings() -> None:
    names = [i["name"] for i in _module()["items"]]
    assert names == ["delay", "bind", "untyped"]


def test_sections_keep_wrapped_and_nested_lines() -> None:
    bind = _item(_module(), "bind")
    assert bind["type"] == "Method"
    assert bind["desc"] == "Binds hotkeys."
    assert bind["stripped_doc"] == "Binds hotkeys.\n\nSecond paragraph."
    assert bind["parameters"] == [
        " * mods - modifier keys",
        " * mappings - a list of tables:",
        "   * `app` - an app to focus; set `force = true`",
        "     to always launch it",
        "   * `func` - a function",
    ]
    assert bind["returns"] == [" * The Demo object"]
    assert bind["notes"] == [" * Call `start` first."]


def test_warnings_for_missing_type_and_bad_signature() -> None:
    module = _module()
    assert _item(module, "untyped")["type"] == "Method"
    messages = [msg for _, msg in module["warnings"]]
    assert any("no type line" in m for m in messages)
    assert any("unrecognised signature" in m for m in messages)


def test_json_matches_hammerspoon_shape() -> None:
    [payload] = json.loads(to_json(_module()))
    assert payload["type"] == "Module"
    bind = next(i for i in payload["items"] if i["name"] == "bind")
    assert bind["def"] == bind["signature"] == "Demo:bind(mods, mappings) -> Demo"
    assert set(bind) >= {"stripped_doc", "parameters", "returns", "notes", "examples"}


def test_html_renders_markdown_toc_and_nesting() -> None:
    html = to_html(_module(), "https://github.com/o/Demo.spoon")
    assert "<code>false</code>" in html
    assert '<a href="https://example.com/Demo.spoon.zip">' in html
    assert '<a href="#bind"' in html and 'id="bind"' in html
    assert "<li><code>mods</code> - modifier keys</li>" in html
    # Nested list, with the wrapped continuation kept inside its item.
    assert re.search(
        r"<ul>\s*<li><code>app</code>[^<]*<code>force = true</code>\s+to always launch it",
        html,
    )
    assert "Notes" in html and "Call <code>start</code> first." in html
    assert '<span class="sig-ret">Demo</span>' in html
    assert "vdev" not in html


def test_html_without_repo_url_has_no_broken_links() -> None:
    html = to_html(_module(), "")
    assert 'href=""' not in html
    assert "/releases/latest" not in html
