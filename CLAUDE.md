# CLAUDE.md — proxmox-host-scripts

Read this before doing anything in this repo. These rules are not suggestions.

## What this repo is

Scripts that run **on the Proxmox VE host** to simplify housekeeping and
everyday host tasks (for example downloading ISOs). Companion of
[proxmox-recipes](https://github.com/farmnerds-net/proxmox-recipes), which
builds app containers.

## Engine

- Scripts load `misc/core.func` (output, logging, error trap, `run_step`,
  `preflight_checks`) from proxmox-recipes, `RECIPES_SRC` / `RECIPES_REF`
  as there. Never copy it here; changes to it go through a PR there.
- Shared code for this repo lives in `lib/` (`ui.func` menus,
  `progress.func` meter). Add to `lib/` only when a second script needs it.
- Loading: each script has an `hs_load` that reads `lib/...` from
  `HOST_SCRIPTS_SRC` (local checkout) or GitHub at `HOST_SCRIPTS_REF`.
  Files are sourced inside a function, so declare globals with
  `declare -g` (`declare -A` there would be local and vanish).
- Like the recipes engine: every question stores its answer in a plain
  variable and is skipped when it is already set, so scripts can run
  without questions. Only `lib/ui.func` reads input.
- Logs go to `/var/log/proxmox-host-scripts/<script>.log` (mode 0600);
  settings a script remembers go in `/etc/proxmox-host-scripts/`.
- Bash: `set -Eeuo pipefail`, quote everything, ShellCheck clean (`.func`
  checked as bash). With `set -E` the ERR trap fires inside command
  substitutions, so functions used in `$(...)` must not end on a failed
  test (`[[ x ]] && printf` as the last command): use `if` and `return 0`.
- **No telemetry.** Nothing phones home.

## Clean-room rule

Original work. Do **not** copy code, names, menu text or flow from
community-scripts/ProxmoxVE (including its host "tools" scripts) or any
other helper-script project, and don't read their source while writing.

## Safety rules (hard)

Claude Code runs as root on a Proxmox host. Protect it.

- **Test on farmlab2 only**, never the production host.
- **Read-only scripts** (reports, checks) may be run freely on farmlab2.
- **Scripts that change host configuration** (repos, packages, network,
  `/etc/pve`, storage config, firewall, cluster, kernels) must not be run
  on farmlab2. Agree with the user on a safe test target first.
- **iso-download:** test downloads to the `local` storage on farmlab2 are
  allowed. **Delete every test ISO afterwards** (`pvesm free local:iso/<file>`)
  and confirm the storage is back to how it was.
- Only create, modify or destroy guests with IDs 900–999.
- A script is done only when ShellCheck passes and a real run on farmlab2
  succeeds within the rules above.

## iso-download specifics

- Catalog and resolvers: `iso/catalog.func`. Resolvers read only the
  distribution's official release files or an official mirror the
  distribution lists, and must yield an https URL plus a SHA-256/512.
  No resolver → `manual` entry (official pages shown, user pastes a link
  and checksum). Never guess or scrape third-party download links.
- **Respect sites' wishes.** If a site refuses scripted requests (403,
  bot checks), don't work around it: drop it or make the entry manual.
  The popularity order is curated in the catalog, not fetched live.
- Downloads go through Proxmox's own `download-url` API. `pvesh` exits 0
  even when that task fails: always check the task's `exitstatus`.
- Run `iso-download.sh --check` after any catalog change; every `auto`
  entry must pass.

## Git

- Branch per change, push it, open a PR to `main` for the user to review.
  Don't push straight to `main`.
- Commit messages: short imperative subject, body explains why.
