## 2026.09.09i
UI Polish: Action Button Icons, Inline History Drawer, Filter Pills & Form Cards:
 - FontAwesome action buttons: enhanced row buttons with crisp FontAwesome icons (`<i class="fa fa-flask"></i> Dry`,
   `<i class="fa fa-play"></i> Run`, `<i class="fa fa-stop"></i> Stop`, `<i class="fa fa-file-text-o"></i> Log`,
   `<i class="fa fa-history"></i> Hist`, `<i class="fa fa-pencil"></i> Edit`, and trash icon for delete) matching
   the UI mockup.
 - Inline history drawer: clicking `Hist` now smoothly expands the run history card directly beneath the targeted
   job row as an inline drawer (with clean toggle, smooth scroll, and close button).
 - History filter pills: upgraded the raw runs failure filter from a plain checkbox to styled pill toggle buttons
   (`All runs` vs `Failures only`) matching the fleet toolbar design.
 - Card-based form containers: partitioned the Add/Edit form into 4 distinct visual sub-cards (Basics, Schedule,
   Transfer Settings, Limits & Safety) with individual title badges and borders.

## 2026.09.09h
Enhanced Verbosity for Plugin Updates & Installations:
 - Comprehensive update pre-clean reporting: displays current vs target version, explicitly confirms
   preservation of existing user job configurations, settings (`paths.env`), and array storage data.
 - Detailed 5-step installation diagnostics: during update or install, provides step-by-step console
   visibility into:
     1. WebUI package file count and SHA256 integrity verification against release manifest (`installed-checksums.txt`).
     2. Configuration directory & job definition counts, including master safety switch state (`DRY_RUN_MASTER`).
     3. Array storage tree verification (`logs/`, `status/`, `backup/`) and CLI engine synchronization.
     4. Cron schedule regeneration, active job entries, and 15-minute maintenance watchdog registration.
     5. System environment checks, detecting rclone binary, configured remotes, and rsync availability.
 - Standalone verbose CLI diagnostics: `boot-setup.sh --verbose` can now be executed manually via terminal
   to verify installation health at any time.

## 2026.09.09g
Inline Help Text Wrapping & Box Containment:
 - Helper text box containment: fixed `blockquote.inline_help` and its inner paragraph tags to enforce
   `white-space: normal`, `overflow-wrap: break-word`, and proper bounding box widths, preventing text
   from overflowing outside its container on a single line when editing inline within table rows.
 - Refined help callout styling: styled help blocks with a dark background (`#14191f`), crisp border with
   Unraid orange accent (`#ff8c2f`), and cyan emphasis highlighting.

## 2026.09.09f
Hourly Transfer Bar Chart & UI Styling from Mockup:
 - Hourly Transfer Bar Graph Card: added rolling 16-hour dual-tone bar graph (cyan data bars + mint activity bars)
   with Y-axis scaling, horizontal guide lines, hover inspection tooltips, and collapsible toggle.
 - Stat Summary Panel: paired with the hourly chart, presenting Avg Rate, 24h Transferred, Total Runs, and Last Run.
 - Cyan/Teal Engine Chip: restyled engine badges (e.g. `rclone/sync`) with elevated teal pill styling, subtle border,
   and engine icons matching the design mockup.
 - Punchy Status Badge: updated Last Run status pills with solid emerald green (`#10b981`), checkmark circle icon,
   and crisp white typography matching `ui-mockup.jpg`.

## 2026.09.09e
Data Tracking & Direct Job On/Off Toggle Switches:
 - Transferred data tracking fix: parse rclone's `--stats-one-line` log lines (`INFO : <size> / <size>, ...`),
   standard multi-line stats, and rsync stats so transferred bytes are accurately captured, recorded to
   status and history, and reflected in the 24h Data Moved card and Last Run column.
 - 24h Data Moved log fallback: automatically reads and tallies transfer sizes from existing run logs when
   prior records had unparsed bytes, immediately restoring accurate metrics without requiring re-runs.
 - Direct On/Off toggle switches: added interactive toggle switches in the table's "On" column, allowing
   instant job activation and deactivation with real-time cron regeneration without opening the edit form.
 - Transferred size in Last Run: display the transferred data amount directly in the Last Run status cell
   (e.g., `OK (4s · 1.050 MiB)`).

## 2026.09.09d
Form Left-Alignment & Edit Button Reliability:
 - Strict left-alignment: all form labels, input fields, selects, and action buttons are
   strictly left-aligned with clean horizontal flow, eliminating Unraid's 40% centered gap.
 - Preserved multi-field controls: inline controls (Transfers/Checkers, Schedules, and Delete caps)
   now stay on a single horizontal row without vertical stacking or centering.
 - Edit button toggle & DOM preservation: safely park `#rj-form-wrap` before detachment,
   preventing accidental DOM deletion and allowing repeat clicks on "Edit" to toggle the form.
 - Duplicate accordion cleanup: hides the redundant bottom accordion header while an inline form is active.

## 2026.09.09c
Inline Job Editing & SSE Daemon Health Connection fix:
 - Inline edit expansion: clicking "Edit" attaches the configuration card directly
   beneath the active job row with highlighted table row accent, keeping the user
   in context rather than jumping down below the table.
 - Inline "Add New Job": clicking "+ Add New Job" attaches the form card right at the
   top of the jobs table.
 - Modernized form card design: styled `#rj-form-wrap` with elevated card background,
   card header with close button, aligned flex field rows, and styled primary/secondary buttons.
 - Daemon Health onopen fix: added missing `EventSource.onopen` handler so the Daemon Health
   indicator immediately transitions to active green `● Live SSE` upon connection.

## 2026.09.09b
Visual enhancement & layout polish matching design mockup:
 - Elevated KPI cards: explicit contrast background (#20262d) and crisp borders (#333d47)
   replacing flat background matching Unraid's dark canvas.
 - 24h Data Moved KPI: calculated rolling 24-hour transfer throughput across active
   jobs displayed in the third summary card.
 - Fleet Toolbar integration: relocated primary "+ Add New Job" button into the fleet
   toolbar alongside refined filter pills (All, Active, Failed) and search input.
 - Card-style table rows: separated rows with individual borders and left status color accents
   (green OK, red failed, blue running, amber ack).
 - Endpoint badge tags: source and destination paths styled as discrete monospace endpoint
   chips with distinct cloud/folder iconography and directional arrows.
 - Semantic status badges: success exit codes rendered as readable "OK (Xs)" rather than "0 (Xs)".
 - Polished action buttons: mixed-case typography with native Unraid orange border accents.

## 2026.09.09a
UI & UX feature additions:
 - Action button grouping: table action buttons organized into functional
   segments (Execution, Diagnostics, Management) with clean dividers while
   retaining native Unraid button styling.
 - Next scheduled run countdown: humanized relative countdown (e.g. "Next: in 4h 15m")
   displayed directly under the schedule frequency in each job row.
 - Fleet toolbar: live client-side search input and quick filter pills (All,
   Active, Failed) above the jobs table for rapid navigation.
 - In-form path autocomplete: source and destination input fields suggest
   configured rclone remotes (from .rclone.conf) and local user shares (/mnt/user/).
 - In-form Test (Dry-run): dedicated button next to Save job to test transfers
   directly inside the accordion form before scheduling.

## 2026.09.09
Restore native Unraid button styling:
 - Reverted button overrides to restore native Unraid `<input type="button">`
   elements with signature orange edges across the WebUI (actions, quick add, history,
   and ack controls).

## 2026.09.08h
Modern WebUI redesign & UX enhancements:
 - KPI metric cards: replaced the plain text status strip with 4 compact summary
   cards (Total & Enabled Jobs, Master Dry-Run Safety status with color-coded
   pill, Daemon SSE connection status with pulsing live dot, and Quick Action
   to add jobs directly from the header).
 - Jobs table styling:
    * Source to Destination paths visually distinguish cloud remotes (cloud
      icon) from local shares/disks (folder icon) with a styled directional flow.
    * Last Run status rendered as a rounded semantic pill (OK, Failed, Running)
      with subtle background tinting.
    * Last Dry-Run output split into distinct mini diff chips (+copies,
      -deletes, !fails) for immediate clarity.
    * Table action buttons organized into a clean button group using Unraid's
      native FontAwesome icon set (Dry, Run/Stop, Ack, Log, Hist, Edit, Del)
      with zero hover animation and native theme border overrides.
 - History drawer: refactored the run history view into a dedicated card panel
   with 24h summary metric cards, rounded CSS sparkline bars, and scrollable
   containers with sticky headers for raw runs and daily rollups.
 - 100% backward compatible: pure HTML/CSS/JS presentation layer improvements
   using Unraid 7 theme variables, with zero external dependencies.

## 2026.09.08f
Live job cancellation (Stop) + detached runs + phantom-status repair:
 - Engine 'stop <job>': stops a live run from the WebUI (red Stop button on a
   running row, with confirmation) or the CLI. Graceful path: stop marker +
   SIGTERM; the run's own trap records rc=143 (status, SSE, history, keep the
   log), then SIGKILL escalation if the engine ignores TERM. A pid is only
   ever signaled when it is alive AND holds the job lock AND its cmdline
   references rclone-jobs + that exact job - a recycled pid can never be
   killed. Stop on an idle job is a clean no-op; syslog + a bell notice
   record the operator stop.
 - Non-tty runs (cron, WebUI) now detach into their own session via setsid
   (same pattern as the preview tasks): the engine is the group leader, so
   the group TERM reaches rclone/rsync/custom-script children too, and a
   crond restart can no longer take a running transfer's session down.
   Scheduled runs log a structured DONE syslog line (rc, secs) since cron's
   output pipe is gone; tty runs stay fully synchronous (Ctrl+C unchanged),
   'preview' stays synchronous.
 - Watchdog: repairs phantom statuses (running:true with the flock free -
   the engine died without its trap: hard kill/OOM) by marking rc=143 and
   SSE-publishing, so a dead job can never pulse RUN in the UI forever;
   sweeps leftover <job>.run.pid files of vanished pids and stale stop
   markers (>10 min); the stuck-run alert behavior is unchanged.
 - Interrupted dry-runs are no longer recorded into the run history (the
   old signal trap could log a 143 line for a DRYRUN).
 - ajax: new stop_job action (POST + CSRF + name validation; all
   verification stays engine-side). Jobs rows render Run+Stop server-side
   (hidden pair) so a mid-run page load shows Stop immediately; the live
   refresh toggles the pair. No MANIFEST change (no new files).

## 2026.09.08e
Tiered retention for high-frequency jobs (history rollups + bounded logs + scheduled watchdog):
 - History is now tiered instead of one raw line per run forever: raw lines for
   HISTORY_RAW_HOURS (max HISTORY_RAW_MAX), then one hourly bucket for
   HISTORY_HOUR_DAYS, then one daily bucket for HISTORY_DAYS (runs/fails/errors/
   secs min-max-sum/bytes per bucket in history/<job>.rollup.jsonl; the raw file
   format is unchanged). A job on a 3-minute schedule now keeps a full 90-day
   trend in a few hundred lines instead of tens of thousands.
 - Compaction runs automatically: piggybacked on hist_add (bounded append, same
   lock) and every 15 minutes via a NEW maintenance line in the managed cron
   block - the watchdog (stale/stuck alerts + pruning) was previously never
   scheduled by the plugin at all.
 - Job logs: OK/dry-run logs age out after LOG_KEEP_DAYS (3) with a per-job
   count cap LOG_KEEP_MAX (300, newest win); failed/interrupted logs carry a
   keep-marker (logs/keep/) and stay LOG_KEEP_FAIL_DAYS (14). tail_log explains
   the new window when a log is gone.
 - paths.env gains the seven retention keys (defaults as above, engine clamps);
   editable on the Safety tab (same Save settings button).
 - WebUI: the HIST panel shows a last-24h summary line, a 48h hourly sparkline
   (raw + hourly buckets merged), a 14-day rollup table and a raw detail table
   with a failures-only filter; history loads up to 600 raw runs (ajax/engine
   cap raised from 200).
 - Doctor: INFO line with history line count, log file count and active
   retention settings; regen --check already flags a missing maintenance line.

## 2026.09.08d
Form alignment regression fix (Jobs tab):
- WebUI: Source/Destination/Script/Backup-dir inputs were completely detached from
  their labels and Browse buttons in both the Add and Edit job forms (2026.09.08c
  regression). The .rj-pathrow rule re-declared display (inline-flex) on the <dd>
  itself, taking those rows out of the Dynamix dl/float layout every other row
  uses. Replaced with the same white-space:nowrap pattern the multi-control rows
  (Transfers/Checkers etc.) already use - inputs align with the Name/Description
  fields again and the Browse button stays inline beside its field.

## 2026.09.08c
WebUI declutter (Jobs tab):
- WebUI: the Add/Edit job form is collapsed by default - the title bar toggles it
  (chevron + click/Enter), Edit and Add open it, Cancel closes it, and a box with
  no jobs yet opens it right away. Result/preview/history panels stay outside the
  collapsible so save and preview messages remain visible.
- WebUI: form fields grouped under Basics / Transfer / Limits & notifications
  sub-headings.
- WebUI: jobs table slimmed 9 -> 7 columns - Engine becomes a gray chip under the
  job name, Last run and Last OK share one cell (colored rc + gray last-OK line),
  Enabled becomes an on/off badge, and the dry-run summary is compacted
  ("MM-DD HH:MM +N -N !N", full text in the tooltip; needs-ack is a red badge).
- WebUI: per-row state cue - colored left border (green last OK / red failed /
  orange needs-ack / blue pulsing while running), disabled rows dimmed.
- WebUI: status strip above the table: master dry-run pill (orange ON / green
  OFF), job counts, and the SSE live indicator (safety state now visible without
  opening the Alerts tab).
- WebUI: small gray "next:" line under each humanized schedule in the table.
- WebUI: Source/Destination/Script/Backup-dir inputs and their Browse button now
  sit side-by-side instead of the button stretching full width.
- WebUI: live refresh patches cells by class (no positional td indices) and
  refreshes row cues; typed confirmation, run confirmations and CSRF flow
  unchanged.

## 2026.09.08b
Job log opens in its own live window:
- WebUI: the per-row Log button now opens a dedicated popup window instead of
  the result panel (named window - repeat clicks reuse it; a blocked popup
  reports back in the result panel).
- New shipped page emhttp/log.php: read-only live tail of one job. Accepts only
  ?job=<valid-name>, content always via the ajax tail_log action (paths only
  ever from the validated status file, engine redaction unchanged). Polls every
  2 s while the job runs, slows to 15 s when idle (catches a run started in the
  main tab), pauses entirely in hidden tabs; Refresh button, auto-scroll
  checkbox that respects a user scrolled up, status chip
  running/finished-rc/idle/error.
- Engine tail-log: JSON gains running/rc/ts from the status file it already
  reads, so the window knows when to stop fast-polling.

## 2026.09.08a
Dialog opacity fix, take 2 (the 2026.09.08 fix was a no-op on the test box):
- WebUI: rjSolidBg() now resolves --background through a throwaway probe element so
  the browser itself normalizes the value to rgb()/rgba(). The previous string
  parser only understood rgb()/rgba(); the theme's actual value (transparent or a
  non-rgb form) passed through untouched, so the modal stayed translucent.
- WebUI: a probe result that is missing or fully transparent falls back to the
  classic panel color chosen from the real page luminance (#f4f4f4 light pages,
  #23292e dark) - rjSolidBg() can never return a transparent color now.

## 2026.09.08
WebUI dialog legibility:
- WebUI: path-browser and deletion-Ack dialogs now paint a fully opaque panel
  background. webGui theme variables (--background) can carry alpha, which let
  the page behind bleed through the modal and made the browse tree unreadable.
  rjSolidBg() keeps the theme tint but flattens it to a solid rgb (over white
  for light themes, over black for dark ones), with the classic dark fallback.
- WebUI: slightly taller browse rows and a brighter expand-icon for clearer
  hierarchy inside the picker.

## 2026.09.07l
Run history + transferred-size trend:
- Engine: every LIVE run end appends one json line {ts,iso,rc,secs,errors,transferred,
  bytes|null,log} to $STORAGE_ROOT/history/<job>.jsonl (interrupted runs record rc=143
  too; dry-runs are excluded). The human-size -> bytes parser is deliberately permissive:
  anything unparseable records null and can never fail a run.
- Watchdog: history files are trimmed to a 90-day cutoff and 400 lines; a corrupt file
  still gets truncated to its newest 400 lines instead of growing forever.
- Engine 'history <job> [n<=200]' + ajax 'history' action: reads line-by-line
  (fromjson?) so a half-written line from a hard kill is skipped, not fatal.
- WebUI: per-row History button opens a newest-first table of the last 20 runs
  (result colored, errors, transferred) with plain-CSS bars relative to the largest
  run - no chart library on an Unraid box.

## 2026.09.07k
Job export / import (fleet setup) on the Alerts & Safety tab:
- Engine 'export-jobs': every job config (regular files, valid names only) plus meta.txt
  (plugin version, export time, host) packed as a deterministic tar.gz and returned
  base64-in-JSON; the UI builds a normal file download. Job names, paths, schedules and
  script locations are inside - credentials never are.
- Engine 'import-jobs <ask|overwrite|skip> <b64-file>': size cap ~1 MiB, member names
  whitelisted BEFORE extraction (only meta.txt, jobs/ and jobs/<valid>.conf - tar-slip
  impossible), each config re-validated by the real save-time validators in a subshell
  (one bad file is rejected individually, the rest still import), atomic installs mode
  0600; overwrite first keeps a .pre-import-<ts> backup; 'ask' (default) reports name
  conflicts and changes nothing. The upload file is consumed by the engine.
- The archive reaches the ajax endpoint as base64 inside the normal urlencoded body,
  never multipart (the CSRF recovery cannot read a multipart body). Cron block is
  regenerated automatically when something was added or replaced.

## 2026.09.07j
Doctor verifies the deployed files against a shipped checksum manifest:
- The build now GENERATES installed-checksums.txt (one 'sha256  deployed-path  mode' line
  per packaged file - version-stamped bytes, MANIFEST order, the file excluded from its
  own list) and embeds it like every other file. Two-pass because a file cannot hash
  itself; it must stay the LAST MANIFEST entry (enforced by both builders). A committed
  placeholder satisfies the manifest<->tree lint - its repo content is never what ships.
- Doctor new section: every listed file must exist with the release sha256 (FAIL
  otherwise - catches the stale/half-deployed symptom an online update can leave) and
  the release mode (WARN on drift). Missing manifest (older install) is an INFO that
  points at a reinstall; a still-deployed build PLACEHOLDER is a WARN.
- build.ps1 and build.sh produce the manifest byte-identically (verified).

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
