#!/bin/bash
# rclone-jobs v{{VERSION}} - manage our block inside /var/spool/cron/crontabs/root
#
# Unraid's scheduler is Dillon's cron 4.5: it does NOT read /etc/cron.d, does NOT
# re-read changed crontabs, and does NOT support environment (PATH=) lines inside
# user crontabs. Empirically verified on the target box (2026-09-03): a marked
# block appended to crontabs/root fires only after an rc.crond restart.
#
# Therefore: we splice a BEGIN/END marker block into the root crontab (everything
# else in the file - Dynamix Scheduler entries, run-parts lines - is preserved
# byte-for-byte) and restart the cron service ONLY when the content actually
# changed (same approach as the installed .plus plugins).
#
# usage:
#   regen-cron.sh            write block (restart cron only on change)
#   regen-cron.sh --dry      print our block; change nothing
#   regen-cron.sh --check    exit 0 if installed block matches jobs/, else 1 + diff
#
# Exit: 0 ok, 1 drift (--check) or invalid job config (line skipped, logged).
set -uo pipefail
NAME="rclone-jobs"
BOOT_DIR="${RJ_BOOT_DIR:-/boot/config/plugins/rclone-jobs}"
EMHTTP_DIR="${RJ_EMHTTP_DIR:-/usr/local/emhttp/plugins/rclone-jobs}"
CRONTAB_FILE="${RJ_CRONTAB_FILE:-/var/spool/cron/crontabs/root}"
RC_CROND="${RJ_RC_CROND:-/etc/rc.d/rc.crond}"
BEGIN_MARK="# $NAME BEGIN (managed block - edits are overwritten; removed on plugin uninstall)"
END_MARK="# $NAME END"

log() { printf '%s\n' "$*" >&2; }

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

engine_path() { # prefer the emhttp copy; fall back to the storage CLI copy
  local e="$EMHTTP_DIR/engine/rclone-jobs.sh" s
  [ -x "$e" ] && { printf '%s' "$e"; return 0; }
  s="$(storage_root)/rclone-jobs.sh"
  [ -x "$s" ] && { printf '%s' "$s"; return 0; }
  printf '%s' "$e"
}

re_sched='^[0-9,*/-]+( [0-9,*/-]+){4}$'
re_name='^[A-Za-z0-9_-]{1,40}$'

block="$(mktemp)" || { log "$NAME regen: mktemp failed"; exit 1; }
errs=0
eng="$(engine_path)"
any=0
for f in "$BOOT_DIR/jobs"/*.conf; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .conf)"
  if ! [[ "$n" =~ $re_name ]]; then log "$NAME regen: SKIP $(basename "$f"): invalid job name"; errs=1; continue; fi
  sched=""; en="yes"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    val="${val#\"}"; val="${val%\"}"
    case "$key" in
      SCHEDULE) sched="$val" ;;
      ENABLED)  en="$val" ;;
    esac
  done < "$f"
  [ "$en" = "no" ] && continue
  if [ -z "$sched" ]; then log "$NAME regen: SKIP $n: enabled but no SCHEDULE"; continue; fi
  if ! [[ "$sched" =~ $re_sched ]]; then log "$NAME regen: SKIP $n: invalid SCHEDULE '$sched'"; errs=1; continue; fi
  echo "$sched /usr/bin/env bash '$eng' run $n 2>&1 | /usr/bin/logger -t $NAME" >> "$block"
  any=1
done

our_block=""
if [ "$any" = 1 ]; then
  our_block="$(printf '%s\n%s\n%s\n' "$BEGIN_MARK" "$(cat "$block")" "$END_MARK")"
fi

# strip our block from the installed crontab -> foreign content (preserved as-is)
foreign="$(mktemp)"; newfile="$(mktemp)"
if [ -f "$CRONTAB_FILE" ]; then
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) == 1 { skip = 1; next }
    index($0, e) == 1 { skip = 0; next }
    skip != 1         { print }
  ' "$CRONTAB_FILE" > "$foreign"
else
  log "$NAME regen: NOTE $CRONTAB_FILE missing - creating it"
fi
cat "$foreign" > "$newfile"
if [ -n "$our_block" ]; then
  # exactly one newline separator between foreign content and our block
  printf '%s\n' "$our_block" >> "$newfile"
fi

case "${1:-}" in
  --dry)
    printf '%s\n' "$our_block"
    rm -f "$block" "$foreign" "$newfile"; exit "$errs" ;;
  --check)
    rc=0
    if [ ! -f "$CRONTAB_FILE" ]; then echo "no $CRONTAB_FILE"; rc=1
    elif ! cmp -s "$newfile" "$CRONTAB_FILE"; then
      echo "crontab drift (ours vs installed):"
      diff "$CRONTAB_FILE" "$newfile" | head -20; rc=1
    fi
    rm -f "$block" "$foreign" "$newfile"
    [ "$errs" -eq 0 ] || rc=1
    exit "$rc" ;;
  "" ) : ;;
  *) log "usage: $0 [--check|--dry]"; rm -f "$block" "$foreign" "$newfile"; exit 1 ;;
esac

if [ -f "$CRONTAB_FILE" ] && cmp -s "$newfile" "$CRONTAB_FILE"; then
  rm -f "$block" "$foreign" "$newfile"
  echo "$NAME regen: crontab already in sync (no cron restart)"
  exit "$errs"
fi
# preserve inode/permissions (Dillon and Dynamix expect the same file, mode 600)
if ! cat "$newfile" > "$CRONTAB_FILE" 2>/dev/null; then
  log "$NAME regen: CANNOT write $CRONTAB_FILE"
  rm -f "$block" "$foreign" "$newfile"; exit 1
fi
chmod 600 "$CRONTAB_FILE" 2>/dev/null
rm -f "$block" "$foreign" "$newfile"
echo "$NAME regen: wrote block into $CRONTAB_FILE"
# Dillon never reloads on its own -> restart, but ONLY on actual change
if [ -z "${RJ_SKIP_RESTART:-}" ] && [ -x "$RC_CROND" ]; then
  "$RC_CROND" restart >/dev/null 2>&1 && echo "$NAME regen: cron restarted (reloads crontab)" \
    || log "$NAME regen: WARNING rc.crond restart failed - schedule inactive until cron restarts"
elif [ -n "${RJ_SKIP_RESTART:-}" ]; then
  echo "$NAME regen: restart skipped (RJ_SKIP_RESTART set)"
fi
exit "$errs"
