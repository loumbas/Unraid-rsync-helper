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
# rclone-jobs settings (no secrets here - Telegram lives in the storage folder notify.env).
# The engine re-reads this file on every run; edit via the WebUI or by hand.

# Where job data (logs, status, backups, dry-run previews) is kept.
# Leave commented to auto-detect: first mounted array disk, hidden dot-folder
# (e.g. /mnt/disk1/.rclone-jobs - not visible in the /mnt/user share namespace).
# Shares (/mnt/user/...) and system paths are refused by policy.
#STORAGE_ROOT=/mnt/disk1/.rclone-jobs

# Master safety switch: yes = every scheduled run executes as DRY-RUN until you
# preview + ack each job. Set to no to let scheduled runs move real data.
DRY_RUN_MASTER=yes

# Quiet hours for alerts (24h, used by watchdog; blank = always alert)
QUIET_START=23:00
QUIET_END=07:00
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
