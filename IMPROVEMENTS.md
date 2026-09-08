# rclone-jobs — improvement backlog (draft plans)

Proposals for future iterations of rclone-jobs. One section per item: motivation,
draft design, files to touch, risks, verification, and effort. All plans must keep
the repo invariants: `build.ps1` == `build.sh` byte-identical output, every new shipped
file added to `src/MANIFEST`, `pwsh -NoProfile -File build.ps1` green, ajax stays
POST-only + CSRF + rate-limit, and nothing weakens the safety model (dry-run gate,
`--max-delete`, mount guard, storage policy).

---

## 1. Live job cancellation ("Stop" button in WebUI & CLI) — DONE in 2026.09.08f

**Implemented as:** engine `stop <job>` + marker-driven trap + `stop_job` ajax +
red Stop button on running rows. Deviations from the draft: instead of only
recording a PID, non-tty runs now self-spawn via `setsid` (same pattern as
`preview-start`) so the engine is its own session/group leader and the group
TERM reaches the transfer children on every launch path (cron/WebUI/CLI); the
pid file is `$STATUS_DIR/<job>.run.pid`; KILL escalation completes the
bookkeeping (status/SSE/history/keep) if the engine died before its trap; the
watchdog also repairs phantom running-statuses and sweeps leftover pid files
and stop markers.

**Motivation.** Detached cancellation (`task-cancel`) exists only for preview tasks. If a
live job is running (`rj-st-run`), there is currently no way to stop or abort it from
the WebUI or CLI — if a multi-terabyte job is started by mistake or saturates array I/O,
the operator must SSH in, find PIDs manually, and kill them. The engine already has an
interrupt trap (`cmd_run` catches `TERM`/`INT`, logs the interruption, marks status
`rc=143`, triggers SSE, and marks the log with `.keep`).

**Draft plan.**
1. Engine: record the session/process group leader PID in `$STATUS_DIR/$JOB_NAME.pid`
   at run start (clean up in `status_finish`). Add a subcommand `stop <job>`: validate
   job name, read PID, send `kill -TERM -- -"$pid"` (with fallback to `"$pid"`), wait 2 s,
   escalate to `SIGKILL` if still alive.
2. Ajax: add `stop_job` action (POST + CSRF + job name validation), invoking engine `stop <job>`.
3. WebUI:
   - When a row is running (`running: true`, `rj-st-run`), replace the "Run" button with
     a red "Stop" button (`value="Stop" class="rj-btn rj-del" data-act="stop"`).
   - Clicking "Stop" triggers an `rjConfirm` dialog, then POSTs `stop_job`.
   - The engine's signal trap records `rc=143`, publishes SSE, and the row returns to idle.

**Files:** `src/engine/rclone-jobs.sh`, `src/emhttp/ajax.php`, `src/emhttp/js/rclone-jobs.js`,
`src/emhttp/rclone-jobs.page`.

**Risks.** Avoid killing unrelated processes if a PID is recycled (verify lock is held
and process name matches before signaling). Prune lingering `*.pid` files in the watchdog sweep.

**Verify.** Start a long transfer from the WebUI, click "Stop", confirm the confirmation
prompt: process terminates within 2 s, row clears `RUN` via SSE, status marks rc=143,
and log reflects "interrupted by signal".

**Effort:** small–medium.

---

## 2. Mode selection for `rsync` engine (`sync` vs `copy` / archive)

**Motivation.** Today the `rsync` engine hardcodes `CMD=(rsync -aHAX --delete --ignore-missing-args)`.
`--delete` is unconditional. For `rclone`, users can select `sync`, `copy`, or `check`.
Many users want rsync for local or unassigned disk backups in an append-only / archive
fashion without deleting destination files that were removed from the source.

**Draft plan.**
1. Engine: in `build_command()`, inspect `J_MODE` for `rsync`:
   - `sync` (default for backward compatibility): keep `--delete`.
   - `copy`: omit `--delete`.
2. Ajax: in `save_job`, permit `mode` to be `sync` or `copy` when `engine === 'rsync'`
   (currently sets `$mode = ''`).
3. WebUI: show the Mode dropdown for `rsync` as well as `rclone`, with options
   `sync (mirror with deletes)` and `copy (keep destination files)`.

**Files:** `src/engine/rclone-jobs.sh`, `src/emhttp/ajax.php`, `src/emhttp/js/rclone-jobs.js`,
`src/emhttp/rclone-jobs.page`.

**Risks.** Existing rsync job configs have `MODE=""` or no `MODE` key; `load_job` must
default empty mode to `sync` for rsync so existing behavior is preserved.

**Verify.** Create an rsync job with `copy` mode: verify generated command line in the
job log does not contain `--delete`; verify a file deleted at source remains on destination.

**Effort:** small.

---

## 3. Filter & exclude patterns in the WebUI (`--exclude` / `--filter`)

**Motivation.** The backend engine already has internal plumbing for `J_ARGS` (`rclone-jobs.sh:307`),
but it is not exposed in `ajax.php` or `rclone-jobs.page`. Unraid users frequently need to
exclude temporary files (`.DS_Store`, `Thumbs.db`, `@eaDir`, `*.tmp`, `.Trash*`) or Docker
container caches without writing custom shell scripts.

**Draft plan.**
1. WebUI: add an "Exclude patterns" input in the job form under Transfer
   (e.g., textarea or text input for glob patterns, space- or newline-separated).
2. Ajax: validate patterns in `save_job` — reject shell metacharacters (`` ` $ ; | & < > " ' \ ``),
   store as `EXCLUDE=pattern1 pattern2` or newline-separated.
3. Engine: parse `J_EXCLUDE` in `load_job`; in `build_command`, append `--exclude "$pat"`
   for each pattern for both `rclone` and `rsync`.

**Files:** `src/engine/rclone-jobs.sh`, `src/emhttp/ajax.php`, `src/emhttp/js/rclone-jobs.js`,
`src/emhttp/rclone-jobs.page`.

**Risks.** Shell expansion / glob accidental evaluation (must be passed as discrete array
elements `CMD+=(--exclude "$pat")`, never eval'd).

**Verify.** Add `*.tmp` and `.DS_Store` to a test job; verify preview report and live run
skip matching files; verify forbidden characters trigger validation errors on save.

**Effort:** small–medium.

---

## 4. Parity check / array resync deferral guard

**Motivation.** Heavy scheduled sync jobs running concurrently with Unraid's monthly parity
check, disk rebuild, or balance operation cause extreme disk thrashing, slowing down both
the parity check and the transfer.

**Draft plan.**
1. Engine: add helper `array_resyncing()` checking `/var/local/emhttp/var.ini`
   (`mdResync > 0` or `sbSynced < sbSyncedTotal`).
2. Job config: add optional `DEFER_ON_PARITY=yes|no` (default `no` or global default).
3. At the beginning of `cmd_run`: if `DEFER_ON_PARITY=yes` and `array_resyncing` is true,
   log `rclone-jobs: $JOB_NAME deferred (array parity check / resync in progress)` to
   syslog, emit a normal-level notice (or silent), and exit 0 without running the transfer.
4. WebUI: add a checkbox under Limits & Notifications: "Skip run if Parity Check is running".

**Files:** `src/engine/rclone-jobs.sh`, `src/emhttp/ajax.php`, `src/emhttp/js/rclone-jobs.js`,
`src/emhttp/rclone-jobs.page`.

**Risks.** Must fail open: if `var.ini` is unreadable, assume no resync and proceed.

**Verify.** Simulate resync flag in a mock environment; verify run exits 0 with a clear
log message and does not trip the dry-run gate or watchdog failure counters.

**Effort:** small.

---

## 5. Visual "Deletion Inspector" for the Ack dialog & preview panel

**Motivation.** When a dry-run predicts deletions exceeding `WARN_DELETE`, the row shows
`needs ack` and requires typing the job name to acknowledge before a live run is allowed.
However, operators cannot easily see *which* files are slated for deletion without opening
and reading through the full 64 KiB raw log.

**Draft plan.**
1. Engine: in `render_preview` or a small helper, parse lines tagged with deletion actions
   (`* -`, `del-`, `delete`, or itemize `*deleting`) and store a capped array of deleted
   paths in `$STATUS_DIR/<job>-dryrun.json` (e.g. `deletions:[...up to 100 paths...]`).
2. WebUI: in the Ack modal, display an expandable list of the files marked for deletion
   above the confirmation input.
3. If deletions exceed the cap, show "and N more... see full preview log".

**Files:** `src/engine/rclone-jobs.sh`, `src/emhttp/preview.php`, `src/emhttp/js/rclone-jobs.js`.

**Risks.** Memory and JSON payload size: strictly cap extracted paths to 100 entries / 32 KiB.

**Verify.** Dry-run a job that deletes 10 files; open Ack dialog; verify exact relative paths
are displayed cleanly before typing confirmation.

**Effort:** medium.

---

## 6. Automated retention & pruning for `BACKUPDIR`

**Motivation.** `BACKUPDIR` (`--backup-dir`) is a key safety feature preventing accidental
data loss by moving deleted/overwritten files to a timestamped or dedicated folder instead
of wiping them. However, without automated pruning, backup directories grow indefinitely
until disk capacity is exhausted.

**Draft plan.**
1. Job config: add optional `BACKUP_KEEP_DAYS` (e.g., default 30 days, 0 = keep forever).
2. Engine watchdog: during the 15-minute maintenance sweep, if a job specifies `BACKUPDIR`
   and `BACKUP_KEEP_DAYS > 0`:
   - For local destinations: run `find "$BACKUPDIR" -type f -mtime +$DAYS -delete`
     (with mount and storage guard verification).
   - For rclone remotes: run `rclone delete --min-age "${DAYS}d" "$BACKUPDIR"`.
3. Safety: only purge within paths explicitly configured as `BACKUPDIR`, subject to the
   same storage policy checks (never delete `/`, `/mnt/user`, etc.).

**Files:** `src/engine/rclone-jobs.sh`, `src/emhttp/ajax.php`, `src/emhttp/rclone-jobs.page`.

**Risks.** Deleting files in the wrong folder: must strictly re-verify that the target path
matches the job's configured `BACKUPDIR` and passes `policy_ok` and `mount_guard`.

**Verify.** Run watchdog against a mock backup folder with old and new files; verify only
files older than the retention threshold are pruned.

**Effort:** medium.

---

## 7. Schedule snooze & global pause switch

**Motivation.** During server maintenance, hardware upgrades, or network troubleshooting,
operators need to temporarily pause all scheduled jobs without having to manually disable
each job one by one (which forgets which jobs were originally active) or toggling the
master dry-run switch.

**Draft plan.**
1. Configuration: add `SCHEDULE_PAUSE_UNTIL` timestamp (or `SCHEDULE_PAUSED=yes`) in `paths.env`.
2. Engine: at the beginning of `cmd_run`, if scheduled run (not manual click) and current
   time `< SCHEDULE_PAUSE_UNTIL`, log `rclone-jobs: schedule paused until <timestamp>` and exit 0.
3. WebUI: in the status strip or Alerts & Safety tab, add "Pause all schedules: [1h | 6h | 24h | Indefinitely]"
   and "Resume". Show a yellow badge in the status strip when paused.

**Files:** `src/engine/rclone-jobs.sh`, `src/emhttp/ajax.php`, `src/emhttp/rclone-jobs.page`,
`src/emhttp/js/rclone-jobs.js`.

**Risks.** Cron still triggers the runner; Dillon cron crontab is not edited back and forth,
avoiding unnecessary crond service restarts.

**Verify.** Set pause for 1 hour; trigger cron; confirm run exits 0 with pause notice; click
"Resume"; confirm subsequent run executes normally.

**Effort:** small–medium.

---

## 8. Dead-man's switch / Healthcheck URL pings (Healthchecks.io / Uptime Kuma)

**Motivation.** Native Unraid notifications handle delivery to bell, email, Telegram, etc.,
on run completion or failure. However, if an Unraid server suffers a hard lockup, network
loss, or Dillon cron stops running, the server cannot send an alert. Homelab operators
rely on dead-man's switch monitoring (Healthchecks.io, Uptime Kuma push monitors) to detect
missing runs.

**Draft plan.**
1. Job config: add optional `PING_URL` field (e.g. `https://hc-ping.com/UUID`).
2. Engine:
   - At run start: if `PING_URL` is set, fire background `curl -s -m 5 "$PING_URL/start" >/dev/null 2>&1 || true`.
   - On success (rc=0 or 24): fire `curl -s -m 5 "$PING_URL" >/dev/null 2>&1 || true`.
   - On failure: fire `curl -s -m 5 "$PING_URL/fail" >/dev/null 2>&1 || true`.
3. Validation: `PING_URL` must match `^https?://[A-Za-z0-9.-]+(/.*)?$` in `ajax.php`,
   preventing command injection.

**Files:** `src/engine/rclone-jobs.sh`, `src/emhttp/ajax.php`, `src/emhttp/rclone-jobs.page`.

**Risks.** Zero external binaries needed (uses system `curl`). Timeouts strictly bounded
to 5 s so unreachable endpoints never block transfers.

**Verify.** Configure a test ping URL; run job; verify remote monitor logs start and
success signals; induce error and verify fail signal is dispatched.

**Effort:** small.

---

## Cross-cutting reminders

- New shipped files require a corresponding `src/MANIFEST` entry (target under
  `/usr/local/emhttp/plugins/rclone-jobs/`, mode `0NNN`).
- `pwsh -NoProfile -File build.ps1` and `build.sh` must remain byte-identical.
- All new ajax actions must remain POST-only, CSRF-validated, and sanitize inputs server-side.
- Safety invariants (dry-run gate, `--max-delete`, mount guard, storage dot-folder policy)
  must remain inviolable.
