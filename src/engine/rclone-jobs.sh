#!/bin/bash
# =============================================================================
# rclone-jobs engine v{{VERSION}} - scheduled transfers with a dry-run gate
# for Unraid 7. Runs ALONGSIDE the 'rclone' plugin: never modifies it, never
# passes --config, never moves its config file.
#
# License: GPL-2.0-or-later.
#
# Deliberately NO 'set -e': the engine must survive a failing job to report
# it. 'set -u' and pipefail are on. PATH is hardened internally because
# crond's PATH does not contain /usr/sbin, where the rclone plugin keeps
# rcloneorig behind its wrapper (verified: env -i PATH=/usr/bin:/bin
# /usr/sbin/rclone version -> exit 127).
#
# Exit codes:
#   0    success (or benign: overlap-blocked, rsync rc 24)
#   75   mount guard: array/share not mounted or path missing - nothing touched
#   77   dry-run gate: run refused until a current dry-run (or ack)
#   78   configuration error (storage policy, conf, fields)
#   127  rclone wrapper missing - reinstall the rclone plugin
#   n    otherwise: the underlying engine's exit code (see the log)
# =============================================================================
set -uo pipefail

ENGINE_VERSION="{{VERSION}}"
NAME="rclone-jobs"
BOOT_DIR="${RJ_BOOT_DIR:-/boot/config/plugins/rclone-jobs}"
EMHTTP_DIR="${RJ_EMHTTP_DIR:-/usr/local/emhttp/plugins/rclone-jobs}"
RCLONE_BIN="/usr/sbin/rclone"
RCLONE_EXPECT_CONF="/boot/config/plugins/rclone/.rclone.conf"
CRON_FILE="${RJ_CRON_FILE:-/var/spool/cron/crontabs/root}"  # Unraid scheduler = Dillon cron: user crontabs only, no /etc/cron.d
NOTIFY_SCRIPT="/usr/local/emhttp/webGui/scripts/notify"
NOTIFY_SCRIPT_DYN="/usr/local/emhttp/plugins/dynamix/scripts/notify"
NOTIFY_LINK="/Utilities/rclone-jobs"
LOCKDIR="/var/run"
DEFAULT_MAX_DELETE="100"
DEFAULT_WARN_DELETE="100"

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
export LC_ALL=C

DRY_RUN_MASTER="yes"
QUIET_START="23:00"
QUIET_END="07:00"
STORAGE_ROOT=""
LOG_DIR=""
STATUS_DIR=""
BACKUP_DIR=""
PHP_BIN=""

# history + log retention (paths.env overrides, clamped in load_paths)
HIST_RAW_HOURS="24"
HIST_RAW_MAX="500"
HIST_HOUR_DAYS="7"
HIST_DAYS="90"
LOG_KEEP_DAYS="3"
LOG_KEEP_FAIL_DAYS="14"
LOG_KEEP_MAX="300"

# ------------------------------------------------------------------- basics --
say()         { printf '%s\n' "$*"; }
stamp_now()   { date '+%F %T'; }
unix_now()    { date +%s; }
syslog_line() { logger -t rclone-jobs -- "$*" 2>/dev/null || true; }

die() { # <exitcode> <message...>
  local code="$1"; shift
  say "rclone-jobs: $*"
  syslog_line "ERROR $* (exit $code)"
  exit "$code"
}

redact() { # stdin->stdout: mask anything secret-looking before it hits a log
  sed -E 's/(token|secret|key|password)([=":])([^ ",]+)/\1\2***REDACTED***/Ig'
}

# lexical normalization (realpath -m: no mkdir side effects) + fail-closed policy
policy_ok() { # <path> -> 0 allowed / 1 forbidden (checks RAW string AND normalized path)
  # raw prefix gate first: a plugin-managed path may never START with a share
  # prefix, even if '../' segments would lexically escape it afterwards.
  # /boot is refused too: the flash device must not take plugin data (USB wear,
  # and the plugin's own config lives in /boot/config/plugins).
  case "$1" in /mnt/user|/mnt/user/*|/boot|/boot/*) return 1 ;; esac
  local rp
  rp="$(realpath -m -- "$1" 2>/dev/null)" || return 1
  case "$rp" in
    /)                       return 1 ;;
    /mnt/user|/mnt/user/*)   return 1 ;;
    /boot|/boot/*)           return 1 ;;
    /etc|/etc/*)             return 1 ;;
    /usr|/usr/*)             return 1 ;;
    /var/log|/var/log/*)     return 1 ;;
    *)                       return 0 ;;
  esac
}

bad_field() { # <value> -> 0 REJECT (shell metacharacters present)
  case "$1" in
    *'`'*|*'$'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'*'*|*'?'*|*'"'*|*"'"*|*'\\'*) return 0 ;;
    *) return 1 ;;
  esac
}

valid_jobname() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,40}$ ]]; }
valid_remote()  { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }

valid_schedule() { # 5 cron fields, numerics plus * , - / only (cron-injection defense)
  local re='^[0-9,*/-]+( [0-9,*/-]+){4}$'
  [[ "$1" =~ $re ]]
}

num_clamp() { # <value> <min> <max> <default> -> validated int on stdout (paths.env values are never trusted)
  local v="${1:-}"
  [[ "$v" =~ ^[0-9]{1,5}$ ]] || { printf '%s' "$4"; return 0; }
  v="$((10#$v))"
  [ "$v" -lt "$2" ] && v="$2"
  [ "$v" -gt "$3" ] && v="$3"
  printf '%s' "$v"
}

# ----------------------------------------------------------- configuration --
detect_storage() { # first /mnt/diskN backed by /dev/md* (array; parity is never mounted)
  local d src
  for d in /mnt/disk[0-9]*; do
    [ -d "$d" ] || continue
    src="$(findmnt -no SOURCE -T "$d" 2>/dev/null)" || continue
    case "$src" in
      # dot-folder: shfs hides dot-directories from the /mnt/user view, so the
      # plugin folder never appears in the share namespace or in zero-touch diffs
      /dev/md*) printf '%s/.%s\n' "$d" "$NAME"; return 0 ;;
    esac
  done
  return 1
}

load_paths() {
  if [ -f "$BOOT_DIR/paths.env" ]; then
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in ''|'#'*) continue ;; esac
      case "$line" in *=*) ;; *) continue ;; esac
      key="${line%%=*}"; val="${line#*=}"
      val="${val#\"}"; val="${val%\"}"
      case "$key" in
        STORAGE_ROOT)   STORAGE_ROOT="$val" ;;
        DRY_RUN_MASTER) DRY_RUN_MASTER="$val" ;;
        QUIET_START)    QUIET_START="$val" ;;
        QUIET_END)      QUIET_END="$val" ;;
        HISTORY_RAW_HOURS)  HIST_RAW_HOURS="$val" ;;
        HISTORY_RAW_MAX)    HIST_RAW_MAX="$val" ;;
        HISTORY_HOUR_DAYS)  HIST_HOUR_DAYS="$val" ;;
        HISTORY_DAYS)       HIST_DAYS="$val" ;;
        LOG_KEEP_DAYS)      LOG_KEEP_DAYS="$val" ;;
        LOG_KEEP_FAIL_DAYS) LOG_KEEP_FAIL_DAYS="$val" ;;
        LOG_KEEP_MAX)       LOG_KEEP_MAX="$val" ;;
      esac
    done < "$BOOT_DIR/paths.env"
  fi
  # explicit environment wins (doctor/tests use these; cron never sets them)
  [ -n "${RJ_STORAGE_ROOT:-}" ]   && STORAGE_ROOT="$RJ_STORAGE_ROOT"
  [ -n "${RJ_DRY_RUN_MASTER:-}" ] && DRY_RUN_MASTER="$RJ_DRY_RUN_MASTER"
  [ -n "$STORAGE_ROOT" ] || STORAGE_ROOT="$(detect_storage || true)"
  # retention knobs: clamp hard, compaction math must never see garbage
  HIST_RAW_HOURS="$(num_clamp "$HIST_RAW_HOURS" 1 168 24)"
  HIST_RAW_MAX="$(num_clamp "$HIST_RAW_MAX" 20 5000 500)"
  HIST_HOUR_DAYS="$(num_clamp "$HIST_HOUR_DAYS" 1 60 7)"
  HIST_DAYS="$(num_clamp "$HIST_DAYS" 7 365 90)"
  [ "$HIST_DAYS" -lt "$HIST_HOUR_DAYS" ] && HIST_DAYS="$HIST_HOUR_DAYS"
  LOG_KEEP_DAYS="$(num_clamp "$LOG_KEEP_DAYS" 1 90 3)"
  LOG_KEEP_FAIL_DAYS="$(num_clamp "$LOG_KEEP_FAIL_DAYS" 1 90 14)"
  [ "$LOG_KEEP_FAIL_DAYS" -lt "$LOG_KEEP_DAYS" ] && LOG_KEEP_FAIL_DAYS="$LOG_KEEP_DAYS"
  LOG_KEEP_MAX="$(num_clamp "$LOG_KEEP_MAX" 20 20000 300)"
}

storage_guard() { # validate STORAGE_ROOT, create plugin dirs, set *_DIR globals
  [ -n "$STORAGE_ROOT" ] || die 78 "STORAGE_ROOT is not set and no array disk was found - start the array or set STORAGE_ROOT in $BOOT_DIR/paths.env"
  policy_ok "$STORAGE_ROOT" || die 78 "STORAGE_ROOT '$STORAGE_ROOT' is REFUSED: plugin data must live outside /mnt/user, /boot, /etc, /usr, /var/log and outside / (share policy)"
  [ -d "$STORAGE_ROOT" ] || mkdir -p "$STORAGE_ROOT" 2>/dev/null || die 78 "cannot create STORAGE_ROOT '$STORAGE_ROOT' (array not started? read-only?)"
  STORAGE_ROOT="$(realpath -- "$STORAGE_ROOT" 2>/dev/null)" || die 78 "cannot resolve STORAGE_ROOT"
  policy_ok "$STORAGE_ROOT" || die 78 "STORAGE_ROOT resolves to '$STORAGE_ROOT' which the share policy forbids (possible ../ smuggling)"
  LOG_DIR="$STORAGE_ROOT/logs"
  STATUS_DIR="$STORAGE_ROOT/status"
  BACKUP_DIR="$STORAGE_ROOT/backup"
  mkdir -p "$LOG_DIR" "$STATUS_DIR" "$BACKUP_DIR" 2>/dev/null || die 78 "cannot create plugin directories under $STORAGE_ROOT"
  touch "$LOG_DIR/.probe" 2>/dev/null || die 78 "STORAGE_ROOT is not writable: $STORAGE_ROOT"
  rm -f "$LOG_DIR/.probe"
}

quiet_now() { # true inside the global quiet window (suppresses heartbeats only)
  local s e c
  [[ "${QUIET_START:-}" =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || return 1
  [[ "${QUIET_END:-}"   =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || return 1
  s=$(( 10#${QUIET_START%:*} * 100 + 10#${QUIET_START#*:} ))
  e=$(( 10#${QUIET_END%:*}   * 100 + 10#${QUIET_END#*:} ))
  c=$(( 10#$(date +%H%M) ))
  if [ "$s" -le "$e" ]; then
    [ "$c" -ge "$s" ] && [ "$c" -lt "$e" ]
  else
    [ "$c" -ge "$s" ] || [ "$c" -lt "$e" ]
  fi
}

notify_unraid() { # <normal|warning|alert> <subject> <desc> [message body]
  # native Unraid notification only: agents (bell, email, Telegram, Discord, ...)
  # are the user's choice in Settings -> Notification Settings; the plugin never
  # talks to any notification provider directly and stores no credentials.
  local n rc
  for n in "$NOTIFY_SCRIPT" "$NOTIFY_SCRIPT_DYN"; do
    [ -x "$n" ] || continue
    if [ -n "${4:-}" ]; then
      "$n" -e "$NAME" -s "$2" -d "$3" -i "$1" -m "$4" -l "$NOTIFY_LINK" >/dev/null 2>&1
    else
      "$n" -e "$NAME" -s "$2" -d "$3" -i "$1" -l "$NOTIFY_LINK" >/dev/null 2>&1
    fi
    rc=$?
    [ "$rc" -eq 0 ] || syslog_line "NOTIFY-FAIL level=$1 subject=$2 (notify script rc=$rc)"
    return "$rc"
  done
  syslog_line "NOTIFY-SKIP level=$1 subject=$2 (no notify script found)"
  return 1
}

notify_job() { # same args as notify_unraid, filtered by the per-job NOTIFY setting
  case "$J_NOTIFY" in
    off)      return 0 ;;
    failures) [ "$1" = normal ] && return 0 ;;
  esac
  notify_unraid "$@"
}

job_notify_setting() { # <job name> -> always|failures|off (legacy HEARTBEAT=no maps to failures)
  local f="$BOOT_DIR/jobs/$1.conf" v
  v="$(sed -nE 's/^NOTIFY=//p' "$f" 2>/dev/null | tail -1)"
  [ -n "$v" ] || v="$([ "$(sed -nE 's/^HEARTBEAT=//p' "$f" 2>/dev/null | tail -1)" = no ] && printf failures || printf always)"
  case "$v" in failures|off) printf '%s' "$v" ;; *) printf 'always' ;; esac
}

notify_dismiss() { # <subject> - clear a stale problem notification (event+subject match)
  # etiquette per Unraid docs: a recovered problem should not leave an alert in
  # the bell; dismissing is never itself an alert, so job NOTIFY=off cannot skip it
  local n
  for n in "$NOTIFY_SCRIPT" "$NOTIFY_SCRIPT_DYN"; do
    [ -x "$n" ] || continue
    "$n" -e "$NAME" -s "$1" -x >/dev/null 2>&1
    return 0
  done
  return 1
}

alert_refuse() { # <message> - loud everywhere; used for pre-transfer refusals
  syslog_line "REFUSED: $*"
  notify_job alert "rclone-jobs: refused to run $JOB_NAME" "$*" "STOP - nothing was transferred or deleted.
reason: $*
job: $JOB_NAME"
}

# ------------------------------------------------------------------- status --
status_file() { printf '%s/%s.json\n' "$STATUS_DIR" "$1"; }
dryrun_file() { printf '%s/%s-dryrun.json\n' "$STATUS_DIR" "$1"; }
run_pid_file()  { printf '%s/%s.run.pid\n' "$STATUS_DIR" "$1"; }
run_stop_mark() { printf '%s/%s.stop\n' "$STATUS_DIR" "$1"; }
conf_hash()   { sha256sum "$1" 2>/dev/null | cut -c1-16; }

status_set_running() { # <job> <confhash> <logfile>
  local f tmp; f="$(status_file "$1")"; tmp="$f.tmp"
  if [ -s "$f" ]; then
    jq --arg c "$2" --arg l "${3:-}" '. + {running:true, confhash:$c} + (if $l=="" then {} else {log:$l} end)' "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f"
  else
    jq -n --arg j "$1" --arg c "$2" --arg l "${3:-}" \
      '{job:$j, rc:null, secs:null, errors:null, run:null, last_ok:0, last_ok_run:null, transferred:"", running:true, confhash:$c}
        + (if $l=="" then {} else {log:$l} end)' \
      > "$tmp" 2>/dev/null && mv -f "$tmp" "$f"
  fi
}

status_finish() { # <job> <rc> <secs> <errors> <transferred> <running true|false> <confhash> [logfile]
  local f ok_run="" last_ok=0
  f="$(status_file "$1")"
  if [ -f "$f" ]; then last_ok="$(jq -r '.last_ok // 0' "$f" 2>/dev/null || echo 0)"; fi
  if [ "$2" -eq 0 ] || [ "$2" -eq 24 ]; then ok_run="$(stamp_now)"; last_ok="$(unix_now)"; fi
  jq -n \
    --arg job "$1" --argjson rc "$2" --argjson secs "$3" --argjson errors "${4:-0}" \
    --arg run "$(stamp_now)" --argjson last_ok "$last_ok" --arg ok_run "$ok_run" \
    --arg transferred "$5" --argjson running "$6" --arg confhash "$7" --arg log "${8:-}" \
    '{job:$job, rc:$rc, secs:$secs, errors:$errors, run:$run, last_ok:$last_ok,
      last_ok_run:(if $ok_run=="" then null else $ok_run end),
      transferred:$transferred, running:$running, confhash:$confhash}
      + (if $log=="" then {} else {log:$log} end)' \
    > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
}

# -------------------------------------------------------------- live status --
# nchan ships with Unraid 7: POST /pub/<channel> reaches every browser holding
# EventSource('/sub/<channel>'). Strictly fire-and-forget: cron or CLI runs on
# a box without nginx must not care whether this works.
sse_publish() { # <job> <running true|false> <rc number|null>
  local j="$1" run="$2" rcv="${3:-null}"
  command -v curl >/dev/null 2>&1 || return 0
  curl -s -m 2 -o /dev/null -X POST "http://localhost/pub/$NAME" \
    -H "Content-Type: application/json" \
    -d "{\"plugin\":\"$NAME\",\"job\":\"$j\",\"running\":$run,\"rc\":$rcv,\"ts\":$(unix_now)}"
  return 0
}

# --------------------------------------------------------------------- jobs --
J_ENGINE=""; J_MODE=""; J_SRC=""; J_DST=""; J_SCHEDULE=""; J_ENABLED="yes"
J_DRYRUN="yes"; J_ARGS=""; J_TRANSFERS="4"; J_CHECKERS="8"; J_BWLIMIT=""
J_BUFFER_SIZE=""; J_FAST_LIST="no"; J_ONEDRIVE_CHUNK_SIZE=""
J_MAXDELETE="$DEFAULT_MAX_DELETE"; J_BACKUPDIR=""; J_WARN_DELETE="$DEFAULT_WARN_DELETE"
J_UMASK="002"; J_HEARTBEAT="yes"; J_NOTIFY=""; J_DESC=""; J_CUSTOM_SCRIPT=""
JOB_NAME=""; JOB_CONF=""

load_job() { # whitelisted KEY=VALUE parse of $BOOT_DIR/jobs/<name>.conf; values never eval'd
  JOB_CONF="$BOOT_DIR/jobs/$JOB_NAME.conf"
  [ -f "$JOB_CONF" ] || die 78 "job '$JOB_NAME' not found ($JOB_CONF)"
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    val="${val#\"}"; val="${val%\"}"
    case "$key" in
      DESC)          J_DESC="$val" ;;
      ENGINE)        J_ENGINE="$val" ;;
      MODE)          J_MODE="$val" ;;
      SRC)           J_SRC="$val" ;;
      DST)           J_DST="$val" ;;
      SCHEDULE)      J_SCHEDULE="$val" ;;
      ENABLED)       J_ENABLED="$val" ;;
      DRYRUN)        J_DRYRUN="$val" ;;
      ARGS)          J_ARGS="$val" ;;
      TRANSFERS)     J_TRANSFERS="$val" ;;
      CHECKERS)      J_CHECKERS="$val" ;;
      BWLIMIT)       J_BWLIMIT="$val" ;;
      BUFFER_SIZE)   J_BUFFER_SIZE="$val" ;;
      FAST_LIST)     J_FAST_LIST="$val" ;;
      ONEDRIVE_CHUNK_SIZE) J_ONEDRIVE_CHUNK_SIZE="$val" ;;
      MAXDELETE)     J_MAXDELETE="$val" ;;
      BACKUPDIR)     J_BACKUPDIR="$val" ;;
      WARN_DELETE)   J_WARN_DELETE="$val" ;;
      UMASK)       J_UMASK="$val" ;;
      HEARTBEAT)   J_HEARTBEAT="$val" ;;
      NOTIFY)      J_NOTIFY="$val" ;;
      CUSTOM_SCRIPT) J_CUSTOM_SCRIPT="$val" ;;
    esac
  done < "$JOB_CONF"
  [ -n "$J_NOTIFY" ] || { [ "$J_HEARTBEAT" = no ] && J_NOTIFY=failures || J_NOTIFY=always; }
  validate_job
}

validate_job() {
  case "$J_ENGINE" in rclone|rsync|custom) ;; *) die 78 "job $JOB_NAME: ENGINE must be rclone|rsync|custom (got '$J_ENGINE')" ;; esac
  case "$J_ENABLED"   in yes|no) ;; *) J_ENABLED=yes ;; esac
  case "$J_DRYRUN"    in yes|no) ;; *) J_DRYRUN=yes ;; esac
  case "$J_HEARTBEAT" in yes|no) ;; *) J_HEARTBEAT=yes ;; esac
  case "$J_NOTIFY"    in always|failures|off) ;; *) J_NOTIFY=always ;; esac
  case "$J_FAST_LIST" in yes|no) ;; *) J_FAST_LIST=no ;; esac
  if [ -n "$J_BUFFER_SIZE" ]; then
    bad_field "$J_BUFFER_SIZE" && die 78 "job $JOB_NAME: BUFFER_SIZE contains forbidden characters"
  fi
  if [ -n "$J_ONEDRIVE_CHUNK_SIZE" ]; then
    bad_field "$J_ONEDRIVE_CHUNK_SIZE" && die 78 "job $JOB_NAME: ONEDRIVE_CHUNK_SIZE contains forbidden characters"
  fi
  [[ "$J_TRANSFERS"   =~ ^[0-9]{1,3}$ ]] || die 78 "job $JOB_NAME: TRANSFERS must be 0-999"
  [[ "$J_CHECKERS"    =~ ^[0-9]{1,3}$ ]] || die 78 "job $JOB_NAME: CHECKERS must be 0-999"
  [[ "$J_MAXDELETE"   =~ ^[0-9]{1,9}$ ]] || die 78 "job $JOB_NAME: MAXDELETE must be numeric"
  [[ "$J_WARN_DELETE" =~ ^[0-9]{1,9}$ ]] || die 78 "job $JOB_NAME: WARN_DELETE must be numeric"
  [[ "$J_UMASK"       =~ ^0?[0-7]{3,4}$ ]] || die 78 "job $JOB_NAME: UMASK must be 3 or 4 octal digits (e.g. 022 or 0022)"
  if [ "$J_ENGINE" != custom ]; then
    [ -n "$J_SRC" ] && [ -n "$J_DST" ] || die 78 "job $JOB_NAME: SRC and DST are required"
    bad_field "$J_SRC" && die 78 "job $JOB_NAME: SRC contains forbidden characters"
    bad_field "$J_DST" && die 78 "job $JOB_NAME: DST contains forbidden characters"
    bad_field "$J_BWLIMIT" && die 78 "job $JOB_NAME: BWLIMIT contains forbidden characters"
    local a
    for a in $J_ARGS; do
      bad_field "$a" && die 78 "job $JOB_NAME: ARGS token '$a' contains forbidden characters"
      case "$a" in --delete-excluded*) die 78 "job $JOB_NAME: ARGS '$a' is refused (it would defeat the storage auto-exclude)" ;; esac
    done
  fi
  case "$J_ENGINE" in
    rclone) case "$J_MODE" in sync|copy|check) ;; *) die 78 "job $JOB_NAME: MODE must be sync|copy|check" ;; esac ;;
    rsync)  [ -z "$J_MODE" ] || die 78 "job $JOB_NAME: rsync jobs have no MODE" ;;
  esac
  if [ -n "$J_BACKUPDIR" ]; then
    bad_field "$J_BACKUPDIR" && die 78 "job $JOB_NAME: BACKUPDIR contains forbidden characters"
    case "$J_BACKUPDIR" in
      *:*) : ;;
      "$STORAGE_ROOT"/*) : ;;
      *) die 78 "job $JOB_NAME: local BACKUPDIR must be inside STORAGE_ROOT ($STORAGE_ROOT) or a remote:path" ;;
    esac
  fi
}

# ------------------------------------------------------------------- guards --
is_local()  { case "$1" in *:*) return 1 ;; *) return 0 ;; esac; }
remote_of() { case "$1" in *:*) printf '%s' "${1%%:*}" ;; *) printf '' ;; esac; }

mount_guard() { # <path> <src|dst> - READ-ONLY checks; never mkdir -p. Exit 75 + alert.
  local d="$1" kind="${2:-dst}" fst src rootfst rootsrc
  if [ "$kind" = src ]; then
    [ -e "$d" ] || { alert_refuse "source '$d' does not exist - array not started / share not mounted - nothing was touched"; die 75 "mount guard: source '$d' does not exist"; }
  else
    [ -d "$d" ] || { alert_refuse "destination '$d' is not a mounted directory - array not started / share not mounted - nothing was touched (it will NOT be created)"; die 75 "mount guard: destination '$d' is not a directory"; }
  fi
  fst="$(findmnt -no FSTYPE -T "$d" 2>/dev/null)" \
    || { alert_refuse "cannot resolve the mount of '$d' - array not started - nothing was touched"; die 75 "mount guard: findmnt failed for '$d'"; }
  src="$(findmnt -no SOURCE -T "$d" 2>/dev/null)"
  case "$fst" in
    tmpfs|rootfs) alert_refuse "'$d' sits on volatile RAM storage ($fst) - array not started / share not mounted - nothing was touched"; die 75 "mount guard: '$d' on $fst" ;;
  esac
  rootfst="$(findmnt -no FSTYPE -T / 2>/dev/null)"
  rootsrc="$(findmnt -no SOURCE -T / 2>/dev/null)"
  if [ -n "$src" ] && [ "$src" = "$rootsrc" ] && [ "$fst" = "$rootfst" ]; then
    alert_refuse "'$d' resolves to the root filesystem ($src) - array not started - nothing was touched"
    die 75 "mount guard: '$d' on root overlay"
  fi
}

# ------------------------------------------------------- storage overlap --
# A job must never swallow the plugin's own storage folder. INSIDE (SRC/DST is
# STORAGE_ROOT or below it): refused outright - logs/status would be uploaded
# and --delete could erase the plugin's own data. ANCESTOR (SRC/DST
# CONTAINS STORAGE_ROOT, e.g. the hosting disk root): the run proceeds with the
# storage top folder auto-excluded on both sides of the transfer.
STORAGE_TOP=""   # e.g. /.rclone-jobs when a side is an ancestor; '' otherwise

storage_classify() { # <local path> -> echo '' | inside | ancestor:<top>
  local p="$1" rp rel
  [ -n "$STORAGE_ROOT" ] || { printf ''; return 0; }
  rp="$(realpath -m -- "$p" 2>/dev/null)" || { printf ''; return 0; }
  case "$rp" in
    "$STORAGE_ROOT"|"$STORAGE_ROOT"/*) printf 'inside'; return 0 ;;
  esac
  case "$STORAGE_ROOT" in
    "$rp"/*)
      rel="${STORAGE_ROOT#"$rp"/}"
      printf 'ancestor:/%s' "${rel%%/*}"
      return 0 ;;
  esac
  # shfs quirk (verified on-box): readdir of /mnt/user surfaces the dot-folder
  # at each disk ROOT, so share-wide jobs traverse it just like disk roots.
  # Only applies when the storage top segment IS that disk-root dot-folder.
  case "$rp" in
    /mnt/user)
      case "$STORAGE_ROOT" in
        /mnt/disk[0-9]*)
          rel="${STORAGE_ROOT#"/mnt/disk"}"; rel="${rel#*/}"
          case "$rel" in
            .*) printf 'ancestor:/%s' "${rel%%/*}"; return 0 ;;
          esac ;;
      esac ;;
  esac
  printf ''
}

ov_report() { # doctor use: one line per overlapping side (JOB_* set by load_job)
  local p cls
  for p in "$J_SRC" "$J_DST"; do
    [ -n "$p" ] || continue
    is_local "$p" || continue
    cls="$(storage_classify "$p")"
    case "$cls" in
      inside)     printf 'job %s: path %s is INSIDE the storage folder - runs will be refused\n' "$JOB_NAME" "$p" ;;
      ancestor:*) printf 'job %s: path %s contains the storage folder - %s is auto-excluded on runs\n' "$JOB_NAME" "$p" "${cls#ancestor:}" ;;
    esac
  done
}

overlap_check() { # after storage_guard + load_job; fills STORAGE_TOP; refuses INSIDE
  STORAGE_TOP=""
  [ -n "$STORAGE_ROOT" ] || return 0
  local p cls top anc=""
  for p in "$J_SRC" "$J_DST"; do
    [ -n "$p" ] || continue
    is_local "$p" || continue
    cls="$(storage_classify "$p")"
    case "$cls" in
      inside)
        alert_refuse "job $JOB_NAME: '$p' is inside the plugin storage folder ($STORAGE_ROOT) - logs and status must never be synced or deleted by a job"
        die 78 "job $JOB_NAME: SRC/DST inside STORAGE_ROOT - nothing was touched" ;;
      ancestor:*)
        top="${cls#ancestor:}"
        if [ -n "$STORAGE_TOP" ] && [ "$STORAGE_TOP" != "$top" ]; then
          die 78 "job $JOB_NAME: SRC and DST both contain the storage folder under different names ('$STORAGE_TOP' vs '$top') - unsupported, split the job"
        fi
        [ -n "$anc" ] || anc="$p"
        STORAGE_TOP="$top" ;;
    esac
  done
  if [ -z "$STORAGE_TOP" ]; then
    rm -f "$STATUS_DIR/$JOB_NAME-overlap" 2>/dev/null || true
    return 0
  fi
  syslog_line "AUTOEXCLUDE job=$JOB_NAME: '$STORAGE_TOP' shielded (SRC/DST '$anc' contains $STORAGE_ROOT)"
  if [ "$J_ENGINE" = custom ]; then
    say "rclone-jobs: $JOB_NAME: custom engine cannot receive an auto-exclude - '$STORAGE_TOP' is NOT shielded under '$anc'"
    local mark="$STATUS_DIR/$JOB_NAME-overlap" cur="$anc|$STORAGE_TOP"
    if [ ! -f "$mark" ] || [ "$(cat "$mark" 2>/dev/null)" != "$cur" ]; then
      printf '%s\n' "$cur" > "$mark" 2>/dev/null || true
      notify_job warning "rclone-jobs: $JOB_NAME storage overlap" "custom engine syncs '$anc' which contains $STORAGE_ROOT; $STORAGE_TOP is not shielded there"
    fi
  else
    say "rclone-jobs: $JOB_NAME: '$STORAGE_TOP' is auto-excluded (SRC/DST '$anc' contains the plugin storage folder)"
  fi
}

guard_rclone_available() {
  [ -x "$RCLONE_BIN" ] || { alert_refuse "the rclone wrapper '$RCLONE_BIN' is gone - reinstall the rclone plugin"; exit 127; }
  local cf
  cf="$("$RCLONE_BIN" config file 2>/dev/null | tr -d '\r' | grep -oE '/[^ ]+' | tail -1)"
  [ "$cf" = "$RCLONE_EXPECT_CONF" ] \
    || { alert_refuse "rclone config file is '$cf', expected '$RCLONE_EXPECT_CONF' - the rclone plugin config moved; refusing to guess"; exit 78; }
}

guard_remotes() {
  local remotes r
  remotes="$("$RCLONE_BIN" listremotes 2>/dev/null | tr -d ':\r')"
  for r in "$(remote_of "$J_SRC")" "$(remote_of "$J_DST")"; do
    [ -n "$r" ] || continue
    valid_remote "$r" || die 78 "job $JOB_NAME: invalid remote name '$r'"
    printf '%s\n' "$remotes" | grep -qxF "$r" \
      || { alert_refuse "remote '$r' is not configured - open the rclone plugin page and check/re-authenticate it"; die 78 "job $JOB_NAME: remote '$r' not in rclone listremotes"; }
  done
}

# -------------------------------------------------------------- dry-run gate --
block_gate() {
  say "rclone-jobs: GATE BLOCKED for $JOB_NAME: $*"
  syslog_line "GATE-BLOCKED job=$JOB_NAME: $*"
  notify_job warning "rclone-jobs gate: $JOB_NAME" "$*" "The real run was blocked by the dry-run gate; nothing was transferred.
job: $JOB_NAME"
  exit 77
}

gate_check() { # refuse LIVE runs without a successful dry-run on the CURRENT conf hash
  local f chash djok djhash djdel djack
  f="$(dryrun_file "$JOB_NAME")"
  chash="$(conf_hash "$JOB_CONF")"
  [ -f "$f" ] || block_gate "no dry-run on record. Run: $0 run $JOB_NAME --dry-run (or press [Dry run] in the UI)"
  djok="$(jq -r '.ok // false' "$f" 2>/dev/null)"
  djhash="$(jq -r '.confhash // ""' "$f" 2>/dev/null)"
  djdel="$(jq -r '.deletes // 0' "$f" 2>/dev/null)"
  djack="$(jq -r '.ack // false' "$f" 2>/dev/null)"
  [ "$djok" = "true" ] || block_gate "the last dry-run did not succeed - run it again"
  [ "$djhash" = "$chash" ] || block_gate "job config changed since the last dry-run - the gate re-armed; dry-run again"
  if [ "${djdel:-0}" -gt "$J_WARN_DELETE" ] && [ "$djack" != "true" ]; then
    block_gate "last dry-run predicts $djdel deletions (WARN_DELETE=$J_WARN_DELETE). Acknowledge: $0 ack $JOB_NAME (UI: type the job name)"
  fi
}

# -------------------------------------------------------------- command line --
CMD=()
build_command() { # <dry yes|no> - fills CMD array; nothing here is ever string-eval'd
  local dry="$1" a
  CMD=()
  case "$J_ENGINE" in
    rclone)
      CMD=("$RCLONE_BIN" "${J_MODE:-copy}" "$J_SRC" "$J_DST")
      CMD+=(--transfers "$J_TRANSFERS" --checkers "$J_CHECKERS")
      [ -n "$J_BUFFER_SIZE" ] && CMD+=(--buffer-size "$J_BUFFER_SIZE")
      [ "$J_FAST_LIST" = yes ] && CMD+=(--fast-list)
      [ -n "$J_ONEDRIVE_CHUNK_SIZE" ] && CMD+=(--onedrive-chunk-size "$J_ONEDRIVE_CHUNK_SIZE")
      CMD+=(--max-delete "$J_MAXDELETE")
      [ -n "$J_BACKUPDIR" ] && CMD+=(--backup-dir "$J_BACKUPDIR")
      [ -n "$J_BWLIMIT" ]   && CMD+=(--bwlimit "$J_BWLIMIT")
      for a in $J_ARGS; do CMD+=("$a"); done
      [ -n "$STORAGE_TOP" ] && CMD+=(--exclude "$STORAGE_TOP" --exclude "$STORAGE_TOP/**")
      if [ "$dry" = yes ]; then CMD+=(-vv --dry-run); else CMD+=(-v --stats 60s --stats-one-line); fi
      ;;
    rsync)
      CMD=(rsync -aHAX --delete --ignore-missing-args)
      if [ "$dry" = yes ]; then CMD+=(-n -v --itemize-changes --info=stats2)
      else CMD+=(-v --info=stats2); fi
      [ -n "$J_BWLIMIT" ] && CMD+=(--bwlimit "$J_BWLIMIT")
      for a in $J_ARGS; do CMD+=("$a"); done
      [ -n "$STORAGE_TOP" ] && CMD+=(--exclude="$STORAGE_TOP/")
      CMD+=("$J_SRC" "$J_DST")
      ;;
    custom)
      [ -n "$J_CUSTOM_SCRIPT" ] || die 78 "job $JOB_NAME: CUSTOM_SCRIPT is not set"
      [ -f "$J_CUSTOM_SCRIPT" ] && [ -x "$J_CUSTOM_SCRIPT" ] \
        || die 78 "job $JOB_NAME: custom script '$J_CUSTOM_SCRIPT' is missing or not executable (custom engine executes a FILE, never a command string)"
      CMD=("$J_CUSTOM_SCRIPT")
      [ -n "$J_SRC" ] && CMD+=("$J_SRC")
      [ -n "$J_DST" ] && CMD+=("$J_DST")
      [ "$dry" = yes ] && CMD+=("--dry-run")
      ;;
  esac
}

find_php() {
  [ -n "$PHP_BIN" ] && return 0
  PHP_BIN="$(command -v php || true)"
  if [ -z "$PHP_BIN" ]; then
    local p
    for p in /usr/bin/php /usr/local/bin/php; do
      [ -x "$p" ] && { PHP_BIN="$p"; break; }
    done
  fi
  [ -n "$PHP_BIN" ]
}

# --------------------------------------------------------- result processing --
ERR_COUNT=0; ERR_LAST=""; ERR_FILES=""; TR="0"
CLS_EMOJI="!"; CLS_HEAD="Failed"

parse_counters() { # <logfile>
  local lf="$1" n t rbytes
  ERR_COUNT=0; ERR_LAST=""; ERR_FILES=""; TR="0"
  n="$(grep -oE 'with [0-9]+ error' "$lf" 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1)"
  [ -n "$n" ] || n="$(grep -cE ' ERROR ' "$lf" 2>/dev/null)"
  ERR_COUNT="${n:-0}"
  ERR_LAST="$(grep -E ' ERROR ' "$lf" 2>/dev/null | tail -3 | sed -E 's/^.*ERROR[ ]*:[ ]*//' | cut -c1-200 | paste -sd '|' -)"
  ERR_FILES="$(grep -E ' ERROR ' "$lf" 2>/dev/null | sed -E 's/^.*ERROR[ ]*:[ ]*//; s/[ :].*$//' | grep -E '/' | sort -u | head -5 | paste -sd '|' -)"
  # 1. rclone --stats-one-line format (e.g. '2026/09/09 11:58:33 INFO  :     1.050 MiB / 1.050 MiB, 100%, 0 B/s, ETA -')
  t="$(grep -E '(INFO|NOTICE)[[:space:]]*:[[:space:]]+[0-9.]+ ?[KMGTPE]?i?B[[:space:]]*/' "$lf" 2>/dev/null | tail -1 \
       | sed -E 's/^.*(INFO|NOTICE)[[:space:]]*:[[:space:]]+//' | cut -d'/' -f1 | xargs 2>/dev/null)"
  # 2. Fallback: rclone multi-line / standard stats (e.g. 'Transferred:   1.050 MiB / 1.050 MiB')
  if [ -z "$t" ]; then
    t="$(grep -E '^[[:space:]]*Transferred:[[:space:]]+[0-9.]+' "$lf" 2>/dev/null | tail -1 \
         | sed -E 's/^[[:space:]]*Transferred:[[:space:]]+//' | cut -d, -f1 | cut -d'/' -f1 | cut -d'(' -f1 | xargs 2>/dev/null)"
  fi
  # 3. Fallback: rsync stats (e.g. 'Total transferred file size: 1,048,576 bytes')
  if [ -z "$t" ]; then
    rbytes="$(grep -E 'Total transferred file size:' "$lf" 2>/dev/null | tail -1 | sed -E 's/^.*:[[:space:]]*//; s/[^0-9]//g')"
    if [ -n "$rbytes" ]; then
      t="${rbytes} B"
    fi
  fi
  [ -n "$t" ] && TR="$t"
}

classify() { # <rc> <error text> - headline used by log, UI and notifications
  local rc="$1" e="$2"
  if printf '%s' "$e" | grep -Eqi 'invalid_grant|AADSTS|refresh token|status code 401|401 Unauthorized'; then
    CLS_EMOJI="LOCK";  CLS_HEAD="re-login needed for the remote - open the rclone plugin page and re-authenticate"
  elif printf '%s' "$e" | grep -Eqi 'no space left|quota'; then
    CLS_EMOJI="DISK";  CLS_HEAD="storage full or quota exceeded"
  elif printf '%s' "$e" | grep -Eqi '429|throttl'; then
    CLS_EMOJI="SLOW";  CLS_HEAD="rate-limited / throttled by the remote"
  elif printf '%s' "$e" | grep -Eqi 'reserved name|name too long|illegal'; then
    CLS_EMOJI="NAME";  CLS_HEAD="invalid filenames (reserved name / path too long) - fix the source before retrying"
  elif [ "$rc" -eq 24 ]; then
    CLS_EMOJI="OK";    CLS_HEAD="OK (rsync: some source files vanished during transfer - benign)"
  elif [ "$rc" -eq 0 ]; then
    CLS_EMOJI="OK";    CLS_HEAD="OK"
  elif [ "$J_ENGINE" = rsync ]; then
    case "$rc" in
      23)          CLS_EMOJI="WARN"; CLS_HEAD="rsync partial transfer (some files skipped with errors)" ;;
      10|12|30|35) CLS_EMOJI="NET";  CLS_HEAD="rsync network/protocol error (exit $rc)" ;;
      11|13|14)    CLS_EMOJI="DISK"; CLS_HEAD="rsync disk/IO error (exit $rc)" ;;
      *)           CLS_EMOJI="ERR";  CLS_HEAD="Failed (exit $rc)" ;;
    esac
  else
    CLS_EMOJI="ERR"; CLS_HEAD="Failed (exit $rc)"
  fi
}

render_preview() { # <logfile> <engine> <rc> <empty-dest yes|no>
  local lf="$1" eng="$2" rc="$3" ed="$4" out df txt
  if ! find_php; then say "(php CLI unavailable - structured preview disabled; raw log: $lf)"; return 0; fi
  df="$(dryrun_file "$JOB_NAME")"
  out="$("$PHP_BIN" "$EMHTTP_DIR/preview.php" --mode json --engine "$eng" --rc "$rc" --empty-dest "$ed" "$lf" 2>/dev/null)"
  if [ -z "$out" ]; then say "(preview renderer produced nothing - raw log kept: $lf)"; return 0; fi
  printf '%s\n' "$out" \
    | jq --arg job "$JOB_NAME" --arg stamp "$(stamp_now)" --arg chash "$(conf_hash "$JOB_CONF")" \
         --argjson warn "$J_WARN_DELETE" --arg log "$lf" \
         '. + {job:$job, stamp:$stamp, confhash:$chash, warnDelete:$warn, ack:false, log:$log}' \
    > "$df.tmp" 2>/dev/null && mv -f "$df.tmp" "$df"
  # text report generated from the CLEAN log (before appending), printed once,
  # then appended - re-parsing after append would double-count
  txt="$("$PHP_BIN" "$EMHTTP_DIR/preview.php" --mode text --engine "$eng" --rc "$rc" --empty-dest "$ed" "$lf" 2>/dev/null)"
  { printf -- '\n---- dry-run report ----\n'
    printf '%s\n' "$txt"
  } >> "$lf"
  printf '%s\n' "$txt"
  return 0
}

# -------------------------------------------------------------- subcommands --
cmd_run() { # <job> [--dry-run] [--sync] [--owned]
  JOB_NAME="${1:-}"
  local want_dry=no owned=no syncmode=no a
  for a in "$@"; do
    case "$a" in --owned) owned=yes ;; --sync) syncmode=yes ;; esac
  done
  [ "${2:-}" = "--dry-run" ] && want_dry=yes
  valid_jobname "$JOB_NAME" || die 78 "invalid job name '$JOB_NAME' (allowed: letters, digits, underscore, hyphen; max 40)"
  load_paths
  # non-tty runs (cron, WebUI nohup) detach into their OWN session (same
  # pattern as preview-start): the engine becomes the group leader, so 'stop'
  # can signal the whole tree - rclone/rsync/custom-script children included -
  # without ever touching the cron or php-fpm group. All authority stays with
  # the owned child: it re-validates, locks, and records its own pid.
  if [ "$owned" = no ] && [ "$syncmode" = no ] && [ ! -t 1 ]; then
    [ -f "$BOOT_DIR/jobs/$JOB_NAME.conf" ] || die 78 "job '$JOB_NAME' not found ($BOOT_DIR/jobs/$JOB_NAME.conf)"
    local spawner="nohup"
    command -v setsid >/dev/null 2>&1 && spawner="setsid"
    $spawner bash "$0" run "$@" --owned > /dev/null 2>&1 < /dev/null &
    say "rclone-jobs: $JOB_NAME dispatched in the background - logs under $STORAGE_ROOT/logs, status: $0 status $JOB_NAME, stop: $0 stop $JOB_NAME"
    return 0
  fi
  storage_guard
  load_job
  local dry=no master_forced=no
  [ "$want_dry" = yes ] && dry=yes
  [ "$J_DRYRUN" = yes ] && dry=yes
  if [ "$DRY_RUN_MASTER" = yes ] && [ "$dry" = no ]; then dry=yes; master_forced=yes; fi
  if [ "$J_ENGINE" = rclone ]; then guard_rclone_available; guard_remotes; fi
  if [ -n "$J_SRC" ]; then is_local "$J_SRC" && mount_guard "$J_SRC" src; fi
  if [ -n "$J_DST" ]; then is_local "$J_DST" && mount_guard "$J_DST" dst; fi
  overlap_check
  [ "$dry" = no ] && gate_check
  if [ "$master_forced" = yes ]; then
    say "rclone-jobs: DRY_RUN_MASTER=yes -> forcing --dry-run (global master switch is ON)"
    syslog_line "MASTER-DRY job=$JOB_NAME real run downgraded to dry-run"
  fi
  local lock="$LOCKDIR/$NAME-$JOB_NAME.lock"
  exec 200>"$lock" || die 78 "cannot open lock file $lock"
  if ! flock -n 200; then
    say "rclone-jobs: $JOB_NAME is already running - overlap blocked, nothing was started"
    syslog_line "OVERLAP job=$JOB_NAME skipped (previous run still active)"
    notify_job warning "rclone-jobs overlap: $JOB_NAME" "a run was skipped because the previous run is still active"
    exit 0
  fi
  local chash sj ts logfile t0 t1 rc stopmark runpid
  # clear any stale stop marker before anything runs: the marker must only
  # ever belong to THIS run
  stopmark="$(run_stop_mark "$JOB_NAME")"; runpid="$(run_pid_file "$JOB_NAME")"
  rm -f "$stopmark" "$runpid" 2>/dev/null
  chash="$(conf_hash "$JOB_CONF")"
  sj="$(status_file "$JOB_NAME")"
  ts="$(date +%Y%m%d-%H%M%S)"
  if [ "$dry" = yes ]; then logfile="$LOG_DIR/$JOB_NAME-DRYRUN-$ts.log"; else logfile="$LOG_DIR/$JOB_NAME-$ts.log"; fi
  # log path recorded in the status BEFORE the run: the WebUI Log button finds
  # the file of a live run too, not only of finished ones
  status_set_running "$JOB_NAME" "$chash" "$logfile"
  printf '%s\n' "$$" > "$runpid" 2>/dev/null
  sse_publish "$JOB_NAME" true null
  build_command "$dry"
  {
    printf 'rclone-jobs %s | job: %s | mode: %s | engine: %s | %s\n' \
      "$ENGINE_VERSION" "$JOB_NAME" "$([ "$dry" = yes ] && echo DRY-RUN || echo LIVE)" "$J_ENGINE" "$(stamp_now)"
    printf 'command: %s\n' "${CMD[*]}" | redact
    printf 'config: %s | rclone config: %s\n' "$JOB_CONF" "$RCLONE_EXPECT_CONF"
    printf -- '----\n'
  } >> "$logfile"
  say "rclone-jobs: $JOB_NAME starting ($([ "$dry" = yes ] && echo dry-run || echo live)) log=$logfile"
  t0="$(unix_now)"
  # signal-aware exec: 'wait' returns immediately (>128) when TERM/INT arrive,
  # so the trap can mark the status before the box goes down. Shutdown keeps
  # its old behavior (children left to the shutdown's own kill pass); when the
  # stop marker exists this is an operator Stop: the run's own process group
  # (setsid session) is terminated so the transfer children actually end.
  trap 'if [ -f "$stopmark" ]; then
    [ -n "${jpid:-}" ] && kill -TERM "$jpid" 2>/dev/null   # fallback runs (nohup, no own group); cmd_stop already group-signaled a setsid run - signaling our own group from here would interrupt this very trap
    why="stopped by operator"; else why="interrupted by signal"; fi
    rm -f "$stopmark" "$runpid" 2>/dev/null
    status_finish "$JOB_NAME" 143 "$(( $(unix_now) - t0 ))" 0 "" false "$chash" "$logfile" 2>/dev/null
    sse_publish "$JOB_NAME" false 143
    [ "$dry" = no ] && hist_add "$JOB_NAME" 143 "$(( $(unix_now) - t0 ))" 0 "" "$logfile"
    mkdir -p "$LOG_DIR/keep" 2>/dev/null
    touch "$LOG_DIR/keep/$(basename "$logfile").keep" 2>/dev/null
    printf "rclone-jobs: %s %s at %s (status marked rc=143)\n" "$JOB_NAME" "$why" "$(stamp_now)" >> "$logfile" 2>/dev/null
    trap - TERM INT
    exit 143' TERM INT
  local jpid
  if [ -t 1 ]; then
    # wrapped in a subshell: $! then waits for the WHOLE pipeline, and the
    # inherited 'set -o pipefail' makes its status the engine's rc, not tee's
    ( ( umask "$J_UMASK"; exec "${CMD[@]}" ) 2>&1 | tee -a "$logfile" ) &
    jpid=$!
    wait "$jpid"; rc=$?
  else
    # exec: jpid IS the transfer process (no intermediate subshell), so a
    # non-session-leader fallback stop can signal it precisely
    ( umask "$J_UMASK"; exec "${CMD[@]}" ) >> "$logfile" 2>&1 &
    jpid=$!
    wait "$jpid"; rc=$?
  fi
  trap - TERM INT
  rm -f "$runpid" "$stopmark" 2>/dev/null
  t1="$(unix_now)"
  local secs=$(( t1 - t0 ))
  parse_counters "$logfile"
  classify "$rc" "$ERR_LAST"
  if [ "$dry" = yes ]; then
    local ed=no
    if is_local "$J_DST" && [ -d "$J_DST" ]; then
      [ -z "$(ls -A "$J_DST" 2>/dev/null | head -1)" ] && ed=yes
    fi
    render_preview "$logfile" "$J_ENGINE" "$rc" "$ed"
    local prc=0 perr=0 ptr=""
    if [ -s "$sj" ]; then
      prc="$(jq -r '.rc // 0' "$sj" 2>/dev/null)"
      perr="$(jq -r '.errors // 0' "$sj" 2>/dev/null)"
      ptr="$(jq -r '.transferred // ""' "$sj" 2>/dev/null)"
    fi
    status_finish "$JOB_NAME" "${prc:-0}" 0 "${perr:-0}" "$ptr" false "$chash" "$logfile"
    sse_publish "$JOB_NAME" false null
  else
    status_finish "$JOB_NAME" "$rc" "$secs" "$ERR_COUNT" "$TR" false "$chash" "$logfile"
    sse_publish "$JOB_NAME" false "$rc"
    hist_add "$JOB_NAME" "$rc" "$secs" "$ERR_COUNT" "$TR" "$logfile"
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 24 ]; then
      # failed log: marked so the watchdog keeps it LOG_KEEP_FAIL_DAYS (OK logs
      # of a busy job age out much faster and flood the count cap)
      mkdir -p "$LOG_DIR/keep" 2>/dev/null || true
      touch "$LOG_DIR/keep/$(basename "$logfile").keep" 2>/dev/null || true
    fi
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ]; then
      # recovered: clear stale problem notices from the bell + fresh watchdog dedup
      notify_dismiss "rclone-jobs: $JOB_NAME FAILED"
      notify_dismiss "rclone-jobs: refused to run $JOB_NAME"
      notify_dismiss "rclone-jobs gate: $JOB_NAME"
      rm -f "$STATUS_DIR/.wd-$JOB_NAME" 2>/dev/null || true
      if [ "$J_NOTIFY" = always ] && ! quiet_now; then
        notify_job normal "rclone-jobs: $JOB_NAME OK" "${secs}s - ${TR} transferred" \
          "job: $JOB_NAME
transferred: ${TR} in ${secs}s
log: $logfile"
      fi
    else
      notify_job alert "rclone-jobs: $JOB_NAME FAILED" "$CLS_HEAD (exit $rc)" \
        "job: $JOB_NAME
result: $CLS_HEAD
exit=$rc - ${secs}s - ${ERR_COUNT} error(s)
errors: $(printf '%s' "${ERR_LAST:-none}" | cut -c1-800)
failing files: ${ERR_FILES:-unknown}
log: $logfile"
    fi
  fi
  say "rclone-jobs: $JOB_NAME finished rc=$rc (${secs}s) - $CLS_HEAD"
  # detached (owned) runs have stdout on /dev/null: keep the cron-pipe-era
  # syslog summary alive for scheduled runs
  [ "$owned" = yes ] && syslog_line "DONE job=$JOB_NAME rc=$rc secs=${secs} - $CLS_HEAD"
  [ "$rc" -eq 24 ] && rc=0
  exit "$rc"
}

cmd_ack() { # acknowledge a deletion-heavy dry-run (UI confirms by typing the job name)
  JOB_NAME="${1:-}"
  valid_jobname "$JOB_NAME" || die 78 "invalid job name '$JOB_NAME'"
  load_paths
  storage_guard
  local f; f="$(dryrun_file "$JOB_NAME")"
  [ -f "$f" ] || die 78 "no dry-run on record for $JOB_NAME - run a dry-run first"
  jq '. + {ack:true}' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" \
    || die 78 "could not update $f"
  say "acknowledged the deletion preview for $JOB_NAME (stays valid until the next dry-run re-arms it)"
}

cmd_stop() { # <job> -> exactly one JSON line. Graceful: marker + group TERM; the
  # run's own trap records rc=143 (status, SSE, history, log keep-marker). A pid
  # is only ever signaled when it is alive, HOLDS the job lock, AND its cmdline
  # references rclone-jobs + this exact job - a recycled pid is never killed.
  JOB_NAME="${1:-}"
  valid_jobname "$JOB_NAME" || task_json_err "invalid job name '$JOB_NAME'"
  load_paths
  storage_guard
  local pf sm sj lk pid i alive pgid cl
  pf="$(run_pid_file "$JOB_NAME")"; sm="$(run_stop_mark "$JOB_NAME")"
  sj="$(status_file "$JOB_NAME")"; lk="$LOCKDIR/$NAME-$JOB_NAME.lock"
  pid=""
  [ -f "$pf" ] && pid="$(cat "$pf" 2>/dev/null | tr -dc '0-9')"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pf" "$sm" 2>/dev/null
    task_json_err "no live run of $JOB_NAME"
  fi
  if ! { [ -f "$lk" ] && ! flock -n "$lk" true 2>/dev/null; }; then
    rm -f "$pf" 2>/dev/null
    task_json_err "no live run of $JOB_NAME (job lock not held - stale pid cleared)"
  fi
  cl="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  case "$cl" in *rclone-jobs.sh*) ;; *)
    rm -f "$pf" 2>/dev/null
    task_json_err "recorded pid $pid is not an rclone-jobs run (stale pid cleared)" ;;
  esac
  case " $cl " in *" $JOB_NAME "*) ;; *)
    rm -f "$pf" 2>/dev/null
    task_json_err "recorded pid $pid does not belong to job $JOB_NAME (stale pid cleared)" ;;
  esac
  touch "$sm" 2>/dev/null
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -dc '0-9')"
  if [ "$pgid" = "$pid" ]; then kill -TERM -- -"$pid" 2>/dev/null || true; else kill -TERM "$pid" 2>/dev/null || true; fi
  # the trap can spend ~2 s in sse_publish before exiting: poll ~4 s
  i=0; alive=yes
  while [ "$i" -lt 40 ]; do
    kill -0 "$pid" 2>/dev/null || { alive=no; break; }
    sleep 0.1; i=$((i + 1))
  done
  if [ "$alive" = no ] || { [ -f "$sj" ] && [ "$(jq -r '.running // true' "$sj" 2>/dev/null)" = "false" ]; }; then
    rm -f "$pf" "$sm" 2>/dev/null
    syslog_line "STOP job=$JOB_NAME stopped by operator (run marked rc=143)"
    notify_job normal "rclone-jobs: $JOB_NAME stopped" "the live run was stopped by the operator (rc=143)" \
      "job: $JOB_NAME
next: the next scheduled run proceeds normally - a partial sync simply resumes"
    printf '{"ok":true,"job":"%s","stopped":true,"hard":false}\n' "$JOB_NAME"
    return 0
  fi
  # the engine ignored TERM (hung): escalate to KILL and finish the bookkeeping
  # the dead trap never did (status, SSE, history, keep-marker for the log)
  if [ "$pgid" = "$pid" ]; then kill -KILL -- -"$pid" 2>/dev/null || true; else kill -KILL "$pid" 2>/dev/null || true; fi
  sleep 1
  local chash lg
  chash="$(jq -r '.confhash // ""' "$sj" 2>/dev/null)"; lg="$(jq -r '.log // ""' "$sj" 2>/dev/null)"
  status_finish "$JOB_NAME" 143 0 0 "" false "$chash" "$lg" 2>/dev/null
  sse_publish "$JOB_NAME" false 143
  hist_add "$JOB_NAME" 143 0 0 "" "$lg"
  if [ -n "$lg" ]; then
    mkdir -p "$LOG_DIR/keep" 2>/dev/null
    touch "$LOG_DIR/keep/$(basename "$lg").keep" 2>/dev/null
  fi
  rm -f "$pf" "$sm" 2>/dev/null
  syslog_line "STOP job=$JOB_NAME hard-killed by operator (engine ignored TERM)"
  notify_job warning "rclone-jobs: $JOB_NAME stopped" "the live run ignored TERM and was force-killed (rc=143)" \
    "job: $JOB_NAME - check the job log; the next scheduled run proceeds normally"
  printf '{"ok":true,"job":"%s","stopped":true,"hard":true}\n' "$JOB_NAME"
}

# ------------------------------------------------------- async preview tasks --
# A dry-run on a huge remote can take minutes; it must never run inside the
# php request that started it. preview-start detaches 'preview' into its own
# session (setsid => own process group, so cancel reaches the rclone children
# too); the UI polls task-status (single-consume: output + files are removed
# when reported done) and may task-cancel while running. Files:
#   $STATUS_DIR/task-<job>.out   stdout/stderr of the detached preview
#   $STATUS_DIR/task-<job>.rc    exit code, written only when finished
#   $STATUS_DIR/task-<job>.pid   pid of the session leader (written by the child)
task_paths() { # sets TP_OUT TP_RC TP_PID for $JOB_NAME
  TP_OUT="$STATUS_DIR/task-$JOB_NAME.out"
  TP_RC="$STATUS_DIR/task-$JOB_NAME.rc"
  TP_PID="$STATUS_DIR/task-$JOB_NAME.pid"
}

task_pid_alive() {
  local pid
  [ -f "$TP_PID" ] || return 1
  pid="$(cat "$TP_PID" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

task_json_err() { # <message> - JSON error without jq (mirrors bj_json_err)
  local e="${1//\\/\\\\}"; e="${e//\"/\\\"}"; e="${e//$'\n'/ }"; e="${e//$'\r'/ }"
  printf '{"ok":false,"running":false,"error":"%s"}\n' "$e"
  exit 0
}

cmd_preview_start() { # <job> -> exactly one JSON line (spawned | busy | error)
  JOB_NAME="${1:-}"
  valid_jobname "$JOB_NAME" || task_json_err "invalid job name '$JOB_NAME'"
  load_paths
  storage_guard
  [ -f "$BOOT_DIR/jobs/$JOB_NAME.conf" ] || task_json_err "job '$JOB_NAME' not found"
  task_paths
  if task_pid_alive && [ ! -f "$TP_RC" ]; then
    printf '{"ok":false,"busy":true,"error":"a preview task is already running for this job"}\n'; return 0
  fi
  local rlock="$LOCKDIR/$NAME-$JOB_NAME.lock"
  if [ -f "$rlock" ] && ! flock -n "$rlock" true 2>/dev/null; then
    printf '{"ok":false,"busy":true,"error":"a run of this job is in progress"}\n'; return 0
  fi
  rm -f "$TP_OUT" "$TP_RC" "$TP_PID"
  # The CHILD records its own pid ($$): with setsid it is the session/group
  # leader, so $! of the short-lived setsid wrapper would be the wrong pid.
  # Positional args only - just a validated job name reaches the child.
  local spawner="nohup" i=0
  command -v setsid >/dev/null 2>&1 && spawner="setsid"
  $spawner bash -c 'echo $$ > "$1"; "$2" "$3" "$4" > "$5" 2>&1; echo $? > "$6"' \
    rj-task "$TP_PID" "$0" preview "$JOB_NAME" "$TP_OUT" "$TP_RC" >/dev/null 2>&1 </dev/null &
  while [ $i -lt 20 ] && [ ! -s "$TP_PID" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$TP_PID" ] || task_json_err "failed to start the detached preview"
  printf '{"ok":true,"job":"%s"}\n' "$JOB_NAME"
}

task_finish_emit() { # <rc> - redacted, size-capped JSON of the finished task; consumes files
  local rc="$1" body
  body="$(tail -c 262144 "$TP_OUT" 2>/dev/null | redact)"
  rm -f "$TP_OUT" "$TP_RC" "$TP_PID"
  command -v jq >/dev/null 2>&1 || { task_json_err "jq unavailable - task cleaned, rerun the preview"; }
  jq -nc --argjson rc "$rc" --arg out "$body" '{running:false, done:true, rc:$rc, out:$out}'
}

cmd_task_status() { # <job> -> {"running":true} | done JSON (single-consume) | none
  JOB_NAME="${1:-}"
  valid_jobname "$JOB_NAME" || task_json_err "invalid job name '$JOB_NAME'"
  load_paths
  storage_guard
  task_paths
  local rc
  if [ -f "$TP_RC" ]; then
    rc="$(cat "$TP_RC" 2>/dev/null | tr -dc '0-9')"; rc="${rc:-143}"
    task_finish_emit "$rc"
  elif task_pid_alive; then
    printf '{"running":true}\n'
  elif [ -f "$TP_PID" ]; then
    task_finish_emit 143   # hard-killed child never wrote its rc
  else
    printf '{"running":false,"none":true}\n'
  fi
}

cmd_task_cancel() { # <job> -> ok JSON; group-kill when the child owns its session
  JOB_NAME="${1:-}"
  valid_jobname "$JOB_NAME" || task_json_err "invalid job name '$JOB_NAME'"
  load_paths
  storage_guard
  task_paths
  task_pid_alive || task_json_err "no preview task running for $JOB_NAME"
  [ -f "$TP_RC" ] && task_json_err "task already finished"
  local pid; pid="$(cat "$TP_PID" 2>/dev/null)"
  kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 2
  kill -0 "$pid" 2>/dev/null && { kill -KILL -- -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true; }
  echo 143 > "$TP_RC" 2>/dev/null || true   # normally the child's own trap-free exit writes 143 first
  printf '{"ok":true}\n'
}

cmd_tail_log() { # <job> -> JSON {ok,log,size,text}: redacted tail of the recorded log.
  # The path comes ONLY from the validated status file and must sit inside
  # LOG_DIR - the request never supplies paths (no traversal possible).
  JOB_NAME="${1:-}"
  valid_jobname "$JOB_NAME" || { printf '{"ok":false,"error":"invalid job name"}\n'; return 0; }
  load_paths
  storage_guard
  command -v jq >/dev/null 2>&1 || { printf '{"ok":false,"error":"jq unavailable"}\n'; return 0; }
  local sj log sz text head=""
  sj="$(status_file "$JOB_NAME")"
  [ -f "$sj" ] || { printf '{"ok":false,"error":"no run recorded for %s yet"}\n' "$JOB_NAME"; return 0; }
  log="$(jq -r '.log // ""' "$sj" 2>/dev/null)"
  case "$log" in
    "$LOG_DIR"/*.log) : ;;
    *) printf '{"ok":false,"error":"no log path recorded for %s (run it once, or status predates v%s)"}\n' "$JOB_NAME" "$ENGINE_VERSION"; return 0 ;;
  esac
  [ -f "$log" ] || { printf '{"ok":false,"error":"log file is gone (OK logs are kept %s day(s), failed logs %s - retention: paths.env)"}\n' "$LOG_KEEP_DAYS" "$LOG_KEEP_FAIL_DAYS"; return 0; }
  sz="$(stat -c %s "$log" 2>/dev/null || echo 0)"
  if [ "${sz:-0}" -gt 65536 ]; then head="[last 64 KiB of ${sz} bytes - truncated]
"; fi
  text="$(tail -c 65536 "$log" | tr -d '\0' | redact)"  # nulls cannot live in $vars or json
  # running/rc/ts let a log window poll live and stop when the run ends
  local run rcn tsj
  run="$(jq -r 'if (.running // false) then "true" else "false" end' "$sj" 2>/dev/null)"
  [ "$run" = "true" ] || run="false"
  rcn="$(jq -r '.rc // "null"' "$sj" 2>/dev/null)"
  case "$rcn" in ''|*[!0-9-]*) rcn="null" ;; esac
  tsj="$(jq -r '.ts // 0' "$sj" 2>/dev/null)"
  case "$tsj" in ''|*[!0-9]*) tsj="0" ;; esac
  jq -nc --arg log "$log" --arg text "$head$text" --argjson size "${sz:-0}" \
        --argjson running "$run" --argjson rc "$rcn" --argjson ts "$tsj" \
    '{ok:true, log:$log, size:$size, running:$running, rc:$rc, ts:$ts, text:$text}'
}

# ------------------------------------------------------ export / import -----
# Fleet setup: export the job set (conf files only - they hold NO secrets by
# design) as a tar.gz delivered base64-through-JSON; import validates EVERY
# member before anything touches jobs/. The archive never follows symlinks
# and member names must match ^jobs/<valid-name>.conf$ (tar-slip guard).
imp_err() { # <message> - one-line JSON error
  local e="${1//\\/\\\\}"; e="${e//\"/\\\"}"; e="${e//$'\n'/ }"
  printf '{"ok":false,"error":"%s"}\n' "$e"
  return 0
}

cmd_export_jobs() { # -> JSON {ok,name,count,archive(b64)} - no STORAGE_ROOT needed
  load_paths
  local f n tmp b64 count=0
  [ -d "$BOOT_DIR/jobs" ] || { imp_err "no jobs configured yet - nothing to export"; return 0; }
  tmp="$(mktemp -d /tmp/rj-export.XXXXXX)" || { imp_err "mktemp failed"; return 0; }
  mkdir -p "$tmp/stage/jobs"
  for f in "$BOOT_DIR/jobs"/*.conf; do
    [ -e "$f" ] || continue
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    n="$(basename "$f" .conf)"
    valid_jobname "$n" || continue
    cp "$f" "$tmp/stage/jobs/$n.conf" || { rm -rf "$tmp"; imp_err "copy failed for $n"; return 0; }
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || { rm -rf "$tmp"; imp_err "no valid job configs to export"; return 0; }
  printf 'plugin=rclone-jobs\nversion=%s\nexported=%s\nhost=%s\n' \
    "$ENGINE_VERSION" "$(stamp_now)" "$(hostname 2>/dev/null || printf unknown)" > "$tmp/stage/meta.txt"
  # -h (no dereference) is the default here: only the regular confs were staged
  ( cd "$tmp/stage" && tar -czf "$tmp/export.tgz" --owner=0 --group=0 --numeric-owner meta.txt jobs ) \
    || { rm -rf "$tmp"; imp_err "tar failed"; return 0; }
  b64="$(base64 -w0 "$tmp/export.tgz" 2>/dev/null)" || b64="$(base64 "$tmp/export.tgz" | tr -d '\n')"
  rm -rf "$tmp"
  jq -nc --arg b64 "$b64" --arg name "rclone-jobs-jobs-$(date +%Y%m%d-%H%M%S).tgz" --argjson count "$count" \
    '{ok:true, name:$name, count:$count, archive:$b64}'
}

cmd_import_jobs() { # <ask|overwrite|skip> <b64-file> -> JSON report; nothing is written before validation
  local mode="${1:-ask}" src="${2:-}" m n f bad="" members mcount=0 tmp b64
  local dest added=0 replaced=0 skipped=0 conflicts="" rejected="" first=true
  case "$mode" in ask|overwrite|skip) ;; *) mode=ask ;; esac
  [ -f "$src" ] || { imp_err "no uploaded archive"; return 0; }
  [ "$(stat -c %s "$src" 2>/dev/null || echo 99999999)" -le 1500000 ] || { rm -f "$src"; imp_err "upload too large (max ~1 MiB)"; return 0; }
  load_paths
  mkdir -p "$BOOT_DIR/jobs" 2>/dev/null || { imp_err "cannot create $BOOT_DIR/jobs"; return 0; }
  tmp="$(mktemp -d /tmp/rj-import.XXXXXX)" || { rm -f "$src"; imp_err "mktemp failed"; return 0; }
  chmod 700 "$tmp"
  base64 -d < "$src" > "$tmp/archive.tgz" 2>/dev/null || { rm -rf "$tmp"; imp_err "upload is not valid base64"; return 0; }
  rm -f "$src"
  [ -s "$tmp/archive.tgz" ] || { rm -rf "$tmp"; imp_err "empty archive"; return 0; }
  members="$(tar -tzf "$tmp/archive.tgz" 2>/dev/null)" || { rm -rf "$tmp"; imp_err "cannot read tar.gz archive"; return 0; }
  # name-only whitelist BEFORE extracting: meta.txt, the jobs/ dir entry, or a
  # plain jobs/<valid>.conf. Nothing absolute, no '..', no symlinks-by-name.
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    mcount=$((mcount + 1))
    [ "$mcount" -le 101 ] || { bad="more than 100 members"; break; }
    case "$m" in meta.txt|jobs/) continue ;; esac
    [[ "$m" =~ ^jobs/[A-Za-z0-9_-]{1,40}\.conf$ ]] || { bad="member '$m' is not a plain jobs/<name>.conf file"; break; }
  done <<< "$members"
  [ -z "$bad" ] || { rm -rf "$tmp"; imp_err "refused: $bad"; return 0; }
  mkdir -p "$tmp/extract" "$tmp/validate/jobs"
  tar -xzf "$tmp/archive.tgz" -C "$tmp/extract" --no-same-owner \
    || { rm -rf "$tmp"; imp_err "extraction failed"; return 0; }
  local eng; eng="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  for f in "$tmp/extract/jobs"/*.conf; do
    [ -e "$f" ] || continue
    [ -f "$f" ] && [ ! -L "$f" ] || { rejected="$rejected ${f##*/}(not-regular)"; continue; }
    n="$(basename "$f" .conf)"
    valid_jobname "$n" || { rejected="$rejected $n(bad-name)"; continue; }
    cp "$f" "$tmp/validate/jobs/$n.conf" || { rejected="$rejected $n(copy-failed)"; continue; }
    # full structural validation with the REAL engine validators in a subshell
    # (load_job+validate_job die 78 on anything wrong; storage checks stay runtime)
    if ! RJ_BOOT_DIR="$tmp/validate" bash "$eng" validate-job "$n" >/dev/null 2>&1; then
      rejected="$rejected $n(invalid-config)"
      rm -f "$tmp/validate/jobs/$n.conf"
      continue
    fi
    dest="$BOOT_DIR/jobs/$n.conf"
    if [ -f "$dest" ]; then
      case "$mode" in
        ask)  [ "$first" = true ] || conflicts="$conflicts,"
              first=false; conflicts="$conflicts$n"; continue ;;
        skip) skipped=$((skipped + 1)); continue ;;
      esac
      cp "$dest" "$dest.pre-import-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
      replaced=$((replaced + 1))
    else
      added=$((added + 1))
    fi
    install -m 600 "$f" "$dest" 2>/dev/null || { cp "$f" "$dest" && chmod 600 "$dest"; }
  done
  rm -rf "$tmp"
  rejected="${rejected# }"
  jq -nc --argjson added "$added" --argjson replaced "$replaced" --argjson skipped "$skipped" \
         --arg conflicts "$conflicts" --arg rejected "$rejected" --arg mode "$mode" \
    '{ok:true, mode:$mode, added:$added, replaced:$replaced, skipped:$skipped,
      conflicts:(if $conflicts=="" then [] else ($conflicts|split(",")) end),
      rejected:(if $rejected=="" then [] else ($rejected|split(" ")) end)}'
}

cmd_validate_job() { # <job> - hidden helper for import: exits 78 on any config problem
  JOB_NAME="${1:-}"
  valid_jobname "$JOB_NAME" || die 78 "invalid job name"
  load_paths
  load_job
  say "valid"
}

# ------------------------------------------------------------- run history --
# One json line per LIVE run in $STORAGE_ROOT/history/<job>.jsonl: the "did
# Wednesday's run slow down?" trend. Parsing the transferred amount into bytes
# is deliberately permissive - a null must never fail a run.
hist_bytes() { # <human size like '1.2 GiB'> -> integer bytes on stdout, rc1 on parse fail
  local s="$1" v u m
  v="$(printf '%s' "$s" | awk 'NR==1{print $1}')"
  u="$(printf '%s' "$s" | awk 'NR==1{print toupper($2)}')"
  case "$v" in ''|*[!0-9.]*) return 1 ;; esac
  case "$u" in
    ''|B|BYTE|BYTES) m=1 ;;
    K|KB|KIB)        m=1024 ;;
    M|MB|MIB)        m=1048576 ;;
    G|GB|GIB)        m=1073741824 ;;
    T|TB|TIB)        m=1099511627776 ;;
    *) return 1 ;;
  esac
  awk -v v="$v" -v m="$m" 'BEGIN{printf "%.0f", v*m}'
}

hist_add() { # <job> <rc> <secs> <errors> <transferred> <logfile> - best effort, never fatal
  local hb="" line dir
  command -v jq >/dev/null 2>&1 || return 0
  hb="$(hist_bytes "${5:-}" 2>/dev/null)" || hb=""
  dir="$STORAGE_ROOT/history"
  mkdir -p "$dir" 2>/dev/null || return 0
  line="$(jq -nc --argjson ts "$(unix_now)" --arg iso "$(stamp_now)" --argjson rc "${2:-0}" \
         --argjson secs "${3:-0}" --argjson errors "${4:-0}" --arg transferred "${5:-}" \
         --arg bytes "$hb" --arg log "${6:-}" \
    '{ts:$ts, iso:$iso, rc:$rc, secs:$secs, errors:$errors, transferred:$transferred,
      bytes:(if $bytes=="" then null else ($bytes|tonumber) end), log:$log}' 2>/dev/null)" || return 0
  [ -n "$line" ] || return 0
  # append + piggyback compaction under one lock: a high-frequency job keeps its
  # raw file bounded even if the watchdog never runs, and a concurrent watchdog
  # compaction never interleaves with this append
  (
    exec 210>>"$dir/.$JOB_NAME.clock" 2>/dev/null || exit 0
    flock -w 10 210 || exit 0
    printf '%s\n' "$line" >> "$dir/$JOB_NAME.jsonl" 2>/dev/null || exit 0
    if [ "$(wc -l < "$dir/$JOB_NAME.jsonl" 2>/dev/null || echo 0)" -gt "$(( HIST_RAW_MAX + 100 ))" ]; then
      hist_compact "$JOB_NAME" locked
    fi
  ) 2>/dev/null || true
  return 0
}

hist_compact() { # <job> [locked] - fold raw runs into hourly/daily rollup buckets.
  # Tiered retention: raw lines live HIST_RAW_HOURS (max HIST_RAW_MAX), then one
  # hourly bucket per hour for HIST_HOUR_DAYS, then one daily bucket per day for
  # HIST_DAYS - so a 3-min job still fits ~600 lines instead of 43k. Rollups go
  # to <job>.rollup.jsonl ({rollup:"h"|"d",ts,iso,runs,fails,errors,secs_*,bytes});
  # the raw file keeps its exact old format. Best effort, never fatal.
  local job="${1:-}" hdir raw roll foldt rawt rollt now craw chr cdd tzoff
  valid_jobname "$job" || return 0
  command -v jq >/dev/null 2>&1 || return 0
  hdir="$STORAGE_ROOT/history"
  raw="$hdir/$job.jsonl"
  roll="$hdir/$job.rollup.jsonl"
  mkdir -p "$hdir" 2>/dev/null || return 0
  if [ "${2:-}" != "locked" ]; then
    exec 210>>"$hdir/.$job.clock" 2>/dev/null || return 0
    flock -n 210 || return 0
  fi
  [ -f "$raw" ] || return 0
  now="$(unix_now)"
  craw=$(( now - HIST_RAW_HOURS * 3600 ))
  chr=$(( now - HIST_HOUR_DAYS * 86400 ))
  cdd=$(( now - HIST_DAYS * 86400 ))
  tzoff=$(( $(date +%s) - $(date -u +%s) ))   # strftime is UTC; keep bucket iso local like raw
  foldt="$hdir/.$job.fold.$$"; rawt="$hdir/.$job.raw.$$"; rollt="$hdir/.$job.roll.$$"
  # effective raw cutoff: the raw-window time, pushed up when more than
  # HIST_RAW_MAX lines still fit in it (ts-based so it works whatever order
  # the file's lines happen to be in; fold keeps ts < fcut, kept keeps >=)
  local fcut
  fcut="$(jq -c -R -n --argjson cut "$craw" --argjson keep "$HIST_RAW_MAX" '
      [ inputs | fromjson? | select(type == "object" and ((.ts | type) == "number")) | .ts ]
      | sort | (if length > $keep then [$cut, .[length - $keep]] | max else $cut end)' \
      "$raw" 2>/dev/null)" || fcut=""
  case "${fcut:-}" in ''|*[!0-9]*) fcut="$craw" ;; esac
  # units folded OUT of raw: older than the effective cutoff
  if ! jq -c -R -n --argjson cut "$fcut" '
      [ inputs | fromjson? | select(type == "object" and ((.ts | type) == "number")) ] as $e
      | $e[] | select(.ts < $cut)
      | { ts, runs: 1, fails: (if .rc == 0 or .rc == 24 then 0 else 1 end),
          errors: (.errors // 0), secs_sum: (.secs // 0), secs_min: (.secs // 0),
          secs_max: (.secs // 0), bytes: (if ((.bytes | type) == "number") then .bytes else null end) }' \
      "$raw" > "$foldt" 2>/dev/null; then
    rm -f "$foldt" "$rawt" "$rollt"; return 0
  fi
  # kept raw window (also self-heals corrupt lines out of the file)
  if ! jq -c -R --argjson cut "$fcut" \
      'fromjson? | select(type == "object") | select((.ts | type) == "number" and .ts >= $cut)' \
      "$raw" 2>/dev/null | tail -n "$HIST_RAW_MAX" > "$rawt"; then
    rm -f "$foldt" "$rawt" "$rollt"; return 0
  fi
  [ -f "$roll" ] || touch "$roll" 2>/dev/null || { rm -f "$foldt" "$rawt" "$rollt"; return 0; }
  # merge folded units with existing buckets: hourly keeps >= chr, everything
  # older (folded raw + old hourly + old daily) re-buckets to daily keeps >= cdd
  if ! jq -c -n --argjson ch "$chr" --argjson cd "$cdd" --argjson off "$tzoff" '
      def agg($k; $kind): group_by(.ts - .ts % $k)
        | map({ rollup: $kind, ts: (.[0].ts - .[0].ts % $k),
                iso: (((.[0].ts - .[0].ts % $k) + $off) | strftime("%Y-%m-%d %H:%M")),
                runs: (map(.runs) | add), fails: (map(.fails) | add),
                errors: (map(.errors) | add), secs_sum: (map(.secs_sum) | add),
                secs_min: (map(.secs_min) | min), secs_max: (map(.secs_max) | max),
                bytes: ([ .[].bytes | select(. != null) ] | if length > 0 then add else null end) })
        | sort_by(.ts);
      [ inputs | select(type == "object" and ((.ts | type) == "number")) ] as $u
      | ( [ $u[] | select((.rollup == null or .rollup == "h") and .ts >= $ch) ]
          # keep buckets OVERLAPPING the window (a run inside the window must
          # never be dropped just because its bucket starts slightly before ch;
          # once ch advances past the whole bucket it gets promoted to daily)
          | agg(3600; "h") | map(select(.ts + 3600 > $ch)) ) as $H
      | ( [ ($u[] | select((.rollup == null or .rollup == "h") and .ts < $ch)),
            ($u[] | select(.rollup == "d")) ]
          | agg(86400; "d") | map(select(.ts + 86400 > $cd)) ) as $D
      | ($H + $D)[]' "$foldt" "$roll" > "$rollt" 2>/dev/null; then
    rm -f "$foldt" "$rawt" "$rollt"; return 0
  fi
  cmp -s "$rawt" "$raw" || mv -f "$rawt" "$raw" 2>/dev/null || true
  cmp -s "$rollt" "$roll" 2>/dev/null || mv -f "$rollt" "$roll" 2>/dev/null || true
  rm -f "$foldt" "$rawt" "$rollt"
  return 0
}

cmd_history() { # <job> [n] -> {ok, job, entries:[...last n raw...], rollups:[h/d buckets]}
  JOB_NAME="${1:-}"
  valid_jobname "$JOB_NAME" || { printf '{"ok":false,"error":"invalid job name"}\n'; return 0; }
  local n="${2:-20}" hf rf
  [[ "$n" =~ ^[0-9]{1,4}$ ]] || n=20
  [ "$n" -gt 600 ] && n=600
  load_paths
  storage_guard
  hf="$STORAGE_ROOT/history/$JOB_NAME.jsonl"
  rf="$STORAGE_ROOT/history/$JOB_NAME.rollup.jsonl"
  if [ ! -f "$hf" ] && [ ! -f "$rf" ]; then
    printf '{"ok":true,"job":"%s","entries":[],"rollups":[]}\n' "$JOB_NAME"; return 0
  fi
  # -R + fromjson? skips corrupt lines one by one (a half-written line from a
  # hard kill must not make the whole history unreadable)
  if [ ! -f "$hf" ]; then printf '[]' > "$hf.ui.$$"; fi
  if [ ! -f "$hf" ] || jq -c -R 'fromjson? | select(type=="object")' "$hf" 2>/dev/null | tail -n "$n" | jq -sc '.' > "$hf.ui.$$" 2>/dev/null; then
    if [ -f "$rf" ]; then
      jq -c -R 'fromjson? | select(type=="object")' "$rf" 2>/dev/null | jq -sc '.' > "$hf.ur.$$" 2>/dev/null \
        || printf '[]' > "$hf.ur.$$"
    else
      printf '[]' > "$hf.ur.$$"
    fi
    jq -c --arg j "$JOB_NAME" --slurpfile ro "$hf.ur.$$" \
      '{ok:true, job:$j, entries:(. // []), rollups:($ro[0] // [])}' < "$hf.ui.$$"
  else
    printf '{"ok":false,"error":"history file unreadable"}\n'
  fi
  rm -f "$hf.ui.$$" "$hf.ur.$$"
}

cmd_list() {
  local f n
  [ -d "$BOOT_DIR/jobs" ] || { say "(no jobs directory: $BOOT_DIR/jobs)"; return 0; }
  for f in "$BOOT_DIR/jobs"/*.conf; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .conf)"
    printf '%s\n' "$n"
  done
}

cmd_status() {
  load_paths
  storage_guard
  local f n en sj dj rc secs run lastok dry
  printf '%-20s %-4s %-4s %-6s %-17s %-17s %s\n' 'JOB' 'EN' 'RC' 'SECS' 'LAST RUN' 'LAST OK' 'LAST DRY-RUN'
  for f in "$BOOT_DIR/jobs"/*.conf; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .conf)"
    valid_jobname "$n" || continue
    en="$(sed -nE 's/^ENABLED=//p' "$f" | tail -1)"
    [ -n "$en" ] || en=yes
    sj="$(status_file "$n")"; dj="$(dryrun_file "$n")"
    rc='-'; secs='-'; run='-'; lastok='never'; dry='-'
    if [ -f "$sj" ]; then
      rc="$(jq -r 'if .running then "RUN" else (.rc // "-") | tostring end' "$sj" 2>/dev/null)"
      secs="$(jq -r '.secs // "-"' "$sj" 2>/dev/null)"
      run="$(jq -r '.run // "-"' "$sj" 2>/dev/null)"
      lastok="$(jq -r '.last_ok_run // "never"' "$sj" 2>/dev/null)"
    fi
    if [ -f "$dj" ]; then
      dry="$(jq -r '"\(.stamp) +\(.copies) -\(.deletes) fail:\(.fails)"' "$dj" 2>/dev/null)"
    fi
    printf '%-20s %-4s %-4s %-6s %-17s %-17s %s\n' "$n" "$en" "${rc:-?}" "${secs:-?}" "${run:-?}" "${lastok:-never}" "${dry:--}"
  done
}

cmd_status_json() { # every job's run + dry-run state as ONE json object (live UI refresh)
  load_paths
  storage_guard
  local f n sj dj first=true st dy warn
  printf '{"ok":true,"jobs":{'
  for f in "$BOOT_DIR/jobs"/*.conf; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .conf)"
    valid_jobname "$n" || continue
    [ "$first" = true ] || printf ','
    first=false
    printf '"%s":' "$n"   # validated ^[A-Za-z0-9_-]{1,40}$ above - safe unescaped
    sj="$(status_file "$n")"; dj="$(dryrun_file "$n")"
    st=''; dy=''
    [ -f "$sj" ] && st="$(jq -c '.' "$sj" 2>/dev/null)"
    [ -f "$dj" ] && dy="$(jq -c '.' "$dj" 2>/dev/null)"
    [ -n "$st" ] || st='null'
    [ -n "$dy" ] || dy='null'
    warn="$(sed -nE 's/^WARN_DELETE=//p' "$f" | tail -1 | tr -d '"')"
    [[ "$warn" =~ ^[0-9]+$ ]] || warn="$DEFAULT_WARN_DELETE"
    # per-job object even on jq failure (|| fallback) so one broken file cannot
    # corrupt the whole response the browser parses
    jq -nc --argjson st "$st" --argjson dy "$dy" --argjson warn "$warn" \
      '{rc:(if $st==null then null elif ($st.running // false) then "RUN" else ($st.rc // null) end),
        running:($st.running // false),
        secs:($st.secs // null),
        run:($st.run // null),
        last_ok_run:($st.last_ok_run // null),
        transferred:($st.transferred // null),
        dry:(if $dy==null then null else {stamp:($dy.stamp // "?"),copies:($dy.copies // 0),
          deletes:($dy.deletes // 0),fails:($dy.fails // 0),ack:($dy.ack // false),
          warnDelete:($dy.warnDelete // $warn)} end)}' 2>/dev/null \
      || printf '{"error":"status unreadable"}'
  done
  printf '}}\n'
}

cmd_watchdog() { # stale-success alerts, stuck-run alerts (deduped 24h), log + task pruning
  load_paths
  storage_guard
  local now f n nn sj last_ok running dedup lk ttf pf2 ppid2 smk pch plg
  now="$(unix_now)"
  for f in "$BOOT_DIR/jobs"/*.conf; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .conf)"
    valid_jobname "$n" || continue
    sj="$(status_file "$n")"
    [ -f "$sj" ] || continue
    dedup="$STATUS_DIR/.wd-$n"
    running="$(jq -r '.running // false' "$sj" 2>/dev/null)"
    if [ "$running" = "true" ]; then
      lk="$LOCKDIR/$NAME-$n.lock"
      if ! { [ -f "$lk" ] && ! flock -n "$lk" true 2>/dev/null; } && [ $(( now - $(stat -c %Y "$sj" 2>/dev/null || echo "$now") )) -gt 60 ]; then
        # phantom run: status claims running but the flock is free - the lock
        # is taken BEFORE the status flips, so this can only mean the engine
        # died without its trap (hard kill, OOM). State truth, not a notice:
        # repaired even for NOTIFY=off so the UI never pulses RUN forever.
        pch="$(jq -r '.confhash // ""' "$sj" 2>/dev/null)"; plg="$(jq -r '.log // ""' "$sj" 2>/dev/null)"
        status_finish "$n" 143 0 0 "" false "$pch" "$plg" 2>/dev/null
        sse_publish "$n" false 143
        rm -f "$STATUS_DIR/$n.run.pid" "$STATUS_DIR/$n.stop" 2>/dev/null
        syslog_line "WATCHDOG: $n claimed running but the lock was free - marked interrupted (rc=143)"
      elif [ $(( now - $(stat -c %Y "$sj" 2>/dev/null || echo "$now") )) -gt 21600 ]; then
        nn="$(job_notify_setting "$n")"
        if [ "$nn" != off ]; then
          if [ ! -f "$dedup" ] || [ $(( now - $(stat -c %Y "$dedup" 2>/dev/null || echo 0) )) -gt 86400 ]; then
            touch "$dedup"
            syslog_line "WATCHDOG: $n looks stuck (running >6h with lock held)"
            notify_unraid alert "rclone-jobs: $n looks stuck" "running for over 6 hours with the lock held" "job: $n - check the WebUI and the job log"
          fi
        fi
      fi
      continue
    fi
    nn="$(job_notify_setting "$n")"
    [ "$nn" = off ] && continue
    last_ok="$(jq -r '.last_ok // 0' "$sj" 2>/dev/null)"
    if [ "${last_ok:-0}" -gt 0 ] && [ $(( now - last_ok )) -gt 93600 ]; then
      if [ ! -f "$dedup" ] || [ $(( now - $(stat -c %Y "$dedup" 2>/dev/null || echo 0) )) -gt 86400 ]; then
        touch "$dedup"
        syslog_line "WATCHDOG: $n has no successful run in over 26h"
        notify_unraid warning "rclone-jobs: $n stale" "no successful run in over 26 hours" "job: $n - check the schedule and the job logs"
      fi
    fi
  done
  # finished preview tasks older than 1h must not linger; running ones never
  # carry an .rc, so a live task is never touched by this sweep
  for ttf in "$STATUS_DIR"/task-*.rc; do
    [ -e "$ttf" ] || continue
    if [ $(( now - $(stat -c %Y "$ttf" 2>/dev/null || echo "$now") )) -gt 3600 ]; then
      rm -f "$ttf" "${ttf%.rc}.out" "${ttf%.rc}.pid"
    fi
  done
  # run leftovers: pid files of vanished pids, and stop markers older than
  # 10 minutes (a live run clears its own pair at start and in its trap)
  for pf2 in "$STATUS_DIR"/*.run.pid; do
    [ -e "$pf2" ] || continue
    ppid2="$(cat "$pf2" 2>/dev/null | tr -dc '0-9')"
    if [ -z "$ppid2" ] || ! kill -0 "$ppid2" 2>/dev/null; then rm -f "$pf2"; fi
  done
  for smk in "$STATUS_DIR"/*.stop; do
    [ -e "$smk" ] || continue
    if [ $(( now - $(stat -c %Y "$smk" 2>/dev/null || echo "$now") )) -gt 600 ]; then rm -f "$smk"; fi
  done
  # history: fold raw runs into hourly/daily rollups (same compaction the runs
  # piggyback, so a job that stopped running still gets its file tiered)
  local hdir="$STORAGE_ROOT/history" hf hn
  if [ -d "$hdir" ]; then
    for hf in "$hdir"/*.jsonl; do
      [ -e "$hf" ] || continue
      hn="$(basename "$hf" .jsonl)"
      case "$hn" in *.rollup) continue ;; esac
      valid_jobname "$hn" || continue
      hist_compact "$hn"
    done
  fi
  # logs: OK/dry-run logs age out after LOG_KEEP_DAYS; failed/interrupted ones
  # carry a keep-marker (written at run end) and stay LOG_KEEP_FAIL_DAYS. The
  # marker expires with the failure window, then the age sweep reclaims the log.
  local kdir="$LOG_DIR/keep" lf jf jname jcnt
  if [ -d "$LOG_DIR" ]; then
    mkdir -p "$kdir" 2>/dev/null || true
    find "$kdir" -maxdepth 1 -type f -mtime +"$LOG_KEEP_FAIL_DAYS" -delete 2>/dev/null
    for lf in "$LOG_DIR"/*.log; do
      [ -e "$lf" ] || continue
      [ -f "$kdir/$(basename "$lf").keep" ] && continue
      if [ $(( now - $(stat -c %Y "$lf" 2>/dev/null || echo "$now") )) -gt $(( LOG_KEEP_DAYS * 86400 )) ]; then
        rm -f "$lf" "$kdir/$(basename "$lf").keep"
      fi
    done
    # count cap (per job): newest LOG_KEEP_MAX live+DRYRUN logs survive regardless
    # of age; marked (failed) logs are never deleted by the cap. Globs require the
    # 8-digit date / DRYRUN tag so a job never touches another job's logs.
    for f in "$BOOT_DIR/jobs"/*.conf; do
      [ -e "$f" ] || continue
      jname="$(basename "$f" .conf)"
      valid_jobname "$jname" || continue
      jcnt=0
      while IFS= read -r jf; do
        [ -n "$jf" ] && [ -e "$jf" ] || continue
        jcnt=$(( jcnt + 1 ))
        if [ "$jcnt" -gt "$LOG_KEEP_MAX" ] && [ ! -f "$kdir/$(basename "$jf").keep" ]; then
          rm -f "$jf" "$kdir/$(basename "$jf").keep"
        fi
      done < <(ls -1t -- "$LOG_DIR/$jname-"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*.log \
                          "$LOG_DIR/$jname-DRYRUN-"*.log 2>/dev/null)
    done
  fi
  find "$LOG_DIR" -maxdepth 1 -type f -name 'doctor-*.txt' -mtime +14 -delete 2>/dev/null
  return 0
}

cmd_shutdown_notice() { # 'stopping' event handler: loud trace for jobs cut off mid-run.
  # MUST exit fast and 0 - a shutdown is never delayed by this. No storage_guard
  # (its die would exit 78): everything degrades to a silent exit 0 instead.
  load_paths
  [ -n "$STORAGE_ROOT" ] && [ -d "$STORAGE_ROOT/status" ] || exit 0
  STATUS_DIR="$STORAGE_ROOT/status"
  local sj n running="" cnt=0 lk
  for sj in "$STATUS_DIR"/*.json; do
    [ -e "$sj" ] || continue
    case "$sj" in *-dryrun.json) continue ;; esac
    [ "$(jq -r '.running // false' "$sj" 2>/dev/null)" = "true" ] || continue
    n="$(basename "$sj" .json)"
    valid_jobname "$n" || continue
    # stale 'running' status (hard-killed earlier) must not cry wolf: the lock
    # must actually be held for this to be a live transfer
    lk="$LOCKDIR/$NAME-$n.lock"
    [ -f "$lk" ] && ! flock -n "$lk" true 2>/dev/null || continue
    running="$running $n"
    cnt=$((cnt + 1))
  done
  [ "$cnt" -gt 0 ] || exit 0
  syslog_line "SHUTDOWN: $cnt job(s) still transferring when the array stopped:$running - cut off; the next run recovers (status marked rc=143)"
  if [ ! -f "/tmp/$NAME-stopping-notice" ]; then
    touch "/tmp/$NAME-stopping-notice" 2>/dev/null || true
    notify_unraid warning "rclone-jobs: $cnt job(s) running at shutdown" "still transferring when the array stopped:$running" "jobs: $running
The transfers were cut off. This is survivable: rclone/rsync re-sync differences on the
next run and the status files recover automatically. Consider the quiet window or a
backup window that does not overlap with array stop/start times."
  fi
  exit 0
}

cmd_notify_test() { # [normal|warning|alert] - one native test notification (UI button + CLI)
  local lvl="${1:-normal}"
  case "$lvl" in normal|warning|alert) ;; *) die 78 "usage: $0 notify-test [normal|warning|alert]" ;; esac
  if notify_unraid "$lvl" "rclone-jobs test notification ($lvl)" "sent at $(stamp_now)" \
       "This is a rclone-jobs v$ENGINE_VERSION test. Seeing it in the WebUI bell - and in email/Telegram/etc. if those agents are enabled under Settings -> Notification Settings - means alerts work."; then
    say "rclone-jobs: test notification sent (level $lvl) - check the bell icon and your enabled agents"
  else
    die 78 "test notification failed - notify script missing or rejected it (looked for: $NOTIFY_SCRIPT, $NOTIFY_SCRIPT_DYN)"
  fi
}

DOCTOR_FAILS=0
DOCTOR_BUF=""
d_line() { # <PASS|WARN|FAIL|INFO> <text> - buffered once, printed once in the fenced block
  printf '%-4s %s\n' "$1" "$2" >> "$DOCTOR_BUF"
  [ "$1" = FAIL ] && DOCTOR_FAILS=$(( DOCTOR_FAILS + 1 ))
  return 0
}

cmd_doctor() { # self-diagnosis; opt-in test notification with --notify
  local opt_notify=no a pv ro rv cf b missing rp regen drift drc probe_rc now sj lo jn save ov ovl nsc n
  local njobs nact jen jsched csf csha cpath cmode cscount csbad csmiss csmod cswant csgot
  for a in "$@"; do [ "$a" = "--notify" ] && opt_notify=yes; done
  DOCTOR_BUF="$(mktemp)"
  say "== rclone-jobs doctor v$ENGINE_VERSION - $(stamp_now) =="
  say ""
  pv="$(sed -nE 's/.*<!ENTITY[[:space:]]+version[[:space:]]+"([^"]+)".*/\1/p' "/boot/config/plugins/$NAME.plg" 2>/dev/null | head -1)"
  if [ -n "$pv" ]; then
    if [ "$pv" = "$ENGINE_VERSION" ]; then d_line PASS "plugin package version matches engine ($pv)"
    else d_line WARN "plg version '$pv' differs from engine '$ENGINE_VERSION' (reinstall the plugin)" ; fi
  else d_line WARN "cannot read plugin version from /boot/config/plugins/$NAME.plg (plugin not installed?)"; fi
  # deploy verification: every packaged file (except this manifest itself) must match
  # the sha256 + mode the release was built with - catches the half-deployed/stale-file
  # symptom an online update can leave behind
  csf="$EMHTTP_DIR/installed-checksums.txt"
  if [ -f "$csf" ]; then
    if head -n 2 "$csf" | grep -q 'PLACEHOLDER'; then
      d_line WARN "installed-checksums.txt is still the build PLACEHOLDER - the plugin on disk was not built by the current pipeline; reinstall the .plg"
    else
      cscount=0; csbad=0; csmiss=0; csmod=0
      while read -r csha cpath cmode || [ -n "${csha:-}" ]; do   # default IFS splits the columns
        case "$csha" in ''|'#'*) continue ;; esac
        cscount=$((cscount + 1))
        if [ ! -f "$cpath" ]; then d_line FAIL "deployed file missing: $cpath"; csmiss=$((csmiss + 1)); continue; fi
        if [ "$(sha256sum "$cpath" 2>/dev/null | cut -d' ' -f1)" != "$csha" ]; then
          d_line FAIL "deployed file differs from the release (stale/partial deploy): $cpath"; csbad=$((csbad + 1))
        else
          cswant=$((8#${cmode:-0000})); csgot=$((8#$(stat -c '%a' "$cpath" 2>/dev/null || echo 0000)))
          if [ "$csgot" -ne "$cswant" ]; then
            d_line WARN "mode drift on $cpath (release wants $cmode, box has $(printf '%04o' "$csgot"))"; csmod=$((csmod + 1))
          fi
        fi
      done < "$csf"
      if [ "$cscount" -eq 0 ]; then d_line WARN "installed-checksums.txt present but contained no entries"
      elif [ $((csbad + csmiss)) -eq 0 ]; then d_line PASS "deployed files match the release checksums ($cscount files)$([ "$csmod" -eq 0 ] && printf ', modes exact' || printf ', %s mode drift see WARN' "$csmod")"
      else d_line FAIL "$((csbad + csmiss)) deployed file(s) differ from the release - reinstall the plugin (.plg) to force a full redeploy"; fi
    fi
  else d_line INFO "no installed-checksums.txt in $EMHTTP_DIR - deploy verification unavailable (plugin older than $ENGINE_VERSION; a reinstall enables it)"; fi
  if [ -x "$RCLONE_BIN" ]; then d_line PASS "rclone wrapper: $RCLONE_BIN"
  else d_line FAIL "rclone wrapper $RCLONE_BIN missing - reinstall the rclone plugin"; fi
  ro="$(command -v rcloneorig 2>/dev/null)"
  if [ -n "$ro" ]; then d_line PASS "rcloneorig: $ro"; else d_line FAIL "rcloneorig not found on PATH - rclone binary missing/broken"; fi
  if [ -x "$RCLONE_BIN" ]; then
    rv="$("$RCLONE_BIN" version 2>/dev/null | head -1)"
    if [ -n "$rv" ]; then d_line PASS "rclone version: $rv"; else d_line FAIL "rclone wrapper produced no version output"; fi
    cf="$("$RCLONE_BIN" config file 2>/dev/null | tr -d '\r' | grep -oE '/[^ ]+' | tail -1)"
    if [ "$cf" = "$RCLONE_EXPECT_CONF" ]; then d_line PASS "rclone config path: $cf"
    else d_line FAIL "rclone config path is '$cf', expected '$RCLONE_EXPECT_CONF'"; fi
    d_line INFO "remotes configured: $("$RCLONE_BIN" listremotes 2>/dev/null | grep -c ':')"
  fi
  load_paths
  if [ -z "$STORAGE_ROOT" ]; then
    d_line FAIL "STORAGE_ROOT unset and no array disk (/mnt/diskN on /dev/md*) detected"
  else
    rp="$(realpath -m -- "$STORAGE_ROOT" 2>/dev/null)"
    if policy_ok "$STORAGE_ROOT"; then d_line PASS "STORAGE_ROOT policy: $rp"
    else d_line FAIL "STORAGE_ROOT '$STORAGE_ROOT' violates the share policy (must be outside /mnt/user, /boot, /etc, /usr, /var/log and outside /)"; fi
    if [ -d "$STORAGE_ROOT" ]; then
      if touch "$STORAGE_ROOT/.rjprobe" 2>/dev/null; then rm -f "$STORAGE_ROOT/.rjprobe"; d_line PASS "STORAGE_ROOT writable"
      else d_line FAIL "STORAGE_ROOT not writable: $STORAGE_ROOT"; fi
      d_line INFO "free space: $(df -h "$STORAGE_ROOT" 2>/dev/null | awk 'NR==2{printf "%s free (%s used) on %s", $4, $5, $1}')"
      d_line INFO "fstype: $(findmnt -no FSTYPE -T "$STORAGE_ROOT" 2>/dev/null)"
      d_line INFO "retention: $(find "$STORAGE_ROOT/history" -maxdepth 1 -name '*.jsonl' -exec cat {} + 2>/dev/null | wc -l) history line(s), $(find "$STORAGE_ROOT/logs" -maxdepth 1 -type f -name '*.log' 2>/dev/null | wc -l) log file(s) (raw ${HIST_RAW_HOURS}h/max ${HIST_RAW_MAX}, hourly ${HIST_HOUR_DAYS}d, daily ${HIST_DAYS}d; logs ${LOG_KEEP_DAYS}d & max ${LOG_KEEP_MAX}/job, failures ${LOG_KEEP_FAIL_DAYS}d)"
    else d_line WARN "STORAGE_ROOT does not exist yet (array stopped, or first run pending): $STORAGE_ROOT"; fi
    if [ -f "$STORAGE_ROOT/notify.env" ]; then
      d_line INFO "legacy notify.env still present (no longer read) - optional cleanup: rm '$STORAGE_ROOT/notify.env'"
    fi
  fi
  nsc=""
  for n in "$NOTIFY_SCRIPT" "$NOTIFY_SCRIPT_DYN"; do [ -x "$n" ] && { nsc="$n"; break; }; done
  if [ -n "$nsc" ]; then d_line PASS "Unraid notify script: $nsc (agents: Settings -> Notification Settings)"
  else d_line WARN "notify script not found - alerts would go to syslog only (webGui broken or not booted?)"; fi
  [ -n "$STORAGE_ROOT" ] && STORAGE_ROOT="$(realpath -m -- "$STORAGE_ROOT" 2>/dev/null || printf '%s' "$STORAGE_ROOT")"
  missing=""
  for b in jq flock rsync logger pgrep findmnt fuser sha256sum; do
    command -v "$b" >/dev/null 2>&1 || missing="$missing $b"
  done
  if [ -z "$missing" ]; then d_line PASS "required binaries present (jq flock rsync logger pgrep findmnt fuser sha256sum)"
  else d_line FAIL "missing binaries:$missing"; fi
  if find_php; then d_line PASS "php CLI: $PHP_BIN"; else d_line WARN "php CLI not found - structured dry-run previews disabled"; fi
  njobs=0; nact=0
  if [ -d "$BOOT_DIR/jobs" ]; then
    for sj in "$BOOT_DIR/jobs"/*.conf; do
      [ -e "$sj" ] || continue
      njobs=$(( njobs + 1 ))
      jen="$(sed -nE 's/^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*"?([^"]*)"?.*/\1/p' "$sj" | tail -1)"
      jsched="$(sed -nE 's/^[[:space:]]*SCHEDULE[[:space:]]*=[[:space:]]*"?([^"]*)"?.*/\1/p' "$sj" | tail -1)"
      [ "$jen" != "no" ] && [ -n "$jsched" ] && nact=$(( nact + 1 ))
    done
  fi
  if [ -f "$CRON_FILE" ]; then
    if grep -qF '# rclone-jobs BEGIN' "$CRON_FILE"; then d_line PASS "managed block present in $CRON_FILE"
    elif [ "$nact" -gt 0 ]; then d_line WARN "no managed block in $CRON_FILE - scheduled jobs are INACTIVE (save any job or run regen-cron.sh)"
    elif [ "$njobs" -eq 0 ]; then d_line INFO "no managed cron block - no jobs configured, nothing to schedule (the block appears automatically when you save an enabled job)"
    else d_line INFO "no managed cron block - no enabled job with a schedule, nothing to schedule (the block appears automatically when you enable a job)"; fi
    regen="$EMHTTP_DIR/scripts/regen-cron.sh"
    if [ -x "$regen" ]; then
      drc=0; drift="$("$regen" --check 2>&1)" || drc=$?
      if [ "$drc" -eq 0 ]; then d_line PASS "crontab block in sync with jobs/ (regen --check)"
      else d_line WARN "crontab drift: $(printf '%s' "$drift" | tr '\n' ' ' | cut -c1-200)"; fi
    else d_line WARN "regen-cron.sh not deployed - cannot verify crontab drift"; fi
    if [ -x "/etc/rc.d/rc.crond" ]; then
      if pgrep -x crond >/dev/null 2>&1; then d_line PASS "cron daemon running (Dillon)"
      else d_line FAIL "crond not running - no schedule fires: /etc/rc.d/rc.crond start"; fi
    fi
  else d_line WARN "crontab file not found: $CRON_FILE"; fi
  probe_rc=0
  env -i PATH=/usr/bin:/bin "$RCLONE_BIN" version >/dev/null 2>&1 || probe_rc=$?
  if [ "$probe_rc" -eq 0 ]; then
    d_line INFO "minimal-PATH probe: rclone works even under cron's PATH (no compensation needed)"
  elif [ "$probe_rc" -eq 127 ]; then
    d_line INFO "minimal-PATH probe: fails with 127 exactly as designed - cron's PATH lacks /usr/sbin; the engine exports a full PATH and the crontab lines invoke bash by absolute path (this is the fix)"
  else
    d_line WARN "minimal-PATH probe failed with exit $probe_rc (expected 0 or 127) - rclone misbehaves under a minimal PATH, check the rclone plugin wrapper"
  fi
  now="$(unix_now)"
  if [ -d "$BOOT_DIR/jobs" ]; then
    if [ "$njobs" -eq 0 ]; then d_line INFO "no jobs configured yet - add one on the Jobs tab"; fi
    for sj in "$BOOT_DIR/jobs"/*.conf; do
      [ -e "$sj" ] || continue
      lo="$(basename "$sj" .conf)"
      if ! valid_jobname "$lo"; then d_line FAIL "invalid job filename: $sj"; continue; fi
      if ov="$( JOB_NAME="$lo"; load_job >/dev/null 2>&1 && ov_report 2>/dev/null )"; then
        while IFS= read -r ovl; do [ -n "$ovl" ] && d_line WARN "$ovl"; done <<< "$ov"
      else d_line FAIL "job $lo: config invalid (check $sj)"; fi
    done
    if [ -n "$STORAGE_ROOT" ] && [ -d "$STORAGE_ROOT/status" ]; then
      STATUS_DIR="$STORAGE_ROOT/status"
      for sj in "$BOOT_DIR/jobs"/*.conf; do
        [ -e "$sj" ] || continue
        jn="$(basename "$sj" .conf)"
        valid_jobname "$jn" || continue
        sj="$(status_file "$jn")"
        if [ -f "$sj" ]; then
          d_line INFO "status $jn: $(jq -c '{rc,secs,run,last_ok_run,running}' "$sj" 2>/dev/null | cut -c1-260)"
          lo="$(jq -r '.last_ok // 0' "$sj" 2>/dev/null)"
          if { [ "${lo:-0}" -eq 0 ] || [ $(( now - lo )) -gt 93600 ]; } && [ "$(jq -r '.running // false' "$sj" 2>/dev/null)" != "true" ]; then
            d_line WARN "job $jn has no successful run in over 26h"
          fi
        else d_line INFO "status $jn: never run"; fi
      done
    fi
  else d_line WARN "no jobs directory yet: $BOOT_DIR/jobs"; fi
  if [ "$opt_notify" = yes ]; then
    if notify_unraid normal "rclone-jobs doctor: test notification" "sent at $(stamp_now)" "If this shows in the WebUI bell and in your enabled agents (email/Telegram/...), alerts work."; then
      d_line PASS "test notification accepted - check the bell and your agents"
    else d_line FAIL "notify script rejected the test notification (see syslog)"; fi
  else d_line INFO "test notification skipped (opt-in: doctor --notify)"; fi
  say ""
  if [ -n "$STORAGE_ROOT" ] && [ -d "$STORAGE_ROOT/logs" ]; then
    local save="$STORAGE_ROOT/logs/doctor-$(date +%Y%m%d-%H%M%S).txt"
    { printf 'rclone-jobs doctor v%s %s\n' "$ENGINE_VERSION" "$(stamp_now)"; cat "$DOCTOR_BUF"; } > "$save" 2>/dev/null \
      && say "(report saved: $save)"
  fi
  echo '```'
  printf 'rclone-jobs doctor v%s on %s (%s) kernel %s unraid %s\n' \
    "$ENGINE_VERSION" "$(hostname 2>/dev/null)" "$(stamp_now)" "$(uname -r 2>/dev/null)" "$(cat /etc/unraid-version 2>/dev/null)"
  cat "$DOCTOR_BUF"
  echo '```'
  rm -f "$DOCTOR_BUF"
  [ "$DOCTOR_FAILS" -eq 0 ] || exit 1
  exit 0
}

# -------------------------------------------------------------------- browse --
# Read-only directory listing for the WebUI path picker. NEVER writes, NEVER
# creates anything, listing is confined to whitelisted roots (local) or to the
# user's own rclone remotes. Output: exactly one JSON object on stdout.
BROWSE_MAX=500

bj_json_err() { # error JSON WITHOUT jq (jq may be the very thing that failed)
  local e="${1//\\/\\\\}"; e="${e//\"/\\\"}"; e="${e//$'\n'/ }"; e="${e//$'\r'/ }"
  [ -n "${jf:-}" ] && rm -f "$jf"
  printf '{"ok":false,"error":"%s"}\n' "$e"
  exit 0
}

bj_run() { # <secs> <cmd...> - run with 'timeout' when coreutils provides it
  if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi
}

cmd_browse() { # browse <local|rclone> <path> [files]
  local scope="${1:-local}" p="${2:-}" with_files="${3:-}"
  local jf rc rp pp n cnt=0 truncated=false outs lo child

  case "$scope" in local|rclone) ;; *) bj_json_err "scope must be local|rclone" ;; esac
  command -v jq >/dev/null 2>&1 || bj_json_err "jq not available"
  bad_field "$p" && bj_json_err "path contains forbidden characters"
  [ ${#p} -le 1024 ] || bj_json_err "path too long"

  jf="$(mktemp /tmp/rj-browse.XXXXXX)" || bj_json_err "mktemp failed"
  bj_emit() { jq -c -n --arg n "$1" --arg p "$2" '{name:$n,path:$p}' >> "$jf"; cnt=$((cnt+1)); }
  bj_out() { # <scope> <path> <parent>
    local entries; entries="$(jq -s -c '.' "$jf" 2>/dev/null)"
    rm -f "$jf"
    jq -c -n --arg scope "$1" --arg path "$2" --arg parent "$3" \
       --argjson entries "${entries:-[]}" --argjson truncated "$truncated" \
       '{ok:true,scope:$scope,path:$path,parent:$parent,entries:$entries,truncated:$truncated}'
    exit 0
  }

  if [ "$scope" = local ]; then
    if [ -z "$p" ]; then # virtual root: shares + array disks + mounts (+ plugins dir for script picking)
      [ -d /mnt/user ] && bj_emit "user (shares)" "/mnt/user"
      for lo in /mnt/disk[0-9]*; do [ -d "$lo" ] && bj_emit "${lo##*/}" "$lo"; done
      [ -d /mnt/remotes ] && bj_emit "remotes (mounts)" "/mnt/remotes"
      [ "$with_files" = files ] && [ -d /usr/local/emhttp/plugins ] && bj_emit "plugins (scripts)" "/usr/local/emhttp/plugins"
      bj_out local "" ""
    fi
    rp="$(realpath -- "$p" 2>/dev/null)" || bj_json_err "path does not exist: $p"
    case "$rp" in
      /mnt/user|/mnt/user/*|/mnt/disk[0-9]*|/mnt/disk[0-9]*/*|/mnt/remotes|/mnt/remotes/*) : ;;
      /usr/local/emhttp/plugins|/usr/local/emhttp/plugins/*)
        [ "$with_files" = files ] || bj_json_err "only the Script field may browse under /usr/local/emhttp/plugins" ;;
      *) bj_json_err "browsing outside /mnt/user, /mnt/diskN, /mnt/remotes is not allowed" ;;
    esac
    [ -d "$rp" ] || bj_json_err "not a directory: $rp"
    pp="$(dirname "$rp")"
    case "$pp" in
      /mnt/user|/mnt/user/*|/mnt/disk[0-9]*|/mnt/disk[0-9]*/*|/mnt/remotes|/mnt/remotes/*|/usr/local/emhttp/plugins|/usr/local/emhttp/plugins/*) : ;;
      *) pp="" ;;
    esac
    # glob does not match dotfiles - plugin/status folders stay invisible
    shopt -s nullglob
    for lo in "$rp"/*; do
      if [ -d "$lo" ]; then :
      elif [ "$with_files" = files ] && [ -f "$lo" ]; then case "$lo" in *.sh) : ;; *) continue ;; esac
      else continue
      fi
      if [ "$cnt" -ge "$BROWSE_MAX" ]; then truncated=true; break; fi
      bj_emit "${lo##*/}" "$lo"
    done
    shopt -u nullglob
    bj_out local "$rp" "$pp"
  fi

  # ---- rclone scope ----
  [ -x "$RCLONE_BIN" ] || bj_json_err "rclone not installed - install the rclone plugin first"
  if [ -z "$p" ]; then
    outs="$(bj_run 15 "$RCLONE_BIN" listremotes 2>&1)" || \
      bj_json_err "rclone listremotes failed: $(printf '%s' "$outs" | tail -n1 | cut -c1-200)"
    while IFS= read -r lo; do
      [ -n "$lo" ] || continue
      if [ "$cnt" -ge "$BROWSE_MAX" ]; then truncated=true; break; fi
      bj_emit "${lo%:}" "$lo"
    done <<< "$outs"
    bj_out rclone "" ""
  fi
  case "$p" in *:*) : ;; *) bj_json_err "rclone path must look like remote:folder" ;; esac
  valid_remote "${p%%:*}" || bj_json_err "invalid remote name in '$p'"
  p="${p%/}"   # normalize: never keep a trailing slash (remote: stays as-is)
  outs="$(bj_run 25 "$RCLONE_BIN" lsf -d --timeout 20s "$p" 2>&1)"; rc=$?
  if [ "$rc" -eq 124 ]; then bj_json_err "rclone timed out on '$p' (25s) - enter the path manually instead"
  elif [ "$rc" -ne 0 ]; then bj_json_err "rclone failed on '$p' (rc $rc): $(printf '%s' "$outs" | tail -n1 | cut -c1-200)"; fi
  case "$p" in
    *:) child="$p" ;;   # remote: -> children are remote:name
    *)  child="$p/" ;;  # remote:a or remote:/a -> remote:a/name
  esac
  pp=""
  if [[ "$p" == *:*/* ]]; then pp="${p%/*}"                       # remote:a/b -> remote:a
  elif [[ "$p" == *:* && "$p" != *: ]]; then pp="${p%%:*}:"; fi   # remote:a   -> remote:
  while IFS= read -r lo; do
    lo="${lo%/}"; [ -n "$lo" ] || continue
    if [ "$cnt" -ge "$BROWSE_MAX" ]; then truncated=true; break; fi
    bj_emit "$lo" "${child}$lo"
  done <<< "$outs"
  bj_out rclone "$p" "$pp"
}

usage() {
  cat <<EOF
rclone-jobs v$ENGINE_VERSION - scheduled transfers with a dry-run gate (Unraid)
usage:
  rclone-jobs.sh run <job> [--dry-run]   run a job (dry-run honors per-job + master switch);
                                         non-tty runs detach - use 'stop' to cancel
  rclone-jobs.sh preview <job>           alias of: run <job> --dry-run (stays synchronous)
  rclone-jobs.sh stop <job>              stop a live run (rc=143; escalates to KILL)
  rclone-jobs.sh preview-start <job>     detached preview (WebUI); poll with task-status
  rclone-jobs.sh task-status <job>       preview task: running | done output (consumed)
  rclone-jobs.sh task-cancel <job>       terminate a running preview task
  rclone-jobs.sh ack <job>               acknowledge a deletion-heavy dry-run
  rclone-jobs.sh status                  one line per job (run + dry-run outcomes)
  rclone-jobs.sh status-json             all jobs' live state as one JSON object
  rclone-jobs.sh tail-log <job>          redacted tail (64 KiB) of the job's last log as JSON
  rclone-jobs.sh history <job> [n]       last n live runs + hourly/daily rollups as JSON
  rclone-jobs.sh watchdog                stale/stuck alerts + history rollups + log pruning
  rclone-jobs.sh list                    list job names
  rclone-jobs.sh export-jobs             job set as tar.gz, base64 on stdout (JSON)
  rclone-jobs.sh import-jobs <ask|overwrite|skip> <b64-file>   validated import
  rclone-jobs.sh browse <local|rclone> <path> [files]   read-only listing as JSON
  rclone-jobs.sh watchdog                stale/stuck alerts + prune logs older than 14d
  rclone-jobs.sh shutdown-notice         'stopping' event: trace jobs cut off mid-run (fast, exit 0)
  rclone-jobs.sh notify-test [level]     test notification via Unraid's notify script
                                         (level: normal|warning|alert, default normal)
  rclone-jobs.sh doctor [--notify]       self-test (PASS/FAIL table + paste-back block)
EOF
}

main() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    run)      [ $# -ge 1 ] || die 78 "usage: $0 run <job> [--dry-run]"; cmd_run "$@" ;;
    preview)  [ $# -ge 1 ] || die 78 "usage: $0 preview <job>"; JOB_NAME="$1"; cmd_run "$JOB_NAME" --dry-run --sync ;;
    stop)     [ $# -ge 1 ] || die 78 "usage: $0 stop <job>"; cmd_stop "$1" ;;
    preview-start) [ $# -ge 1 ] || die 78 "usage: $0 preview-start <job>"; cmd_preview_start "$1" ;;
    task-status)   [ $# -ge 1 ] || die 78 "usage: $0 task-status <job>"; cmd_task_status "$1" ;;
    task-cancel)   [ $# -ge 1 ] || die 78 "usage: $0 task-cancel <job>"; cmd_task_cancel "$1" ;;
    ack)      [ $# -ge 1 ] || die 78 "usage: $0 ack <job>"; cmd_ack "$1" ;;
    status)   cmd_status ;;
    status-json) cmd_status_json ;;
    tail-log) [ $# -ge 1 ] || die 78 "usage: $0 tail-log <job>"; cmd_tail_log "$1" ;;
    history)  cmd_history "$@" ;;
    export-jobs) cmd_export_jobs ;;
    import-jobs) cmd_import_jobs "$@" ;;
    validate-job) [ $# -ge 1 ] || die 78 "usage: $0 validate-job <job>"; cmd_validate_job "$1" ;;
    list)     cmd_list ;;
    browse)   cmd_browse "$@" ;;
    watchdog) cmd_watchdog ;;
    shutdown-notice) cmd_shutdown_notice ;;
    notify-test) cmd_notify_test "$@" ;;
    doctor)   cmd_doctor "$@" ;;
    *)        usage; exit 78 ;;
  esac
}

main "$@"
