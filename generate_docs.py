#!/usr/bin/env python3
"""Generate docs.json and index.html from Hammerspoon-style docstrings in init.lua."""

import json
import re
import subprocess
import sys
import textwrap
from datetime import UTC, datetime
from pathlib import Path

from jinja2 import Environment
from markdown_it import MarkdownIt
from markupsafe import Markup, escape


def _repo_url(repo_root: Path) -> str:
    try:
        raw = subprocess.check_output(
            ["git", "remote", "get-url", "origin"],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except subprocess.CalledProcessError:
        return ""
    # Convert SSH (git@github.com:owner/repo.git) to HTTPS
    m = re.match(r"git@([^:]+):(.+?)(?:\.git)?$", raw)
    if m:
        return f"https://{m.group(1)}/{m.group(2)}"
    # Strip embedded credentials (e.g. https://x-access-token:TOKEN@github.com/...)
    m = re.match(r"https://(?:[^@/]+@)?(.+)", raw)
    if m:
        raw = f"https://{m.group(1)}"
    return raw.removesuffix(".git")


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------


def extract_blocks(source: str) -> list[tuple[int, list[str]]]:
    """Return docstring blocks as (first line number, content lines).

    A docstring line is exactly ``---`` or starts with ``--- ``; the prefix is
    removed and any further indentation is kept, so nested lists and wrapped
    lines survive. ``----`` rules and ``---@`` annotations are not docstrings.
    """
    blocks: list[tuple[int, list[str]]] = []
    current: list[str] = []
    start = 0

    for lineno, raw_line in enumerate(source.splitlines(), start=1):
        line = raw_line.rstrip()
        if line == "---" or line.startswith("--- "):
            if not current:
                start = lineno
            current.append(line[4:])
        elif current:
            blocks.append((start, current))
            current = []

    if current:
        blocks.append((start, current))

    return blocks


# Display order in the HTML page.
_ITEM_TYPES = (
    "Variable",
    "Constant",
    "Field",
    "Constructor",
    "Method",
    "Function",
    "Command",
    "Deprecated",
)

_SECTIONS = {
    "Parameters:": "parameters",
    "Returns:": "returns",
    "Notes:": "notes",
    "Examples:": "examples",
}

_SIGNATURE_RE = re.compile(r"^(\w+)([.:])(\w+)")


def _trim_blank(lines: list[str]) -> list[str]:
    start, end = 0, len(lines)
    while start < end and not lines[start].strip():
        start += 1
    while end > start and not lines[end - 1].strip():
        end -= 1
    return lines[start:end]


def _first_paragraph(lines: list[str]) -> str:
    para: list[str] = []
    for line in _trim_blank(lines):
        if not line.strip():
            break
        para.append(line.strip())
    return " ".join(para)


def _infer_type(signature: str) -> str:
    m = _SIGNATURE_RE.match(signature)
    if m and m.group(2) == ":":
        return "Method"
    return "Function" if "(" in signature else "Variable"


def parse_sections(body: list[str]) -> dict:
    """Split an item body (after the type line) into description and sections.

    Section contents are kept as raw lines, as in Hammerspoon's own docs.json,
    so wrapped and nested bullets are preserved.
    """
    desc_lines: list[str] = []
    sections: dict[str, list[str]] = {key: [] for key in _SECTIONS.values()}
    current = desc_lines

    for line in body:
        key = _SECTIONS.get(line.strip())
        if key:
            current = sections[key]
        else:
            current.append(line)

    desc_lines = _trim_blank(desc_lines)
    return {
        "desc": _first_paragraph(desc_lines),
        "stripped_doc": "\n".join(desc_lines),
        **{key: _trim_blank(lines) for key, lines in sections.items()},
    }


def extract_version(source: str) -> str:
    """Extract obj.version value from Lua source, or empty string if absent."""
    m = re.search(r'^obj\.version\s*=\s*"([^"]+)"', source, re.MULTILINE)
    return m.group(1) if m else ""


def parse_module(blocks: list[tuple[int, list[str]]]) -> dict:
    """Parse all blocks into a structured module dict.

    Problems found along the way are collected in ``module["warnings"]`` as
    ``(line number, message)`` pairs.
    """
    module: dict = {
        "name": "",
        "version": "",
        "desc": "",
        "doc": "",
        "items": [],
        "warnings": [],
    }

    def warn(lineno: int, msg: str) -> None:
        module["warnings"].append((lineno, msg))

    for lineno, block in blocks:
        if not block:
            continue
        first = block[0].strip()

        m = re.match(r"^=== (\w+) ===$", first)
        if m:
            module["name"] = m.group(1)
            body = _trim_blank(block[1:])
            module["doc"] = "\n".join(body)
            module["desc"] = _first_paragraph(body)
            continue

        m = _SIGNATURE_RE.match(first)
        if not m:
            if first:
                warn(lineno, f"skipping docstring with unrecognised signature: {first}")
            continue
        if module["name"] and m.group(1) != module["name"]:
            warn(lineno, f"{first}: expected prefix {module['name']!r}")

        body = block[1:]
        head = _trim_blank(body)
        if head and head[0].strip() in _ITEM_TYPES:
            item_type = head[0].strip()
            body = head[1:]
        else:
            item_type = _infer_type(first)
            warn(lineno, f"{first}: no type line, assuming {item_type}")

        sections = parse_sections(body)
        module["items"].append(
            {
                "name": m.group(3),
                "type": item_type,
                "signature": first,
                "doc": "\n".join(_trim_blank(body)),
                **sections,
            }
        )

    return module


def to_json(module: dict) -> str:
    """Serialise in the shape Hammerspoon's hs.doc reads from a Spoon's docs.json."""
    payload = [
        {
            "name": module["name"],
            "version": module["version"],
            "type": "Module",
            "desc": module["desc"],
            "doc": module["doc"],
            "items": [
                {
                    "name": item["name"],
                    "type": item["type"],
                    "signature": item["signature"],
                    "def": item["signature"],
                    "desc": item["desc"],
                    "doc": item["doc"],
                    "stripped_doc": item["stripped_doc"],
                    "parameters": item["parameters"],
                    "returns": item["returns"],
                    "notes": item["notes"],
                    "examples": item["examples"],
                }
                for item in module["items"]
            ],
        }
    ]
    return json.dumps(payload, indent=2)


# ---------------------------------------------------------------------------
# HTML rendering
# ---------------------------------------------------------------------------

_md = MarkdownIt("commonmark", {"linkify": True}).enable("linkify")


def _markdown(lines: list[str] | str) -> Markup:
    text = lines if isinstance(lines, str) else "\n".join(lines)
    return Markup(_md.render(textwrap.dedent(text)))


def _parameters_markdown(lines: list[str]) -> Markup:
    """Render a Parameters section, setting each top-level name in code."""
    text = textwrap.dedent("\n".join(lines))
    text = re.sub(r"^([*-] )(\w+)( - )", r"\1`\2`\3", text, flags=re.MULTILINE)
    return _markdown(text)


_SIG_PARTS_RE = re.compile(
    r"^(?P<obj>\w+)(?P<sep>[.:])(?P<name>\w+)"
    r"(?P<args>\(.*?\))?"
    r"(?:\s*->\s*(?P<ret>.+))?$"
)


def _signature_html(signature: str) -> Markup:
    m = _SIG_PARTS_RE.match(signature)
    if not m:
        return escape(signature)
    out = (
        Markup('<span class="sig-obj">{}{}</span><span class="sig-name">{}</span>')
    ).format(m["obj"], m["sep"], m["name"])
    if m["args"]:
        out += Markup('<span class="sig-args">{}</span>').format(m["args"])
    if m["ret"]:
        out += Markup(
            ' <span class="sig-arrow">&rarr;</span> <span class="sig-ret">{}</span>'
        ).format(m["ret"])
    return out


_TEMPLATE = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ name }} — Hammerspoon Spoon</title>
<meta name="description" content="{{ desc }}">
<style>
  :root {
    --fg: #1a1a1a; --muted: #6b7280; --bg: #fff; --accent: #2563eb;
    --border: #e5e7eb; --muted-bg: #f3f4f6; --code-bg: #f6f7f9;
    --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  @media (prefers-color-scheme: dark) {
    :root { --fg: #e5e7eb; --muted: #9ca3af; --bg: #111; --accent: #60a5fa;
            --border: #374151; --muted-bg: #1f2937; --code-bg: #1a1d23; }
  }
  * { box-sizing: border-box; }
  html { scroll-padding-top: 1rem; }
  body { font: 16px/1.6 system-ui, sans-serif; color: var(--fg); background: var(--bg);
         max-width: 1120px; margin: 0 auto; padding: 2rem 1rem; }
  a { color: var(--accent); overflow-wrap: anywhere; }
  code { font-family: var(--mono); font-size: .875em; background: var(--code-bg);
         border: 1px solid var(--border); border-radius: 4px; padding: .05em .3em; }
  pre { background: var(--code-bg); border: 1px solid var(--border); border-radius: 6px;
        padding: .75rem 1rem; overflow-x: auto; }
  pre code { background: none; border: 0; padding: 0; }
  header { margin-bottom: 2rem; }
  h1 { font-size: 1.9rem; margin: 0 0 .25rem; display: flex; align-items: baseline; gap: .6rem; flex-wrap: wrap; }
  .version { font-size: .85rem; font-weight: 500; color: var(--muted);
             border: 1px solid var(--border); border-radius: 999px; padding: 0 .55rem; }
  .subtitle { font-size: 1.1rem; margin: 0 0 1rem; }
  .links { display: flex; gap: 1rem; flex-wrap: wrap; margin: 0; }
  .links a { text-decoration: none; }
  .links a:hover { text-decoration: underline; }
  .layout { display: grid; gap: 2rem; }
  .toc { border: 1px solid var(--border); border-radius: 6px; padding: .75rem 1rem;
         font-size: .9rem; align-self: start; }
  .toc h2 { font-size: .75rem; margin: .75rem 0 .25rem; }
  .toc h2:first-child { margin-top: 0; }
  .toc ul { list-style: none; margin: 0; padding: 0; }
  .toc li { margin: .1rem 0; }
  .toc a { text-decoration: none; font-family: var(--mono); font-size: .85rem;
           overflow-wrap: anywhere; }
  .toc a:hover { text-decoration: underline; }
  @media (min-width: 900px) {
    .layout { grid-template-columns: 220px minmax(0, 1fr); }
    .toc { position: sticky; top: 1rem; max-height: calc(100vh - 2rem); overflow-y: auto; }
  }
  h2 { font-size: .85rem; font-weight: 600; text-transform: uppercase;
       letter-spacing: .06em; color: var(--muted); }
  main > h2 { margin: 2.5rem 0 .75rem; }
  main > h2:first-child { margin-top: 0; }
  .overview { margin-bottom: 1rem; }
  .overview > :first-child { margin-top: 0; }
  .item { border: 1px solid var(--border); border-radius: 6px; margin-bottom: 1.25rem; }
  .item:target { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
  .item-header { display: flex; align-items: baseline; gap: .75rem;
                 padding: .6rem 1rem; background: var(--muted-bg);
                 border-bottom: 1px solid var(--border); border-radius: 6px 6px 0 0; }
  .sig { font-family: var(--mono); font-size: .9rem; flex: 1; min-width: 0;
         overflow-wrap: anywhere; background: none; border: 0; padding: 0; }
  .sig-obj, .sig-arrow { color: var(--muted); }
  .sig-name { font-weight: 700; }
  .sig-ret { color: var(--accent); }
  .badge { font-size: .7rem; text-transform: uppercase; letter-spacing: .05em;
           color: var(--muted); border: 1px solid var(--border); border-radius: 4px;
           padding: 0 .4rem; white-space: nowrap; }
  .anchor { color: var(--muted); text-decoration: none; font-weight: 600; }
  .anchor:hover { color: var(--accent); }
  .item-body { padding: .75rem 1rem; }
  .item-body > :first-child { margin-top: 0; }
  .item-body > :last-child { margin-bottom: 0; }
  .item-body ul { padding-left: 1.25rem; }
  .item-body li { margin: .15rem 0; }
  .item-body li > ul { margin: .15rem 0; }
  .section-label { font-weight: 600; font-size: .85rem; margin: .9rem 0 .2rem; }
  .section-label + ul, .section-label + p { margin-top: 0; }
  footer { margin-top: 3rem; font-size: .85rem; color: var(--muted); text-align: center; }
</style>
</head>
<body>
<header id="top">
  <h1>{{ name }}{% if version %} <span class="version">v{{ version }}</span>{% endif %}</h1>
  {% if desc_html %}<p class="subtitle">{{ desc_html }}</p>{% endif %}
  {% if repo_url %}
  <p class="links">
    <a href="{{ repo_url }}">GitHub</a>
    <a href="{{ repo_url }}/releases/latest">Latest release</a>
  </p>
  {% endif %}
</header>
<div class="layout">
<nav class="toc" aria-label="Contents">
  {% if overview %}<h2><a href="#overview">Overview</a></h2>{% endif %}
  {% for group in groups %}
  <h2>{{ group.title }}</h2>
  <ul>
    {% for item in group["items"] %}
    <li><a href="#{{ item.anchor }}" title="{{ item.desc | replace("`", "") }}">{{ item.name }}</a></li>
    {% endfor %}
  </ul>
  {% endfor %}
</nav>
<main>
{% if overview %}
<h2 id="overview">Overview</h2>
<div class="overview">{{ overview }}</div>
{% endif %}
{% for group in groups %}
<h2>{{ group.title }}</h2>
{% for item in group["items"] %}
<section class="item" id="{{ item.anchor }}">
  <div class="item-header">
    <code class="sig">{{ item.sig_html }}</code>
    <span class="badge">{{ item.type }}</span>
    <a class="anchor" href="#{{ item.anchor }}" aria-label="Link to {{ item.name }}">#</a>
  </div>
  <div class="item-body">
    {{ item.desc_html }}
    {% for label, html in item.sections %}
    <p class="section-label">{{ label }}</p>
    {{ html }}
    {% endfor %}
  </div>
</section>
{% endfor %}
{% endfor %}
</main>
</div>
<footer>
  Generated {{ today }}{% if repo_url %} &mdash; <a href="{{ repo_url }}">{{ repo_url }}</a>{% endif %}
</footer>
</body>
</html>
"""

_env = Environment(autoescape=True, trim_blocks=True, lstrip_blocks=True)


def _overview_lines(doc: str) -> list[str]:
    """The module doc minus its first paragraph (shown as the subtitle)."""
    lines = _trim_blank(doc.splitlines())
    while lines and lines[0].strip():
        lines.pop(0)
    return _trim_blank(lines)


def to_html(module: dict, repo_url: str) -> str:
    by_type: dict[str, list] = {}
    for item in module["items"]:
        by_type.setdefault(item["type"], []).append(item)

    anchors: set[str] = set()
    groups = []
    for type_name in _ITEM_TYPES:
        items = []
        for item in by_type.get(type_name, []):
            anchor = item["name"]
            if anchor in anchors:
                anchor = f"{item['name']}-{type_name.lower()}"
            anchors.add(anchor)
            items.append(
                {
                    "name": item["name"],
                    "type": item["type"],
                    "anchor": anchor,
                    "desc": item["desc"],
                    "sig_html": _signature_html(item["signature"]),
                    "desc_html": _markdown(item["stripped_doc"]),
                    "sections": [
                        (label, render(item[key]))
                        for label, key, render in (
                            ("Parameters", "parameters", _parameters_markdown),
                            ("Returns", "returns", _markdown),
                            ("Notes", "notes", _markdown),
                            ("Examples", "examples", _markdown),
                        )
                        if item[key]
                    ],
                }
            )
        if items:
            groups.append({"title": f"{type_name}s", "items": items})

    version = module["version"]
    overview = _overview_lines(module["doc"])
    return _env.from_string(_TEMPLATE).render(
        name=module["name"],
        # Unstamped local builds carry a placeholder like "dev"; don't show it.
        version=version if version[:1].isdigit() else "",
        desc=module["desc"],
        desc_html=Markup(_md.renderInline(module["desc"])),
        overview=_markdown(overview) if overview else "",
        groups=groups,
        repo_url=repo_url,
        today=datetime.now(tz=UTC).date().isoformat(),
    )


def main() -> None:
    repo_root = Path.cwd()
    lua_file = repo_root / "init.lua"
    out_dir = repo_root / "docs"
    out_dir.mkdir(exist_ok=True)

    source = lua_file.read_text()
    blocks = extract_blocks(source)
    module = parse_module(blocks)
    module["version"] = extract_version(source)

    for lineno, msg in module["warnings"]:
        print(f"{lua_file.name}:{lineno}: warning: {msg}", file=sys.stderr)

    if not module["name"]:
        print(
            "ERROR: No module header (=== Name ===) found in init.lua", file=sys.stderr
        )
        sys.exit(1)

    repo_url = _repo_url(repo_root)

    json_path = out_dir / "docs.json"
    json_path.write_text(to_json(module))
    print(f"Wrote {json_path}")

    html_path = out_dir / "index.html"
    html_path.write_text(to_html(module, repo_url))
    print(f"Wrote {html_path}")


if __name__ == "__main__":
    main()
