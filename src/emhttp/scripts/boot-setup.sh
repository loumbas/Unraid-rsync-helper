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
fi

up=no
for d in /mnt/disk[0-9]*; do
  [ -d "$d" ] || continue
  s="$(findmnt -no SOURCE -T "$d" 2>/dev/null)" || true
  case "$s" in /dev/md*) up=yes; break ;; esac
done
if [ "$up" = yes ]; then
  [ -x "$D/scripts/install-engine.sh" ] && "$D/scripts/install-engine.sh" >/dev/null 2>&1
  [ -x "$D/scripts/regen-cron.sh" ]     && "$D/scripts/regen-cron.sh" >/dev/null 2>&1
else
  log "array not started - engine deploy deferred to array_started event"
fi
exit 0
