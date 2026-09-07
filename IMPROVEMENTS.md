# rclone-jobs — improvement backlog (draft plans)

Follow-up ideas from the 2026.09.07e best-practices compliance pass (deferred by scope,
not rejected). One section per item: motivation, draft design, files to touch, risks,
verification. All plans must keep the repo invariants: `build.ps1` == `build.sh`
byte-identical output, every new shipped file added to `src/MANIFEST`, `pwsh -NoProfile
-File build.ps1` green, ajax stays POST-only + CSRF + master rate-limit, and nothing
weakens the safety model (dry-run gate, `--max-delete`, mount guard, storage policy).
i18n scaffolding (`_()` + catalogs) is out of scope by owner decision — not listed.

Priority order (value per effort): ~~2/1/3/5~~ shipped (07f/07g/07h/07i) → **6**
(robustness) → **4**, **7** (features).

---

## 1. Live status via nchan SSE (drop full-page reloads) — SHIPPED 2026.09.07g

**Shipped notes.** Engine: `sse_publish()` (fire-and-forget curl, 2 s cap) called at run
start (after the lock) and both finish paths; new `status-json` subcommand = one JSON per
refresh. Page: `EventSource('/sub/rclone-jobs')` patches rows in place (delegated
`.rj-btn` handler so the live-added Ack button works); after 2 consecutive socket errors
it degrades to the new 60 s interval refresh + "live: off" indicator. **Correction to the
draft below:** publish is `POST http://localhost/pub/<channel>` (per
`plugin-docs/docs/core/nchan-websocket.md`), not `PUT /sub/...`.

**Status (2026.09.07f research, pre-ship).** Corrected premises: there is NO timed auto-refresh
today — status only changes on a manual page reload — so this item must ADD the 60 s
fallback itself. There is also no `stop` subcommand; drop it from the call-site list.

**Motivation.** Every UI action ends in `location.reload()`, and the Jobs tab never
refreshes on its own — a cron-started run shows as "RUN" only after a manual reload. Unraid 7 ships
nchan: publish to `http://localhost/sub/<channel>` (PUT/POST), subscribe from the page
with `new EventSource('/sub/<channel>')` (same-origin, session-cookie auth). Reference:
`plugin-docs/docs/core/nchan-websocket.md`.

**Draft plan.**
1. Engine: add `sse_publish()` helper — `curl -m 2 -X PUT --data-binary "$json"
   http://localhost/sub/rclone-jobs || true` (never fatal; cron runs without nginx must
   not care).    Publish at run start (after lock) and run end: `{"job":"NAME","rc":N,"run":"...","last_ok":"..."}`.
   Call sites: `cmd_run` start (after lock) and both finish paths.
2. Page/JS: open one `EventSource`; on message matching a listed job, patch that row's
   Last-run / Last OK / actions cells in place (or call a new ajax action
   `status_json` and re-render only the table body — simpler, still no page reload).
3. Fallback: if `EventSource` is missing or errors twice, fall back to a NEW 60 s
   `setInterval` refresh (there is no auto-refresh yet); show a tiny "live: off" indicator.

**Files:** `src/engine/rclone-jobs.sh`, `src/emhttp/js/rclone-jobs.js`,
`src/emhttp/rclone-jobs.page`, `src/emhttp/ajax.php` (optional `status_json`).

**Risks.** Self-signed https is fine (EventSource follows page scheme). Debounce
messages (a watchdog sweep + real run can fire together). Never let the socket block
page load — open it after first render.

**Verify.** Two browser tabs: start a run from the CLI/`cron` on the box and watch the
badge flip within ~1 s in both; kill nginx-side channel (restart nginx) and confirm
fallback refresh still updates.

**Effort:** medium.

---

## 2. Async dry-run preview and remote browse (no PHP-request timeouts) — SHIPPED 2026.09.07f (preview only)

**Shipped scope (owner decision).** Preview only. `browse` already bounds itself with
`timeout` (15 s listremotes / 25 s lsf), and making the picker modal a start+poll cycle
for every folder click costs UX for little gain — the minutes-long hang was always the
dry-run. Implemented exactly as drafted below minus browse: engine `preview-start` /
`task-status` / `task-cancel` (single-consume, redacted, capped 256 KiB), `run_dry` kept
one release, `save_job` no longer previews inline, UI polls 1 s (120 cap) with a Cancel
button, post-save preview survives the reload via a `sessionStorage` flag. Remaining
optional: nothing.

**Motivation.** `preview` and `browse` run rclone synchronously inside the ajax PHP
request. On a huge remote (or slow backend) the web request hangs until timeout,
blocking an emhttp worker and showing nothing useful. This is the known long-task
pattern: detach + poll.

**Draft plan.**
1. Engine: add subcommands `preview <job>` and `browse <remote> <path> <json|dirs>`
   that do what ajax does today but write results to
   `$STATUS_DIR/task-<id>.out` + `.rc` (id = job name / hash for browse, plus a
   per-task lock so only one preview per job runs). Reuse the existing redaction.
2. Ajax: `preview_start` / `browse_start` spawn
   `nohup engine ... > /dev/null 2>&1 &` and return the task id;
   `task_status <id>` returns `{"running":true}` or the file contents + rc and unlinks
   the task files (single-consume). Keep old sync actions as dead code one release,
   then delete.
3. JS: replace the single POST with start + 1 s polling (cap ~120 polls), spinner +
   Cancel button (`task_cancel` = `kill` the recorded pid, best effort).

**Files:** `src/engine/rclone-jobs.sh`, `src/emhttp/ajax.php`,
`src/emhttp/js/rclone-jobs.js`.

**Risks.** Task-file cleanup (watchdog prune must include `task-*`); idempotency when
the user hits Save twice (existing double-submit guard helps); never return task output
to a *different* job's requester (id embeds the job).

**Verify.** Fake a slow remote (rclone `sleep`-ing S3 endpoint or a FUSE mount with
`--low-level-retries 20`); UI shows progress and completes after >60 s of work; box
stays responsive; no `task-*` files older than 1 h after abort.

**Effort:** medium–large.

---

## 3. "Tail last log" viewer in the WebUI — SHIPPED 2026.09.07h

**Shipped notes.** Engine `tail-log <job>` (path read only from the validated status
file, must sit under LOG_DIR; NUL-stripped, redacted, 64 KiB tail with a byte-count
banner) + `log` key written into the status at run START (live runs viewable too).
Page: 'Log' button per row renders into the existing result panel. ajax `tail_log` is a
thin passthrough.

**Motivation (pre-ship).** Diagnosing a failed run today means syslog or SSH. The engine already
writes `LOG_DIR/<job>-<stamp>.log` (redacted stats exist); a read-only viewer closes
the loop.

**Draft plan.**
1. Engine: record the absolute log path in the status file (`log=` key) at run start.
2. Ajax: new `tail_log` action — validate job name like the others (no path input),
   read the last 64 KiB of the recorded path, re-apply the secret-redaction filter,
   return for a `<pre>` block in the existing result panel (or a small modal like the
   browse overlay).
3. Page: small "Log" button per job row next to Run/Stop.

**Files:** `src/engine/rclone-jobs.sh` (status key), `src/emhttp/ajax.php`,
`src/emhttp/rclone-jobs.js`, `src/emhttp/rclone-jobs.page`.

**Risks.** Output size (cap + "[truncated]" marker); UTF-8 mid-line truncation is
cosmetic-only; the log path must come from validated status data, never from the
request (no traversal); POST + CSRF like every other action.

**Verify.** Run a job whose command line contains a token and confirm the viewer shows
`****`; a 5 MB log renders instantly with only the tail; unknown/invalid job names 4xx
out like other actions.

**Effort:** small.

---

## 4. Job export / import (fleet setup)

**Motivation.** Re-creating 15 jobs per server doesn't scale; a portable job-set
archive is the cheap version of "fleet management".

**Draft plan.**
1. Engine: `export_jobs` → tar (gzip) of `BOOT_DIR/jobs/*.conf` to stdout/tmp, plus a
   `meta.txt` (plugin version, hostname, date). No secrets in confs by design, but the
   UI must warn that paths/custom scripts are included.
2. Engine: `import_jobs <archive>` — unpack to a tmp dir, validate **every** file with
   the same validators as save-job (name regex, key whitelist, schedule, engine paths,
   storage policy), only then move into `jobs/` per an overwrite flag (`ask` default:
   report conflicts, change nothing).
3. Ajax: `export_jobs` returns the archive base64 inside the JSON response (JS builds a
   Blob download client-side); `import_jobs` accepts the archive as **base64 inside the
   normal urlencoded body, never multipart** — the CSRF recovery in ajax.php cannot read
   the token out of a multipart body (see the CONTENT_TYPE guard at the top). Size cap
   ~1 MiB, ≤100 members, every member must match `^[A-Za-z0-9_-]{1,40}\.conf$`
   (tar-slip guard by name, before extracting).
4. Page: Alerts/Settings tab gains Export / Import buttons + result panel.

**Files:** `src/engine/rclone-jobs.sh`, `src/emhttp/ajax.php`,
`src/emhttp/rclone-jobs.page`, `src/emhttp/js/rclone-jobs.js`.

**Risks.** Import is the dangerous half: never bypass validators, never import
`notify.env`/status/logs. Export must not follow symlinks. Document that importing
over an existing job needs the explicit overwrite flag.

**Verify.** Round-trip export→import on a fresh box reproduces the job set byte-equal;
tar with `../evil.conf` member and a 50 MB member are both rejected; conflict without
flag leaves originals untouched.

**Effort:** medium.

---

## 5. `stopping` event: notice for jobs that hold a lock during shutdown — SHIPPED 2026.09.07i

**Shipped notes.** New `emhttp/event/stopping` (0755, MANIFEST) calls the engine's
`shutdown-notice` under `timeout 10`, always exits 0. The subcommand counts jobs with
`running:true` AND the run lock actually held (a stale status from an old hard kill
never cries wolf), writes one syslog line and one bell notice (once-marker
`/tmp/rclone-jobs-stopping-notice`). `cmd_run` now executes via background + `wait`
with a TERM/INT trap: status is marked rc=143 immediately (verified: engine exits 143
within the signal, log gets an 'interrupted by signal' line); rclone children are left
to the shutdown's own kill pass, exactly as drafted.

**Motivation (pre-ship).** Array stop with a running job means rclone gets cut off (SIGKILL after
grace). Today that is silent. A `stopping` event (fires before array stop) can at least
leave a loud trace — the engine already survives hard kills (status file is rewritten
on next run), and the docs list `stopping` as a standard emhttp event.

**Draft plan.**
1. New `src/emhttp/event/stopping` (mode 0755, add `src/MANIFEST` line): if any
   `$STATUS_DIR/*.lock` (or recorded pid alive), write a syslog line
   `rclone-jobs: N job(s) still running at shutdown: names...` and a throttled bell
   notification (once — marker file in `/tmp`).
2. Engine: `trap` TERM/INT in `cmd_run` → log "interrupted by signal" into the job log,
   mark status `rc=interrupted`, re-raise so rclone children die naturally. Keep it
   simple: no force-unmount attempts, no blocking.
3. Event must exit 0 fast (all work guarded with `|| true`, short timeouts) — never
   delay a shutdown.

**Files:** `src/emhttp/event/stopping` (new), `src/MANIFEST`,
`src/engine/rclone-jobs.sh`.

**Risks.** False positives (a 2 s job vs a real 40 min one — fine, it's informational);
notification noise handled by the once-marker; do not weaken the watchdog's stale-lock
logic, which stays the recovery path after a hard kill.

**Verify.** Start a long job (big `--transfers` throttle), stop the array: syslog line
present, one bell notice, shutdown time unaffected; no event output when idle.

**Effort:** small.

---

## 6. Doctor: verify deployed files against a shipped checksum manifest

**Motivation.** The pre-2026.09.07 "stale files linger" symptom showed an online update
can half-deploy. Doctor checks behavior today but never compares the deployed
`/usr/local/emhttp/plugins/rclone-jobs/` files against what the release *should* be.

**Draft plan.**
1. Build: emit `installed-checksums.txt` (one `sha256  path  mode` line per shipped
   file, computed from the version-stamped bytes — same bytes as `<SHA256>`), add it to
   `src/MANIFEST` so it is packaged. Deterministic ordering (MANIFEST order) so
   `build.ps1`/`build.sh` stay byte-identical. **Two-pass build required** (a file
   cannot hash itself): pass 1 hashes every MANIFEST entry except the checksums file;
   the content is then GENERATED IN MEMORY and embedded+hashed like any other file. A
   committed placeholder `src/emhttp/installed-checksums.txt` (clearly marked GENERATED)
   keeps the two-way manifest lint happy; its repo content is never what ships.
2. Doctor: new section — for each line: file present? sha matches? mode matches? FAIL
   on hash mismatch, WARN on mode drift (web-owned files get chmod'ed on re-save is
   *not* expected — any drift means a partial redeploy).

**Files:** `build.ps1`, `build.sh`, `src/MANIFEST`, `src/engine/rclone-jobs.sh`.

**Risks.** Touches the build pipeline — must re-verify byte-identity of the two
builders and that `<SHA256>` values are unchanged (checksums file is hashed like every
other file, so it changes the .plg once; fine). Web-owned files (`emhttp/`) are
overwritten by the plugin manager on update, so they belong in the manifest too.

**Verify.** Clean box: all PASS. Corrupt a deployed file by hand: doctor FAILs with the
path. Reinstall via .plg: back to PASS.

**Effort:** medium (build-pipeline care).

---

## 7. Run history + transferred-size trend

**Motivation.** Status shows only the last run; operators want "did Wednesday's run
slow down?" and per-job success rates.

**Draft plan.**
1. Engine: at run end append one JSON line to `BOOT_DIR/history/<job>.jsonl`:
   `{ts, rc, seconds, checks, transfers, deleted, bytes}` — parse rclone's final
   `--stats-one-line`-style summary from the log (best effort; null fields on parse
   failure, never fail the run over it).
2. Watchdog prune: cap each history file at ~400 lines (keep newest) + 90-day cutoff.
3. Ajax: `history <job>` returns the last N lines. Page: expandable per-row detail
   (last-20 table + tiny inline bar chart in plain CSS/`<div>`s — no chart library on
   an Unraid box).

**Files:** `src/engine/rclone-jobs.sh`, `src/emhttp/ajax.php`,
`src/emhttp/js/rclone-jobs.js`, `src/emhttp/rclone-jobs.page`.

**Risks.** rclone summary format drifts across versions — parsing must be regex-permissive
and the UI must render "n/a" gracefully; history lives under `STORAGE_ROOT` (dot-folder)
so the storage policy already covers it.

**Verify.** Runs on the current rclone version populate all fields; a hand-written log
without a summary line still appends (nulls); 500-line file is trimmed to cap by the
next watchdog sweep.

**Effort:** medium.

---

## Cross-cutting reminders for whoever picks these up

- New shipped file ⇒ `src/MANIFEST` line (target under `/usr/local/emhttp/plugins/rclone-jobs/`,
  mode `0NNN`) or the lint fails the build.
- Re-run `pwsh -NoProfile -File build.ps1` (lints src+dist) and re-verify `build.sh`
  byte-identity (sha256 of the .plg from both) with every change.
- New ajax actions: POST + `$csrf_token` + rate-limit + the same job-name/key
  validation; return only redacted output.
- Engine stays `set -uo pipefail` without `set -e`; exit codes 0/75/77/78/127 are a
  contract with the cron block; the hardened PATH must keep covering `/usr/sbin`.
- After engine/ajax changes, re-check the README "Safety model" table still matches
  reality; on-box acceptance notes go in `tests/acceptance-*.md` per existing convention.
