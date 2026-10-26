#!/bin/sh
# Bootstrap installer (M18 task 2). Usage: install.sh [--prefix P] [--force] TARBALL
# Installs the R4 layout under P (default $HOME/.local):
#   P/lib/dynide/releases/<V>/   P/lib/dynide/current -> releases/<V>
#   P/bin/dynide -> ../lib/dynide/current/bin/dynide
# Verifies TARBALL.sha256 when present; refuses to overwrite releases/<V> without --force.
# Creates no state or config dirs (the launcher does). POSIX sh; needs only tar, mv, ln.
set -eu

die() { echo "install.sh: $*" >&2; exit 1; }

prefix=${HOME:+$HOME/.local} force=0 tarball=''
while [ $# -gt 0 ]; do
  case $1 in
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; prefix=$2; shift 2 ;;
    --force) force=1; shift ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$tarball" ] || die "one tarball only"; tarball=$1; shift ;;
  esac
done
[ -n "$tarball" ] || die "usage: install.sh [--prefix P] [--force] TARBALL"
[ -n "$prefix" ] || die "no --prefix and HOME is unset"
[ -f "$tarball" ] || die "no such tarball: $tarball"

if [ -f "$tarball.sha256" ]; then
  want=$(cut -d' ' -f1 <"$tarball.sha256")
  if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum <"$tarball" | cut -d' ' -f1)
  elif command -v shasum >/dev/null 2>&1; then got=$(shasum -a 256 <"$tarball" | cut -d' ' -f1)
  else die "no sha256sum or shasum to verify $tarball"; fi
  [ "$got" = "$want" ] || die "sha256 mismatch for $tarball (want $want, got $got)"
fi

top=$(tar -tzf "$tarball" | head -n 1 | cut -d/ -f1)
case $top in dynide-?*) ;; *) die "unexpected tarball top dir '$top'" ;; esac
v=${top#dynide-}
# v names releases/<v>: no path separators, no . or .. (and the version chars build.sh allows)
case $v in . | .. | *[!0-9A-Za-z._+-]*) die "bad version '$v' in tarball top dir '$top'" ;; esac

lib="$prefix/lib/dynide"
rel="$lib/releases/$v"
if [ -e "$rel" ] && [ "$force" = 0 ]; then
  die "$rel exists (use --force to replace it)"
fi
mkdir -p "$lib/releases" "$prefix/bin"

# extract beside the target, then rename into place: a failed extract leaves nothing half-installed
stage="$lib/releases/.stage.$$"
cleanup() { rm -rf "$stage" "$lib/.current.$$" "$prefix/bin/.dynide.$$"; }
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
rm -rf "$stage"
mkdir "$stage"
tar -xzf "$tarball" --no-same-owner -C "$stage"
[ -x "$stage/$top/bin/dynide" ] || die "tarball has no $top/bin/dynide"
# --force: the old release is moved aside, never deleted before its replacement is in place
old=''
if [ -e "$rel" ]; then old="$rel.old.$$"; mv "$rel" "$old"; fi
mv "$stage/$top" "$rel"

# atomic flip: temp symlink, then rename over `current` without following it (GNU -T, BSD -h)
ln -s "releases/$v" "$lib/.current.$$"
if mv --version >/dev/null 2>&1; then mv -fT "$lib/.current.$$" "$lib/current"
else mv -fh "$lib/.current.$$" "$lib/current"; fi

ln -s ../lib/dynide/current/bin/dynide "$prefix/bin/.dynide.$$"
if mv --version >/dev/null 2>&1; then mv -fT "$prefix/bin/.dynide.$$" "$prefix/bin/dynide"
else mv -fh "$prefix/bin/.dynide.$$" "$prefix/bin/dynide"; fi

[ -z "$old" ] || rm -rf "$old"
echo "installed dynide $v in $rel"
case ":${PATH:-}:" in
  *":$prefix/bin:"*) echo "$prefix/bin is on PATH" ;;
  *) echo "$prefix/bin is NOT on PATH; add it: export PATH=\"$prefix/bin:\$PATH\"" ;;
esac
