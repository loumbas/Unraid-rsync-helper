# rclone-jobs (Unraid plugin)

Single-file Unraid 7 plugin: `src/` is assembled into `dist/rclone-jobs.plg` (XML with
every file embedded as `<FILE><INLINE>`). There is no package manager, no npm/composer,
no CI — verification is the offline lint + manual on-box testing.

## Build & verify

- `pwsh -NoProfile -File build.ps1` — the only build command. Runs `tests/offline-lint.ps1`
  before (src) and after (dist); either failure aborts. `build.sh` is the WSL/Git-Bash twin
  and must stay **byte-identical** to `build.ps1` (compare the printed sha256 of the .plg).
- Lint only: `pwsh -NoProfile -File tests/offline-lint.ps1 -Root . [-Plg dist/rclone-jobs.plg]`
- `dist/rclone-jobs.plg` is intentionally committed — rebuild and commit it with any src change.
- There is no automated test suite; `tests/` holds the lint plus on-box acceptance records
  (`acceptance-*.md`, `baseline-*.txt`) from the operator's LMBS-SRV box (Unraid 7.3.2).

## Hard rules enforced by offline-lint.ps1 (build fails otherwise)

- Every shipped file (src/engine, src/emhttp, src/jobs) must be listed in `src/MANIFEST` —
  two-way checked, and targets must be under `/usr/local/emhttp/plugins/rclone-jobs/` with
  mode `0NNN`. Adding a file = adding a MANIFEST line.
- All `src/` files: LF-only, no BOM (`.gitattributes` normalizes this; `*.ps1` are the
  deliberate CRLF exception). Scripts and `emhttp/event/*` need a shebang; `*.page` must
  start with a `Menu=` line + `---` separator.
- Shipped files must not contain `C:\`, `/mnt/c/`, `loumpardias`, or `LMBS-SRV` (dev-machine
  leak scan). A `TG_TOKEN` assignment with a non-empty value anywhere in the repo fails
  the scan — secrets only in `$STORAGE_ROOT/notify.env` (600, never in /boot or the
  browser). Don't phrase repo rules in a way that re-triggers this scanner.

## Versioning / release

- Version is a date in `src/VERSION` (`YYYY.MM.DD`, optional lowercase same-day suffix
  like `2026.09.04a`), validated at build. `{{VERSION}}`
  placeholders in engine/page sources are stamped LAST by the build (after FILES/CHANGES);
  keep that substitution order in both build scripts.
- Release flow: bump `src/VERSION`, add a top `## YYYY.MM.DD` section to `src/CHANGELOG.md`
  (only that first section is embedded in the .plg), rebuild, commit src + dist together.
- `pluginURL` (entities in `src/rclone-jobs.plg.in`) points at the raw `main`-branch
  `dist/rclone-jobs.plg` of `https://github.com/loumbas/Unraid-rsync-helper` — never
  rename/move `dist/rclone-jobs.plg` or change the default branch without updating them.

## Architecture gotchas (Unraid-specific, verified on-box)

- `src/engine/rclone-jobs.sh` is the whole backend; PHP (`ajax.php`, `preview.php`) only
  shells out to it. It runs **alongside** the rclone plugin: never passes `--config`,
  reuses `/boot/config/plugins/rclone/.rclone.conf`.
- Deliberately **no `set -e`** in the engine (must survive failing jobs to report them);
  `set -uo pipefail` + internally hardened PATH (cron's PATH lacks `/usr/sbin` where the
  rclone wrapper lives). Exit codes 0/75/77/78/127 are contract — see engine header.
- Scheduling: Unraid's Dillon cron reads only user crontabs, never `/etc/cron.d`. Jobs go
  in a marker block in `/var/spool/cron/crontabs/root`; `regen-cron.sh` restarts cron only
  when the block actually changed and must preserve Dynamix entries byte-for-byte.
- Unraid 7 WebUI: `.page` content must be INLINE (the `File=` directive is dead); ajax and
  script URLs must be absolute. Page lives at Settings via `Menu="Utilities"`.
- Storage policy (engine-enforced): plugin data only in a hidden dot-folder on an array
  disk (`/mnt/diskN/.rclone-jobs`); `/mnt/user`, `/etc`, `/usr`, `/var/log`, `/` rejected.
- Upgrades on this box require **remove-then-install** (over-install refreshes the saved
  .plg but not deployed files) — do not "fix" this in code; it is documented in INSTALL.md.

## Scope notes

- `plugin-docs/` is untracked (gitignored) reference docs from a plugin template. Treat it
  as read-only reference: `plugin-docs/docs/` documents Unraid plugin mechanics (plg file,
  events, page files, CSRF, cron, Dynamix framework) — useful when in doubt, but its
  `release.ps1` (git tagging) and validation scripts belong to that template, not to this
  repo's flow. Don't edit it as if it shipped.
- Safety model (dry-run gate, master switch, `--max-delete`, mount guard, CSRF/POST-only
  ajax) is the product's core promise; changes must not weaken it. Re-check README.md
  "Safety model" table after touching engine or ajax code.
