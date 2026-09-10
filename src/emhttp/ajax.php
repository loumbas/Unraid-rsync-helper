<?php
/* rclone-jobs v{{VERSION}} - ajax endpoint. POST + CSRF only.
   Every engine/config mutation goes through the whitelisted validators below;
   values are written as plain KEY=VALUE config lines and are NEVER shell-eval'd. */

$RJ_PLUGIN = '/usr/local/emhttp/plugins/rclone-jobs';
$RJ_BOOT   = '/boot/config/plugins/rclone-jobs';
$RJ_ENGINE = $RJ_PLUGIN.'/engine/rclone-jobs.sh';
$RJ_REGEN  = $RJ_PLUGIN.'/scripts/regen-cron.sh';

header('Content-Type: application/json');

/* ---- transport security ----
   Unraid 7.2+ local_prepend.php validates the CSRF token for EVERY POST and
   then unsets $_POST['csrf_token'] and the X-CSRF header before this script
   runs, so both look empty here no matter what the browser sent. Recover the
   token from the raw urlencoded body (php://input is re-readable since PHP
   5.6); the re-check itself stays as defense-in-depth without the prepend. */
$ini  = @parse_ini_file('/var/local/emhttp/var.ini');
$tokS = $_SERVER['HTTP_X_CSRF_TOKEN'] ?? '';
$tokP = $_POST['csrf_token'] ?? '';
$tok  = is_string($tokP) && $tokP !== '' ? $tokP : (is_string($tokS) ? $tokS : '');
if ($tok === '' && stripos((string)($_SERVER['CONTENT_TYPE'] ?? ''), 'multipart/') === false) {
    $raw = (string)@file_get_contents('php://input');
    if ($raw !== '' && strpos($raw, 'csrf_token=') !== false) {
        $rp = []; parse_str($raw, $rp);
        if (isset($rp['csrf_token']) && is_string($rp['csrf_token'])) $tok = $rp['csrf_token'];
    }
}
if (!is_array($ini) || empty($ini['csrf_token']) || !hash_equals((string)$ini['csrf_token'], $tok)) {
    http_response_code(403); echo json_encode(['ok' => false, 'error' => 'CSRF token mismatch - reload the page']); exit;
}
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405); echo json_encode(['ok' => false, 'error' => 'POST only']); exit;
}

/* ---- helpers (mirror engine validators) ---- */
function rj_out($arr) { echo json_encode($arr); exit; }
function rj_str($v)   { return is_string($v) ? $v : ''; }
function rj_num($v)   { return is_numeric($v) ? (int)$v : -1; } /* -1 always fails the range checks below */
function rj_name_ok($n)  { return is_string($n) && preg_match('/^[A-Za-z0-9_-]{1,40}$/', $n); }
function rj_badfield($v) { return preg_match('/[`$;|&<>*?"\'\\\\\r\n]/', $v) === 1; }
function rj_sched_part($x, $lo, $hi) {
    /* one cron field: lists of '*', values, ranges and steps, each within range */
    if ($x === '*') return true;
    foreach (explode(',', $x) as $part) {
        $step = 1;
        if (strpos($part, '/') !== false) {
            $sp = explode('/', $part, 2);
            if (!preg_match('/^\d{1,2}$/', $sp[1])) return false;
            $step = (int)$sp[1]; $part = $sp[0];
            if ($step < 1 || $step > $hi) return false;
        }
        if ($part === '*') continue;
        $vals = explode('-', $part);
        if (count($vals) === 1) $vals[] = ($step > 1 ? $hi : $vals[0]);
        if (count($vals) !== 2) return false;
        foreach ($vals as $v) if (!preg_match('/^\d{1,2}$/', $v)) return false;
        if ((int)$vals[0] < $lo || (int)$vals[1] > $hi || (int)$vals[0] > (int)$vals[1]) return false;
    }
    return true;
}
function rj_sched_ok($s) {
    /* cron-injection defense: numerics plus * , - / only, plus per-field ranges:
       min 0-59, hour 0-23, dom 1-31, mon 1-12, dow 0-7 (7 = Sunday alias) */
    if (!is_string($s) || $s === '') return false;
    $f = preg_split('/\s+/', trim($s));
    if (count($f) !== 5) return false;
    $lim = [[0, 59], [0, 23], [1, 31], [1, 12], [0, 7]];
    foreach ($f as $i => $x) {
        if (!preg_match('#^[0-9*,-/]+$#', $x)) return false;
        if (!rj_sched_part($x, $lim[$i][0], $lim[$i][1])) return false;
    }
    return true;
}
function rj_env_upsert($file, $pairs, $mode = null) {
    /* replace/add KEY=VALUE lines, keep comments and unknown keys, LF endings */
    $lines = is_readable($file) ? file($file, FILE_IGNORE_NEW_LINES) : [];
    foreach ($pairs as $k => $v) {
        $found = false; $newl = "$k=$v";
        foreach ($lines as $i => $line) {
            if (preg_match('/^\s*'.preg_quote($k, '/').'\s*=/', $line)) { $lines[$i] = $newl; $found = true; break; }
        }
        if (!$found) $lines[] = $newl;
    }
    /* atomic: temp file + rename (never a half-written paths.env) */
    file_put_contents($file.'.tmp', implode("\n", $lines)."\n");
    if ($mode !== null) @chmod($file.'.tmp', $mode);
    @rename($file.'.tmp', $file);
}
function rj_engine($args, &$out = null, &$rc = null, $bg = false) {
    $cmd = '/bin/bash ' . escapeshellarg($GLOBALS['RJ_ENGINE']) . ' ' . $args;
    /* bg: nohup keeps the job alive when php-fpm reaps the request's children */
    if ($bg) { exec('nohup ' . $cmd . ' > /dev/null 2>&1 &', $o, $r); $out = []; $rc = 0; return; }
    exec($cmd . ' 2>&1', $o, $r); $out = $o; $rc = $r;
}
function rj_regen(&$out) {
    exec('/bin/bash ' . escapeshellarg($GLOBALS['RJ_REGEN']) . ' 2>&1', $out, $rc);
    return $rc;
}

$action = rj_str($_POST['action'] ?? '');
$name   = $_POST['job'] ?? '';

switch ($action) {

case 'save_job':
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name (letters, digits, dash, underscore, max 40)']);
    $engine   = rj_str($_POST['engine'] ?? 'rclone');
    if (!in_array($engine, ['rclone', 'rsync', 'custom'], true)) rj_out(['ok' => false, 'error' => 'engine must be rclone|rsync|custom']);
    $mode     = rj_str($_POST['mode'] ?? '');
    $src      = trim(rj_str($_POST['src'] ?? ''));
    $dst      = trim(rj_str($_POST['dst'] ?? ''));
    $script   = trim(rj_str($_POST['script'] ?? ''));
    $sched    = trim(rj_str($_POST['schedule'] ?? ''));
    $enabled  = rj_str($_POST['enabled'] ?? 'yes') === 'no' ? 'no' : 'yes';
    $dryrun   = rj_str($_POST['dryrun'] ?? 'yes') === 'no' ? 'no' : 'yes';
    $notifyIn = rj_str($_POST['notify'] ?? 'always');
    $notify   = in_array($notifyIn, ['always', 'failures', 'off'], true) ? $notifyIn : 'always';
    $desc     = substr(trim(rj_str($_POST['desc'] ?? '')), 0, 120);
    $trans    = rj_num($_POST['transfers'] ?? 4);
    $check    = rj_num($_POST['checkers'] ?? 8);
    $bwlimit  = trim(rj_str($_POST['bwlimit'] ?? ''));
    $bufsize  = trim(rj_str($_POST['buffer_size'] ?? ''));
    $fastlist = rj_str($_POST['fast_list'] ?? 'no') === 'yes' ? 'yes' : 'no';
    $odchunk  = trim(rj_str($_POST['onedrive_chunk_size'] ?? ''));
    $args     = trim(rj_str($_POST['args'] ?? ''));
    $exclude  = trim(rj_str($_POST['exclude'] ?? ''));
    $deferp   = rj_str($_POST['deferparity'] ?? 'no') === 'yes' ? 'yes' : 'no';
    $maxdel   = rj_num($_POST['maxdelete'] ?? 100);
    $warndel  = rj_num($_POST['warndelete'] ?? 100);
    $bdir     = trim(rj_str($_POST['backupdir'] ?? ''));
    if (rj_badfield($desc) || rj_badfield($bwlimit) || rj_badfield($bdir) || rj_badfield($bufsize) || rj_badfield($odchunk) || rj_badfield($args))
        rj_out(['ok' => false, 'error' => 'description/limit/backupdir/rclone options contain forbidden characters']);
    if (stripos($args, '--delete-excluded') !== false)
        rj_out(['ok' => false, 'error' => 'ARGS --delete-excluded is refused (defeats storage auto-exclude)']);

    /* exclude patterns: whitespace-separated globs, stored space-joined in the
       conf. Globs (* ? [ ] { }) are legal - the engine appends each pattern as a
       discrete array element, never eval'd - but shell control characters,
       quotes, backslashes and leading dashes are refused (mirrors engine
       valid_exclude; patterns containing spaces are impossible by design) */
    $ex_pats = $exclude === '' ? [] : preg_split('/\s+/', $exclude, -1, PREG_SPLIT_NO_EMPTY);
    if (count($ex_pats) > 64) rj_out(['ok' => false, 'error' => 'exclude: too many patterns (max 64)']);
    foreach ($ex_pats as $p) {
        if (strlen($p) > 200) rj_out(['ok' => false, 'error' => 'exclude pattern too long (max 200 chars): '.substr($p, 0, 40)]);
        if (strpos($p, '-') === 0) rj_out(['ok' => false, 'error' => 'exclude pattern must not start with a dash: '.substr($p, 0, 40)]);
        if (preg_match('/[`$;|&<>"\'\\\\\0]/', $p) === 1) rj_out(['ok' => false, 'error' => 'exclude pattern contains forbidden characters: '.substr($p, 0, 40)]);
    }
    $exclude = implode(' ', $ex_pats);
    if (strlen($exclude) > 2000) rj_out(['ok' => false, 'error' => 'exclude: too long (max 2000 chars total)']);

    /* every engine is scheduled by cron - a job without a valid SCHEDULE would be
       written to disk but silently skipped by regen-cron.sh: refuse at save time */
    if ($sched === '' || rj_sched_ok($sched) === false) rj_out(['ok' => false, 'error' => 'invalid schedule: 5 cron fields expected (minute 0-59, hour 0-23, day 1-31, month 1-12, weekday 0-7; * , - / allowed)']);

    if ($engine === 'custom') {
        if ($script === '' || rj_badfield($script)) rj_out(['ok' => false, 'error' => 'custom job needs a Script path without shell metacharacters']);
        if (strpos($script, '/') !== 0) rj_out(['ok' => false, 'error' => 'Script must be an absolute path']);
        $mode = ''; $src = ''; $dst = ''; $exclude = '';
    } else {
        if ($src === '' || $dst === '') rj_out(['ok' => false, 'error' => 'SRC and DST are required']);
        if (rj_badfield($src) || rj_badfield($dst)) rj_out(['ok' => false, 'error' => 'SRC/DST contain forbidden characters']);
        if ($engine === 'rclone' && !in_array($mode, ['sync', 'copy', 'check'], true)) rj_out(['ok' => false, 'error' => 'rclone mode must be sync|copy|check']);
        if ($engine === 'rsync') $mode = '';
        if ($bdir !== '' && rj_badfield($bdir)) rj_out(['ok' => false, 'error' => 'backupdir contains forbidden characters']);
    }
    if ($trans < 1 || $trans > 999 || $check < 1 || $check > 999) rj_out(['ok' => false, 'error' => 'transfers/checkers must be 1-999']);
    if ($maxdel < 0 || $warndel < 0) rj_out(['ok' => false, 'error' => 'delete limits must be >= 0']);

    @mkdir($RJ_BOOT.'/jobs', 0700, true);
    $L = [];
    if ($desc !== '') $L[] = "DESC=$desc";
    $L[] = "ENGINE=$engine";
    if ($mode !== '') $L[] = "MODE=$mode";
    if ($engine === 'custom') { $L[] = "CUSTOM_SCRIPT=$script"; }
    else { $L[] = "SRC=$src"; $L[] = "DST=$dst"; }
    $L[] = "SCHEDULE=$sched";
    $L[] = "ENABLED=$enabled";
    $L[] = "DRYRUN=$dryrun";
    $L[] = "NOTIFY=$notify";
    if ($deferp === 'yes') $L[] = "DEFER_ON_PARITY=yes";
    if ($engine !== 'custom') {
        $L[] = "TRANSFERS=$trans"; $L[] = "CHECKERS=$check";
        if ($bwlimit !== '') $L[] = "BWLIMIT=$bwlimit";
        if ($engine === 'rclone') {
            if ($bufsize !== '') $L[] = "BUFFER_SIZE=$bufsize";
            if ($fastlist === 'yes') $L[] = "FAST_LIST=yes";
            if ($odchunk !== '') $L[] = "ONEDRIVE_CHUNK_SIZE=$odchunk";
        }
        $L[] = "MAXDELETE=$maxdel"; $L[] = "WARN_DELETE=$warndel";
        if ($bdir !== '') $L[] = "BACKUPDIR=$bdir";
        if ($args !== '') $L[] = "ARGS=$args";
        if ($exclude !== '') $L[] = "EXCLUDE=$exclude";
    }
    $conf = $RJ_BOOT.'/jobs/'.$name.'.conf';
    $isNew = !file_exists($conf);
    /* atomic: write .tmp then rename - a job config is never half-written */
    file_put_contents($conf.'.tmp', implode("\n", $L)."\n");
    chmod($conf.'.tmp', 0600);
    rename($conf.'.tmp', $conf);

    /* NO inline preview here: a dry-run on a huge remote can take minutes and
       used to hang this request. The UI chains preview_start + polling after
       a successful save (the engine task keeps running across the page reload). */
    $rg = []; rj_regen($rg);
    rj_out(['ok' => true, 'msg' => ($isNew ? 'Job created. ' : 'Job updated. ') . implode(' ', $rg)]);

case 'toggle_job':
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    $conf = $RJ_BOOT.'/jobs/'.$name.'.conf';
    if (!is_file($conf)) rj_out(['ok' => false, 'error' => 'job not found']);
    $enabled = rj_str($_POST['enabled'] ?? 'yes') === 'no' ? 'no' : 'yes';
    rj_env_upsert($conf, ['ENABLED' => $enabled], 0600);
    $rg = []; rj_regen($rg);
    rj_out(['ok' => true, 'job' => $name, 'enabled' => $enabled]);

case 'toggle_dryrun':
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    $conf = $RJ_BOOT.'/jobs/'.$name.'.conf';
    if (!is_file($conf)) rj_out(['ok' => false, 'error' => 'job not found']);
    $dryrun = rj_str($_POST['dryrun'] ?? 'yes') === 'no' ? 'no' : 'yes';
    rj_env_upsert($conf, ['DRYRUN' => $dryrun], 0600);
    rj_out(['ok' => true, 'job' => $name, 'dryrun' => $dryrun]);

case 'delete_job':
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    $conf = $RJ_BOOT.'/jobs/'.$name.'.conf';
    if (!is_file($conf)) rj_out(['ok' => false, 'error' => 'job not found']);
    $bk = $conf.'.removed-'.trim((string)shell_exec("date +%Y%m%d-%H%M%S"));  # system TZ, not PHP UTC
    rename($conf, $bk);
    $rg = []; rj_regen($rg);
    rj_out(['ok' => true, 'msg' => 'Job deleted (config kept as '.$bk.') '.implode(' ', $rg)]);

case 'preview_start':
case 'task_status':
case 'task_cancel': {
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    $sub = ['preview_start' => 'preview-start', 'task_status' => 'task-status', 'task_cancel' => 'task-cancel'][$action];
    $eo = []; $erc = 0;
    rj_engine($sub . ' ' . escapeshellarg($name), $eo, $erc);
    $bj = json_decode(implode("\n", $eo), true);
    if (!is_array($bj)) rj_out(['ok' => false, 'error' => 'bad task response (rc ' . $erc . ')']);
    rj_out($bj);
}

case 'browse':
    /* read-only path picker listing; all confinement happens in the engine */
    $bscope = rj_str($_POST['scope'] ?? '') === 'rclone' ? 'rclone' : 'local';
    $bpath  = trim(rj_str($_POST['path'] ?? ''));
    if ($bpath !== '' && rj_badfield($bpath)) rj_out(['ok' => false, 'error' => 'path contains forbidden characters']);
    if (strlen($bpath) > 1024) rj_out(['ok' => false, 'error' => 'path too long']);
    if ($bscope === 'local' && $bpath !== '' && $bpath[0] !== '/') rj_out(['ok' => false, 'error' => 'local paths must start with /']);
    $eo = []; $erc = 0;
    rj_engine('browse ' . escapeshellarg($bscope) . ' ' . escapeshellarg($bpath)
              . (($_POST['files'] ?? '') === '1' ? ' files' : ''), $eo, $erc);
    $bj = json_decode(implode("\n", $eo), true);
    if (!is_array($bj) || !isset($bj['ok'])) rj_out(['ok' => false, 'error' => 'bad browse response (rc ' . $erc . ')']);
    rj_out($bj);

case 'tail_log':
    /* read-only: the engine takes the path from the validated status file and
       re-applies the redaction filter; no path ever comes from the request */
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    $eo = []; $erc = 0;
    rj_engine('tail-log ' . escapeshellarg($name), $eo, $erc);
    $bj = json_decode(implode("\n", $eo), true);
    if (!is_array($bj) || !isset($bj['ok'])) rj_out(['ok' => false, 'error' => 'bad log response (rc ' . $erc . ')']);
    rj_out($bj);

case 'export_jobs':
    /* job set as tar.gz base64 (confs hold no secrets by design; the UI warns
       that paths and custom-script locations are part of the archive) */
    $eo = []; $erc = 0;
    rj_engine('export-jobs', $eo, $erc);
    $bj = json_decode(implode("\n", $eo), true);
    if (!is_array($bj) || !isset($bj['ok'])) rj_out(['ok' => false, 'error' => 'bad export response (rc ' . $erc . ')']);
    rj_out($bj);

case 'import_jobs':
    /* the archive travels as base64 inside this urlencoded body, NEVER as
       multipart - the CSRF recovery above cannot read a multipart body. The
       engine enforces the size cap, the member-name whitelist (tar-slip),
       the full save-job validators and the ask/overwrite/skip conflict mode. */
    $arch = rj_str($_POST['archive'] ?? '');
    if ($arch === '') rj_out(['ok' => false, 'error' => 'no archive data']);
    if (strlen($arch) > 1500000) rj_out(['ok' => false, 'error' => 'archive too large (max ~1 MiB)']);
    $modeIn = rj_str($_POST['mode'] ?? 'ask');
    $mode = in_array($modeIn, ['ask', 'overwrite', 'skip'], true) ? $modeIn : 'ask';
    $tmp = @tempnam('/tmp', 'rj-import-');
    if ($tmp === false) rj_out(['ok' => false, 'error' => 'cannot stage the upload']);
    @chmod($tmp, 0600);
    file_put_contents($tmp, $arch);
    $eo = []; $erc = 0;
    rj_engine('import-jobs ' . $mode . ' ' . escapeshellarg($tmp), $eo, $erc);
    @unlink($tmp); /* the engine consumes it; belt and braces */
    $bj = json_decode(implode("\n", $eo), true);
    if (!is_array($bj) || !isset($bj['ok'])) rj_out(['ok' => false, 'error' => 'bad import response (rc ' . $erc . ')']);
    if ($bj['ok'] && ((int)($bj['added'] ?? 0) + (int)($bj['replaced'] ?? 0)) > 0) {
        $rg = []; rj_regen($rg);
        $bj['regen'] = implode(' ', $rg);
    }
    rj_out($bj);

case 'history':
    /* last N live runs of one job (ts, rc, secs, transferred, bytes) for the
       Jobs-tab trend panel; n is range-checked here and again in the engine */
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    $hn = rj_num($_POST['n'] ?? 20);
    if ($hn < 1 || $hn > 600) $hn = 20;
    $eo = []; $erc = 0;
    rj_engine('history ' . escapeshellarg($name) . ' ' . $hn, $eo, $erc);
    $bj = json_decode(implode("\n", $eo), true);
    if (!is_array($bj) || !isset($bj['ok'])) rj_out(['ok' => false, 'error' => 'bad history response (rc ' . $erc . ')']);
    rj_out($bj);

case 'run_job':
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    rj_engine('run ' . escapeshellarg($name), $o, $r, true);
    rj_out(['ok' => true, 'msg' => 'Started in background - the Jobs table updates live when it starts and finishes.']);

case 'stop_job':
    /* stop a live run: the engine verifies lock + cmdline before signaling
       anything, so a recycled pid can never be killed from here */
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    $eo = []; $erc = 0;
    rj_engine('stop ' . escapeshellarg($name), $eo, $erc);
    $bj = json_decode(implode("\n", $eo), true);
    if (!is_array($bj) || !isset($bj['ok'])) rj_out(['ok' => false, 'error' => 'bad stop response (rc ' . $erc . ')']);
    rj_out($bj);

case 'status_json':
    /* no job parameter: the whole status map for the live (SSE-triggered or 60 s
       fallback) refresh of the Jobs table; the engine emits exactly one JSON */
    $eo = []; $erc = 0;
    rj_engine('status-json', $eo, $erc);
    $bj = json_decode(implode("\n", $eo), true);
    if (!is_array($bj) || !isset($bj['ok'])) rj_out(['ok' => false, 'error' => 'bad status response (rc ' . $erc . ')']);
    rj_out($bj);

case 'ack_job':
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    if (($_POST['confirm'] ?? '') !== $name) rj_out(['ok' => false, 'error' => 'confirmation text did not match the job name']);
    $eo = []; $erc = 0;
    rj_engine('ack ' . escapeshellarg($name), $eo, $erc);
    rj_out(['ok' => $erc === 0, 'out' => implode("\n", $eo), 'rc' => $erc]);

case 'save_alerts':
    $pairs = [];
    if (isset($_POST['master'])) {
        $m = rj_str($_POST['master']) === 'no' ? 'no' : 'yes';
        rj_env_upsert($RJ_BOOT.'/paths.env', ['DRY_RUN_MASTER' => $m], 0600);
    }
    $qs = trim(rj_str($_POST['quiet_start'] ?? '')); $qe = trim(rj_str($_POST['quiet_end'] ?? ''));
    $qp = [];
    /* same shape the engine's quiet_now() accepts (single-digit hour allowed) */
    if (!preg_match('/^([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$/', $qs) && $qs !== '') rj_out(['ok' => false, 'error' => 'quiet window start must be HH:MM (24h) or empty']);
    if (!preg_match('/^([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$/', $qe) && $qe !== '') rj_out(['ok' => false, 'error' => 'quiet window end must be HH:MM (24h) or empty']);
    $qp['QUIET_START'] = $qs; $qp['QUIET_END'] = $qe;
    /* retention: same clamps as the engine's num_clamp(); out-of-range input is
       clamped silently (the field hints show the allowed range) */
    $retmap = [
        'HISTORY_RAW_HOURS'  => ['raw_hours',  24, 1, 168],
        'HISTORY_RAW_MAX'    => ['raw_max',    500, 20, 5000],
        'HISTORY_HOUR_DAYS'  => ['hour_days',  7, 1, 60],
        'HISTORY_DAYS'       => ['hist_days',  90, 7, 365],
        'LOG_KEEP_DAYS'      => ['log_days',   3, 1, 90],
        'LOG_KEEP_FAIL_DAYS' => ['fail_days',  14, 1, 90],
        'LOG_KEEP_MAX'       => ['log_max',    300, 20, 20000],
    ];
    foreach ($retmap as $envkey => $spec) {
        if (!isset($_POST[$spec[0]])) continue;
        $v = preg_match('/^\d{1,5}$/', trim(rj_str($_POST[$spec[0]]))) ? intval(trim(rj_str($_POST[$spec[0]]))) : $spec[1];
        $qp[$envkey] = strval(max($spec[2], min($spec[3], $v)));
    }
    if (intval($qp['HISTORY_DAYS'] ?? 90) < intval($qp['HISTORY_HOUR_DAYS'] ?? 7)) $qp['HISTORY_DAYS'] = $qp['HISTORY_HOUR_DAYS'];
    if (intval($qp['LOG_KEEP_FAIL_DAYS'] ?? 14) < intval($qp['LOG_KEEP_DAYS'] ?? 3)) $qp['LOG_KEEP_FAIL_DAYS'] = $qp['LOG_KEEP_DAYS'];
    rj_env_upsert($RJ_BOOT.'/paths.env', $qp, 0600);
    rj_out(['ok' => true, 'msg' => 'Settings saved. Delivery (email/Telegram/...) is configured in Settings -> Notification Settings.']);

case 'notify_test':
    $lvl = rj_str($_POST['level'] ?? 'normal');
    if (!in_array($lvl, ['normal', 'warning', 'alert'], true)) $lvl = 'normal';
    $eo = []; $erc = 0;
    rj_engine('notify-test ' . $lvl, $eo, $erc);
    rj_out(['ok' => $erc === 0, 'out' => implode("\n", $eo), 'rc' => $erc]);

case 'doctor':
    $args = 'doctor' . (($_POST['notify'] ?? '') === 'yes' ? ' --notify' : '');
    $eo = []; $erc = 0;
    rj_engine($args, $eo, $erc);
    rj_out(['ok' => $erc === 0, 'out' => implode("\n", $eo), 'rc' => $erc]);

default:
    http_response_code(400);
    rj_out(['ok' => false, 'error' => 'unknown action']);
}
