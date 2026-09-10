# spoon-tools

Shared tooling for [Hammerspoon](https://www.hammerspoon.org/) Spoon repositories. Contains a doc generator, reusable GitHub Actions workflows, and a Renovate config preset — things that would otherwise be copied into every spoon.

---

## `spoon-generate-docs`

Parses Hammerspoon-style `---` docstrings from `init.lua` and writes:

- `docs/docs.json` — structured JSON used by the release workflow
- `docs/index.html` — a standalone rendered doc page deployed to GitHub Pages

It reads `obj.version` from `init.lua` and auto-detects the repo URL from `git remote get-url origin`.

**Local invocation** (run from inside a spoon repo):

```sh
uvx --from git+https://github.com/hugoh/spoon-tools spoon-generate-docs
```

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
Chore-only merges bump nothing and the job is a no-op.

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
```

The calling repo must have GitHub Pages enabled (source: GitHub Actions) and the `github-pages` environment configured.

#### Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|   INPUT    | REQUIRED | DEFAULT |                                                DESCRIPTION                                                 |
|------------|----------|---------|------------------------------------------------------------------------------------------------------------|
| spoon_name |   true   |         |        Spoon name (e.g. AudioPilot) — used for the zip filename and must match obj.name in init.lua        |
|    tag     |  false   |         | Existing tag to (re-)release; skips the Conventional-Commit bump. Leave empty for normal push-to-main use. |

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
