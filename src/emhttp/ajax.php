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
    /* charset rule of the engine (valid_schedule) plus per-field ranges:
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
    file_put_contents($file, implode("\n", $lines)."\n");
    if ($mode !== null) @chmod($file, $mode);
}
function rj_engine($args, &$out = null, &$rc = null, $bg = false) {
    $cmd = '/bin/bash ' . escapeshellarg($GLOBALS['RJ_ENGINE']) . ' ' . $args;
    if ($bg) { exec($cmd . ' > /dev/null 2>&1 &', $o, $r); $out = []; $rc = 0; return; }
    exec($cmd . ' 2>&1', $o, $r); $out = $o; $rc = $r;
}
function rj_regen(&$out) {
    exec('/bin/bash ' . escapeshellarg($GLOBALS['RJ_REGEN']) . ' 2>&1', $out, $rc);
    return $rc;
}

$action = $_POST['action'] ?? '';
$name   = $_POST['job'] ?? '';

switch ($action) {

case 'save_job':
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name (letters, digits, dash, underscore, max 40)']);
    $engine   = $_POST['engine'] ?? 'rclone';
    if (!in_array($engine, ['rclone', 'rsync', 'custom'], true)) rj_out(['ok' => false, 'error' => 'engine must be rclone|rsync|custom']);
    $mode     = $_POST['mode'] ?? '';
    $src      = trim((string)($_POST['src'] ?? ''));
    $dst      = trim((string)($_POST['dst'] ?? ''));
    $script   = trim((string)($_POST['script'] ?? ''));
    $sched    = trim((string)($_POST['schedule'] ?? ''));
    $enabled  = ($_POST['enabled'] ?? 'yes') === 'no' ? 'no' : 'yes';
    $dryrun   = ($_POST['dryrun'] ?? 'yes') === 'no' ? 'no' : 'yes';
    $notify   = in_array($_POST['notify'] ?? 'always', ['always', 'failures', 'off'], true) ? $_POST['notify'] : 'always';
    $desc     = substr(trim((string)($_POST['desc'] ?? '')), 0, 120);
    $trans    = (int)($_POST['transfers'] ?? 4);
    $check    = (int)($_POST['checkers'] ?? 8);
    $bwlimit  = trim((string)($_POST['bwlimit'] ?? ''));
    $maxdel   = (int)($_POST['maxdelete'] ?? 100);
    $warndel  = (int)($_POST['warndelete'] ?? 100);
    $bdir     = trim((string)($_POST['backupdir'] ?? ''));
    if (rj_badfield($desc) || rj_badfield($bwlimit) || rj_badfield($bdir))
        rj_out(['ok' => false, 'error' => 'description/limit/backupdir contain forbidden characters']);

    if ($engine === 'custom') {
        if ($script === '' || rj_badfield($script)) rj_out(['ok' => false, 'error' => 'custom job needs a Script path without shell metacharacters']);
        if (strpos($script, '/') !== 0) rj_out(['ok' => false, 'error' => 'Script must be an absolute path']);
        $mode = ''; $src = ''; $dst = ''; $schedOrig = $sched;
    } else {
        if ($sched === '' || rj_sched_ok($sched) === false) rj_out(['ok' => false, 'error' => 'invalid schedule: 5 cron fields expected (minute 0-59, hour 0-23, day 1-31, month 1-12, weekday 0-7; * , - / allowed)']);
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
    if ($engine !== 'custom') {
        $L[] = "TRANSFERS=$trans"; $L[] = "CHECKERS=$check";
        if ($bwlimit !== '') $L[] = "BWLIMIT=$bwlimit";
        $L[] = "MAXDELETE=$maxdel"; $L[] = "WARN_DELETE=$warndel";
        if ($bdir !== '') $L[] = "BACKUPDIR=$bdir";
    }
    $conf = $RJ_BOOT.'/jobs/'.$name.'.conf';
    $isNew = !file_exists($conf);
    file_put_contents($conf, implode("\n", $L)."\n");
    chmod($conf, 0600);

    /* dry-run the saved config once so the UI shows a real preview immediately */
    $eo = []; $erc = 0;
    rj_engine('preview ' . escapeshellarg($name), $eo, $erc);
    $rg = []; rj_regen($rg);
    rj_out(['ok' => true, 'msg' => ($isNew ? 'Job created. ' : 'Job updated. ') . implode(' ', $rg),
            'preview' => implode("\n", $eo), 'preview_rc' => $erc]);

case 'delete_job':
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    $conf = $RJ_BOOT.'/jobs/'.$name.'.conf';
    if (!is_file($conf)) rj_out(['ok' => false, 'error' => 'job not found']);
    $bk = $conf.'.removed-'.trim((string)shell_exec("date +%Y%m%d-%H%M%S"));  # system TZ, not PHP UTC
    rename($conf, $bk);
    $rg = []; rj_regen($rg);
    rj_out(['ok' => true, 'msg' => 'Job deleted (config kept as '.$bk.') '.implode(' ', $rg)]);

case 'run_dry':
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    $eo = []; $erc = 0;
    rj_engine('preview ' . escapeshellarg($name), $eo, $erc);
    rj_out(['ok' => true, 'out' => implode("\n", $eo), 'rc' => $erc]);

case 'browse':
    /* read-only path picker listing; all confinement happens in the engine */
    $bscope = ($_POST['scope'] ?? '') === 'rclone' ? 'rclone' : 'local';
    $bpath  = trim((string)($_POST['path'] ?? ''));
    if ($bpath !== '' && rj_badfield($bpath)) rj_out(['ok' => false, 'error' => 'path contains forbidden characters']);
    if (strlen($bpath) > 1024) rj_out(['ok' => false, 'error' => 'path too long']);
    if ($bscope === 'local' && $bpath !== '' && $bpath[0] !== '/') rj_out(['ok' => false, 'error' => 'local paths must start with /']);
    $eo = []; $erc = 0;
    rj_engine('browse ' . escapeshellarg($bscope) . ' ' . escapeshellarg($bpath)
              . (($_POST['files'] ?? '') === '1' ? ' files' : ''), $eo, $erc);
    $bj = json_decode(implode("\n", $eo), true);
    if (!is_array($bj) || !isset($bj['ok'])) rj_out(['ok' => false, 'error' => 'bad browse response (rc ' . $erc . ')']);
    rj_out($bj);

case 'run_job':
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    rj_engine('run ' . escapeshellarg($name), $o, $r, true);
    rj_out(['ok' => true, 'msg' => 'Started in background - status updates within a minute (see Last run column after reload).']);

case 'ack_job':
    if (!rj_name_ok($name)) rj_out(['ok' => false, 'error' => 'invalid job name']);
    if (($_POST['confirm'] ?? '') !== $name) rj_out(['ok' => false, 'error' => 'confirmation text did not match the job name']);
    $eo = []; $erc = 0;
    rj_engine('ack ' . escapeshellarg($name), $eo, $erc);
    rj_out(['ok' => $erc === 0, 'out' => implode("\n", $eo), 'rc' => $erc]);

case 'save_alerts':
    $pairs = [];
    if (isset($_POST['master'])) {
        $m = $_POST['master'] === 'no' ? 'no' : 'yes';
        rj_env_upsert($RJ_BOOT.'/paths.env', ['DRY_RUN_MASTER' => $m], 0600);
    }
    $qs = trim((string)($_POST['quiet_start'] ?? '')); $qe = trim((string)($_POST['quiet_end'] ?? ''));
    $qp = [];
    if ($qs === '' || preg_match('/^([01][0-9]|2[0-3]):[0-5][0-9]$/', $qs)) $qp['QUIET_START'] = $qs;
    if ($qe === '' || preg_match('/^([01][0-9]|2[0-3]):[0-5][0-9]$/', $qe)) $qp['QUIET_END'] = $qe;
    if ($qp) rj_env_upsert($RJ_BOOT.'/paths.env', $qp, 0600);
    rj_out(['ok' => true, 'msg' => 'Settings saved. Delivery (email/Telegram/...) is configured in Settings -> Notification Settings.']);

case 'notify_test':
    $lvl = (string)($_POST['level'] ?? 'normal');
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
