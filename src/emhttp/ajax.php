<?php
/* rclone-jobs v{{VERSION}} - ajax endpoint. POST + CSRF only.
   Every engine/config mutation goes through the whitelisted validators below;
   values are written as plain KEY=VALUE config lines and are NEVER shell-eval'd. */

$RJ_PLUGIN = '/usr/local/emhttp/plugins/rclone-jobs';
$RJ_BOOT   = '/boot/config/plugins/rclone-jobs';
$RJ_ENGINE = $RJ_PLUGIN.'/engine/rclone-jobs.sh';
$RJ_REGEN  = $RJ_PLUGIN.'/scripts/regen-cron.sh';

header('Content-Type: application/json');

/* ---- transport security ---- */
$ini  = @parse_ini_file('/var/local/emhttp/var.ini');
$tokS = $_SERVER['HTTP_X_CSRF_TOKEN'] ?? '';
$tokP = $_POST['csrf_token'] ?? '';
$tok  = is_string($tokP) && $tokP !== '' ? $tokP : (is_string($tokS) ? $tokS : '');
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
function rj_sched_ok($s) {
    if (!is_string($s) || $s === '') return false;
    $f = preg_split('/\s+/', trim($s));
    if (count($f) !== 5) return false;
    foreach ($f as $x) if (!preg_match('#^[0-9*,-/]+$#', $x)) return false;
    return true;
}
function rj_read_env($file) {
    $out = [];
    if (!is_readable($file)) return $out;
    foreach (file($file, FILE_IGNORE_NEW_LINES) as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#' || strpos($line, '=') === false) continue;
        list($k, $v) = explode('=', $line, 2);
        $out[trim($k)] = trim($v, " \t\"");
    }
    return $out;
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
function rj_storage() {
    $p = rj_read_env('/boot/config/plugins/rclone-jobs/paths.env');
    $s = $p['STORAGE_ROOT'] ?? '';
    if ($s === '') {
        foreach (glob('/mnt/disk[0-9]*') as $d) {
            $src = trim((string)@shell_exec('findmnt -no SOURCE -T ' . escapeshellarg($d) . ' 2>/dev/null'));
            if (strpos($src, '/dev/md') === 0) { $s = $d.'/.rclone-jobs'; break; }
        }
    }
    return $s;
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
        if ($sched === '' || rj_sched_ok($sched) === false) rj_out(['ok' => false, 'error' => 'schedule must be 5 cron fields (numbers, * , - / only)']);
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

    $stor = rj_storage();
    if ($stor === '') rj_out(['ok' => false, 'error' => 'storage folder not available - start the array']);
    @mkdir($stor, 0700, true);
    $np = [];
    if (isset($_POST['tg_enabled'])) $np['TG_ENABLED'] = $_POST['tg_enabled'] === 'yes' ? 'yes' : 'no';
    if (isset($_POST['tg_chat_id'])) {
        $cid = trim((string)$_POST['tg_chat_id']);
        if ($cid !== '' && !preg_match('/^[0-9-]{1,32}$/', $cid)) rj_out(['ok' => false, 'error' => 'chat id must be numeric (may start with -)']);
        $np['TG_CHAT_ID'] = $cid;
    }
    $token = (string)($_POST['tg_token'] ?? '');
    if ($token !== '') {
        if (!preg_match('/^[0-9]{6,}:[A-Za-z0-9_-]{20,}$/', $token)) rj_out(['ok' => false, 'error' => 'bot token format unexpected (digits:secret)']);
        $np['TG_TOKEN'] = $token;
    }
    if ($np) rj_env_upsert($stor.'/notify.env', $np, 0600);
    rj_out(['ok' => true, 'msg' => 'Settings saved (token ' . ($token !== '' ? 'updated' : 'unchanged') . ').']);

case 'tg_test':
    $eo = []; $erc = 0;
    rj_engine('doctor --telegram', $eo, $erc);
    $line = '';
    foreach ($eo as $l) if (stripos($l, 'telegram') !== false) $line .= $l."\n";
    rj_out(['ok' => true, 'out' => trim($line) !== '' ? trim($line) : 'no telegram result']);

case 'doctor':
    $args = 'doctor' . (($_POST['telegram'] ?? '') === 'yes' ? ' --telegram' : '');
    $eo = []; $erc = 0;
    rj_engine($args, $eo, $erc);
    rj_out(['ok' => $erc === 0, 'out' => implode("\n", $eo), 'rc' => $erc]);

default:
    http_response_code(400);
    rj_out(['ok' => false, 'error' => 'unknown action']);
}
