## 2026.09.07c
- No cron knowledge needed anymore: the job form's Schedule field is now a visual
  builder - every N minutes | hourly | daily | weekly (weekday checkboxes) |
  monthly (day-of-month) | Custom (cron) - with a live summary showing the
  generated expression, the next 3 run times and gotcha notes (EITHER-matching
  when a custom expression restricts both day-of-month and day-of-week; months
  without day 29-31 skip). Existing expressions are reverse-mapped into the
  builder on Edit; anything exotic stays editable under Custom.
- The jobs table Schedule column shows human text (e.g. "Every day at 03:30");
  the raw cron expression is on hover.
- Storage format unchanged: SCHEDULE remains a classic 5-field cron line, the
  engine and crontab generation are untouched. The ajax validator additionally
  range-checks each field (0-59, 0-23, 1-31, 1-12, 0-7) as defense-in-depth.

## 2026.09.07b
- Tabs now look like tabs. The page CSS is injected from a small inline script at
  parse time: an inline <style> block inside .page content did not survive rendering
  on Unraid 7.3.2, so the strip showed as a bare bulleted list spread across the
  whole page. Real tab strip now: compact, left-aligned, no bullets, active tab
  connected to a full-width underline bar (theme-independent, dark+light safe).
- Quiet-window inputs stay on one row (fixed small width, spaced 'to'); the Test
  level dropdown no longer stretches across the whole column.

## 2026.09.07a
- Notifications now use ONLY the native Unraid system: every alert goes through the
  webGui notify script, and delivery (WebUI bell, email, Telegram, Discord, Pushover)
  is whatever the user enabled per importance level under Settings -> Notification
  Settings. The plugin stores no credentials and never contacts a notification
  provider itself (the rclone transfers themselves are unchanged).
- Removed the built-in Telegram sender: the bot-token/chat-id fields, the notify.env
  secret file handling and 'doctor --telegram' are gone. Existing notify.env files
  are no longer read and are left untouched - delete the leftover secret file by
  hand when convenient: rm '/mnt/diskN/.rclone-jobs/notify.env'
- Fix: notifications were silently DELETED instead of shown - every call passed -x
  ("delete matching notification") to the notify script, so nothing ever appeared.
- New per-job Notify setting: always (OK + problems) | failures only | off. Old
  HEARTBEAT=no configs map to 'failures'; off also silences failures for that job
  (syslog and the job log are still written). The quiet window keeps suppressing
  only the OK notices.
- Richer notices: run results carry a full message body (seconds, transferred,
  error counts, log path) and a clickable link to the plugin page.
- Testing: new 'notify-test [normal|warning|alert]' engine command, a "Send test
  notification" button on the Alerts & Safety tab, and 'doctor --notify' (opt-in).

## 2026.09.07
- Fix: online update / over-install now actually replaces changed files. Every embedded
  file carries a <SHA256> of its deployed bytes; the plugin manager skips an existing
  destination unless a checksum fails, so without them an update refreshed the stored
  .plg but left the old files in place. Checksums are computed after the version stamp,
  so unchanged files still skip at boot and changed ones are redeployed on update.
- Verbosity: the plugin install/update and remove windows now show what is happening -
  previous version -> new version, emhttp copy being cleared, boot-setup progress,
  deployed-file count, and exactly what removal keeps (config + storage data) with the
  full-cleanup command.

## 2026.09.04l
- Fix: clicking a tab header popped Unraid's 'External link' dialog. Tab headers no longer
  carry href="#..." (Unraid's a[href] interceptor treats the bare hash as a navigation);
  they are href-less a.rj-tab elements with keyboard support (Enter/Space) and the URL
  still keeps #tab_rj_* so deep links and reloads land on the right tab.

## 2026.09.04k
- Plugin author changed to "sir_lou" (shown in Plugin Manager).

## 2026.09.04j
- The plugin info popup now carries the last 10 builds: the .plg <CHANGES> block embeds
  up to 10 '## ' sections of the changelog (newest first) instead of just the latest one.
- Plugins list: a brief description is now shown under the plugin name (desc attribute
  on the PLUGIN tag): "Schedule rclone/rsync jobs with a dry-run gate, mount guard,
  delete limits and Telegram/Dynamix alerts".

## 2026.09.04i
- WebUI layout: text/password inputs in the job form and Alerts tab are capped to the
  browse-row width (420px, max-width 100%) - no more full-page-width fields; number
  fields are 64px and Schedule/Bandwidth/Quiet-window keep their size= width. The
  Transfers/Checkers, Max/Warn deletes and Quiet-window rows stay on one line, and
  the Browse button sits beside its field again.
- Tabs now behave as tabs: the plugin initializes the ul.tabs strip itself (first tab
  active, other panels hidden, hash deep-links #tab_rj_* honored). State-setting and
  event-namespaced (.rjtab), so it coexists with any platform tab js.

## 2026.09.04h
- Storage-overlap guard: a job whose SRC or DST is inside the plugin storage folder
  is now REFUSED (exit 78 + alert) - logs/status/notify.env can no longer be uploaded
  or --delete-erased by a misconfigured job. A job whose SRC/DST contains the storage
  folder (the hosting disk root, or /mnt/user - shfs surfaces the dot-folder there)
  runs with the storage top folder auto-excluded: rclone gets two anchored --exclude
  patterns, rsync gets an anchored --exclude (which also shields it from --delete).
  ARGS --delete-excluded is refused; custom-engine jobs warn once per change (Telegram
  + notify + syslog) because no exclude can be injected there. Doctor reports the
  overlap per job; the job form shows an inline hint on SRC/DST.

## 2026.09.04g
- WebUI restyled to the native settings-page anatomy: icon .title section headers
  replace all fieldsets/legends (Add job, Safety, Telegram notifications, Doctor);
  button rows are now dl rows aligned with the fields; wide inputs use the webgui
  'variable' class; jobs table gains click-to-sort headers (native tablesorter).

## 2026.09.04f
- Settings forms rebuilt on the native Unraid pattern (definition-list rows plus
  inline-help blockquotes toggled by the sidebar Help button): no more table overflow,
  explanation text is never cropped.
- Help text added for every field on both tabs: cron syntax, engines, mode,
  source/destination rules, delete limits, backup dir, master switch, quiet window,
  Telegram token/chat id storage.

## 2026.09.04e
- Fix: every ajax action returned 403 - Unraid 7.2+ local_prepend.php validates the CSRF
  token and then UNSETS it from $_POST and the X-CSRF header before plugin PHP runs, so
  our re-check always saw an empty token. Token is now recovered from the raw urlencoded
  body (php://input, re-readable since PHP 5.6); the hash_equals re-check is kept as
  defense-in-depth.

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
