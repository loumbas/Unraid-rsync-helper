# rclone-jobs for Unraid

Scheduled **rclone / rsync / custom-script** jobs for Unraid 7, built around one rule:
**nothing ever deletes or overwrites data you have not previewed first.**

Runs alongside (never inside) the `rclone` plugin by Waseh and reuses its config
(`/boot/config/plugins/rclone/.rclone.conf`).

## What it does

- Job types: `rclone` (sync/copy/check), `rsync`, `custom` (any script, no shell metachars in config).
- Scheduling via a managed block inside `/var/spool/cron/crontabs/root` (Unraid's Dillon
  cron does not read `/etc/cron.d` and never re-reads changed crontabs; the plugin
  restarts the cron service only when the block actually changes). Dynamix Scheduler
  entries are preserved byte-for-byte.
- **Dry-run gate**: every job starts in dry-run mode. A job becomes "real" only after a
  successful preview whose config hash still matches the current config. Editing a job
  re-arms the gate. A global **master switch** (default ON) forces *all* scheduled runs
  to stay dry-runs.
- Deletion safety: `--max-delete` hard cap, warn threshold, optional delete-confirmation
  (`Ack`) in the WebUI, optional `BACKUPDIR` (before-delete copy to a remote or the
  storage folder).
- Alerts: native Unraid notifications only. Delivery (bell, email, Telegram, Discord,
  Pushover) is configured once under *Settings → Notification Settings*; nothing to set
  up here and no credentials stored. Per-job `NOTIFY=always|failures|off` plus a quiet
  window for the OK notices. `notify-test` / a UI button / `doctor --notify` verify it.
- Self-diagnostics: `doctor` checks rclone wrapper/config, storage policy, crontab sync,
  cron daemon, binaries, notify script — one pasteable block.
- Locks: per-job `flock` (overlapping runs are skipped + alerted); watchdog detects
  stuck runs and >26 h without success — it runs automatically every 15 min from the
  managed cron block (also compacts history and prunes logs; `watchdog` by hand works too).
- Retention (tiered, survives minutes-schedules): run history keeps raw lines for
  24 h, hourly buckets for 7 days, daily buckets for 90 days; OK/dry-run logs age
  out after 3 days (max 300/job), failed logs stay 14 days — all tunable in
  `paths.env` or the Safety tab.

## Safety model (hard guarantees)

| Guard | Behavior |
|---|---|
| Master dry-run switch | ON by default; when ON, schedule = simulation, period |
| Per-job gate | real run requires a fresh matching dry-run |
| Share policy | plugin data lives in a hidden dot-folder (`/mnt/diskN/.rclone-jobs`), never under `/mnt/user`, `/boot`, `/etc`, `/usr`, `/var/log`, `/` |
| Mount guard | source must exist, destination must be an already-mounted non-tmpfs directory; never auto-creates destinations |
| Storage overlap | a job with SRC/DST **inside** the storage folder is refused; a job whose SRC/DST **contains** it (hosting disk root, `/mnt/user`) runs with `/.rclone-jobs` auto-excluded (custom engine: warned, cannot exclude) |
| Config injection | job names, schedules and paths are whitelist-validated; config values are never shell-evaluated |
| WebUI | POST-only ajax, CSRF-checked, values re-validated server-side |
| Path browser | read-only listing; confined to `/mnt/user`, `/mnt/diskN`, `/mnt/remotes` (plus the plugins dir for Script), symlink-escaped paths rejected, dot-folders hidden, 500-entry cap, rclone calls time-bounded |
| Uninstall | removes code + schedule block; keeps your configs, logs and status data |

## WebUI

**Utilities → rclone-jobs**: Jobs (table, dry-run/run/ack/edit/delete, per-job notify
level), Alerts & Safety (master switch, quiet window, test notification), Doctor
(one-click self-test). Source, Destination,
Backup dir and Script fields have a **Browse...** picker: modal dialog with a Server tab
(shares/array disks/mounts) and an Rclone remotes tab (folders via `rclone lsf`); free
typing stays possible for not-yet-existing destinations.

## CLI

```
/usr/local/emhttp/plugins/rclone-jobs/engine/rclone-jobs.sh list|status|preview <job>|run <job>|ack <job>|notify-test [level]|doctor [--notify]|watchdog
```
A copy of the engine is kept in the storage folder (`/mnt/diskN/.rclone-jobs/rclone-jobs.sh`).

## Storage location & upgrades

Job data lives in a hidden dot-folder directly on an array disk
(`/mnt/diskN/.rclone-jobs`). It is not a share; note shfs does surface the path
(`/mnt/user/.rclone-jobs`) to `ls -a`/`find` — cosmetic only, and any job whose
SRC/DST is the hosting disk root or `/mnt/user` auto-excludes the folder (see
Safety model), so even this plugin's own whole-disk jobs never touch it. To upgrade: Plugins →
**Check for Updates → Update** (every embedded file carries a `<SHA256>`, so changed files are
redeployed, not skipped; config and all job data survive untouched). Remove-then-install remains
the fallback if an update ever leaves stale files behind.

## Files

| Location | Purpose |
|---|---|
| `/boot/config/plugins/rclone-jobs/paths.env` | settings (master switch, quiet window, optional STORAGE_ROOT) |
| `/boot/config/plugins/rclone-jobs/jobs/*.conf` | one file per job (KEY=VALUE, whitelisted keys) |
| `/mnt/diskN/.rclone-jobs/` | logs, status JSON, backups |
| `/var/spool/cron/crontabs/root` | managed block (BEGIN/END markers) |

See `src/CHANGELOG.md` for release notes and `INSTALL.md` for install instructions.

## Deviations from the community plugin guidelines

This plugin follows the standard Unraid plugin guidelines (single .plg with INLINE
files, CSRF-checked POST-only ajax, dynamix `notify` levels, LF-only + shebangs,
doc-prescribed file modes, `<CHANGES>` changelog). Three deliberate deviations,
each box-verified on Unraid 7.3.2:

| Deviation | Guideline says | Why here |
|---|---|---|
| Cron in `/var/spool/cron/crontabs/root` marker block | `<plugin>.cron` in /boot + `update_cron`, or `/etc/cron.d/` | Unraid's Dillon cron reads neither location and never re-reads changed crontabs; the marker block + restart-on-change (same approach as Dynamix Scheduler) is the only mechanism observed to actually fire. All other doc cron rules (logger redirect, overlap lock, array-state deferral) are followed. |
| Data in `/mnt/diskN/.rclone-jobs` dot-folder | `/mnt/user/appdata/<plugin>/` | Intentional product policy: plugin data must not be traversable by share tools or snapshotted by share-level jobs. Stricter than the docs' path allowlist, never looser. |
| No `set -e` in the engine | `set -e` + ERR trap | A failing job must not abort the run of the remaining jobs or the reporting; `set -uo pipefail` plus per-job error capture + contract exit codes (0/75/77/78/127) implements the same "fail loud, survive" goal. PLG INLINE blocks still end with `true` so a non-zero exit never aborts install/update. |

The `installed` / `updating` / `uninstalling` handlers in `event/` are plugin
lifecycle hooks (fired by Unraid's plugin manager, not the 16 emhttp array
events); they are quiet, idempotent and always `exit 0`. `array_started` and
`started` are genuine emhttp events: `array_started` can fire before the disks
are mounted, so `started` is the guaranteed retry for the engine deploy + cron
block once `/mnt/diskN` are really up.

## License

GPL-2.0-or-later.
