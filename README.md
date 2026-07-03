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

## Reusable workflows

Reference these from a spoon's `.github/workflows/` directory with `uses:`.

### `spoon-hk.yml` — lint checks

Runs `hk check` (via mise). Use for push/PR CI.

```yaml
name: hk
on:
  push:
    branches: [main, renovate/**]
  pull_request:

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  check:
    uses: hugoh/spoon-tools/.github/workflows/spoon-hk.yml@main
```

### `spoon-tests.yml` — Lua tests

Runs `mise run test` (busted). Accepts an optional `pre_test` command to run first (used by AudioPilot to vendor JS dependencies).

```yaml
name: Tests
on:
  push:
    branches: [main, renovate/**]
  pull_request:

jobs:
  test:
    uses: hugoh/spoon-tools/.github/workflows/spoon-tests.yml@main
    # with:
    #   pre_test: mise run vendor   # AudioPilot only
```

**Inputs:**

| Input      | Required | Description                                 |
| ---------- | -------- | ------------------------------------------- |
| `pre_test` | No       | Shell command to run before `mise run test` |

### `spoon-release.yml` — release and deploy docs

Triggered by a `v*` tag push. Updates `obj.version` in `init.lua`, packages the spoon zip, creates a GitHub Release, and deploys `docs/` to GitHub Pages.

```yaml
name: Release
on:
  push:
    tags: ["v*"]

jobs:
  release:
    uses: hugoh/spoon-tools/.github/workflows/spoon-release.yml@main
    with:
      spoon_name: MySpoon   # must match obj.name in init.lua
    secrets: inherit
```

**Inputs:**

| Input        | Required | Description                                               |
| ------------ | -------- | --------------------------------------------------------- |
| `spoon_name` | Yes      | Spoon name (e.g. `AudioPilot`); used for the zip filename |

The calling repo must have GitHub Pages enabled (source: GitHub Actions) and the `github-pages` environment configured.

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
