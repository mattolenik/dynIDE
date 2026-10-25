#!/bin/sh
# Render the Homebrew formula for a local tarball (M18 task 4).
# Usage: package_check.sh TARBALL   -> live/_build/release/packaging/herdr-live.rb
# Then `brew style` it and (optionally) install it in a throwaway Homebrew (see the m18 task-4 report).
set -eu
tb=${1:?usage: package_check.sh TARBALL}
[ -f "$tb" ] || { echo "no such tarball: $tb" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
live=$(cd "$here/../.." && pwd)
tb=$(cd "$(dirname "$tb")" && pwd)/$(basename "$tb")
sum=$(shasum -a 256 <"$tb" | cut -d' ' -f1)
v=$(basename "$tb" | sed -n 's/^herdr-live-\([0-9][^-]*\)-.*/\1/p')
[ -n "$v" ] || { echo "cannot read version from $tb" >&2; exit 1; }
out=$live/_build/release/packaging
mkdir -p "$out"
sed -e "s|@URL@|file://$tb|" -e "s|@VERSION@|$v|" -e "s|@SHA256@|$sum|" \
  "$live/rel/packaging/homebrew/herdr-live.rb.in" >"$out/herdr-live.rb"
/usr/bin/ruby -c "$out/herdr-live.rb" >/dev/null
echo "$out/herdr-live.rb"
