# Acceptance record - rclone-jobs 2026.09.04 on LMBS-SRV (2026-09-04)

Box: Unraid 7.3.2, kernel 6.18.38, rclone v1.75.0 (wrapper `/usr/sbin/rclone` ->
`rcloneorig`), PHP 8.4, Dillon cron 4.5. All items below were executed by the
operator on the box; evidence is operator-pasted output.

## Lifecycle (real .plg via dynamix.plugin.manager)

| Item | Result |
|---|---|
| Clean install (`plugin install /tmp/rclone-jobs.plg`) | PASS - files deployed, boot-setup ran, plugin listed |
| Scheduled run via installed engine | PASS - cron-fired job produced DRYRUN log + `rc=0 - OK` + syslog tag `rclone-jobs` |
| Reboot persistence | PASS - after reboot: managed block present, block in sync, daemon running, job executed again |
| Uninstall | PASS - code + managed crontab block removed, cron restarted, `/boot` config + `/mnt/disk1/.rclone-jobs` data kept |
| Upgrade path | remove-then-install deploys all files (2026.09.02 -> 2026.09.04 verified in both engine copies). Over-install refreshes the saved .plg but not deployed files on this box - documented in INSTALL.md |

## Zero-touch (outside `/mnt/diskN/.rclone-jobs`)

| Item | Result |
|---|---|
| `/mnt/user` normal listing | PASS - no rclone-jobs entry |
| `find /mnt/user -mindepth 1 ! -path '*/.*' -name 'rclone-jobs*'` | PASS - 0 hits (2026-09-04 paste) |
| Share visibility | dot-folder is not a share; shfs surfaces `/mnt/user/.rclone-jobs` to `ls -a`/`find` only (cosmetic; documented in README) |
| `/etc/cron.d` | PASS - still only `appdata.cleanup.plus`, `folderview.plus`, `root` (untouched mtimes) |
| `/boot/config/shares` | PASS - mtime 2026-07-12 (untouched) |
| `/var/spool/cron/crontabs/root` | PASS - byte-exact restores in every tamper/reinstall cycle; final state after uninstall: our lines 0 |

Note: the original `/tmp/rj-baseline/MASTER.sha256` was lost when the box
rebooted (/tmp is RAM). Its content is preserved in `baseline-2026-09-02.txt`
in this folder; equivalent evidence re-derived via the checks above.

## Engine / safety

| Item | Result |
|---|---|
| Dry-run gate (master switch + exit 77 ack flow) | PASS |
| Preview parsing vs rclone 1.75 markers (copied/updated/skipped/deleted/bytes) | PASS - e.g. `"bytes":"6 B"`, sample stale.txt |
| Storage policy rejects `/`, `/mnt/user`, `/etc`, `/usr`, `/var/log`, non-dot paths | PASS |
| Schedule validation (rejects `* ; reboot`, accepts `*/5 ...`) | PASS |
| Cron delivery: marker block in crontabs/root, regen restarts Dillon only on change, `--check` detects drift | PASS (Dillon reads no /etc/cron.d on this box - see INSTALL.md) |
| notify.env 0600, secrets never echoed | PASS |
| Doctor on installed plugin | PASS - all PASS + by-design WARNs (minimal-PATH probe 127, no managed block until a job exists) |
| Final state | v2026.09.04 installed, 0 jobs configured, crontab clean |

## Not executed

- Live Telegram send (token not configured; Alerts & Safety tab flow is CLI-tested only).
- `updating` event script on over-install (moot given remove+install upgrade path).
