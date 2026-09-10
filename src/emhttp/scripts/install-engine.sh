#!/bin/bash
# rclone-jobs v{{VERSION}} - idempotent engine deployment (run at install/update/array_started).
# Creates the storage tree and refreshes the CLI copy of the engine.
# NEVER touches: jobs/, paths.env, logs/, status/, backup/ - and a legacy notify.env
# (pre-2026.09.07a Telegram secret file) is left in place untouched; see CHANGELOG.
set -uo pipefail
NAME="rclone-jobs"
BOOT_DIR="${RJ_BOOT_DIR:-/boot/config/plugins/rclone-jobs}"
EMHTTP_DIR="${RJ_EMHTTP_DIR:-/usr/local/emhttp/plugins/rclone-jobs}"

log() { printf '%s\n' "$*"; logger -t "$NAME" -- "install-engine: $*" 2>/dev/null || true; }

# keep in sync with engine policy_ok()
policy_ok() {
  case "$1" in
    /|/mnt/user|/mnt/user/*|/boot|/boot/*|/etc|/etc/*|/usr|/usr/*|/var/log|/var/log/*) return 1 ;;
  esac
  local rp
  rp="$(realpath -m -- "$1" 2>/dev/null)" || return 1
  case "$rp" in
    /|/mnt/user|/mnt/user/*|/boot|/boot/*|/etc|/etc/*|/usr|/usr/*|/var/log|/var/log/*) return 1 ;;
  esac
  return 0
}

storage_root() {
  local v="" line key val
  if [ -f "$BOOT_DIR/paths.env" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in ''|'#'*) continue ;; esac
      case "$line" in *=*) ;; *) continue ;; esac
      key="${line%%=*}"; val="${line#*=}"
      val="${val#\"}"; val="${val%\"}"
      [ "$key" = "STORAGE_ROOT" ] && v="$val"
    done < "$BOOT_DIR/paths.env"
  fi
  [ -n "${RJ_STORAGE_ROOT:-}" ] && v="$RJ_STORAGE_ROOT"
  if [ -z "$v" ]; then
    local d src
    for d in /mnt/disk[0-9]*; do
      [ -d "$d" ] || continue
      src="$(findmnt -no SOURCE -T "$d" 2>/dev/null)" || continue
      case "$src" in /dev/md*) v="$d/.$NAME"; break ;; esac
    done
  fi
  printf '%s' "$v"
}

SR="$(storage_root)"
if [ -z "$SR" ]; then
  log "no STORAGE_ROOT set and no array disk found - deploy deferred (array_started will retry)"
  exit 0
fi
if ! policy_ok "$SR"; then
  log "REFUSED STORAGE_ROOT '$SR' (must live outside /, /mnt/user, /boot, /etc, /usr, /var/log) - nothing done"
  exit 1
fi
if ! mkdir -p "$SR" "$SR/logs" "$SR/status" "$SR/backup" 2>/dev/null; then
  log "cannot create storage tree under $SR (array stopped? read-only?) - retry at array_started"
  exit 1
fi

SRC="$EMHTTP_DIR/engine/rclone-jobs.sh"
if [ -f "$SRC" ]; then
  if cmp -s "$SRC" "$SR/rclone-jobs.sh" 2>/dev/null; then
    log "engine CLI copy already up to date"
  else
    # atomic swap: write a temp in the SAME dir, then rename over the target.
    # A bash process still executing the old file keeps its (unlinked) inode
    # and finishes cleanly - an in-place cp could corrupt a live run.
    tmp="$SR/.rclone-jobs.sh.new.$$"
    if cp -f "$SRC" "$tmp" 2>/dev/null && chmod 0755 "$tmp" 2>/dev/null && mv -f "$tmp" "$SR/rclone-jobs.sh"; then
      log "engine CLI copy refreshed -> $SR/rclone-jobs.sh"
    else
      rm -f "$tmp" 2>/dev/null
      log "WARNING: could not refresh $SR/rclone-jobs.sh"
    fi
  fi
else
  log "WARNING: $SRC missing - plugin files not in place yet"
fi

chmod 700 "$SR" 2>/dev/null || true
log "done (storage: $SR)"
exit 0
