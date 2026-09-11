# rclone-jobs — Operator Manual

Complete guide to the **rclone-jobs** plugin for Unraid 7: scheduled
rclone / rsync / custom-script transfers built around one rule —
**nothing ever deletes or overwrites data you have not previewed first.**

Quick links: [Install](INSTALL.md) · [README](README.md) · [Changelog](src/CHANGELOG.md)

---

## Table of contents

1. [Concepts at a glance](#1-concepts-at-a-glance)
2. [Before you start (requirements)](#2-before-you-start-requirements)
3. [First-run walkthrough](#3-first-run-walkthrough)
4. [WebUI tour](#4-webui-tour)
5. [Creating and editing a job](#5-creating-and-editing-a-job)
6. [The dry-run gate and Ack workflow](#6-the-dry-run-gate-and-ack-workflow)
7. [Scheduling](#7-scheduling)
8. [Engines in detail](#8-engines-in-detail)
9. [Safety model explained](#9-safety-model-explained)
10. [Notifications](#10-notifications)
11. [Live status, run control and the watchdog](#11-live-status-run-control-and-the-watchdog)
12. [Storage layout and retention](#12-storage-layout-and-retention)
13. [Settings reference (paths.env)](#13-settings-reference-pathsenv)
14. [Job configuration reference](#14-job-configuration-reference)
15. [CLI reference](#15-cli-reference)
16. [Export / import (fleet setup)](#16-export--import-fleet-setup)
17. [Upgrading and uninstalling](#17-upgrading-and-uninstalling)
18. [Troubleshooting](#18-troubleshooting)
19. [FAQ](#19-faq)

---

## 1. Concepts at a glance

| Concept | What it means |
|---|---|
| **Job** | One scheduled transfer, defined by a `KEY=VALUE` config file. Named with letters, digits, `-`, `_` (max 40 chars; the name cannot be changed later). |
| **Engine** | What actually moves the data: `rclone` (sync/copy/check), `rsync`, or `custom` (your own executable script). |
| **Dry-run** | A simulated run. rclone runs with `--dry-run -vv`, rsync with `-n --itemize-changes`; nothing is written or deleted. The result (would-copy / would-delete / error counts) is stored and shown in the table. |
| **Dry-run gate** | A **live** run is refused (exit 77) unless the job has a *successful* dry-run on record whose hash matches the *current* config. Any edit to the job re-arms the gate. |
| **Ack** | If the last dry-run predicts more deletions than the job's `WARN_DELETE`, a live run additionally requires an explicit acknowledgement. |
| **Master dry-run switch** | Global kill-switch (default **ON**). While ON, *every scheduled run of every job* is a dry-run, regardless of per-job settings. |
| **Mount guard** | Before any transfer: the source must exist and the destination must already be a mounted, non-RAM directory. Never auto-creates destinations (exit 75 otherwise). |
| **Storage folder** | The plugin's own data (logs, status, history, backup) lives in a hidden dot-folder on an array disk (`/mnt/diskN/.rclone-jobs`), never on `/boot`, `/mnt/user`, or system paths. |
| **Watchdog** | Maintenance that runs every 15 min from the plugin's cron block: stuck-run and stale-run alerts, history compaction, log pruning, status repair. |

The plugin runs **alongside** the `rclone` plugin by Waseh: it reuses
`/boot/config/plugins/rclone/.rclone.conf` and its wrapper, and never modifies
it or passes `--config`.

---

## 2. Before you start (requirements)

- **Unraid 7.x** with the array **started** (the plugin needs a mounted
  `/mnt/diskN` for its storage folder).
- The **`rclone` plugin installed** (any version). Define and authenticate
  your remotes on the rclone plugin page first — rclone-jobs only references
  those remotes, it has no remote configuration of its own.
- `rsync` is only needed for `rsync`-engine jobs.
- Notifications arrive through **Unraid's own notification system**; for
  email/Telegram/Discord/Pushover delivery, configure the agents once under
  *Settings → Notification Settings*. The plugin itself stores **no
  credentials**.

---

## 3. First-run walkthrough

1. **Install** (see [INSTALL.md](INSTALL.md)) — plugin URL or `.plg` file.
2. Open **Utilities → rclone-jobs**.
3. **Doctor tab → Run doctor.** Expect all PASS/INFO. Two expected INFOs:
   the minimal-PATH probe note (documents the cron PATH fix) and "no jobs
   configured" until you create one.
4. **Alerts & Safety tab → Send test notification** (level `alert` is the
   loudest). Check the WebUI bell and any agents you enabled.
5. **Jobs tab → + Add New Job.** Create one small job (e.g. a daily `copy`
   of one folder to a remote), press **Dry-run**, read the preview summary
   (`+N` would copy, `-N` would delete, `!N` errors).
6. Keep the **master switch ON** while you build your set: every scheduled
   run stays a simulation. When all jobs' dry-runs look right, turn the
   master switch **off** to let scheduled runs transfer for real.

Everything the plugin does is logged to syslog under tag `rclone-jobs`
(`grep rclone-jobs /var/log/syslog`).

---

## 4. WebUI tour

Page location: **Utilities → rclone-jobs** (reached via Settings → Utilities).
Three tabs; the page footer always shows the running version and storage path
(a stale over-install is obvious at a glance).

### Jobs tab

- **KPI cards** — total & enabled jobs, master dry-run state (orange pill ON
  / green OFF), live SSE connection status (pulsing dot), quick *Add job*.
- **Hourly transfer chart** — rolling 16-hour dual-tone bar chart (bytes +
  runs) with Avg Rate, 24 h Transferred, Total Runs and Last Run stats.
- **Fleet toolbar** — live search box, filter pills (*All / Active / Failed*)
  and the **+ Add New Job** button.
- **Jobs table** — per row: job name (+ engine chip + description), **On**
  (enabled toggle), **Dry** (per-job dry-run toggle, amber DRY / green LIVE),
  schedule (human text + "next: in ..." countdown; raw cron on hover),
  source → destination endpoint chips (cloud vs folder icons), **Last run**
  (semantic pill with duration + transferred, last-OK line below), **last
  dry-run** summary (`+N -N !N` diff chips; red NEEDS ACK badge when an
  acknowledgement is pending), and the action buttons:

  | Button | Action |
  |---|---|
  | **Dry** | Start a detached dry-run preview (live progress + Cancel; survives page reload) |
  | **Run / Stop** | Start a live run — while running, the button becomes a red **Stop** (see section 11) |
  | **Ack** | Appears when the gate needs a deletion acknowledgement (type the job name to confirm) |
  | **Log** | Dedicated live log window for that job (2 s refresh while running, 15 s idle, auto-scroll that pauses when you scroll up) |
  | **Hist** | Inline history drawer: last-24 h summary, 48 h sparkline, 14-day rollup table, raw runs with a failures-only filter |
  | **Edit** | Inline edit form directly under the row (toggles) |
  | **Del** | Delete the job (confirm dialog; removes config + schedule line) |

- **Live updates** — the table patches itself in place over Server-Sent
  Events (no reload). If the SSE socket fails twice, the page degrades to a
  60 s auto-refresh and the indicator shows `live: off`.
- **Browse...** — Source, Destination, Backup dir and Script fields each have
  a modal picker with a **Server** tab (user shares, array disks, mounts) and
  an **Rclone remotes** tab (live folder listing). Free typing stays possible
  for destinations that do not exist yet.
- Responsive: the table adapts down to phone width (stacked paths, icon
  buttons, then a card layout below 768 px).

### Alerts & Safety tab

- **Master dry-run switch** — YES = all scheduled runs simulate.
- **Quiet window** — start/end (24 h clock, defaults 23:00 → 07:00):
  suppresses only the *OK* notices; failures and warnings are always sent.
- **Retention** — the seven history/log knobs (section 12) with a **Save
  settings** button; values are clamped server-side to safe ranges.
- **Delivery** — link to Settings → Notification Settings + *Send test
  notification* (normal / warning / alert).
- **Job portability** — export the whole job set as a `.tgz` download and
  import one (ask / overwrite / skip modes, section 16).

### Doctor tab

Read-only self-test with a PASS / INFO / WARN / FAIL report covering: plugin
& engine versions, the rclone wrapper + config file, the storage folder
(share policy, writability, free space), required binaries and PHP, the cron
integration (managed block present, drift against the jobs folder, cron daemon
alive), **deployed-file checksums against the release manifest**, every job
config (validity, storage overlap, last-run status, staleness > 26 h) and
rclone's behavior under cron's minimal PATH. The fenced block at the end of
the report is a paste-ready summary for support threads; a copy is saved under
`logs/doctor-*.txt`. The checkbox additionally sends one test notification.

---

## 5. Creating and editing a job

The form opens inline (top of the table for Add, under the row for Edit),
grouped in four cards.

### Basics

| Field | Notes |
|---|---|
| **Name** | Unique id, letters/digits/`-`/`_`, max 40. Names the config file and the cron entry — immutable afterwards (rename = create new + delete old). |
| **Description** | Free text (max 120 chars), shown under the job name. |
| **Enabled** | `no` keeps config + history but removes the schedule line; manual Dry/Run still work. Also toggleable from the table's **On** switch. |

### Schedule

A visual builder — **Daily / Hourly / Every N minutes / Weekly (weekday pill
buttons) / Monthly (day-of-month) / Custom (cron)** — with a live summary card
showing the generated expression and the next 3 run times (server local time).
The stored format is a classic 5-field cron line, so existing expressions
reverse-map into the builder on Edit; anything exotic stays editable under
Custom (numbers, `*`, `,`, `-`, `/` only; day-of-week accepts 0 and 7 for
Sunday). Gotchas the summary warns about: restricting **both** day-of-month
and day-of-week is an OR match in classic cron, and months without day 29–31
skip those runs.

### Transfer Settings

| Field | Notes |
|---|---|
| **Engine** | `rclone` · `rsync` · `custom script` |
| **Mode (rclone)** | `sync` (mirror — may delete), `copy` (add/update only, never deletes), `check` (compare only). rsync jobs have no mode. |
| **Source** | Local path (`/mnt/user/...`, `/mnt/diskN/...`, mounts) or `remote:folder`. Must exist at run time (mount guard). |
| **Destination** | Where files land. A local destination must already be a mounted directory — never auto-created. New sub-folders *inside* a valid destination are created by the transfer engine. |
| **Script (custom)** | Absolute path to an **executable file** (Browse lists `*.sh` under the plugins dir). Runs as root with a hardened PATH; exit code and output are recorded like any other engine. A command *string* is never accepted. |

### Limits & Safety

| Field | Notes |
|---|---|
| **Per-job dry-run** | `yes` (default) = this job only ever simulates on schedule. The master switch always wins. Toggle from the table's **Dry** column. |
| **Notify** | `always` / `failures` / `off` for this job (section 10). |
| **Skip during parity / resync** | `yes` = live runs are skipped (exit 0, syslog `DEFERRED`, one notice per episode) while a parity check, disk rebuild or balance is running. Dry-runs never defer. |
| **Transfers / Checkers** | rclone `--transfers` / `--checkers` (defaults 4 / 8). |
| **Bandwidth limit** | rclone/rsync `--bwlimit` syntax (e.g. `8M`), empty = off. |
| **Max deletes / Warn deletes** | Hard cap passed as rclone `--max-delete` (default 100). `WARN_DELETE` is the ack threshold: predicted deletions above it block a live run until Ack (section 6). |
| **Backup dir** (rclone) | Passed as `--backup-dir`: files that would be deleted/overwritten are moved there first. Must be a `remote:path` or a sub-folder inside the plugin storage folder. |
| **Buffer size** (rclone) | `--buffer-size` per stream (e.g. `64M`). |
| **Fast list** (rclone) | `--fast-list` — one recursive listing instead of many; helps OneDrive/Google Drive/S3 with deep trees (more RAM). |
| **OneDrive chunk size** (rclone) | `--onedrive-chunk-size` (e.g. `60M`) — accelerates large uploads to OneDrive. |
| **Additional flags** | Extra CLI parameters appended verbatim as discrete arguments. Shell metacharacters are rejected (section 9); `--delete-excluded` is always refused. |
| **Exclude patterns** | One glob per line (or space-separated), max 64 patterns / 2000 chars total. Passed as discrete `--exclude` arguments to rclone/rsync — never shell-evaluated. Globs (`* ? [ ] [a-z]`) are allowed; quotes, backslashes, patterns starting with a dash, and control characters are rejected. Editing this field re-arms the dry-run gate. |

**Save** writes the config atomically and reloads the table; it does *not*
start an unsolicited preview — press **Test (dry-run)** in the form or **Dry**
on the row when you want one. Any save changes the config hash, so the gate
re-arms: dry-run again before the next live run.

---

## 6. The dry-run gate and Ack workflow

The gate is the plugin's core promise. For a **live** run (manual Run with the
switches off, or a scheduled run), the engine checks the job's dry-run record
and refuses (exit **77** + notification) unless **all** of these hold:

1. A dry-run is **on record** for this job.
2. That dry-run **succeeded**.
3. Its stored config hash **matches the current job config** — editing *any*
   field (paths, flags, excludes, ...) re-arms the gate.
4. The predicted deletion count is **≤ `WARN_DELETE`**, **or** you have
   acked the current dry-run.

The master dry-run switch sits *above* the gate: while ON, scheduled runs
never even attempt a live transfer (they run as simulations instead).

Typical promotion workflow for one job:

```
create/edit job → Dry-run → read summary → (deletions > warn? Ack)
                → per-job Dry switch = LIVE → master switch OFF
                → scheduled runs are real
```

The row shows a red **NEEDS ACK** badge whenever rule 4 is pending; the Ack
button asks you to **type the job name** (a fat-finger guard). The ack is
bound to the current dry-run + config hash — a new edit invalidates it.

---

## 7. Scheduling

- Expressions are classic 5-field cron (`minute hour day-of-month month
  day-of-week`), evaluated in the **server's local time zone**.
- Jobs are written into a **managed marker block** (`BEGIN/END rclone-jobs`)
  inside `/var/spool/cron/crontabs/root`. Unraid's Dillon cron reads only user
  crontabs (not `/etc/cron.d`) and never re-reads a changed file, so the
  plugin regenerates the block on every job change and restarts the cron
  service **only when the block actually changed**.
- **Dynamix Scheduler entries are preserved byte-for-byte** — the plugin never
  touches lines outside its markers.
- The block also contains a **`*/15` maintenance line** that runs the watchdog
  (history compaction, log pruning, stuck/stale alerts). Do not remove it
  manually; `regen-cron.sh` and Doctor flag drift.
- Cron lines use absolute paths and the engine exports its own PATH (cron's
  minimal PATH lacks `/usr/sbin`, where the rclone wrapper lives).
- Overlapping runs are blocked per job with `flock`: a second start is skipped
  with an alert, never queued behind the first.
- Scheduled runs **detach** into their own session (`setsid`), so a crond
  restart cannot kill a running transfer; results are logged as a structured
  `DONE` syslog line (rc, seconds).

---

## 8. Engines in detail

### rclone

Uses the rclone plugin's binary and config — remotes are whatever the rclone
plugin page shows; the plugin never passes `--config`. Built command (always
discrete array arguments, never string-evaluated):

```
rclone <sync|copy|check> SRC DST --transfers N --checkers N
  [--buffer-size X] [--fast-list] [--onedrive-chunk-size X]
  --max-delete N [--backup-dir DIR] [--bwlimit X] [additional flags]
  [--exclude P]...  ( -vv --dry-run | -v --stats 60s --stats-one-line )
```

Remote names used in SRC/DST must exist in `rclone listremotes` — an unknown
remote refuses the run (exit 78) with an alert pointing at the rclone plugin
page. Transferred byte counts are parsed from the stats lines into status,
history and the charts.

### rsync

For local↔local and local↔remote (ssh) targets:

```
rsync -aHAX --delete --ignore-missing-args
  ( -n -v --itemize-changes --info=stats2 | -v --info=stats2 )
  [--bwlimit X] [additional flags] [--exclude P]... SRC DST
```

Deletions always happen (it is `--delete`), which is exactly why the dry-run
gate, the exclude patterns and the storage-overlap guards apply here too.
rsync exit 24 (*some source files vanished* — normal on live folders) is
treated as benign success.

### custom

Runs your **executable script file** (missing or non-executable → exit 78).
Invocation: `script [SRC] [DST] [--dry-run]` — SRC/DST are optional positional
hints, and `--dry-run` is appended while the run is a simulation. The script
runs as root with a hardened PATH; honor the flag inside your script if you
want honest simulations (the gate still controls *when* the script runs for
real). The plugin cannot inject excludes into a custom engine, so a
storage-overlap on a custom job is a warn-once alert instead of an auto-fix
(section 9).

---

## 9. Safety model explained

Every guard below is enforced **engine-side** (the WebUI only mirrors it), so
the CLI and cron paths get exactly the same protection.

| Guard | Behavior |
|---|---|
| **Master dry-run switch** | ON by default. While ON, the schedule only simulates — no per-job setting can override it. |
| **Per-job dry-run** | `DRYRUN=yes` by default; the job simulates until you explicitly set it LIVE. |
| **Dry-run gate + Ack** | Section 6 — live runs require a fresh, successful, matching dry-run, plus an Ack when predicted deletions exceed `WARN_DELETE`. Refusal = exit 77 + warning notice; nothing touched. |
| **Mount guard** | Source must exist; destination must already be a mounted directory; anything resolving to tmpfs/rootfs (array not started) is refused with exit 75 + alert. Destinations are **never** auto-created. |
| **Share/storage policy** | Plugin data only under a hidden dot-folder on an array disk. `STORAGE_ROOT` under `/mnt/user`, `/boot`, `/etc`, `/usr`, `/var/log` or `/` is refused everywhere (engine, installer, Doctor), checked both on the raw string and after path normalization (`..` smuggling fails). `/boot` is refused to spare the flash device. |
| **Storage overlap** | A job with SRC/DST **inside** the storage folder is refused outright (exit 78) — plugin logs/status can never be uploaded or `--delete`d by a misconfigured job. A job whose SRC/DST **contains** the storage folder (hosting-disk root, `/mnt/user`) runs with `/.rclone-jobs` **auto-excluded** on both sides (rclone: two anchored excludes; rsync: one anchored `--exclude`). `--delete-excluded` in Additional flags is refused. Custom-engine jobs get a warn-once alert instead (no exclude can be injected there). |
| **Delete caps** | rclone `--max-delete` (default 100) is always passed; the `WARN_DELETE` + Ack rule sits on top of it. |
| **Config injection** | Job names, remote names, schedules, paths, excludes and flags are whitelist-validated on save; config values are parsed by key and **never shell-evaluated**, reaching rclone/rsync as discrete array arguments. Shell metacharacters (backtick, `$ ; \| & < > * ? " '` and backslash) are rejected in paths and flags — globs are allowed *only* inside Exclude patterns, where they are safe. |
| **WebUI** | POST-only ajax, CSRF-checked (token recovered from the raw body — Unraid 7.2+ unsets it before plugin PHP runs), non-scalar POST values rejected, all values re-validated server-side; destructive actions need typed/confirm dialogs. |
| **Path browser** | Strictly read-only; confined to `/mnt/user`, `/mnt/diskN`, `/mnt/remotes` (plus `*.sh` under the plugins dir for the Script field); realpath containment rejects symlink/`..` escapes; dot-folders hidden; 500-entry cap; rclone listings time-bounded. |
| **Secrets hygiene** | Log output passes a redaction filter (`token/secret/key/password=...` masked) before storage and before display; the plugin stores no credentials and never contacts a notification provider. |
| **Uninstall** | Removes code + cron block (restarting cron only when the block was present); **keeps** your configs, logs, history and backups. |

---

## 10. Notifications

All alerts go through **Unraid's native notify system** — delivery (WebUI
bell, email, Telegram, Discord, Slack, Pushover) is configured once per
importance level under *Settings → Notification Settings*. Nothing is
configured in this plugin and no credentials are stored here.

- **Levels** — `normal` (OK heartbeats), `warning` (gate blocks, stale jobs,
  parity deferrals), `alert` (refusals, failures, stuck runs, shutdown
  cut-offs).
- **Per job** — `NOTIFY`: `always` (OK + problems) / `failures` (problems
  only) / `off` (silent; syslog + the job log are still written). Legacy
  `HEARTBEAT=no` configs map to `failures`.
- **Quiet window** — suppresses only the `normal` OK notices inside the window
  (default 23:00 → 07:00, may wrap midnight); problems are always sent.
- **Recovery etiquette** — a successful run dismisses that job's stale FAILED
  / refused / gate notices from the bell.
- **Rich notices** — run results include seconds, transferred bytes, error
  counts, the log path, and a deep link to the plugin page.
- **Test** — Alerts & Safety tab button, `notify-test [normal|warning|alert]`
  on the CLI, or `doctor --notify`.

Since 2026.09.07a there is **no built-in Telegram sender**; a leftover
`/mnt/diskN/.rclone-jobs/notify.env` is never read and can be deleted.

---

## 11. Live status, run control and the watchdog

- **Live updates (SSE)** — the engine publishes run start/finish events to
  nchan (`/pub/rclone-jobs`; fire-and-forget, 2 s cap, never fatal — cron runs
  work fine without nginx). The page subscribes via
  `EventSource('/sub/rclone-jobs')` and patches rows in place; after two
  socket failures it degrades to 60 s polling (`live: off`).
- **Stop a live run** — red **Stop** button (or `stop <job>` on the CLI): a
  stop marker + SIGTERM goes to the run's process group (so rclone/rsync
  children are included), escalating to SIGKILL if TERM is ignored; the run
  records rc **143** and keeps its log. A PID is only signaled when it is
  alive, holds the job lock and runs that exact job — a recycled PID can never
  be killed. Stop on an idle job is a clean no-op.
- **Array shutdown** — the `stopping` event logs and notifies (once) about
  jobs cut off mid-run; the engine's signal traps mark rc 143, publish status
  and never delay a shutdown.
- **Overlap lock** — per-job `flock`; a second concurrent start is skipped
  with an alert instead of racing.
- **Parity deferral** — with `DEFER_ON_PARITY=yes`, a live run that begins
  while a parity check, disk rebuild or balance is active is skipped before
  anything else is touched (exit 0, syslog `DEFERRED`, one notice per
  deferral episode). Dry-runs never defer; stale deferral markers sweep after
  7 days.
- **Watchdog** (every 15 min from the managed cron block, or `watchdog` by
  hand):
  - **Stuck**: `running` + lock held > 6 h → alert (deduplicated 24 h).
  - **Stale**: no successful run in > 26 h → warning (quiet while parity
    deferrals are active).
  - **Phantom repair**: `running:true` with the lock free (the engine died
    without its trap — hard kill/OOM) is corrected to rc 143 and published, so
    a dead job can never pulse RUN forever.
  - Sweeps leftover pid/stop-marker files, prunes finished preview task files
    (> 1 h), compacts history and prunes logs (section 12).

---

## 12. Storage layout and retention

Default `STORAGE_ROOT` is the first array disk's dot-folder, auto-detected at
install/boot (e.g. `/mnt/disk1/.rclone-jobs`). It is not a share; shfs may
surface it to `ls -a` under `/mnt/user` — cosmetic only, and any job whose
SRC/DST contains it auto-excludes it (section 9).

```
STORAGE_ROOT/
├── rclone-jobs.sh      # engine copy for CLI use (atomically re-deployed)
├── logs/               # <job>-YYYYmmdd-HHMMSS.log, <job>-DRYRUN-*.log,
│   ├── keep/           #   doctor-*.txt; failed logs carry a keep-marker
│   └── ...
├── status/             # <job>.json, <job>-dryrun.json, task-*.out/.rc/.pid,
│                       # <job>.run.pid, <job>.stop, <job>.defer
├── history/            # <job>.jsonl (raw lines) + <job>.rollup.jsonl
│                       #   (hourly + daily buckets)
└── backup/             # local backup-dir target area
```

**Tiered history** (survives minutes-schedules): every live run appends a raw
JSON line, kept for `HISTORY_RAW_HOURS` (max `HISTORY_RAW_MAX` lines), then
folded into one **hourly** bucket for `HISTORY_HOUR_DAYS` days, then one
**daily** bucket for `HISTORY_DAYS` days (runs/fails/errors/duration/bytes per
bucket). A 3-minute schedule therefore keeps a full 90-day trend in a few
hundred lines instead of tens of thousands. Compaction runs automatically
after runs and with the 15-minute watchdog. Dry-runs are not recorded to
history.

**Logs**: OK and dry-run logs age out after `LOG_KEEP_DAYS` (also capped at
`LOG_KEEP_MAX` files per job, newest win); failed/interrupted logs stay
`LOG_KEEP_FAIL_DAYS`. The Log button always shows a log while it exists; once
aged out, the viewer says so.

Retention knobs (all clamped — invalid values fall back to the default):

| Knob (`paths.env`) | Default | Range | Meaning |
|---|---|---|---|
| `HISTORY_RAW_HOURS` | 24 | 1–168 | raw per-run lines kept (hours) |
| `HISTORY_RAW_MAX` | 500 | 20–5000 | raw lines cap per job |
| `HISTORY_HOUR_DAYS` | 7 | 1–60 | hourly buckets (days) |
| `HISTORY_DAYS` | 90 | 7–365 | daily buckets (days, never below hourly) |
| `LOG_KEEP_DAYS` | 3 | 1–90 | OK/dry-run log age-out |
| `LOG_KEEP_FAIL_DAYS` | 14 | 1–90 | failed log age-out (never below keep days) |
| `LOG_KEEP_MAX` | 300 | 20–20000 | log files cap per job |

All seven are editable on the **Alerts & Safety** tab (same clamps
server-side) or by editing `paths.env` directly.

---

## 13. Settings reference (paths.env)

`/boot/config/plugins/rclone-jobs/paths.env` — plain `KEY=VALUE`, whitelisted
keys, written atomically by the UI (also safe to hand-edit):

| Key | Default | Meaning |
|---|---|---|
| `DRY_RUN_MASTER` | `yes` | master dry-run switch (section 6) |
| `QUIET_START` / `QUIET_END` | `23:00` / `07:00` | OK-notice quiet window (24 h clock, may wrap midnight) |
| `STORAGE_ROOT` | *(auto)* | plugin data folder; set explicitly to pin a disk (e.g. `/mnt/disk2/.rclone-jobs`). Must satisfy the share policy or the engine exits 78. Moving the folder: stop jobs, move the data, set the key, run Doctor. |
| `HISTORY_RAW_HOURS` ... `LOG_KEEP_MAX` | see section 12 | retention knobs |
| `CONFIG_VERSION` | `1` | format marker (readers ignore unknown keys) |

Values are re-validated/clamped on every read — garbage in a hand-edit
degrades to defaults, never to a broken run.

---

## 14. Job configuration reference

`/boot/config/plugins/rclone-jobs/jobs/<name>.conf` — one file per job,
whitelisted `KEY=VALUE` lines (unknown keys ignored, values never eval'd).
Changing **any** key changes the config hash and therefore **re-arms the
dry-run gate** — by design.

| Key | Values / default | Used by | Notes |
|---|---|---|---|
| `DESC` | text, ≤ 120 | UI | description |
| `ENGINE` | `rclone` \| `rsync` \| `custom` | all | required |
| `MODE` | `sync` \| `copy` \| `check` | rclone | required for rclone; forbidden for rsync |
| `SRC`, `DST` | paths / `remote:path` | rclone, rsync | required (optional for custom); shell metacharacters rejected |
| `SCHEDULE` | 5-field cron | all | required for scheduled runs |
| `ENABLED` | `yes`/`no` (yes) | cron | table **On** switch |
| `DRYRUN` | `yes`/`no` (yes) | engine | table **Dry** switch; per-job simulation mode |
| `TRANSFERS` / `CHECKERS` | 0–999 (4 / 8) | rclone | `--transfers` / `--checkers` |
| `BWLIMIT` | e.g. `8M` | rclone, rsync | `--bwlimit` |
| `BUFFER_SIZE` | e.g. `64M` | rclone | `--buffer-size` |
| `FAST_LIST` | `yes`/`no` (no) | rclone | `--fast-list` |
| `ONEDRIVE_CHUNK_SIZE` | e.g. `60M` | rclone | `--onedrive-chunk-size` |
| `MAXDELETE` | 0–999999999 (100) | rclone | `--max-delete` hard cap |
| `WARN_DELETE` | 0–999999999 (100) | gate | Ack threshold (section 6) |
| `BACKUPDIR` | `remote:path` or path inside STORAGE_ROOT | rclone | `--backup-dir` before-delete copy |
| `ARGS` | space-separated flags | rclone, rsync | additional flags; `--delete-excluded` refused |
| `EXCLUDE` | globs, space/newline-separated (≤ 64 patterns / 2000 chars) | rclone, rsync | `--exclude` patterns (section 5) |
| `DEFER_ON_PARITY` | `yes`/`no` (no) | engine | skip live runs during parity/rebuild/balance |
| `NOTIFY` | `always` \| `failures` \| `off` (always) | alerts | per-job notification level |
| `HEARTBEAT` | `yes`/`no` | legacy | `no` maps to `NOTIFY=failures` |
| `UMASK` | octal (002) | engine | applied to the transfer process |
| `CUSTOM_SCRIPT` | absolute executable path | custom | required for custom engine |

---

## 15. CLI reference

Engine location (either copy works — the storage copy is refreshed atomically
on boot/update):

```
/usr/local/emhttp/plugins/rclone-jobs/engine/rclone-jobs.sh <command> ...
/mnt/diskN/.rclone-jobs/rclone-jobs.sh <command> ...
```

| Command | Description |
|---|---|
| `list` | list job names |
| `status` | one line per job (run + dry-run outcomes) |
| `status-json` | all jobs' live state as one JSON object |
| `run <job> [--dry-run]` | run a job; non-tty runs detach — use `stop` to cancel |
| `preview <job>` | synchronous dry-run alias of `run <job> --dry-run` |
| `stop <job>` | stop a live run (rc 143; escalates to KILL) |
| `ack <job>` | acknowledge a deletion-heavy dry-run |
| `preview-start <job>` | detached preview (what the WebUI uses) |
| `task-status <job>` | preview task state: `running` or `done` + output (consumed once) |
| `task-cancel <job>` | terminate a running preview task |
| `tail-log <job>` | redacted tail (64 KiB) of the job's last log as JSON |
| `history <job> [n]` | last n live runs + hourly/daily rollups as JSON |
| `export-jobs` | job set as tar.gz, base64 on stdout (JSON) |
| `import-jobs <ask\|overwrite\|skip> <b64-file>` | validated import (section 16) |
| `validate-job <job>` | run all save-time validators on one job config |
| `browse <local\|rclone> <path> [files]` | read-only confined listing as JSON |
| `watchdog` | stale/stuck alerts + history rollups + log pruning |
| `shutdown-notice` | internal (`stopping` event hook) |
| `notify-test [normal\|warning\|alert]` | send one test notification |
| `doctor [--notify]` | full self-test, PASS/FAIL table + paste-back block |

### Exit codes (contract)

| Code | Meaning |
|---|---|
| 0 | success (or benign: overlap-blocked start, parity deferral, rsync rc 24) |
| 75 | mount guard — source missing / destination not a mounted directory; nothing touched |
| 77 | dry-run gate — live run refused until a current dry-run (and Ack if required) |
| 78 | configuration error (share policy, invalid field, unknown remote, bad storage root) |
| 127 | rclone wrapper missing — reinstall the rclone plugin |
| 143 | interrupted (Stop button, signal, array shutdown) |
| n | otherwise the underlying engine's exit code (see the job log) |

### Examples

```bash
E=/usr/local/emhttp/plugins/rclone-jobs/engine/rclone-jobs.sh

$E status                         # quick overview
$E run backups --dry-run          # preview from the shell
$E ack backups                    # accept predicted deletions
$E run backups                    # live run (gate must pass)
$E stop backups                   # cancel a live run
$E tail-log backups               # last 64 KiB of the last log
$E doctor                         # self-test
```

---

## 16. Export / import (fleet setup)

- **Export** (Alerts & Safety tab, or `export-jobs`): every job config plus a
  small `meta.txt` (plugin version, export time, host) packed as a
  deterministic `.tgz` download. It contains job names, paths, schedules and
  script locations — **no credentials** (rclone credentials always stay in the
  server's rclone config) — but treat the file as infrastructure detail.
- **Import**: upload the `.tgz` with a mode:
  - `ask` (default) — report name conflicts, change nothing;
  - `overwrite` — replace same-named jobs (a `.pre-import-<timestamp>` backup
    of each replaced config is kept first);
  - `skip` — keep existing same-named jobs.
- Safety: ~1 MiB size cap, member names whitelisted **before** extraction
  (tar-slip impossible), every config re-validated by the real save-time
  validators (one bad file is rejected individually, the rest still import),
  installs are atomic with mode 0600. Remote names must already exist in this
  server's rclone config or the imported job refuses to run until they do.
  The cron block is regenerated automatically when something is added or
  replaced.

---

## 17. Upgrading and uninstalling

- **Online update (recommended)**: Plugins → Check for Updates → **Update**
  (shell: `plugin update rclone-jobs.plg`). Every embedded file carries a
  `<SHA256>` of its deployed bytes and the update pre-clean wipes the old
  RAM-resident copy, so changed files are actually redeployed and files
  deleted between releases cannot linger. Config and job data survive
  untouched. Doctor verifies the deployed checksums afterwards.
- **Fallback** (an update looked ineffective): remove, then install the newer
  `.plg`. Versions are dates (`YYYY.MM.DD`, optional lowercase same-day
  suffix).
- **Uninstall**: Plugins → Remove. Removes the code and the managed crontab
  block (cron restarted only when the block was present). **Kept on purpose**:
  `/boot/config/plugins/rclone-jobs/` (settings + job configs) and
  `/mnt/diskN/.rclone-jobs/` (logs, status, history, backups). Full cleanup:

  ```
  rm -rf /mnt/disk1/.rclone-jobs /boot/config/plugins/rclone-jobs*
  ```

---

## 18. Troubleshooting

Start with **Doctor** — it covers most of this automatically. Then the job log
(Log button) and `grep rclone-jobs /var/log/syslog`.

| Symptom | Cause / fix |
|---|---|
| Nothing runs on schedule | Job needs `ENABLED=yes` + a schedule; check Doctor's crontab block/drift lines; the master switch decides dry vs real (dry runs produce no transfers by design). |
| Exit 77 on Run / scheduled | Dry-run gate — press **Dry-run** (or `run <job> --dry-run`) until it succeeds; Ack first if deletions exceed the warn threshold. Any edit re-arms it. |
| Exit 75 in logs | Mount guard — source missing or destination not a mounted directory (array stopped / share unmounted). Nothing was touched; fix the path or the array state. |
| Exit 78 | Config error — the message names the field (bad char in a path, invalid schedule, unknown remote, storage policy). Unknown remote: open the rclone plugin page and check/re-authenticate it. |
| Exit 127 | The rclone plugin's wrapper is missing — reinstall the rclone plugin. |
| "rclone not found" only under cron | Intentional probe detail: cron's PATH lacks `/usr/sbin`; the engine exports a full PATH itself and cron lines use absolute paths. Doctor reports this as INFO. |
| Row pulses RUN but nothing happens | Should self-heal (watchdog phantom repair within 15 min). Manual: `watchdog` or check for a crashed engine (`dmesg` for OOM). |
| Run refuses while parity runs, job says DEFERRED | Working as configured (`DEFER_ON_PARITY=yes`); it runs at the next scheduled time once the sync/check finishes. |
| No notifications | Settings → Notification Settings: agents enabled for the level? Per-job `NOTIFY` not `off`? OK notices are suppressed inside the quiet window. Test with `notify-test alert`. |
| Bell shows old failures | A successful run dismisses stale notices; dismiss manually otherwise. |
| Update seemed to change nothing | Should not happen since 2026.09.07 (embedded `<SHA256>`s); run Doctor — a checksum FAIL means stale files: remove + reinstall the `.plg`. |
| Table not updating live | SSE socket down → the page auto-falls back to 60 s polling (`live: off` indicator); nginx/nchan issue on the box, transfers are unaffected. |
| Log window says log is gone | OK/dry-run logs age out (default 3 days / 300 per job); failed logs stay 14 days. Tune on the Alerts & Safety tab. |

---

## 19. FAQ

**Can a scheduled job ever delete before I previewed?**
No. A live run requires a successful, current dry-run (plus Ack above the warn
threshold), and the master switch (ON by default) keeps all scheduled runs
simulating until you turn it off.

**Why does editing one flag block all my live runs?**
That is the gate re-arming: the dry-run you approved no longer describes what
would happen now. Re-run the dry-run.

**Where does my data go on disk?**
Only job *metadata* (logs/status/history) goes to `/mnt/diskN/.rclone-jobs`;
transferred files go exactly where the job's DST says. Nothing is written on
`/boot` except settings/job configs.

**Does it touch the rclone plugin or its config?**
No — it reuses `/boot/config/plugins/rclone/.rclone.conf` read-only and never
passes `--config`.

**Can jobs run while the array is stopped?**
No, and they never write to RAM decoys: the mount guard refuses (exit 75) with
an alert. After boot, the `started` event re-deploys the engine and cron block
once disks are mounted.

**How do I pin the storage to a specific disk?**
Set `STORAGE_ROOT=/mnt/diskN/.rclone-jobs` in `paths.env` (the folder must not
be under `/mnt/user`, `/boot`, `/etc`, `/usr`, `/var/log` or `/`).

**I deleted a job — are its logs gone?**
Logs and history stay under the storage folder until normal retention ages
them out; only the config and schedule line are removed.

**Is there an API?**
The CLI (`status-json`, `history`, `tail-log`, ...) returns JSON and is safe to
script. The WebUI ajax endpoints are POST+CSRF-bound and meant for the page
only.

---

*Manual for rclone-jobs v2026.09.10g — GPL-2.0-or-later.*
