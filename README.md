# spoon-tools

Shared tooling for [Hammerspoon](https://www.hammerspoon.org/) Spoon repositories. Contains a doc generator, reusable GitHub Actions workflows, and a Renovate config preset — things that would otherwise be copied into every spoon.

---

## `spoon-generate-docs`

Parses Hammerspoon-style `---` docstrings from `init.lua` and writes:

- `docs/docs.json` — the Hammerspoon `hs.doc` format, shipped inside the Spoon zip
- `docs/index.html` — a standalone rendered doc page deployed to GitHub Pages

Docstrings are Markdown (CommonMark; bare URLs are linked). Section bullets
under `Parameters:`, `Returns:`, `Notes:` and `Examples:` may wrap and nest.
The page has a table of contents and a permalink on every item. Malformed
blocks (unrecognised signature, missing type line) are reported as warnings.

It reads `obj.version` from `init.lua` and auto-detects the repo URL from `git remote get-url origin`.

**Local invocation** (run from inside a spoon repo):

```sh
uvx --from git+https://github.com/hugoh/spoon-tools spoon-generate-docs
```

---

## `hs_mock`

A mock of the Hammerspoon `hs` global for testing Spoons under
[busted](https://lunarmodules.github.io/busted/). It covers the APIs most Spoons
share; anything else raises `hs_mock: hs.<name> is not mocked` until the test
adds it.

**Install** into a project-local tree (the mise Lua tree is shared by every
repo, so a global install can't be pinned per spoon). Each release attaches a
rockspec pinned to its tag:

```toml
# mise.toml
[env]
HS_MOCK_VERSION = "1.6.1" # bumped by the Renovate preset below

[tasks.deps]
run = "luarocks install --tree .rocks https://github.com/hugoh/spoon-tools/releases/download/v$HS_MOCK_VERSION/hs-mock-$HS_MOCK_VERSION-1.rockspec"
sources = ["mise.toml"]
outputs = [".rocks/lib/luarocks/rocks-5.4/hs-mock/*/rock_manifest"] # skip once installed

[tasks.test]
depends = ["deps"]
run = "busted test_spec.lua --verbose"
```

```lua
-- .busted
return { _all = { lpath = ".rocks/share/lua/5.4/?.lua;.rocks/share/lua/5.4/?/init.lua" } }
```

Add `.rocks/` to `.gitignore`.

**Use** a fresh mock per test:

```lua
local hs_mock = require("hs_mock")
local hs, ctl, Spoon

before_each(function()
  hs, ctl = hs_mock.new()
  _G.hs = hs
  hs.wifi = { currentNetwork = function() return "home" end } -- add what the spoon also needs
  Spoon = dofile("init.lua")
end)

it("polls every minute", function()
  Spoon:start()
  ctl.advance(60)
  assert.same({ "polled" }, ctl.logged("info"))
end)
```

**Mocked:** `logger.new`; `timer.doAfter`, `doEvery`, `new`, `secondsSinceEpoch`,
`absoluteTime`; `task.new`; `menubar.new`; `notify.new`, `activationTypes`;
`caffeinate.watcher`; `application.find`, `get`, `watcher`; `hotkey.bind`;
`audiodevice` (devices, defaults, `watcher`); `image.imageFromName`, `iconForFile`;
`execute`; `open`; `ipc` (present); `alert`; `settings`; `screen.mainScreen`;
`mouse.absolutePosition`; `eventtap` (`keyStroke`, `leftClick`, `new`, `event`);
`websocket`; `wifi`; `host.interfaceStyle`; `distributednotifications`;
`spoons.resourcePath` (returns the file unchanged); `application.launchOrFocus`,
`launchOrFocusByBundleID`, `frontmostApplication`;
`json.read`, `write`; `fs.attributes`, `mkdir`; `fnutils` (Hammerspoon's own
code, vendored). Event constants match Hammerspoon 1.1.1.

**Test controls** (`ctl`):

| Control | Effect |
|---|---|
| `ctl.now` | Virtual clock in seconds; drives `secondsSinceEpoch` and `absoluteTime` (ns) |
| `ctl.advance(s)` | Moves the clock, firing due timers in due-time order (ties in scheduling order); `doEvery` and started `timer.new` re-arm |
| `ctl.flush()` | Fires the one-shot timers pending now, whatever their delay; leaves repeating timers and ones scheduled meanwhile |
| `ctl.timers()` | Running timers |
| `ctl.logs`, `ctl.logged(level)` | Every log line at every level (`{ logger, level, message }`), or the messages at one level |
| `ctl.tasks` | Created tasks; `task:complete(code, stdout, stderr)` calls back. `terminate()` doesn't |
| `ctl.onTask = fn(task)` | Called on `task:start()`; returning an exit code completes the task at once |
| `ctl.menubars` | Created menubars (`_title`, `_icon`, `_menu`, `_tooltip`, `_deleted`…); `bar:_click()` |
| `ctl.notifications`, `ctl.activate(note, type)` | Created notifications (`_attributes`, `_sent`, `_withdrawn`); activation calls back |
| `ctl.caffeinate(event)`, `ctl.appEvent(name, event, app)` | Delivers to started watchers |
| `ctl.apps[name]`, `ctl.frontmost` | `application.find` / `get` match a key of `ctl.apps`, else a `bundleID()` among those apps and the frontmost one; `frontmostApplication` returns `ctl.frontmost` |
| `ctl.launched` | Names and bundle ids passed to `launchOrFocus` / `launchOrFocusByBundleID` |
| `ctl.addAudioDevice{ name, uid, input, transport, muted, volume, inUse }` | Adds an output (or `input = true`) device; `uid` defaults to `name` |
| `ctl.audio.defaultOutput`, `ctl.audio.defaultInput` | The default devices; `setDefault*Device()` updates them |
| `ctl.audioEvent(event)`, `ctl.deviceEvent(device, event, scope, element)` | Fires the running `audiodevice.watcher`, or a watching device's callback |
| `ctl.executed`, `ctl.onExecute = fn(cmd)` | Commands passed to `hs.execute`; `onExecute` returns its `output, status, type, rc` (default `"", true, "exit", 0`) |
| `ctl.opened` | Paths passed to `hs.open` |
| `ctl.alerts` | `{ id, text, style, screen, seconds, closed }` per `alert.show` (which returns the string `id`) |
| `ctl.settings`, `ctl.screenFrame`, `ctl.mousePosition` | Backing state for `settings`, `screen.mainScreen():frame()` and `mouse.absolutePosition` |
| `ctl.keyStrokes`, `ctl.clicks`, `ctl.posted` | `eventtap.keyStroke` / `leftClick` calls and posted events |
| `ctl.newEvent{ type, systemKey, flags }`, `ctl.tapEvent(event)` | Builds an event; delivers it to the first enabled tap watching its type and returns that tap's answer |
| `ctl.websockets`, `ctl.websocketEvent(ws, event, message)` | Created websockets (`_url`, `_sent`, `_closed`); calls a socket's callback |
| `ctl.wifiNetwork`, `ctl.wifiEvent(message, interface)` | `wifi.currentNetwork`; notifies running wifi watchers (default `"SSIDChange"`, `"en0"`) |
| `ctl.interfaceStyle` | `host.interfaceStyle`: `nil` (light) or `"Dark"`, as macOS reports |
| `ctl.distributedNotification(name, object, userInfo)` | Delivers to running watchers registered for that name, or for all |
| `ctl.images[nameOrPath]` | What `image.imageFromName` / `iconForFile` return; unknown names give `nil`, as in Hammerspoon |
| `ctl.hotkeys` | Bindings: `mods`, `key`, `message`, `pressed`, `enabled`, `deleted` |
| `ctl.files[path]`, `ctl.dirs[path]` | The filesystem behind `json` and `fs`; a non-table file value reads as malformed JSON |

`json.read` and `json.write` copy, like real serialization.

**What stays local.** A spoon's tests keep their own fake, with a comment on why,
when it is a test assertion rather than a mock (such as checking that a lookup is
exact), when it is deliberately unrealistic (such as a `json.decode` that passes
tables through), or when an honest shared version would need deep modelling
(`axuielement` trees, `webview` with its JavaScript bridge, `canvas`). Anything
generic goes here instead. Releases follow
this repo's tags; refresh the vendored `fnutils` with `mise run vendor-fnutils <hammerspoon-tag>`.

---

## Workflows

Lint and tests need nothing spoon-specific — call
[`hugoh/gh-workflows`](https://github.com/hugoh/gh-workflows) directly.

### `hk.yml` — lint checks

```yaml
name: hk
on:
  push:
    branches: [main, renovate/**]
  pull_request:

permissions:
  contents: read
  packages: read
  statuses: write

jobs:
  check:
    uses: hugoh/gh-workflows/.github/workflows/hk.yml@<pinned-sha>
    permissions:
      contents: read
      packages: read
      statuses: write
```

### `tests.yml` — Lua tests

`setup` (checkout + mise) then `mise run test` (busted). Interleave any extra
step — e.g. AudioPilot vendors JS deps first.

```yaml
name: Tests
on:
  push:
    branches: [main, renovate/**]
  pull_request:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    concurrency:
      group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
      cancel-in-progress: true
    steps:
      - uses: hugoh/gh-workflows/setup@<pinned-sha>
      # - run: mise run vendor   # AudioPilot only
      - run: mise run test
```

### `spoon-release.yml` — tag, release, deploy docs

The one workflow with spoon-specific glue: on push to `main` it runs the
Conventional-Commit bump ([`hugoh/cog-bump`](https://github.com/hugoh/cog-bump)),
and when that yields a new tag it stamps `obj.version` into `init.lua`, packages
the spoon zip, creates a GitHub Release, and deploys `docs/` to GitHub Pages.
Chore-only merges bump nothing and the job is a no-op — dispatch with
`bump: patch` to force a release from such history.

```yaml
name: Release
on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      tag:
        description: Existing tag to (re-)release; leave empty for normal use
        required: false
        type: string
      bump:
        description: Force the bump level (auto = derive from commits)
        required: false
        type: choice
        default: auto
        options: [auto, patch, minor, major]

permissions:
  contents: write
  pages: write
  id-token: write

jobs:
  release:
    uses: hugoh/spoon-tools/.github/workflows/spoon-release.yml@<pinned-sha>
    with:
      spoon_name: MySpoon   # must match obj.name in init.lua
      tag: ${{ inputs.tag }}
      bump: ${{ inputs.bump }}
```

The calling repo must have GitHub Pages enabled (source: GitHub Actions) and the `github-pages` environment configured.

#### Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|   INPUT    | REQUIRED | DEFAULT  |                                                         DESCRIPTION                                                         |
|------------|----------|----------|-----------------------------------------------------------------------------------------------------------------------------|
|    bump    |  false   | `"auto"` | Force the bump level instead of deriving it from the commits: auto (default), patch, minor, major. Ignored when tag is set. |
| docs_only  |  false   | `false`  |      Regenerate and redeploy the Pages docs only; no bump, no GitHub Release. Uses `tag`, or the latest tag if empty.       |
| spoon_name |   true   |          |                Spoon name (e.g. AudioPilot) — used for the zip filename and must match obj.name in init.lua                 |
|    tag     |  false   |          |         Existing tag to (re-)release; skips the Conventional-Commit bump. Leave empty for normal push-to-main use.          |

<!-- AUTO-DOC-INPUT:END -->

#### Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->
No outputs.
<!-- AUTO-DOC-OUTPUT:END -->

---

## Renovate preset

Add to a spoon's `.renovaterc.json` to inherit all shared Renovate config (automerge, scheduling, grouping, Lua version cap):

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>hugoh/spoon-tools"]
}
```

> **Note:** `default.json` in this repo root is the Renovate preset file. It is not package config.
