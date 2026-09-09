#!/bin/bash
# rclone-jobs v{{VERSION}} - boot/install setup, called from the .plg install script and
# the 'installed' event. Safe to run at any time (array may be down, files half-deployed).
# Creates the /boot config skeleton + default paths.env (NEVER overwrites), and deploys
# engine copy + crontab block when an array disk is mounted. Always exits 0.
set -u
NAME="rclone-jobs"
B="${RJ_BOOT_DIR:-/boot/config/plugins/$NAME}"
D="${RJ_EMHTTP_DIR:-/usr/local/emhttp/plugins/$NAME}"
log() { logger -t "$NAME" -- "setup: $*" 2>/dev/null || true; }

VERBOSE=no
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=yes ;;
  esac
done

v_echo() {
  if [ "$VERBOSE" = "yes" ]; then
    printf '%s\n' "$*"
  fi
}

v_echo " [1/5] Verifying WebUI package files and integrity..."
v_echo "       Target directory : $D"
file_count="$(find "$D" -type f 2>/dev/null | wc -l)"
v_echo "       Files extracted  : ${file_count:-0}"
csf="$D/installed-checksums.txt"
if [ -f "$csf" ]; then
  if head -n 2 "$csf" | grep -q 'PLACEHOLDER'; then
    v_echo "       Checksum status  : build placeholder (check skipped)"
  else
    cscount=0; csbad=0; csmiss=0
    while read -r csha cpath cmode || [ -n "${csha:-}" ]; do
      case "$csha" in ''|'#'*) continue ;; esac
      cscount=$((cscount + 1))
      if [ ! -f "$cpath" ]; then
        csmiss=$((csmiss + 1))
      elif [ "$(sha256sum "$cpath" 2>/dev/null | cut -d' ' -f1)" != "$csha" ]; then
        csbad=$((csbad + 1))
      fi
    done < "$csf"
    if [ $((csbad + csmiss)) -eq 0 ]; then
      v_echo "       Checksum status  : PASS ($cscount package files verified matching SHA256)"
    else
      v_echo "       Checksum status  : WARN ($((csbad + csmiss)) of $cscount files mismatched or missing)"
    fi
  fi
fi

# Ensure WebUI icon compatibility across various Unraid page loaders
mkdir -p "$D/images" "$D/icons" 2>/dev/null || true
if [ -f "$D/rclone-jobs.svg" ]; then
  ln -sf "$D/rclone-jobs.svg" "$D/icon.svg" 2>/dev/null || true
  ln -sf "$D/rclone-jobs.svg" "$D/rclone-jobs.png" 2>/dev/null || true
  ln -sf "$D/rclone-jobs.svg" "$D/images/rclone-jobs.svg" 2>/dev/null || true
  ln -sf "$D/rclone-jobs.svg" "$D/images/rclone-jobs.png" 2>/dev/null || true
  ln -sf "$D/rclone-jobs.svg" "$D/icons/rclone-jobs.svg" 2>/dev/null || true
  ln -sf "$D/rclone-jobs.svg" "$D/icons/rclone-jobs.png" 2>/dev/null || true
fi

v_echo " [2/5] Checking configuration directory & persistence..."
v_echo "       Config location  : $B"
mkdir -p "$B/jobs" 2>/dev/null || true

if [ ! -f "$B/paths.env" ]; then
  cat > "$B/paths.env" <<'EOF'
# rclone-jobs settings (no secrets here - the plugin stores none; notification agents
# are configured in Unraid's own Settings -> Notification Settings).
# The engine re-reads this file on every run; edit via the WebUI or by hand.

# Where job data (logs, status, backups, dry-run previews) is kept.
# Leave commented to auto-detect: first mounted array disk, hidden dot-folder
# (e.g. /mnt/disk1/.rclone-jobs - not visible in the /mnt/user share namespace).
# Shares (/mnt/user/...), the flash (/boot) and system paths are refused by policy.
#STORAGE_ROOT=/mnt/disk1/.rclone-jobs

# Master safety switch: yes = every scheduled run executes as DRY-RUN until you
# preview + ack each job. Set to no to let scheduled runs move real data.
DRY_RUN_MASTER=yes

# Quiet hours for alerts (24h, used by watchdog; blank = always alert)
QUIET_START=23:00
QUIET_END=07:00

# History + log retention (integers; the engine clamps anything else back to the
# defaults shown). History is tiered so high-frequency jobs stay bounded: every
# live run is kept raw for HISTORY_RAW_HOURS (max HISTORY_RAW_MAX lines), then
# folded into one hourly bucket for HISTORY_HOUR_DAYS, then one daily bucket for
# HISTORY_DAYS. Job logs: OK/dry-run logs age out after LOG_KEEP_DAYS (and no
# more than LOG_KEEP_MAX files per job); failed/interrupted logs stay
# LOG_KEEP_FAIL_DAYS. The watchdog (cron block, every 15 min) does the work.
HISTORY_RAW_HOURS=24
HISTORY_RAW_MAX=500
HISTORY_HOUR_DAYS=7
HISTORY_DAYS=90
LOG_KEEP_DAYS=3
LOG_KEEP_FAIL_DAYS=14
LOG_KEEP_MAX=300

# Config schema marker (readers must ignore unknown keys; a future release that
# changes this file's format bumps the number and migrates from the old value).
CONFIG_VERSION=1
EOF
  log "created default $B/paths.env"
  v_echo "       Settings file    : created default $B/paths.env (DRY_RUN_MASTER=yes)"
else
  v_echo "       Settings file    : $B/paths.env (preserved)"
  drm="$(grep -E '^[[:space:]]*DRY_RUN_MASTER=' "$B/paths.env" 2>/dev/null | cut -d'=' -f2 | tr -d '\" ')"
  v_echo "       Master safety    : DRY_RUN_MASTER=${drm:-yes}"
fi

job_count="$(find "$B/jobs" -maxdepth 1 -name "*.conf" 2>/dev/null | wc -l)"
v_echo "       User jobs        : ${job_count:-0} job configuration(s) preserved"

v_echo " [3/5] Setting up array storage & CLI engine..."
up=no
for d in /mnt/disk[0-9]*; do
  [ -d "$d" ] || continue
  s="$(findmnt -no SOURCE -T "$d" 2>/dev/null)" || true
  case "$s" in /dev/md*) up=yes; break ;; esac
done
if [ "$up" = yes ]; then
  if [ -x "$D/scripts/install-engine.sh" ]; then
    if [ "$VERBOSE" = "yes" ]; then
      "$D/scripts/install-engine.sh" 2>&1 | while IFS= read -r line; do
        [ -n "$line" ] && v_echo "       $line"
      done
    else
      "$D/scripts/install-engine.sh" >/dev/null 2>&1
    fi
  fi
else
  log "array not started - engine deploy deferred to array_started event"
  v_echo "       Array status     : Stopped / No mounted array disk detected"
  v_echo "       Notice           : Engine deploy will automatically run when array starts (array_started event)"
fi

v_echo " [4/5] Synchronizing scheduler & maintenance watchdog..."
if [ "$up" = yes ]; then
  if [ -x "$D/scripts/regen-cron.sh" ]; then
    if [ "$VERBOSE" = "yes" ]; then
      "$D/scripts/regen-cron.sh" 2>&1 | while IFS= read -r line; do
        [ -n "$line" ] && v_echo "       $line"
      done
    else
      "$D/scripts/regen-cron.sh" >/dev/null 2>&1
    fi
  fi
  ct="/var/spool/cron/crontabs/root"
  if [ -f "$ct" ] && grep -qF '# rclone-jobs BEGIN' "$ct" 2>/dev/null; then
    sched_entries="$(sed -n '/^# rclone-jobs BEGIN/,/^# rclone-jobs END/p' "$ct" 2>/dev/null | grep -c '/usr/bin/env bash' || echo 0)"
    v_echo "       Cron status      : active in $ct ($sched_entries entry/entries, incl. 15m watchdog)"
  fi
else
  v_echo "       Notice           : Schedule sync deferred until array starts"
fi

v_echo " [5/5] Checking system environment & dependencies..."
rc_bin="$(command -v /usr/sbin/rclone 2>/dev/null || command -v rclone 2>/dev/null || echo "")"
if [ -n "$rc_bin" ] && [ -x "$rc_bin" ]; then
  rc_ver="$("$rc_bin" --version 2>/dev/null | head -1)"
  v_echo "       rclone binary    : $rc_bin (${rc_ver:-ready})"
else
  v_echo "       rclone binary    : NOTICE: rclone not found in standard paths (install rclone plugin)"
fi
if [ -f "/boot/config/plugins/rclone/.rclone.conf" ]; then
  rc_remotes="$(grep -E '^[[:space:]]*\[' "/boot/config/plugins/rclone/.rclone.conf" 2>/dev/null | tr -d '[]' | tr '\n' ' ')"
  v_echo "       rclone config    : /boot/config/plugins/rclone/.rclone.conf (remotes: ${rc_remotes:-none})"
else
  v_echo "       rclone config    : not found at /boot/config/plugins/rclone/.rclone.conf"
fi
if command -v rsync >/dev/null 2>&1; then
  v_echo "       rsync binary     : $(command -v rsync)"
fi

exit 0
