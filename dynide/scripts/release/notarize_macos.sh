#!/bin/sh
# Submits a signed dynIDE macOS release for Apple notarization (M18 task 5).
# Usage: notarize_macos.sh --keychain-profile PROFILE [--dry-run] TARBALL
# TARBALL is the build.sh .tar.gz of the signed tree, already re-packed after sign_macos.sh
# (see docs/herdr-live/site/signing.md). notarytool takes a zip, so the tree is zipped with
# ditto. A plain tarball cannot be stapled: Gatekeeper checks the ticket online.
# --dry-run prints the commands and contacts nothing.
set -eu
profile='' dry=0
usage() { echo "usage: notarize_macos.sh --keychain-profile PROFILE [--dry-run] TARBALL" >&2 && exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --keychain-profile) [ $# -ge 2 ] || usage; profile=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ -n "$profile" ] && [ $# -eq 1 ] && [ -f "$1" ] || usage
tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
zip=$work/notarize.zip
run() { if [ $dry -eq 1 ]; then echo "+ $*"; else "$@"; fi; }

echo "+ tar -xzf $tarball -C $work/tree" >&2
mkdir "$work/tree"
tar -xzf "$tarball" -C "$work/tree"
run ditto -c -k --keepParent "$work/tree"/* "$zip"
run xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
if [ $dry -eq 1 ]; then
  echo "notarize_macos.sh: dry run, nothing submitted. After 'Accepted', check with:" >&2
  echo "  xcrun notarytool log <submission-id> --keychain-profile $profile" >&2
fi
echo "note: tarballs cannot be stapled; ship the same tarball, Gatekeeper finds the ticket online." >&2
