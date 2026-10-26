#!/bin/sh
# Signs every Mach-O in a herdr-live macOS release tree (M18 task 5).
# Usage: sign_macos.sh --identity "Developer ID Application: NAME (TEAM)" [--dry-run] RELEASE_DIR
# Libraries (.so, .dylib) first, then executables; each file on its own (no --deep) with
# the hardened runtime, a secure timestamp and rel/macos/entitlements.plist. --dry-run
# prints every codesign command and runs only read-only checks (codesign --verify,
# spctl --assess) so the current state shows.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
ent=$here/../../rel/macos/entitlements.plist
id='' dry=0
usage() { echo "usage: sign_macos.sh --identity ID [--dry-run] RELEASE_DIR" >&2 && exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --identity) [ $# -ge 2 ] || usage; id=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ -n "$id" ] && [ $# -eq 1 ] && [ -d "$1" ] || usage
root=$(cd "$1" && pwd)
[ "$(uname -s)" = Darwin ] || { echo "sign_macos.sh: macOS only" >&2 && exit 1; }

list=$(mktemp)
trap 'rm -f "$list"' EXIT
find "$root" -type f ! -type l | sort | while read -r f; do
  case $(file -b "$f") in
    *Mach-O*dynamically\ linked\ shared\ library* | *Mach-O*bundle*) echo "0 $f" ;;
    *Mach-O*) echo "1 $f" ;;
  esac
done | sort -s -k1,1n >"$list"

n=0
while read -r _ f; do
  n=$((n + 1))
  cmd="codesign --force --options runtime --timestamp --entitlements $ent --sign \"$id\" \"$f\""
  if [ $dry -eq 1 ]; then
    echo "+ $cmd"
    codesign --verify --verbose=1 "$f" 2>&1 | sed 's/^/    /' || true
  else
    codesign --force --options runtime --timestamp --entitlements "$ent" --sign "$id" "$f"
  fi
done <"$list"
echo "sign_macos.sh: $n Mach-O files$([ $dry -eq 1 ] && echo ' (dry run, nothing signed)')" >&2

if [ $dry -eq 1 ]; then
  echo "+ spctl --assess --type execute --verbose $root/bin/dynide_broker   (read-only)"
  spctl --assess --type execute --verbose "$root/bin/dynide_broker" 2>&1 | sed 's/^/    /' || true
else
  while read -r _ f; do codesign --verify --strict --verbose=1 "$f"; done <"$list"
fi
