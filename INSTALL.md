# Installing rclone-jobs

Requirements: Unraid 7.x, the `rclone` plugin installed (any version), array started.

## From the plugin URL (recommended)

1. WebGUI: Plugins → Install Plugin → paste
   `https://raw.githubusercontent.com/loumbas/Unraid-rsync-helper/main/dist/rclone-jobs.plg`
   → Install. Future releases are picked up by **Check for Updates**
   (`plugin update rclone-jobs.plg` on the shell).
2. Open **Utilities → rclone-jobs**. Start with the master dry-run switch ON (default):
   create jobs, press **Dry-run**, read the preview, then turn the master switch off
   when you trust the set.

## From a .plg file

1. Copy `dist/rclone-jobs.plg` to the server:
   `scp dist/rclone-jobs.plg root@<tower>:/tmp/`
2. Install (as root):
   ```
   /usr/local/emhttp/plugins/dynamix.plugin.manager/scripts/plugin install /tmp/rclone-jobs.plg
   ```
   Or in the WebGUI: Plugins → Install Plugin → upload/select the file.
3. Open **Utilities → rclone-jobs**. Start with the master dry-run switch ON (default):
   create jobs, press **Dry-run**, read the preview, then turn the master switch off
   when you trust the set.

## Upgrading

**Online update (recommended):** Plugins → Check for Updates → **Update** (shell
equivalent: `plugin check rclone-jobs.plg && plugin update rclone-jobs.plg`). Every
embedded file carries a `<SHA256>` of its deployed bytes and the update pre-clean
wipes the old RAM-resident copy, so changed files are actually redeployed and files
deleted between releases cannot linger (since 2026.09.07; the first online update
from an older build is a full redeploy). Config and job data survive untouched.

Fallback (e.g. an update looked ineffective): remove first, then install the newer
`.plg`: `plugin remove rclone-jobs.plg && plugin install /tmp/rclone-jobs.plg`.
Version numbers are dates (`YYYY.MM.DD`, optional lowercase letter for same-day
releases, e.g. `2026.09.04a`).

## Uninstalling

Plugins → Remove (or `plugin remove rclone-jobs.plg`). This removes the code and the
managed crontab block (cron is restarted only when our block was present) and stops
running jobs. **Kept on purpose:** `/boot/config/plugins/rclone-jobs/` (your configs),
`/mnt/diskN/.rclone-jobs/` (logs, status, backups). Delete them manually
for a full cleanup:

```
rm -rf /mnt/disk1/.rclone-jobs /boot/config/plugins/rclone-jobs*
```

## Notifications (Telegram, email, ...)

The plugin uses **Unraid's own notification system** - there is nothing to configure
here. *Settings → Notification Settings* decides which agents receive each importance
level (WebUI bell always; Telegram/email/Discord/Pushover need their token/webhook
entered once, system-wide). Per job, the **Notify** dropdown picks *always*,
*failures only* or *off*; the quiet window suppresses only the OK notices.

Test from the Alerts & Safety tab ("Send test notification", any level), on the shell
(`rclone-jobs.sh notify-test alert`) or via Doctor (`--notify`).

Since 2026.09.07a the built-in Telegram sender is gone; an old
`/mnt/diskN/.rclone-jobs/notify.env` is no longer read and can be deleted:
`rm '/mnt/diskN/.rclone-jobs/notify.env'`

## First-run checklist

1. Doctor tab → all PASS (expected WARN: minimal-PATH probe - that documents the
   wrapper fix; and "no managed block" until you create a scheduled job).
2. Alerts & Safety tab → "Send test notification" → check the bell (and Telegram/email
   if those agents are enabled in Notification Settings).
3. Create one job, press Dry-run, inspect the copy/delete summary.
4. `status` column updates after each run; syslog tag is `rclone-jobs`
   (`grep rclone-jobs /var/log/syslog`).

## Troubleshooting

- **Nothing runs on schedule**: Doctor → crontab block/drift lines; the schedule needs
  ENABLED=yes plus a SCHEDULE, and the master switch decides dry vs real.
- **Exit 75 in logs**: mount guard - source missing or destination not a mounted dir
  (array stopped / share unmounted). Nothing was touched.
- **Exit 77**: dry-run gate - run a preview (WebUI Dry-run) first, Ack if deletions.
- **rclone not found in cron**: intentional - cron's PATH lacks /usr/sbin; the engine
  exports a full PATH itself, cron lines use absolute paths.
