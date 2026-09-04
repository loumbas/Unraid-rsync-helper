## 2026.09.04d
- Fix: WebUI state blob (#rj-data) was HTML-escaped inside a raw-text script tag, so
  JSON.parse failed and the whole page JS died on startup (Browse/Save/Run never bound).
  State now ships as real JSON with only the five risky characters hex-escaped.
- JS hardening: rjData() falls back to complete defaults - a bad blob can no longer
  kill the ready handler.
- Jobs table: Source-to-Destination ellipsis moved to a div wrapper (max-width on a
  table cell is ignored in auto table layout); table set width:100%.

## 2026.09.04c
- Page footer: plugin version + storage path shown at the bottom of every tab (makes a
  stale over-install obvious at a glance - updates need remove-then-install on this box).
- Form CSS: path fields and other inputs are width-capped and box-sizing:border-box,
  so they no longer crop at the settings-table edge on narrow screens.

## 2026.09.04b
- WebUI: path browser for Source, Destination, Backup dir and Script fields - modal
  picker with Server tab (/mnt/user shares, array disks, mounts) and Rclone remotes
  tab (bucket/folder listing), breadcrumbs, Up/Refresh, double-click select.
- Engine: new read-only 'browse' subcommand (single JSON object): whitelisted roots,
  realpath containment (symlink/.. escape rejected), dot-folders hidden, 500-entry cap,
  time-bounded rclone listings; Script mode additionally lists *.sh under the plugins dir.
- ajax: new 'browse' action (POST+CSRF, thin dispatch to the engine).

## 2026.09.04a
- pluginURL/support/project now point to the public GitHub repo - Check for Updates
  and one-click install-from-URL work.
- Method="update" pre-clean: updates wipe the stale RAM copy before redeploying files.
- launch fixed to Utilities/rclone-jobs; deprecated category attribute removed.
- JS handlers namespaced (.rclonejobs); destructive actions use swal confirmations.

## 2026.09.04
- WebUI: inline .page content (Unraid 7 webgui drops File=), absolute ajax paths, menu entry
  with icon under User Utilities. Fix: notify.env TG_TOKEN parsing.

## 2026.09.02
- Initial release. Scheduled rclone / rsync / custom jobs with a dry-run gate,
  Telegram + Dynamix alerts, self-diagnosing doctor, strict share policy (all
  plugin data in a hidden dot-folder on an array disk, never under /mnt/user).
- Scheduling via a managed block in /var/spool/cron/crontabs/root (Dillon cron)
  with rc.crond restart only on change; Dynamix Scheduler entries are preserved.
- Uninstall keeps /boot config and all job data (logs, status, backups, notify.env).
