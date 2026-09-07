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
      esac
    done < "$BOOT_DIR/paths.env"
  fi
  # explicit environment wins (doctor/tests use these; cron never sets them)
  [ -n "${RJ_STORAGE_ROOT:-}" ]   && STORAGE_ROOT="$RJ_STORAGE_ROOT"
  [ -n "${RJ_DRY_RUN_MASTER:-}" ] && DRY_RUN_MASTER="$RJ_DRY_RUN_MASTER"
  [ -n "$STORAGE_ROOT" ] || STORAGE_ROOT="$(detect_storage || true)"
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
conf_hash()   { sha256sum "$1" 2>/dev/null | cut -c1-16; }

status_set_running() { # <job> <confhash>
  local f tmp; f="$(status_file "$1")"; tmp="$f.tmp"
  if [ -s "$f" ]; then
    jq --arg c "$2" '. + {running:true, confhash:$c}' "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f"
  else
    jq -n --arg j "$1" --arg c "$2" \
      '{job:$j, rc:null, secs:null, errors:null, run:null, last_ok:0, last_ok_run:null, transferred:"", running:true, confhash:$c}' \
      > "$tmp" 2>/dev/null && mv -f "$tmp" "$f"
  fi
}

status_finish() { # <job> <rc> <secs> <errors> <transferred> <running true|false> <confhash>
  local f ok_run="" last_ok=0
  f="$(status_file "$1")"
  if [ -f "$f" ]; then last_ok="$(jq -r '.last_ok // 0' "$f" 2>/dev/null || echo 0)"; fi
  if [ "$2" -eq 0 ] || [ "$2" -eq 24 ]; then ok_run="$(stamp_now)"; last_ok="$(unix_now)"; fi
  jq -n \
    --arg job "$1" --argjson rc "$2" --argjson secs "$3" --argjson errors "${4:-0}" \
    --arg run "$(stamp_now)" --argjson last_ok "$last_ok" --arg ok_run "$ok_run" \
    --arg transferred "$5" --argjson running "$6" --arg confhash "$7" \
    '{job:$job, rc:$rc, secs:$secs, errors:$errors, run:$run, last_ok:$last_ok,
      last_ok_run:(if $ok_run=="" then null else $ok_run end),
      transferred:$transferred, running:$running, confhash:$confhash}' \
    > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
}

# --------------------------------------------------------------------- jobs --
J_ENGINE=""; J_MODE=""; J_SRC=""; J_DST=""; J_SCHEDULE=""; J_ENABLED="yes"
J_DRYRUN="yes"; J_ARGS=""; J_TRANSFERS="4"; J_CHECKERS="8"; J_BWLIMIT=""
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
  local lf="$1" n t
  ERR_COUNT=0; ERR_LAST=""; ERR_FILES=""; TR="0"
  n="$(grep -oE 'with [0-9]+ error' "$lf" 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1)"
  [ -n "$n" ] || n="$(grep -cE ' ERROR ' "$lf" 2>/dev/null)"
  ERR_COUNT="${n:-0}"
  ERR_LAST="$(grep -E ' ERROR ' "$lf" 2>/dev/null | tail -3 | sed -E 's/^.*ERROR[ ]*:[ ]*//' | cut -c1-200 | paste -sd '|' -)"
  ERR_FILES="$(grep -E ' ERROR ' "$lf" 2>/dev/null | sed -E 's/^.*ERROR[ ]*:[ ]*//; s/[ :].*$//' | grep -E '/' | sort -u | head -5 | paste -sd '|' -)"
  t="$(grep -E '^[[:space:]]*Transferred:' "$lf" 2>/dev/null | tail -1 \
       | sed -E 's/^[[:space:]]*Transferred:[[:space:]]+//' | cut -d, -f1 | cut -d'/' -f1 | xargs 2>/dev/null)"
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
cmd_run() { # <job> [--dry-run]
  JOB_NAME="${1:-}"
  local want_dry=no
  [ "${2:-}" = "--dry-run" ] && want_dry=yes
  valid_jobname "$JOB_NAME" || die 78 "invalid job name '$JOB_NAME' (allowed: letters, digits, underscore, hyphen; max 40)"
  load_paths
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
  local chash sj ts logfile t0 t1 rc
  chash="$(conf_hash "$JOB_CONF")"
  sj="$(status_file "$JOB_NAME")"
  status_set_running "$JOB_NAME" "$chash"
  build_command "$dry"
  ts="$(date +%Y%m%d-%H%M%S)"
  if [ "$dry" = yes ]; then logfile="$LOG_DIR/$JOB_NAME-DRYRUN-$ts.log"; else logfile="$LOG_DIR/$JOB_NAME-$ts.log"; fi
  {
    printf 'rclone-jobs %s | job: %s | mode: %s | engine: %s | %s\n' \
      "$ENGINE_VERSION" "$JOB_NAME" "$([ "$dry" = yes ] && echo DRY-RUN || echo LIVE)" "$J_ENGINE" "$(stamp_now)"
    printf 'command: %s\n' "${CMD[*]}" | redact
    printf 'config: %s | rclone config: %s\n' "$JOB_CONF" "$RCLONE_EXPECT_CONF"
    printf -- '----\n'
  } >> "$logfile"
  say "rclone-jobs: $JOB_NAME starting ($([ "$dry" = yes ] && echo dry-run || echo live)) log=$logfile"
  t0="$(unix_now)"
  if [ -t 1 ]; then
    ( umask "$J_UMASK"; "${CMD[@]}" ) 2>&1 | tee -a "$logfile"
    rc="${PIPESTATUS[0]}"
  else
    ( umask "$J_UMASK"; "${CMD[@]}" ) >> "$logfile" 2>&1
    rc=$?
  fi
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
    status_finish "$JOB_NAME" "${prc:-0}" 0 "${perr:-0}" "$ptr" false "$chash"
  else
    status_finish "$JOB_NAME" "$rc" "$secs" "$ERR_COUNT" "$TR" false "$chash"
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

cmd_watchdog() { # stale-success alerts, stuck-run alerts (deduped 24h), log + task pruning
  load_paths
  storage_guard
  local now f n nn sj last_ok running dedup lk ttf
  now="$(unix_now)"
  for f in "$BOOT_DIR/jobs"/*.conf; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .conf)"
    valid_jobname "$n" || continue
    sj="$(status_file "$n")"
    [ -f "$sj" ] || continue
    nn="$(job_notify_setting "$n")"
    [ "$nn" = off ] && continue
    dedup="$STATUS_DIR/.wd-$n"
    running="$(jq -r '.running // false' "$sj" 2>/dev/null)"
    if [ "$running" = "true" ]; then
      lk="$LOCKDIR/$NAME-$n.lock"
      if [ -f "$lk" ] && ! flock -n "$lk" true 2>/dev/null; then
        if [ $(( now - $(stat -c %Y "$sj" 2>/dev/null || echo "$now") )) -gt 21600 ]; then
          if [ ! -f "$dedup" ] || [ $(( now - $(stat -c %Y "$dedup" 2>/dev/null || echo 0) )) -gt 86400 ]; then
            touch "$dedup"
            syslog_line "WATCHDOG: $n looks stuck (running >6h with lock held)"
            notify_unraid alert "rclone-jobs: $n looks stuck" "running for over 6 hours with the lock held" "job: $n - check the WebUI and the job log"
          fi
        fi
      fi
      continue
    fi
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
  find "$LOG_DIR" -maxdepth 1 -type f \( -name '*.log' -o -name 'doctor-*.txt' \) -mtime +14 -delete 2>/dev/null
  return 0
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
  local njobs nact jen jsched
  for a in "$@"; do [ "$a" = "--notify" ] && opt_notify=yes; done
  DOCTOR_BUF="$(mktemp)"
  say "== rclone-jobs doctor v$ENGINE_VERSION - $(stamp_now) =="
  say ""
  pv="$(sed -nE 's/.*<!ENTITY[[:space:]]+version[[:space:]]+"([^"]+)".*/\1/p' "/boot/config/plugins/$NAME.plg" 2>/dev/null | head -1)"
  if [ -n "$pv" ]; then
    if [ "$pv" = "$ENGINE_VERSION" ]; then d_line PASS "plugin package version matches engine ($pv)"
    else d_line WARN "plg version '$pv' differs from engine '$ENGINE_VERSION' (reinstall the plugin)" ; fi
  else d_line WARN "cannot read plugin version from /boot/config/plugins/$NAME.plg (plugin not installed?)"; fi
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
  rclone-jobs.sh run <job> [--dry-run]   run a job (dry-run honors per-job + master switch)
  rclone-jobs.sh preview <job>           alias of: run <job> --dry-run
  rclone-jobs.sh preview-start <job>     detached preview (WebUI); poll with task-status
  rclone-jobs.sh task-status <job>       preview task: running | done output (consumed)
  rclone-jobs.sh task-cancel <job>       terminate a running preview task
  rclone-jobs.sh ack <job>               acknowledge a deletion-heavy dry-run
  rclone-jobs.sh status                  one line per job (run + dry-run outcomes)
  rclone-jobs.sh list                    list job names
  rclone-jobs.sh browse <local|rclone> <path> [files]   read-only listing as JSON
  rclone-jobs.sh watchdog                stale/stuck alerts + prune logs older than 14d
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
    preview)  [ $# -ge 1 ] || die 78 "usage: $0 preview <job>"; JOB_NAME="$1"; cmd_run "$JOB_NAME" --dry-run ;;
    preview-start) [ $# -ge 1 ] || die 78 "usage: $0 preview-start <job>"; cmd_preview_start "$1" ;;
    task-status)   [ $# -ge 1 ] || die 78 "usage: $0 task-status <job>"; cmd_task_status "$1" ;;
    task-cancel)   [ $# -ge 1 ] || die 78 "usage: $0 task-cancel <job>"; cmd_task_cancel "$1" ;;
    ack)      [ $# -ge 1 ] || die 78 "usage: $0 ack <job>"; cmd_ack "$1" ;;
    status)   cmd_status ;;
    list)     cmd_list ;;
    browse)   cmd_browse "$@" ;;
    watchdog) cmd_watchdog ;;
    notify-test) cmd_notify_test "$@" ;;
    doctor)   cmd_doctor "$@" ;;
    *)        usage; exit 78 ;;
  esac
}

main "$@"
