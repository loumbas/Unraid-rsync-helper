# Installing rclone-jobs

Requirements: Unraid 7.x, the `rclone` plugin installed (any version), array started.

## From a .plg file

1. Copy `dist/rclone-jobs.plg` to the server:
   `scp dist/rclone-jobs.plg root@<tower>:/tmp/`
2. Install (as root):
   ```
   /usr/local/emhttp/plugins/dynamix.plugin.manager/scripts/plugin install /tmp/rclone-jobs.plg
   ```
   Or in the WebGUI: Plugins → Install Plugin → upload/select the file.
3. Open **Settings → rclone-jobs**. Start with the master dry-run switch ON (default):
   create jobs, press **Dry-run**, read the preview, then turn the master switch off
   when you trust the set.

## Upgrading

Install the newer `.plg` (same filename) - the plugin manager replaces files, fires the
`updating` event, refreshes the engine copy and re-validates the cron block. Version
numbers are dates (`YYYY.MM.DD`).

## Uninstalling

Plugins → Remove (or `plugin remove rclone-jobs.plg`). This removes the code and the
managed crontab block (cron is restarted only when our block was present) and stops
running jobs. **Kept on purpose:** `/boot/config/plugins/rclone-jobs/` (your configs),
`/mnt/diskN/.rclone-jobs/` (logs, status, backups, `notify.env`). Delete them manually
for a full cleanup:

```
rm -rf /mnt/disk1/.rclone-jobs /boot/config/plugins/rclone-jobs*
```

## Telegram (optional)

Alerts & Safety tab: paste the bot token (from @BotFather) and your chat id, enable,
"Send test message". Values are stored in `/mnt/diskN/.rclone-jobs/notify.env` (mode
600). No outbound network traffic ever happens unless Telegram is enabled.

## First-run checklist

1. Doctor tab → all PASS (expected WARN: minimal-PATH probe - that documents the
   wrapper fix; and "no managed block" until you create a scheduled job).
2. Create one job, press Dry-run, inspect the copy/delete summary.
3. `status` column updates after each run; syslog tag is `rclone-jobs`
   (`grep rclone-jobs /var/log/syslog`).

## Troubleshooting

- **Nothing runs on schedule**: Doctor → crontab block/drift lines; the schedule needs
  ENABLED=yes plus a SCHEDULE, and the master switch decides dry vs real.
- **Exit 75 in logs**: mount guard - source missing or destination not a mounted dir
  (array stopped / share unmounted). Nothing was touched.
- **Exit 77**: dry-run gate - run a preview (WebUI Dry-run) first, Ack if deletions.
- **rclone not found in cron**: intentional - cron's PATH lacks /usr/sbin; the engine
  exports a full PATH itself, cron lines use absolute paths.
