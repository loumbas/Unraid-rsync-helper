#!/usr/bin/env bash
# build.sh - assemble dist/rclone-jobs.plg from src/ (WSL / Git-Bash equivalent of build.ps1).
# Output must be byte-identical to build.ps1. Full lint lives in tests/offline-lint.ps1;
# this script runs an internal equivalent of the hard checks (CR/BOM/placeholders/targets).
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")" && pwd)}"
SRC="$ROOT/src"
DIST="$ROOT/dist"
PLG="$DIST/rclone-jobs.plg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL  $*" >&2; exit 1; }

[ -d "$SRC" ] || fail "src/ not found under $ROOT"

# ------------------------------------------------------------- inputs ------
VERSION="$(tr -d '\r\n' < "$SRC/VERSION")"
echo "$VERSION" | grep -Eq '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$' || fail "src/VERSION must be YYYY.MM.DD, got: $VERSION"

# changelog: first '## ' section up to (exclusive) the next '## ' heading,
# trailing whitespace stripped per line, trailing newlines stripped overall.
CHANGES="$(awk '
  /^## / { if (started) exit; started = 1 }
  started { sub(/[ \t\r]+$/, ""); print }
' "$SRC/CHANGELOG.md")"
[ -n "$CHANGES" ] || fail "src/CHANGELOG.md has no '## ' section"

# ---------------------------------------------------- normalize + escape ----
norm_file() { # $1=src -> stdout: UTF-8 no BOM, LF-only, final newline
  local f="$1" magic
  magic="$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')"
  if [ "$magic" = "efbbbf" ]; then f="/dev/stdin"; tail -c +4 "$1" > "$TMP/nobom"; fi
  awk 'BEGIN { RS = "\r\n|\r|\n" } { printf "%s\n", $0 }' < "${f}"
}
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# internal lint: no CR/BOM in any packaged source + plg.in
while IFS= read -r mline || [ -n "$mline" ]; do
  case "$mline" in ''|'#'*) continue ;; esac
  set -- $mline
  [ $# -eq 3 ] || fail "MANIFEST malformed: $mline"
  sfile="$SRC/$1"
  [ -f "$sfile" ] || fail "MANIFEST src missing: $sfile"
  LC_ALL=C grep -q $'\r' "$sfile" && fail "CR found (must be LF-only): src/$1"
  [ "$(head -c 3 "$sfile" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] && fail "BOM found: src/$1"
done < "$SRC/MANIFEST"
for f in "$SRC/rclone-jobs.plg.in" "$SRC/VERSION" "$SRC/CHANGELOG.md"; do
  LC_ALL=C grep -q $'\r' "$f" && fail "CR found: $f"
done

# --------------------------------------------------- assemble <FILE> block --
: > "$TMP/files"
first=1
: > "$TMP/rows"
while IFS= read -r mline || [ -n "$mline" ]; do
  case "$mline" in ''|'#'*) continue ;; esac
  set -- $mline
  src="$1"; target="$2"; mode="$3"
  case "$target" in /usr/local/emhttp/plugins/rclone-jobs/*) ;; *) fail "target outside plugin dir: $target" ;; esac
  echo "$mode" | grep -Eq '^0[0-7]{3}$' || fail "bad mode: $mode"
  [ $first -eq 1 ] || printf '\n' >> "$TMP/files"
  first=0
  printf '  <FILE Name="%s" Mode="%s">\n<INLINE>\n' "$target" "$mode" >> "$TMP/files"
  norm_file "$SRC/$src" | xml_escape >> "$TMP/files"
  printf '</INLINE>\n  </FILE>\n' >> "$TMP/files"
  bytes=$(norm_file "$SRC/$src" | wc -c | tr -d ' ')
  sha=$(norm_file "$SRC/$src" | sha256sum | cut -d' ' -f1)
  printf '%s %s %s %s %s\n' "$src" "$target" "$mode" "$bytes" "$sha" >> "$TMP/rows"
done < "$SRC/MANIFEST"

# ------------------------------------------------------------- template ----
# Order must mirror build.ps1: embed FILES/CHANGES first, stamp VERSION LAST so
# {{VERSION}} inside embedded engine sources is replaced too.
mkdir -p "$DIST"
: > "$TMP/out"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '{{CHANGES}}') printf '%s\n' "$CHANGES" >> "$TMP/out" ;;
    '{{FILES}}')   cat "$TMP/files" >> "$TMP/out" ;;
    *)             printf '%s\n' "$line" >> "$TMP/out" ;;
  esac
done < "$SRC/rclone-jobs.plg.in"
awk -v ver="$VERSION" '{ gsub(/\{\{VERSION\}\}/, ver); print }' "$TMP/out" > "$PLG"

# ------------------------------------------------------------ dist lint ----
LC_ALL=C grep -q $'\r' "$PLG" && fail "dist plg contains CR"
[ "$(head -c 3 "$PLG" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] && fail "dist plg has BOM"
grep -q '{{' "$PLG" && fail "dist plg contains unsubstituted placeholder"
grep -q "$VERSION" "$PLG" || fail "dist plg missing version"
while IFS= read -r mline || [ -n "$mline" ]; do
  case "$mline" in ''|'#'*) continue ;; esac
  set -- $mline
  n=$(grep -c "Name=\"$2\"" "$PLG" || true)
  [ "$n" -eq 1 ] || fail "target $2 appears $n times (expected 1)"
done < "$SRC/MANIFEST"

# ---------------------------------------------------------- manifest -------
echo
printf '%-42s %8s  %s\n' 'FILE' 'BYTES' 'SHA256'
while read -r src target mode bytes sha; do
  printf '%-42s %8s  %s\n' "src/$src" "$bytes" "$sha"
done < "$TMP/rows"
plgb=$(wc -c < "$PLG" | tr -d ' ')
plgs=$(sha256sum "$PLG" | cut -d' ' -f1)
printf '%-42s %8s  %s\n' 'dist/rclone-jobs.plg' "$plgb" "$plgs"
echo
echo "OK: dist/rclone-jobs.plg version $VERSION"
