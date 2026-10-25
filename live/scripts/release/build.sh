#!/bin/sh
# Builds the self-contained herdr-live release tarball (M18 task 1).
# Usage: build.sh [--version V] [--out DIR]
#   V: $HERDR_LIVE_VERSION, else @version in live/mix.exs. DIR: live/_build/release.
# Writes DIR/herdr-live-<V>-<os>-<arch>.tar.gz (os macos|linux, arch aarch64|x86_64) and
# its .sha256 (`shasum -a 256 -c` format), and prints the tarball path last on stdout
# (build output goes to stderr). The tarball's top dir herdr-live-<V>/ is a release root:
# bin/herdr-live (the launcher), bin/herdr_broker, bin/herdr_live (the Mix release
# script), scripts/tty_guard.sh, erts-*/, lib/, releases/<V>/ (see mix.exs `releases`).
# On macOS, dylibs from outside the OS (Homebrew's libcrypto under crypto.so) are copied
# next to the library that links them, relinked with @loader_path and ad-hoc re-signed;
# the build fails if any non-OS link is left. Linux links the OS's libcrypto.so.3.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
live=$(cd "$here/../.." && pwd)
out=$live/_build/release
v=${HERDR_LIVE_VERSION:-$(sed -n 's/^  @version "\(.*\)"$/\1/p' "$live/mix.exs")}
usage() { echo "usage: build.sh [--version V] [--out DIR]" >&2 && exit 2; }
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case $1 in
    --version) v=$2 ;;
    --out) out=$2 ;;
    *) usage ;;
  esac
  shift 2
done
case $(uname -s) in Darwin) os=macos ;; Linux) os=linux ;; *) echo "build.sh: unsupported OS" >&2 && exit 1 ;; esac
case $(uname -m) in arm64 | aarch64) arch=aarch64 ;; x86_64 | amd64) arch=x86_64 ;; *) echo "build.sh: unsupported arch" >&2 && exit 1 ;; esac
name=herdr-live-$v
mkdir -p "$out"
out=$(cd "$out" && pwd)
tarball=$out/$name-$os-$arch.tar.gz
stage=$out/stage
rm -rf "$stage"
mkdir -p "$stage"
root=$stage/$name

(
  cd "$live"
  export MIX_ENV=prod HERDR_LIVE_VERSION="$v"
  mix deps.get
  mix release herdr_live --overwrite --path "$root"
) >&2

# the dependencies of a Mach-O file outside the OS (its own install id excluded)
foreign() {
  id=$(otool -D "$1" 2>/dev/null | sed -n 2p)
  otool -L "$1" 2>/dev/null | sed -n '2,$s/^[[:space:]]*\([^ ]*\) .*/\1/p' |
    while read -r dep; do
      case $dep in /usr/lib/* | /System/* | @loader_path/* | "$id") ;; *) echo "$dep" ;; esac
    done
}

if [ "$os" = macos ]; then
  find "$root" -type f \( -name '*.so' -o -name '*.dylib' \) | while read -r f; do
    for dep in $(foreign "$f"); do
      lib=$(basename "$dep")
      dir=$(dirname "$f")
      if [ ! -f "$dir/$lib" ]; then
        cp "$dep" "$dir/$lib"
        chmod u+w "$dir/$lib"
        install_name_tool -id "@loader_path/$lib" "$dir/$lib" 2>/dev/null
        codesign -f -s - "$dir/$lib" 2>/dev/null
      fi
      install_name_tool -change "$dep" "@loader_path/$lib" "$f" 2>/dev/null
      codesign -f -s - "$f" 2>/dev/null
      echo "bundled $lib for ${f#"$root"/}" >&2
    done
  done
  left=$(find "$root" -type f | while read -r f; do
    for dep in $(foreign "$f"); do echo "${f#"$root"/}: $dep"; done
  done)
  [ -z "$left" ] || { echo "build.sh: links outside the OS left:" >&2 && echo "$left" >&2 && exit 1; }
fi

rm -f "$tarball" "$tarball.sha256"
tar -C "$stage" -czf "$tarball" "$name"
rm -rf "$stage"
cd "$out"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$(basename "$tarball")" >"$tarball.sha256"
else
  shasum -a 256 "$(basename "$tarball")" >"$tarball.sha256"
fi
echo "$tarball"
