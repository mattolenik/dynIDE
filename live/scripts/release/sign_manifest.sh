#!/bin/sh
# Signs an update manifest (M18 R5): a thin wrapper over make_manifest.exs, the one
# signing implementation, so the real key and the dev key take the same path.
# Usage: sign_manifest.sh --key KEY --url-base URL [--dry-run] [make_manifest.exs options] TARBALL...
# KEY is a keygen.sh-format private key file. Writes manifest.json and manifest.json.sig.
# --dry-run checks KEY exists and prints the command; it reads no key and writes nothing.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
key='' dry=0
args=
# peel off --key/--dry-run, pass everything else through untouched
while [ $# -gt 0 ]; do
  case $1 in
    --key) [ $# -ge 2 ] || { echo "sign_manifest.sh: --key needs a file" >&2; exit 2; }; key=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) args="$args
$1"; shift ;;
  esac
done
[ -n "$key" ] || { echo "usage: sign_manifest.sh --key KEY --url-base URL [--dry-run] TARBALL..." >&2; exit 2; }
[ -f "$key" ] || { echo "sign_manifest.sh: no key file $key" >&2; exit 1; }
if [ $dry -eq 1 ]; then
  echo "+ elixir $here/make_manifest.exs --key $key$(printf '%s' "$args" | tr '\n' ' ')"
  echo "sign_manifest.sh: dry run, nothing signed" >&2
  exit 0
fi
# word splitting on newlines only, so paths with spaces survive
IFS='
'
# shellcheck disable=SC2086
exec elixir "$here/make_manifest.exs" --key "$key" $args
