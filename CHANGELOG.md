# Changelog

## 2026.09.02
Initial release.

- Job engines: rclone (sync/copy/check), rsync, custom script; per-job schedule,
  dry-run flag, transfers/checkers, bandwidth limit, max-delete cap, warn threshold,
  backup dir.
- Dry-run gate (preview must pass before real run, config-hash bound), global master
  dry-run switch, mount guard, share policy (data outside /mnt/user in a hidden
  array dot-folder), per-job flock overlap protection.
- Scheduling: managed block in /var/spool/cron/crontabs/root + rc.crond restart on
  change only (Dillon cron specifics).
- WebUI (Settings): jobs table + editor, live dry-run previews, ack flow,
  Alerts & Safety (master, quiet window, Telegram), Doctor.
- Alerts: Dynamix notifications + optional Telegram (notify.env, 0600).
- Uninstall keeps all user configuration and data.
