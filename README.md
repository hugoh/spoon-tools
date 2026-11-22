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

The Hammerspoon `hs` mock the spoons test with now lives in its own repository,
[hugoh/hs-mock](https://github.com/hugoh/hs-mock), and is published to
[luarocks.org](https://luarocks.org/modules/hugoh/hs-mock). The Renovate preset
below bumps a spoon's `HS_MOCK_VERSION` pin from its releases.

---

## Workflows

A spoon uses one `ci.yml`: lint and tests need nothing spoon-specific (call
[`hugoh/gh-workflows`](https://github.com/hugoh/gh-workflows) directly), a
`ci-gate` job aggregates them, and `release` runs only once the gate passes.
`ci-gate` is the single required status check.

### `ci.yml` — checks, gate, release

`setup` (checkout + mise) then `mise run test` (busted). Interleave any extra
step — e.g. AudioPilot vendors JS deps first.

The release calls `spoon-release.yml` below: on push to `main` it runs the
Conventional-Commit bump ([`hugoh/cog-bump`](https://github.com/hugoh/cog-bump)),
and when that yields a new tag it stamps `obj.version` into `init.lua`, packages
the spoon zip, creates a GitHub Release, and deploys `docs/` to GitHub Pages.
Chore-only merges bump nothing and the job is a no-op — dispatch with
`bump: patch` to force a release from such history.

```yaml
name: ci

permissions: {}

concurrency:
  group: ${{ github.workflow }}-caller-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

on:
  push:
    branches:
      - main
  pull_request:
  workflow_dispatch:
    inputs:
      tag:
        description: Tag to release (used to backfill a missed release; leave empty for normal use)
        required: false
        type: string
      bump:
        description: Force the bump level (auto = derive from commits)
        required: false
        type: choice
        default: auto
        options: [auto, patch, minor, major]
      docs_only:
        description: Regenerate and redeploy the Pages docs only (no bump, no release)
        required: false
        type: boolean
        default: false

jobs:
  check:
    uses: hugoh/gh-workflows/.github/workflows/hk.yml@<pinned-sha>
    permissions:
      contents: read
      packages: read
      statuses: write

  test:
    name: Tests
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    steps:
      - uses: hugoh/gh-workflows/setup@<pinned-sha>
      # - run: mise run vendor   # AudioPilot only
      - run: mise run test

  ci-gate:
    if: always()
    needs: [check, test]
    runs-on: ubuntu-latest
    timeout-minutes: 2
    permissions: {}
    steps:
      - uses: re-actors/alls-green@<pinned-sha>
        with:
          jobs: ${{ toJSON(needs) }}

  release:
    needs: ci-gate
    if: github.event_name != 'pull_request'
    permissions:
      contents: write
      pages: write
      id-token: write
    uses: hugoh/spoon-tools/.github/workflows/spoon-release.yml@<pinned-sha>
    with:
      spoon_name: MySpoon   # must match obj.name in init.lua
      tag: ${{ inputs.tag }}
      bump: ${{ inputs.bump }}
      docs_only: ${{ inputs.docs_only == true }}
```

A spoon that ships a native macOS binary builds it inside its `mise run package` task and sets `runs_on: macos-latest`; only the release job moves to macOS, and the docs deploy stays on Linux.

The calling repo must have GitHub Pages enabled (source: GitHub Actions) and the `github-pages` environment configured.

#### Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|   INPUT    | REQUIRED |      DEFAULT      |                                                                DESCRIPTION                                                                 |
|------------|----------|-------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
|    bump    |  false   |     `"auto"`      |        Force the bump level instead of deriving it from the commits: auto (default), patch, minor, major. Ignored when tag is set.         |
| docs_only  |  false   |      `false`      |              Regenerate and redeploy the Pages docs only; no bump, no GitHub Release. Uses `tag`, or the latest tag if empty.              |
|  runs_on   |  false   | `"ubuntu-latest"` | Runner label for the release job (the one that runs `mise run package`). Use macos-latest for a spoon that packages a native macOS binary. |
| spoon_name |   true   |                   |                        Spoon name (e.g. AudioPilot) — used for the zip filename and must match obj.name in init.lua                        |
|    tag     |  false   |                   |                 Existing tag to (re-)release; skips the Conventional-Commit bump. Leave empty for normal push-to-main use.                 |

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
