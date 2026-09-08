<?php
/* rclone-jobs v{{VERSION}} - standalone job-log window: read-only live tail.
   Only ?job=NAME is accepted (same regex as ajax); content always goes
   through the ajax tail_log action, which takes the path from the validated
   status file and re-applies the engine redaction. No path, ever, comes from
   the request. POSTs carry the live emhttp CSRF token.
   License: GPL-2.0-or-later. PHP 8.x clean. */

header('Content-Type: text/html; charset=utf-8');
$job = isset($_GET['job']) ? (string)$_GET['job'] : '';
if (!preg_match('/^[A-Za-z0-9_-]{1,40}$/', $job)) { http_response_code(400); echo 'invalid job name'; exit; }

$ini = @parse_ini_file('/var/local/emhttp/var.ini');
$tok = (is_array($ini) && isset($ini['csrf_token'])) ? (string)$ini['csrf_token'] : '';

$jobH  = htmlspecialchars($job, ENT_QUOTES, 'UTF-8');
$jobJS = json_encode($job, JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT);
$tokJS = json_encode($tok, JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT);
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta name="robots" content="noindex, nofollow">
<title>rclone-jobs log - <?= $jobH ?></title>
<style>
  html,body{margin:0;padding:0;height:100%;background:#1b2126;color:#e8e8e8;
            font:12px/1.45 "Helvetica Neue",Helvetica,Arial,sans-serif}
  #bar{display:flex;align-items:center;gap:10px;flex-wrap:wrap;padding:8px 12px;
       border-bottom:1px solid #46505a;background:#23292e}
  #bar b{font-size:13px}
  #chip{padding:2px 10px;border-radius:10px;background:#46505a;color:#cfd6dc;white-space:nowrap}
  #chip.run{background:#2e97c2;color:#fff}
  #chip.ok{background:#2e7d32;color:#fff}
  #chip.bad{background:#b3403a;color:#fff}
  #meta{color:#9aa7b2;font-family:monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1;min-width:180px}
  #bar label{white-space:nowrap;cursor:pointer;user-select:none}
  #bar button{padding:3px 12px;border:1px solid #5a6570;background:#23292e;color:#e8e8e8;border-radius:3px;cursor:pointer}
  #bar button:hover{background:#2e97c2;border-color:#2e97c2;color:#fff}
  #err{display:none;padding:6px 12px;background:#3a2323;color:#e6867e;border-bottom:1px solid #5a6570;white-space:pre-wrap}
  #lg{box-sizing:border-box;width:100%;height:calc(100% - 46px);margin:0;padding:10px 12px;overflow:auto;
      white-space:pre-wrap;word-break:break-all;font:12px/1.45 monospace}
</style>
</head>
<body>
<div id="bar">
  <b>job: <?= $jobH ?></b>
  <span id="chip">connecting…</span>
  <span id="meta"></span>
  <label><input type="checkbox" id="autoscroll" checked> auto-scroll</label>
  <button type="button" id="refresh">Refresh</button>
  <button type="button" id="close">Close</button>
</div>
<div id="err"></div>
<pre id="lg">loading log …</pre>
<script>
(function () {
  'use strict';
  var JOB = <?= $jobJS ?>, TOK = <?= $tokJS ?>;
  var RUN_MS = 2000, IDLE_MS = 15000;
  var busy = false, timer = null, running = null;
  var pre = document.getElementById('lg'), chip = document.getElementById('chip'),
      meta = document.getElementById('meta'), err = document.getElementById('err'),
      auto = document.getElementById('autoscroll');

  function setChip(text, cls) { chip.textContent = text; chip.className = cls || ''; }
  function showErr(t) { err.textContent = t; err.style.display = t ? 'block' : 'none'; }

  function nearBottom() { return pre.scrollHeight - pre.scrollTop - pre.clientHeight < 60; }
  function toBottom() { pre.scrollTop = pre.scrollHeight; }

  function tick() {
    if (busy || document.hidden) return;
    busy = true;
    var body = 'action=tail_log&job=' + encodeURIComponent(JOB) + '&csrf_token=' + encodeURIComponent(TOK);
    fetch('/plugins/rclone-jobs/ajax.php', { method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: body })
      .then(function (x) { return x.json().catch(function () { return { ok: false, error: 'HTTP ' + x.status + ' (not JSON)' }; }); })
      .then(function (res) {
        busy = false;
        if (!res || !res.ok) { setChip('error', 'bad'); showErr((res && res.error) || 'no response'); schedule(); return; }
        showErr('');
        var stick = auto.checked && (nearBottom() || pre.textContent === 'loading log …');
        if (pre.textContent !== res.text) {
          pre.textContent = res.text;
          if (stick) toBottom();
        } else if (stick && auto.checked) { toBottom(); }
        running = !!res.running;
        if (res.running) setChip('running…', 'run');
        else if (res.rc === null || res.rc === undefined) setChip('idle', '');
        else setChip('finished rc=' + res.rc, res.rc === 0 ? 'ok' : 'bad');
        meta.textContent = (res.log || '') + '  (' + res.size + ' bytes total, redacted tail)';
        schedule();
      })
      .catch(function (e) { busy = false; setChip('error', 'bad'); showErr('could not reach ajax endpoint: ' + e); schedule(); });
  }

  function schedule() { clearTimeout(timer); timer = setTimeout(tick, running ? RUN_MS : IDLE_MS); }

  document.getElementById('refresh').addEventListener('click', function () { clearTimeout(timer); tick(); });
  document.getElementById('close').addEventListener('click', function () { window.close(); });
  auto.addEventListener('change', function () { if (auto.checked) toBottom(); });
  document.addEventListener('visibilitychange', function () { if (!document.hidden) { clearTimeout(timer); tick(); } });
  tick();
})();
</script>
</body>
</html>
