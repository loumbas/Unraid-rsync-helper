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
- Alerts: Unraid notifications (Dynamix) + optional Telegram (bot token in
  `notify.env`, mode 600, never stored in /boot or the browser).
- Self-diagnostics: `doctor` checks rclone wrapper/config, storage policy, crontab sync,
  cron daemon, binaries, notify.env perms — one pasteable block.
- Locks: per-job `flock` (overlapping runs are skipped + alerted); watchdog detects
  stuck runs and >26 h without success.

## Safety model (hard guarantees)

| Guard | Behavior |
|---|---|
| Master dry-run switch | ON by default; when ON, schedule = simulation, period |
| Per-job gate | real run requires a fresh matching dry-run |
| Share policy | plugin data lives in a hidden dot-folder (`/mnt/diskN/.rclone-jobs`), never under `/mnt/user`, `/etc`, `/usr`, `/var/log`, `/` |
| Mount guard | source must exist, destination must be an already-mounted non-tmpfs directory; never auto-creates destinations |
| Config injection | job names, schedules and paths are whitelist-validated; config values are never shell-evaluated |
| WebUI | POST-only ajax, CSRF-checked, values re-validated server-side |
| Uninstall | removes code + schedule block; keeps your configs, logs, status and Telegram file |

## WebUI

**Settings → rclone-jobs**: Jobs (table, dry-run/run/ack/edit/delete), Alerts & Safety
(master switch, quiet window, Telegram), Doctor (one-click self-test).

## CLI

```
/usr/local/emhttp/plugins/rclone-jobs/engine/rclone-jobs.sh list|status|preview <job>|run <job>|ack <job>|doctor [--telegram]|watchdog
```
A copy of the engine is kept in the storage folder (`/mnt/diskN/.rclone-jobs/rclone-jobs.sh`).

## Storage location & upgrades

Job data lives in a hidden dot-folder directly on an array disk
(`/mnt/diskN/.rclone-jobs`). It is not a share and share tools never traverse it;
note shfs does surface the path (`/mnt/user/.rclone-jobs`) to `ls -a`/`find` —
cosmetic only. To upgrade: **remove the plugin, then install the new .plg**
(installing over an existing install may refresh the saved .plg but not the
deployed files; config and all job data survive a remove).

## Files

| Location | Purpose |
|---|---|
| `/boot/config/plugins/rclone-jobs/paths.env` | settings (master switch, quiet window, optional STORAGE_ROOT) |
| `/boot/config/plugins/rclone-jobs/jobs/*.conf` | one file per job (KEY=VALUE, whitelisted keys) |
| `/mnt/diskN/.rclone-jobs/` | logs, status JSON, backups, `notify.env` (600) |
| `/var/spool/cron/crontabs/root` | managed block (BEGIN/END markers) |

See `src/CHANGELOG.md` for release notes and `INSTALL.md` for install instructions.

## License

GPL-2.0-or-later.
