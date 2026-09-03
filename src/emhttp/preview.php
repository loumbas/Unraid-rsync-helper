<?php
/*
 * rclone-jobs preview renderer - turns rclone/rsync dry-run logs into a
 * structured report (JSON for status/<job>-dryrun.json, text for humans).
 * Used by the engine via PHP CLI and by the WebUI via include.
 *
 * License: GPL-2.0-or-later. PHP 8.x clean.
 * CLI: preview.php --mode json|text [--engine rclone|rsync] [--rc N]
 *                   [--empty-dest yes|no] <logfile>
 */

function rj_preview_parse(string $file, string $engine): array
{
    $r = ['copies' => 0, 'news' => 0, 'updates' => 0, 'skips' => 0, 'deletes' => 0,
          'fails' => 0, 'other' => 0, 'bytes' => '', 'delete_samples' => [],
          'fail_samples' => [], 'emptyDest' => false, 'fatal' => '', 'ok' => false];
    if (!is_readable($file)) {
        $r['fatal'] = 'dry-run log not readable';
        return $r;
    }
    $fp = fopen($file, 'r');
    if ($fp === false) {
        $r['fatal'] = 'dry-run log could not be opened';
        return $r;
    }
    $newsDbg = 0; $deletesSum = -1; $copiesSum = -1; $skipsSum = -1;
    $transBytesRe = '/^\s*Transferred:\s+([0-9.]+ ?(?:[KMGTPE]i?)?B)/i';
    $transFilesRe = '/^\s*Transferred:\s+(\d+) \/ (\d+)/';
    $deletedSumRe = '/^\s*Deleted:\s+(\d+) \(files\)/';
    $checksRe     = '/^\s*Checks:\s+(\d+) \/ \d+/';
    while (($line = fgets($fp)) !== false) {
        $line = rtrim($line, "\r\n");
        if ($engine === 'rsync') {
            if (preg_match('/^(deleting |\*deleting\b)/', $line)) {
                $r['deletes']++;
                if (count($r['delete_samples']) < 25) { $r['delete_samples'][] = substr(trim(substr($line, strlen('deleting '))), 0, 300); }
            } elseif (preg_match('/^[<>.chLpgoatD*+.][f.dD][c^+][sA-Za-z.][i.][x+.][pP][oO][gG][tTuU]/', $line)) {
                if (str_starts_with($line, '<f+++++++++')) { $r['copies']++; $r['news']++; }
                elseif ($line[0] === '<')                 { $r['copies']++; $r['updates']++; }
                elseif ($line[0] === '.')                 { $r['skips']++; }
                else                                      { $r['other']++; }
            } elseif (preg_match('/ERROR/i', $line)) {
                $r['fails']++;
                if (count($r['fail_samples']) < 10) { $r['fail_samples'][] = substr($line, 0, 300); }
            } elseif (preg_match($transBytesRe, $line, $m)) {
                $r['bytes'] = trim($m[1]);
            }
            continue;
        }
        // rclone - markers verified against REAL v1.75.0 '-vv --dry-run' output:
        //   NOTICE: <file>: Skipped copy as --dry-run is set (size N)
        //   NOTICE: <file>: Skipped delete as --dry-run is set (size N)
        //   summary: Transferred:/Deleted: N (files)/Checks: lines at column 0
        if (preg_match('/^\s*Transferred:\s+[0-9.]+ ?(?:[KMGTPE]i?)?B/', $line)) {
            if ($r['bytes'] === '' && preg_match($transBytesRe, $line, $m)) { $r['bytes'] = trim($m[1]); }
        } elseif (preg_match($transFilesRe, $line, $m)) {
            $copiesSum = (int)$m[2];
        } elseif (preg_match($deletedSumRe, $line, $m)) {
            $deletesSum = (int)$m[1];
        } elseif (preg_match($checksRe, $line, $m)) {
            $skipsSum = (int)$m[1];
        } elseif (preg_match('/ ERROR /', $line)) {
            $r['fails']++;
            if (count($r['fail_samples']) < 10) { $r['fail_samples'][] = substr($line, 0, 300); }
        } elseif (preg_match("/Can't copy/i", $line)) {
            $r['fails']++;
            if (count($r['fail_samples']) < 10) { $r['fail_samples'][] = substr($line, 0, 300); }
        } elseif (preg_match('/NOTICE: (.+?): Skipped delete as --dry-run/i', $line, $m)) {
            $r['deletes']++;
            if (count($r['delete_samples']) < 25) { $r['delete_samples'][] = substr(trim($m[1]), 0, 300); }
        } elseif (preg_match('/Skipped (mkdir|delete dir|set directory)/i', $line)) {
            // directory bookkeeping - not a file operation, counted nowhere
        } elseif (preg_match('/NOTICE: .*: Skipped copy as --dry-run/i', $line)) {
            $r['copies']++;
        } elseif (preg_match('/File not found at Destination/', $line)) {
            $newsDbg++;
        } elseif (preg_match('/\bCopied\b/', $line)) {
            $r['copies']++;
            if (stripos($line, '(new)') !== false) { $r['news']++; } else { $r['updates']++; }
        } elseif ($line !== '') {
            $r['other']++;
        }
    }
    fclose($fp);
    // summary lines are authoritative when present
    if ($engine === 'rclone') {
        if ($deletesSum >= 0) { $r['deletes'] = $deletesSum; }
        if ($copiesSum >= 0 && $r['copies'] === 0) { $r['copies'] = $copiesSum; }
        if ($skipsSum >= 0)   { $r['skips'] = $skipsSum; }
        if ($r['news'] === 0 && $newsDbg > 0) { $r['news'] = $newsDbg; }
        if ($r['news'] > $r['copies']) { $r['news'] = $r['copies']; }
        $r['updates'] = $r['copies'] - $r['news'];
    }
    // emptyDest is decided ONLY by the engine (--empty-dest: local destination
    // exists but is empty). A log-based heuristic would false-positive whenever
    // source and destination simply share no filenames.
    return $r;
}

function rj_preview_text(array $r, int $rc, bool $emptyDestArg, int $warnDelete): string
{
    $out = [];
    $out[] = 'DRY RUN - nothing was changed';
    $out[] = 'will copy     : ' . $r['copies'] . ($r['bytes'] !== '' ? '  (' . $r['bytes'] . ')' : '');
    $out[] = '  of which new: ' . $r['news'] . ', updates: ' . $r['updates'];
    $out[] = 'will skip     : ' . $r['skips'];
    $out[] = 'will DELETE   : ' . $r['deletes'];
    $out[] = 'will fail     : ' . $r['fails'] . '  (fix these before the real run)';
    $out[] = 'unparsed lines: ' . $r['other'];
    if ($r['deletes'] > 0) {
        $out[] = '';
        $out[] = '--- deletions (max 25) ---';
        foreach ($r['delete_samples'] as $s) { $out[] = '  DELETE  ' . $s; }
    }
    if ($r['fails'] > 0) {
        $out[] = '';
        $out[] = '--- will-fail samples ---';
        foreach ($r['fail_samples'] as $s) { $out[] = '  FAIL  ' . $s; }
    }
    if ($r['emptyDest'] || $emptyDestArg) {
        $out[] = '';
        $out[] = '*** WARNING: destination looks EMPTY or new - a live sync would now mirror the source onto it.';
        $out[] = '*** If the source is wrong or partially missing, this is exactly how destinations get wiped.';
        $out[] = '*** Check SRC and DST before ever running live.';
    }
    if ($warnDelete > 0 && $r['deletes'] > $warnDelete) {
        $out[] = '';
        $out[] = '*** RED BLOCK: this run would DELETE ' . $r['deletes'] . ' files (threshold WARN_DELETE=' . $warnDelete . ').';
        $out[] = '*** The live [Run] button stays blocked until you acknowledge this number.';
    }
    if ($rc !== 0) {
        $out[] = '';
        $out[] = '*** Dry-run exited with code ' . $rc . ' - treat the source/destination state as UNRELIABLE.';
    }
    return implode("\n", $out) . "\n";
}

if (PHP_SAPI === 'cli') {
    $mode = 'json'; $engine = 'rclone'; $rc = 0; $ed = false; $file = '';
    $argv0 = array_shift($argv);
    while (count($argv) > 0) {
        $a = array_shift($argv);
        if ($a === '--mode')        { $mode = (string)array_shift($argv); }
        elseif ($a === '--engine')  { $engine = (string)array_shift($argv); }
        elseif ($a === '--rc')      { $rc = (int)array_shift($argv); }
        elseif ($a === '--empty-dest') { $ed = ((string)array_shift($argv)) === 'yes'; }
        else                        { $file = $a; }
    }
    if ($file === '' || !is_readable($file)) { fwrite(STDERR, "preview.php: unreadable log file\n"); exit(2); }
    $r = rj_preview_parse($file, $engine);
    $r['ok'] = ($rc === 0 && $r['fails'] === 0 && $r['fatal'] === '');
    $r['rc'] = $rc;
    $r['engine'] = $engine;
    if ($ed) { $r['emptyDest'] = true; }
    if ($mode === 'text') {
        echo rj_preview_text($r, $rc, $ed, 0);
    } else {
        echo json_encode($r, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), "\n";
    }
    exit(0);
}
