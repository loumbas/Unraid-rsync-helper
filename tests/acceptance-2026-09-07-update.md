# Acceptance - 2026.09.07: online-update fix (per-file SHA256) + install/update/remove verbosity

Offline verification (dev machine, this commit):

| Check | Result |
|---|---|
| `pwsh -NoProfile -File build.ps1` (src + dist lint) | PASS - 17 checks green, dist v2026.09.07 |
| build.sh (bash 5.2) output byte-identical to build.ps1 | PASS - .plg sha256 `cc1f609e978c8ed3...` from both |
| XML round-trip: parse dist .plg, unescape each `<INLINE>`, hash vs embedded `<SHA256>` | PASS - 12/12 match after stripping the single leading newline after the `<INLINE>` tag (the plugin manager trims it - the working `.page` deployment proves first-byte-exact start) |
| All embedded content version-stamped (no `{{` inside any INLINE) | PASS |

On-box checklist (LMBS-SRV, Unraid 7.3.2) - PENDING:

| Step | Command / action | Expected |
|---|---|---|
| 1 | Remove old, install new .plg (Plugins -> Install Plugin URL) | Window shows `rclone-jobs v2026.09.07 - fresh install`, deployed-file count; plugin works |
| 2 | `sha256sum /usr/local/emhttp/plugins/rclone-jobs/engine/rclone-jobs.sh` | Equals the `<SHA256>` in the .plg (`a1d9914d...`). If it differs only by leading/trailing newline, adjust what the build hashes (see AGENTS.md) - do NOT drop checksums |
| 3 | Bump a test version, `plugin check rclone-jobs.plg && plugin update rclone-jobs.plg` (or WebUI Update) | Update window shows `previous version: X -> new: Y` and `cleared`; changed file actually replaced (`grep ENGINE_VERSION` in deployed engine); `grep rclone-jobs /var/log/syslog` shows `update: stale emhttp copy cleared` (confirms Method="update" blocks run on update on 7.3.2 - docs claim it, plugin help text only guarantees install-method blocks) |
| 4 | Over-install same version: `plugin install` the new .plg over the running install | Files replaced (checksum mismatch path), not silently skipped; plugin still works afterwards |
| 5 | Reboot | Plugin re-installed silently at boot, WebUI OK, cron block intact (checksums skip unchanged files at most; a rewrite is also fine) |
| 6 | Plugins -> Remove | Window shows cron splice, `deleting code`, and the KEPT-on-purpose banner with the full-cleanup command |
| 7 | Online update from 2026.09.04l (the currently installed build) straight to 2026.09.07 | Full redeploy via the new pre-clean + checksums; no manual remove needed |
