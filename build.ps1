# build.ps1 - assemble dist/rclone-jobs.plg from src/ (Windows PowerShell 5.1+, no modules).
# - Normalizes every packaged file: strip BOM, CRLF/CR -> LF, ensure final newline.
# - Stamps version from src/VERSION, injects src/CHANGELOG.md top section, embeds
#   every src/MANIFEST file as an XML-escaped <FILE><INLINE> entry.
# - Runs tests/offline-lint.ps1 BEFORE (source) and AFTER (dist) and fails on findings.
# - Prints a manifest: file, target, mode, bytes, sha256.
# The output must be byte-identical to build.sh (WSL/Git-Bash equivalent).
[CmdletBinding()]
param(
    [string]$Root = ""
)
$ErrorActionPreference = 'Stop'
if ($Root -eq "") { $Root = $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path
$srcRoot = Join-Path $Root 'src'
$distDir = Join-Path $Root 'dist'
$lintPs1 = Join-Path $Root 'tests\offline-lint.ps1'

function Read-NormText([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    } else {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    return $text
}
function ConvertTo-XmlText([string]$s) {
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}
function Get-Sha256Bytes([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($Bytes)
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLower()
    } finally { $sha.Dispose() }
}

Write-Host "== rclone-jobs build =="

# 1. source lint (hard gate)
& $lintPs1 -Root $Root -SrcOnly
if ($LASTEXITCODE -ne 0) { throw "source lint failed - build aborted" }
Write-Host ''

# 2. inputs
$version = (Read-NormText (Join-Path $srcRoot 'VERSION')).Trim()
if ($version -notmatch '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}[a-z]?$') { throw "src/VERSION must be YYYY.MM.DD with optional same-day letter suffix, got: $version" }

# changelog: the last 10 '## ' sections (file is newest-first), up to (exclusive)
# the 11th heading; trailing whitespace stripped per line, trailing newlines stripped.
$maxSections = 10
$clText = Read-NormText (Join-Path $srcRoot 'CHANGELOG.md')
$clLines = $clText -split "`n"
$section = New-Object System.Collections.ArrayList
$started = $false
$heads = 0
foreach ($line in $clLines) {
    if ($line -match '^## ') {
        if ($started) {
            $heads++
            if ($heads -ge $maxSections) { break }
        }
        $started = $true
    }
    if ($started) { [void]$section.Add($line.TrimEnd()) }
}
if (-not $started) { throw "src/CHANGELOG.md has no '## ' section" }
$changes = ((($section | ForEach-Object { $_ }) -join "`n")).TrimEnd("`n")
$changes = ConvertTo-XmlText $changes

# manifest
$entries = @()
$ln = 0
foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $srcRoot 'MANIFEST'))) {
    $ln++
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $parts = $t -split '\s+'
    if ($parts.Count -ne 3) { throw "MANIFEST line $ln malformed: $t" }
    $entries += [pscustomobject]@{ Src = ($parts[0] -replace '\\', '/'); Target = $parts[1]; Mode = $parts[2] }
}

# 3. build <FILE> block + per-file manifest
$fileBlockParts = New-Object System.Collections.ArrayList
$manifestRows = New-Object System.Collections.ArrayList
foreach ($e in $entries) {
    $srcPath = Join-Path $srcRoot ($e.Src.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $srcPath)) { throw "manifest src missing: $srcPath" }
    $norm = Read-NormText $srcPath
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($norm)
    $sha = Get-Sha256Bytes $bytes
    [void]$manifestRows.Add([pscustomobject]@{ Src = $e.Src; Target = $e.Target; Mode = $e.Mode; Bytes = $bytes.Length; Sha256 = $sha })
    $escaped = ConvertTo-XmlText $norm
    $entryText = '  <FILE Name="' + $e.Target + '" Mode="' + $e.Mode + '">' + "`n" +
                 '<INLINE>' + "`n" +
                 $escaped +
                 '</INLINE>' + "`n" +
                 '  </FILE>' + "`n"
    [void]$fileBlockParts.Add($entryText)
}
$fileBlock = ($fileBlockParts -join "`n")

# 4. assemble plg
$tpl = Read-NormText (Join-Path $srcRoot 'rclone-jobs.plg.in')
# NOTE: order matters and must mirror build.sh: embed FILES first (token's own newline is
# absorbed; empty block deletes the whole line), then CHANGES, then VERSION LAST so that
# {{VERSION}} inside embedded engine sources is stamped too.
$out = $tpl.Replace("{{FILES}}`n", $fileBlock).Replace('{{CHANGES}}', $changes).Replace('{{VERSION}}', $version)
$outBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($out)

if (-not (Test-Path -LiteralPath $distDir)) { New-Item -ItemType Directory -Path $distDir | Out-Null }
$plgPath = Join-Path $distDir 'rclone-jobs.plg'
[System.IO.File]::WriteAllBytes($plgPath, $outBytes)

# 5. dist lint (hard gate)
Write-Host ''
& $lintPs1 -Root $Root -Plg $plgPath
if ($LASTEXITCODE -ne 0) { throw "dist lint failed - build aborted" }

# 6. manifest report
Write-Host ''
Write-Host ("{0,-42} {1,8}  {2}" -f 'FILE', 'BYTES', 'SHA256')
foreach ($r in $manifestRows) {
    Write-Host ("{0,-42} {1,8}  {2}" -f ('src/' + $r.Src), $r.Bytes, $r.Sha256)
}
$plgSha = Get-Sha256Bytes $outBytes
Write-Host ("{0,-42} {1,8}  {2}" -f 'dist/rclone-jobs.plg', $outBytes.Length, $plgSha)
Write-Host ''
Write-Host "OK: dist/rclone-jobs.plg version $version"
