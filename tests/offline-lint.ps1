# tests/offline-lint.ps1 - offline build lint for rclone-jobs.
# Works on Windows PowerShell 5.1 and PowerShell 7+. No external modules.
# Usage:
#   offline-lint.ps1 -Root <repoRoot>            # source-tree checks only
#   offline-lint.ps1 -Root <repoRoot> -Plg <dist/rclone-jobs.plg>   # + built-plugin checks
# Exit 0 = green, 1 = findings (build.ps1 aborts on non-zero).
[CmdletBinding()]
param(
    [string]$Root = ".",
    [string]$Plg = "",
    [switch]$SrcOnly
)
$ErrorActionPreference = 'Stop'

$script:Fails   = New-Object System.Collections.ArrayList
$script:Passes  = 0

function Add-Fail([string]$m) { [void]$script:Fails.Add($m); Write-Host "FAIL  $m" }
function Add-Pass([string]$m) { $script:Passes++; Write-Host "PASS  $m" }

function Read-Text([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}
function Test-Bom([string]$Path) {
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $b = New-Object byte[] 3
        $n = $fs.Read($b, 0, 3)
        return ($n -eq 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    } finally { $fs.Dispose() }
}
function ToRel([string]$Path) { return ($Path -replace '\\', '/') }

$Root    = (Resolve-Path -LiteralPath $Root).Path
$srcRoot = Join-Path $Root 'src'
if (-not (Test-Path -LiteralPath $srcRoot)) { Add-Fail "src/ not found under $Root"; exit 1 }

# ---------------------------------------------------------------- manifest --
$manPath = Join-Path $srcRoot 'MANIFEST'
$entries = @()
if (-not (Test-Path -LiteralPath $manPath)) {
    Add-Fail "src/MANIFEST missing"
} else {
    $ln = 0
    foreach ($line in [System.IO.File]::ReadAllLines($manPath)) {
        $ln++
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($line.Contains("`r")) { Add-Fail "MANIFEST line $ln contains CR"; continue }
        $parts = $t -split '\s+'
        if ($parts.Count -ne 3) { Add-Fail "MANIFEST line ${ln}: expected 3 fields, got $($parts.Count): $t"; continue }
        if ($parts[0] -notmatch '^[A-Za-z0-9._/-]+$') { Add-Fail "MANIFEST line ${ln}: bad src path '$($parts[0])'" }
        if ($parts[1] -notmatch '^/usr/local/emhttp/plugins/rclone-jobs/') { Add-Fail "MANIFEST line ${ln}: target must start with /usr/local/emhttp/plugins/rclone-jobs/ : $($parts[1])" }
        if ($parts[2] -notmatch '^0[0-7]{3}$') { Add-Fail "MANIFEST line ${ln}: bad mode '$($parts[2])' (expect 0NNN octal)" }
        $entries += [pscustomobject]@{ Src = $parts[0]; Target = $parts[1]; Mode = $parts[2] }
    }
    if ($script:Fails.Count -eq 0) { Add-Pass "MANIFEST parses ($($entries.Count) entries)" }
}

# ---------------------------------------------------- two-way coverage ------
$manifestSrc = @($entries | ForEach-Object { ToRel $_.Src })
$treeFiles   = @()
foreach ($d in @('engine', 'emhttp', 'jobs')) {
    $full = Join-Path $srcRoot $d
    if (Test-Path -LiteralPath $full) {
        Get-ChildItem -LiteralPath $full -Recurse -File | ForEach-Object {
            $rel = ToRel $_.FullName.Substring($srcRoot.Length + 1)
            $treeFiles += $rel
        }
    }
}
$missingFromManifest = @($treeFiles | Where-Object { $manifestSrc -notcontains $_ })
$missingFromTree     = @($manifestSrc | Where-Object { -not (Test-Path -LiteralPath (Join-Path $srcRoot ($_.Replace('/', [IO.Path]::DirectorySeparatorChar)))) })
if ($missingFromManifest.Count -eq 0 -and $missingFromTree.Count -eq 0) {
    Add-Pass "manifest <-> tree two-way coverage ($($treeFiles.Count) package files)"
} else {
    foreach ($m in $missingFromManifest) { Add-Fail "tree file not referenced by MANIFEST (and therefore not by the .plg): src/$m" }
    foreach ($m in $missingFromTree)     { Add-Fail "MANIFEST references file not in tree: src/$m" }
}

# ------------------------------------------------ per-source-file hygiene ---
# Scan the WHOLE src tree (plus plg.in and VERSION), not just manifest entries:
# orphan files must not hide hygiene problems from a later phase.
$hygieneFiles = @($treeFiles) + @('rclone-jobs.plg.in', 'VERSION')
$bomSeen = @(); $crSeen = @()
foreach ($rel in $hygieneFiles) {
    $p = Join-Path $srcRoot ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $p)) { continue }
    if (Test-Bom $p) { $bomSeen += $rel }
    if ((Read-Text $p).Contains("`r")) { $crSeen += $rel }
}
if ($bomSeen.Count -eq 0) { Add-Pass "no UTF-8 BOM in any source file" } else { foreach ($b in $bomSeen) { Add-Fail "UTF-8 BOM found: src/$b" } }
if ($crSeen.Count -eq 0)  { Add-Pass "no CR (CRLF) in any source file" }  else { foreach ($c in $crSeen)  { Add-Fail "CR found (must be LF-only): src/$c" } }

# shebangs: *.sh and everything under emhttp/event/
$shebBad = @(); $shebN = 0
foreach ($rel in $hygieneFiles) {
    $isScript = $rel.EndsWith('.sh') -or $rel.StartsWith('emhttp/event/')
    if (-not $isScript) { continue }
    $shebN++
    $p = Join-Path $srcRoot ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $first = ([IO.File]::ReadAllLines($p) | Select-Object -First 1)
    if ($first -notlike '#!*') { $shebBad += "$rel (first line: '$first')" }
}
if ($shebN -eq 0) { Add-Pass "shebang check (no script files yet - vacuous)" }
elseif ($shebBad.Count -eq 0) { Add-Pass "shebang on every script/event file ($shebN)" }
else { foreach ($s in $shebBad) { Add-Fail "missing shebang: src/$s" } }

# .page header
$pages = @($treeFiles | Where-Object { $_ -like '*.page' })
foreach ($rel in $pages) {
    $p = Join-Path $srcRoot ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $txt = Read-Text $p
    $lines = $txt -split "`n"
    if ($lines[0] -notmatch '^Menu=') { Add-Fail "$rel : first line must be a Menu= metadata line" }
    elseif ($lines -notcontains '---') { Add-Fail "$rel : missing '---' header separator" }
    else { Add-Pass "$rel metadata header ok" }
}

# PHP sanity (PHP 8.x): opening tag present; dead PHP4/5 constructs absent
$phps = @($treeFiles | Where-Object { $_ -like '*.php' })
foreach ($rel in $phps) {
    $p = Join-Path $srcRoot ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $txt = Read-Text $p
    if ($txt.Length -lt 5 -or $txt.Substring(0, [Math]::Min(64, $txt.Length)) -notmatch '<\?') { Add-Fail "$rel : no <? opening tag near top" }
    if ($txt -match '\beach\s*\(')   { Add-Fail "$rel : each() is removed in PHP 8" }
    if ($txt -match 'create_function\s*\(') { Add-Fail "$rel : create_function() is removed in PHP 8" }
}
if ($phps.Count -gt 0 -and $script:Fails.Count -eq 0) { Add-Pass "PHP files present and PHP8-clean by heuristic ($($phps.Count))" }

# conf.example sanity: KEY=VALUE lines
$confs = @($treeFiles | Where-Object { $_ -like 'jobs/*' })
foreach ($rel in $confs) {
    $p = Join-Path $srcRoot ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $bad = 0
    foreach ($line in ([IO.File]::ReadAllLines($p))) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t -notmatch '^[A-Z][A-Z0-9_]*=') { Add-Fail "$rel : non KEY=VALUE line: $t"; $bad++ }
    }
    if ($bad -eq 0) { Add-Pass "$rel parses as KEY=VALUE" }
}

# ------------------------------------------- dev-path / secret leak scans ---
# Scan set: everything that ships (manifest files + plg.in). Dev-only files
# (build.ps1, INSTALL.md) legitimately mention Windows paths / the host name.
$devPathPats = @('C:\\', '/mnt/c/', 'loumpardias', 'LMBS-SRV')
$devHits = 0
foreach ($rel in $hygieneFiles) {
    $p = Join-Path $srcRoot ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $txt = Read-Text $p
    foreach ($pat in $devPathPats) {
        if ($txt.Contains($pat)) { Add-Fail "dev-machine path '$pat' appears in shipped file src/$rel"; $devHits++ }
    }
}
if ($devHits -eq 0) { Add-Pass "no dev-machine paths in shipped files" }

# secret scan: TG_<TOKEN> with a non-empty value anywhere in the repo (spec rule).
# Pattern built by concatenation so this file never matches itself.
$tgPat = ('TG_' + 'TOKEN\s*=\s*["'' ]*[^''"\s#]')
$tgHits = 0
$excludeNames = @('offline-lint.ps1')
Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
    ($_.FullName -notmatch '\\\.git\\') -and ($excludeNames -notcontains $_.Name)
} | ForEach-Object {
    $ext = $_.Extension.ToLower()
    if (@('.png', '.jpg', '.gif', '.ico', '.zip', '.txz') -contains $ext) { return }
    $txt = Read-Text $_.FullName
    foreach ($m in [regex]::Matches($txt, $tgPat)) {
        Add-Fail ("possible Telegram token value in " + (ToRel $_.FullName.Substring($Root.Length + 1)) + " - secrets must only ever live in `$STORAGE_ROOT/notify.env")
        $tgHits++
    }
}
if ($tgHits -eq 0) { Add-Pass "no TG_*TOKEN*= with value anywhere in repo" }

# ------------------------------------------------------------ plg.in shape --
$plgIn = Join-Path $srcRoot 'rclone-jobs.plg.in'
if (Test-Path -LiteralPath $plgIn) {
    $txt = Read-Text $plgIn
    $okShape = $true
    if ($txt -notmatch '<!ENTITY\s+name\s+"rclone-jobs">') { Add-Fail "plg.in: plugin name entity is not rclone-jobs"; $okShape = $false }
    foreach ($ph in @('{{VERSION}}', '{{CHANGES}}', '{{FILES}}')) {
        if (-not $txt.Contains($ph)) { Add-Fail "plg.in: missing build placeholder $ph"; $okShape = $false }
    }
    if ($okShape) { Add-Pass "plg.in shape ok (name entity + placeholders)" }
} else { Add-Fail "src/rclone-jobs.plg.in missing" }

# --------------------------------------------- built-plugin checks (-Plg) ---
$versionPath = Join-Path $srcRoot 'VERSION'
$version = (Read-Text $versionPath).Trim()

if (-not $SrcOnly) {
    if ($Plg -eq '') { $Plg = Join-Path $Root 'dist/rclone-jobs.plg' }
    if (-not (Test-Path -LiteralPath $Plg)) {
        Add-Fail "built plugin not found: $Plg (run build.ps1)"
    } else {
        $txt = Read-Text $Plg
        if (Test-Bom $Plg) { Add-Fail "dist plg has BOM" } else { Add-Pass "dist plg: no BOM" }
        if ($txt.Contains("`r")) { Add-Fail "dist plg contains CR" } else { Add-Pass "dist plg: LF-only" }
        if ($txt -match '\{\{')  { Add-Fail "dist plg contains unsubstituted {{placeholder}}" } else { Add-Pass "dist plg: no unsubstituted placeholders" }
        if ($txt.Contains($version)) { Add-Pass "dist plg carries version $version" } else { Add-Fail "dist plg does not contain version $version" }

        # real XML well-formedness (internal DTD subset allowed, external resolver off):
        # catches unescaped & / < in hand-written INLINE blocks and plg.in edits
        $xmlOk = $true; $xmlErr = ''
        try {
            $xrSet = New-Object System.Xml.XmlReaderSettings
            $xrSet.DtdProcessing = [System.Xml.DtdProcessing]::Parse
            $xrSet.XmlResolver = $null
            $xr = [System.Xml.XmlReader]::Create($Plg, $xrSet)
            try { while ($xr.Read()) {} } finally { $xr.Close() }
        } catch { $xmlOk = $false; $xmlErr = $_.Exception.Message }
        if ($xmlOk) { Add-Pass "dist plg: XML well-formed (entities resolve)" } else { Add-Fail "dist plg XML parse error: $xmlErr" }

        $targetHits = 0
        foreach ($e in $entries) {
            $needle = 'Name="' + $e.Target + '"'
            $n = ([regex]::Matches($txt, [regex]::Escape($needle))).Count
            if ($n -ne 1) { Add-Fail "target $($e.Target) appears $n times in plg (expected exactly 1)" } else { $targetHits++ }
        }
        if ($entries.Count -gt 0 -and $targetHits -eq $entries.Count) { Add-Pass "every manifest target embedded exactly once ($targetHits)" }
        if ($entries.Count -eq 0) { Add-Pass "target embedding check (no entries yet - vacuous)" }

        $badTargets = @()
        foreach ($m in [regex]::Matches($txt, 'Name="([^"]+)"')) {
            $v = $m.Groups[1].Value
            if ($v -notmatch '^/usr/local/emhttp/plugins/rclone-jobs/') { $badTargets += $v }
            $known = @($entries | ForEach-Object { $_.Target })
            if ($known -notcontains $v) { $badTargets += "$v (not in MANIFEST)" }
        }
        if ($badTargets.Count -eq 0) { Add-Pass "every plg target is known and under the plugin dir" }
        else { foreach ($b in $badTargets) { Add-Fail "plg references unknown/foreign target: $b" } }
    }
}

# ---------------------------------------------------------------- summary --
Write-Host ''
if ($script:Fails.Count -gt 0) {
    Write-Host "RESULT: FAIL - $($script:Fails.Count) finding(s), $script:Passes passed"
    exit 1
}
Write-Host "RESULT: PASS - $script:Passes checks green"
exit 0
