## 2026.09.07i
'stopping' event: a loud trace when jobs are cut off by an array stop:
- New emhttp event 'stopping' (10 s timeout cap, always exits 0 - a shutdown is never
  delayed): the engine's 'shutdown-notice' counts jobs whose status says running AND
  whose run lock is actually held (a stale status from an old hard kill never notifies),
  writes one syslog line and one bell notice (once-marker in /tmp).
- cmd_run is now signal-aware: the transfer runs in the background and 'wait' lets a
  TERM/INT trap mark the status rc=143 immediately, append 'interrupted by signal' to
  the job log and publish the state over SSE before the engine exits 143. rclone
  children are left to the shutdown's own kill pass (no force-killing from the engine).
- The tty branch keeps the real engine exit code via a pipefail-wrapped subshell
  (a bare backgrounded pipeline would report tee's status instead).

## 2026.09.07h
Tail-log viewer in the WebUI:
- Engine: the absolute log path is now recorded into the status file at run START (so a
  live run's log is viewable too) and kept by status_finish; new 'tail-log <job>'
  subcommand returns the redacted tail (64 KiB, NUL-stripped) of that log as JSON with a
  byte-count banner. The path comes only from the validated status file and must sit
  inside LOG_DIR - a request can never name a path (no traversal).
- WebUI: a 'Log' button per job row shows the redacted tail in the result panel; ajax
  'tail_log' is a thin POST+CSRF passthrough like every other action.
- Old status files (from before the log key) get a clear 'run it once' message.

## 2026.09.07g
Live status via nchan SSE - the Jobs table now updates itself:
- Engine: sse_publish() sends a fire-and-forget POST to http://localhost/pub/rclone-jobs
  (nchan ships with Unraid 7; 2 s curl cap, never fatal - cron runs without nginx do not
  care) at run start (after the lock) and at both finish paths (dry + live).
- Engine: new 'status-json' subcommand returns every job's run + dry-run state as one
  JSON object; a corrupt status file degrades that job's fields to null instead of
  breaking the response.
- WebUI: EventSource('/sub/rclone-jobs') patches the Last run / Last OK / Last dry-run
  cells in place (debounced 500 ms) and adds/removes the [NEEDS ACK] badge + Ack button
  by the real gate rule; row buttons are now delegated so the live-added Ack works.
  After two socket failures the page degrades to a 60 s auto-refresh (there was none at
  all before) with a 'live: off' indicator; the indicator shows live/connecting/off.
- Run button message no longer tells the user to reload - the table updates live.

## 2026.09.07f
Async dry-run preview - long previews no longer run inside the web request:
- Engine: new 'preview-start' / 'task-status' / 'task-cancel' subcommands. The dry-run
  is detached with setsid (own process group so cancel reaches the rclone children);
  output goes to $STATUS_DIR/task-<job>.out, exit code to .rc, session-leader pid to
  .pid. task-status reports redacted output (tail-capped 256 KiB) exactly once
  (single-consume) and cleans up; a dead child without an .rc is reported as 143.
- save_job no longer previews inline (that call could hang an emhttp worker for
  minutes on a huge remote); the UI chains the preview after the save and the task
  survives the table reload (a sessionStorage flag makes the fresh page resume it).
- WebUI: the Dry-run button now shows live 'running... Ns' progress with a Cancel
  button; the job run-lock is checked before spawning, so a preview can never queue
  behind a live run. Watchdog prunes finished task files older than 1 hour.
- 'run_dry' (synchronous) is kept, deprecated, for one release for old cached pages.

## 2026.09.07e
Best-practices compliance pass (checked against the Unraid plugin-dev docs) + fixes:
- Boot robustness: new 'started' event retries the engine deploy + cron block once the
  array is fully mounted - covers the case where array_started fired before /mnt/diskN
  were actually mounted (deferred deploys used to wait for the next boot/save).
- Safety policy: STORAGE_ROOT under /boot is now REFUSED everywhere (engine,
  install-engine, doctor) - the flash device must not take job data (USB wear).
- Custom-script jobs: the schedule is validated at save time like every other engine -
  an invalid SCHEDULE used to be written and then silently skipped by the scheduler.
- Jobs table: the [NEEDS ACK] badge and the Ack button now follow the engine's real
  gate rule (predicted deletions > WARN_DELETE and not yet acked); previously the
  badge could never appear.
- Recovery etiquette: a successful run clears its stale FAILED / refused / gate
  notifications from the WebUI bell and re-arms the watchdog dedup.
- Live runs started from the WebUI are detached with nohup (survive php-fpm child
  reaping). Job configs and paths.env are written atomically (tmp+rename).
- Ajax hardening: non-scalar POST values are rejected instead of warning; a malformed
  quiet-window value is now reported as an error instead of being silently dropped.
- WebUI: weekday 7 (=Sunday) is accepted in the Custom cron preview like the server
  accepts it; deletion Ack uses a proper typed-confirmation dialog instead of prompt();
  Save buttons disable while their request is in flight; tab strip and Browse/Ack
  dialogs use webGui theme variables (light theme safe) with the old colors as fallback.
- paths.env gains a CONFIG_VERSION=1 marker on fresh installs (readers ignore unknown
  keys; future format changes migrate from this value).
- Build lint: shellcheck (severity=warning) and php -l now run over the shipped
  scripts/PHP when those tools exist on the build box; skipped with a note when absent.

## 2026.09.07d
- Doctor fix (seen on a box with no jobs): the report no longer WARNs that the cron
  block is missing when nothing is scheduled - with zero jobs (or only disabled ones)
  a missing block is the CORRECT state and regen-cron.sh would add nothing. The
  report now says explicitly 'no jobs configured' and the WARN still appears when
  enabled jobs exist but the block does not.
- Doctor fix: the by-design minimal-PATH probe failure (exit 127 - cron's PATH lacks
  /usr/sbin) is reported as INFO instead of WARN; a WARN now only appears on an
  unexpected exit code.
- Doctor tab: explanatory text added - what the checks cover, the PASS/INFO/WARN/FAIL
  legend, that the run is read-only apart from saving a report copy, and that the
  fenced block at the end is a paste-ready summary for support threads.

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
