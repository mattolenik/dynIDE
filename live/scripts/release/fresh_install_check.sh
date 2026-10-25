#!/bin/sh
# Fresh-environment install proof (M18 task 2). Usage: fresh_install_check.sh [tarball]
# macOS host: new temp HOME and a prefix with a space, env -i, install.sh from the tarball,
# then run it. Linux: the same body inside a clean ubuntu:24.04 podman container (no extra
# packages), tarball and scripts mounted read-only. The tarball defaults to
# the one in _build/release for this OS (aarch64). Env: HERDR_FRESH_IMAGE overrides the image.
# Body checks: install, --version, headless start + ping, pane split (2 panes), SIGTERM
# (status 0), state dir mode 0700, nothing new in herdr-live's default
# locations under the real HOME (state, config, cache, ~/.local/lib|bin).
set -u
# ubuntu:24.04 already ships libssl3t64 (libcrypto.so.3), libtinfo6 and glibc 2.39: nothing to apt-install.
# HERDR_FRESH_APT="pkg ..." installs extra packages (for a slimmer image).
LINUX_DEPS=${HERDR_FRESH_APT:-}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

if [ "${1:-}" = --inner ]; then # body: inner TARBALL INSTALL_SH
  tarball=$2 install=$3
  tmp=$(mktemp -d)
  pid=''
  trap '[ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null; rm -rf "$tmp"' EXIT
  fail() { echo "FAIL: $*" >&2; tail -n 30 "$tmp/state/herdr-live/herdr-live.log" >&2 2>/dev/null; exit 1; }
  mkdir -p "$tmp/home" "$tmp/t"
  touch "$tmp/marker"
  prefix="$tmp/pre fix"
  # a script, not a function, so the backgrounded pid is the exec'd broker and SIGTERM reaches it
  cat >"$tmp/envx" <<X
#!/bin/sh
exec env -i HOME="$tmp/home" PATH="$prefix/bin:/usr/bin:/bin" TERM=xterm-256color SHELL=/bin/sh \\
  LANG=C.UTF-8 TMPDIR="$tmp/t" XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config" \\
  HERDR_LIVE_RUNTIME_DIR="$tmp/rt" "\$@"
X
  chmod +x "$tmp/envx"
  envx() { "$tmp/envx" "$@"; }
  envx sh "$install" --prefix "$prefix" "$tarball" >"$tmp/install.out" 2>&1 || fail "install: $(cat "$tmp/install.out")"
  grep -q "is on PATH" "$tmp/install.out" || fail "install did not report bin on PATH: $(cat "$tmp/install.out")"
  echo "PASS: install.sh into '$prefix'"
  [ ! -e "$tmp/state" ] && [ ! -e "$tmp/config" ] || fail "install created state or config dirs"
  v=$(envx herdr-live --version) || fail "--version"
  case $v in "herdr-live "*) echo "PASS: $v" ;; *) fail "--version: $v" ;; esac
  "$tmp/envx" sh -c 'cd / && HERDR_LIVE_HEADLESS=1 HERDR_LIVE_CONFIG=/dev/null exec herdr-live' </dev/null >"$tmp/start.out" 2>&1 &
  pid=$!
  i=0
  until envx herdr-live ping >"$tmp/ping" 2>&1; do
    i=$((i + 1)); kill -0 "$pid" 2>/dev/null || fail "broker exited: $(cat "$tmp/start.out")"
    [ "$i" -lt 60 ] || fail "no ping in 30 s: $(cat "$tmp/ping")"; sleep 0.5
  done
  echo "PASS: headless start answers ping"
  ids() { envx herdr-live pane list | grep -o '"pane_id":"[^"]*"' | sort -u; }
  first=$(ids | sed 's/.*:"\(.*\)"/\1/')
  [ -n "$first" ] || fail "no first pane"
  envx herdr-live pane split "$first" --direction right >"$tmp/split" 2>&1 || fail "pane split: $(cat "$tmp/split")"
  [ "$(ids | grep -c .)" = 2 ] || fail "pane list: $(ids) (wanted 2 panes)"
  echo "PASS: pane split, pane list = 2"
  kill -TERM "$pid"
  i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 60 ] || fail "broker still up 30 s after SIGTERM"; sleep 0.5
  done
  wait "$pid"; rc=$?; pid=''
  [ "$rc" = 0 ] || fail "SIGTERM exit status $rc"
  echo "PASS: SIGTERM stops the broker with status 0"
  mode=$(stat -c %a "$tmp/state/herdr-live" 2>/dev/null || stat -f %Lp "$tmp/state/herdr-live")
  [ "$mode" = 700 ] || fail "state dir mode $mode (wanted 700)"
  echo "PASS: state dir mode 700"
  # only herdr-live's own default locations: other programs (the user's herdr) write in HOME too
  stray=''
  for h in "${REAL_HOME:-/nonexistent}" /root; do
    stray="$stray$(find "$h/.local/state/herdr-live" "$h/.config/herdr-live" "$h/.cache/herdr-live" \
      "$h/.local/lib/herdr-live" "$h/.local/bin/herdr-live" -newer "$tmp/marker" 2>/dev/null | head -n 5)"
  done
  [ -z "$stray" ] || fail "files written outside the temp dir: $stray"
  echo "PASS: nothing written outside the temp dir"
  exit 0
fi

tarball=${1:-}
if [ -z "$tarball" ]; then
  case $(uname) in Darwin) os=macos ;; *) os=linux ;; esac
  # shellcheck disable=SC2012 # glob of known names
  tarball=$(ls "$root"/_build/release/herdr-live-*-"$os"-aarch64.tar.gz 2>/dev/null | tail -n 1)
fi
[ -f "$tarball" ] || { echo "FAIL: no tarball (run build.sh)" >&2; exit 1; }
tarball=$(cd "$(dirname "$tarball")" && pwd)/$(basename "$tarball")

if [ "$(uname)" = Darwin ]; then
  echo "== macOS fresh install"
  REAL_HOME=$HOME sh "$0" --inner "$tarball" "$here/install.sh" && echo "PASS: macOS fresh install"
  mac=$?
else
  mac=0
fi
[ "$mac" = 0 ] || exit 1

echo "== Linux fresh install (ubuntu:24.04 container)"
image=${HERDR_FRESH_IMAGE:-docker.io/library/ubuntu:24.04}
name="herdr-m18-fresh-$$"
trap 'podman rm -f "$name" >/dev/null 2>&1' EXIT
# the linux tarball is the one mounted, whatever host runs this
# shellcheck disable=SC2012 # glob of known names
ltar=$(ls "$root"/_build/release/herdr-live-*-linux-aarch64.tar.gz | tail -n 1)
podman run --name "$name" --rm \
  -v "$ltar:/in/$(basename "$ltar"):ro" -v "$ltar.sha256:/in/$(basename "$ltar").sha256:ro" \
  -v "$here:/scripts:ro" "$image" sh -c "
    set -e
    command -v erl >/dev/null && { echo 'erl present in image' >&2; exit 1; }
    [ -z '$LINUX_DEPS' ] || { apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $LINUX_DEPS >/dev/null; }
    sh /scripts/fresh_install_check.sh --inner /in/$(basename "$ltar") /scripts/install.sh" || exit 1
echo "PASS: Linux fresh install"
