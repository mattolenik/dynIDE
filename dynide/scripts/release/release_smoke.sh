#!/bin/sh
# Smoke test of the self-contained release (M18 task 1). Usage: release_smoke.sh [tarball]
# Without a tarball it runs keygen.sh and build.sh --dev-key first (and checks update-keys/). It installs the tarball with install.sh (R4 layout)
# under a prefix with a space (<prefix>/lib/herdr-live/releases/<V>, current -> releases/<V>,
# <prefix>/bin/herdr-live -> ../lib/herdr-live/current/bin/herdr-live) and runs every
# command through that symlink in a clean env (env -i: temp HOME, XDG dirs, runtime dir,
# PATH=/usr/bin:/bin with no erl, elixir or mix), started from cwd /. Checks: --version;
# a headless start answers ping within 20 s with the version; a second start prints
# "already running" on stderr and exits 2; one pane, whose shell
# starts in $HOME and inherits no RELEASE_* env; the broker's VM argv is pinned to
# releases/<V> (`current` resolved); kernel-restart keeps the pane id; 20 pings p50 < 300 ms (printed with the
# load average); attach reaches the client socket; SIGTERM stops the broker with status
# 0 and leaves no process of this run. PASS/FAIL lines like launcher_smoke.sh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)

# leftover detection only (a FAIL, never a kill): every process of this run has $tmp in its argv
ours() { pgrep -f -- "$tmp"; }
pid='' spid=''
vm_pids() { sed -n 's/.*dynide-broker: started vm .* pid=\([0-9]*\) .*/\1/p' "$tmp/state/herdr-live/herdr-live.log" 2>/dev/null; }
# shellcheck disable=SC2329 # invoked via trap
cleanup() { # only pids this run holds: broker, attach wrapper and launcher, the broker's VMs
  for p in $pid $spid $(cat "$tmp/attach.pid" 2>/dev/null) $(vm_pids); do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
fail() {
  echo "FAIL: $*" >&2
  echo "--- log" >&2
  tail -n 40 "$tmp/state/herdr-live/herdr-live.log" >&2 2>/dev/null
  exit 1
}

if [ $# -ge 1 ]; then
  tarball=$1
else
  pub=$("$here/keygen.sh") || fail "keygen.sh"
  built=$("$here/build.sh" --dev-key) || fail "build.sh failed"
  tarball=$(printf '%s\n' "$built" | tail -n 1)
fi
[ -f "$tarball" ] || fail "no tarball $tarball"

top=$(tar -tzf "$tarball" | head -n 1 | cut -d/ -f1)
v=${top#herdr-live-}
if [ -n "${pub:-}" ]; then # built here with --dev-key: it trusts exactly the dev key
  keys=$(tar -tzf "$tarball" | grep "^$top/releases/$v/update-keys/.")
  [ "$keys" = "$top/releases/$v/update-keys/dev-update.pub" ] || fail "update-keys: $keys (wanted dev-update.pub only)"
  [ "$(tar -xzOf "$tarball" "$top/releases/$v/update-keys/dev-update.pub")" = "$(cat "$pub")" ] ||
    fail "update-keys/dev-update.pub is not $pub"
  echo "PASS: build.sh --dev-key: the release trusts exactly the dev key"
fi

# install.sh refuses a tarball whose top dir names a bad version (.., ., a space)
for bad in .. . 'a b'; do
  mkdir -p "$tmp/bad/herdr-live-$bad/bin" || fail mkdir
  cp /bin/sh "$tmp/bad/herdr-live-$bad/bin/herdr-live" || fail cp
  tar -C "$tmp/bad" -czf "$tmp/bad.tar.gz" "herdr-live-$bad" || fail "bad tarball $bad"
  sh "$here/install.sh" --prefix "$tmp/badprefix" "$tmp/bad.tar.gz" >"$tmp/bad.out" 2>&1 &&
    fail "install.sh accepted top dir herdr-live-$bad"
  grep -q "bad version" "$tmp/bad.out" || fail "install.sh herdr-live-$bad: $(cat "$tmp/bad.out")"
  [ ! -e "$tmp/badprefix/lib/herdr-live/current" ] || fail "install.sh herdr-live-$bad left a current link"
  rm -rf "$tmp/bad" "$tmp/bad.tar.gz"
done
echo "PASS: install.sh refuses tarball top dirs herdr-live-.., herdr-live-. and herdr-live-a b"

prefix="$tmp/pre fix"
mkdir -p "$tmp/home" "$tmp/t" || fail mkdir
sh "$here/install.sh" --prefix "$prefix" "$tarball" >"$tmp/install.out" 2>&1 || fail "install.sh: $(cat "$tmp/install.out")"
bin="$prefix/bin/herdr-live"
printf 'onboarding = false\n' >"$tmp/config.toml"

# x.sh: a command in the clean env
cat >"$tmp/x.sh" <<X
#!/bin/sh
exec env -i HOME="$tmp/home" PATH=/usr/bin:/bin TERM=xterm-256color SHELL=/bin/sh \
  LANG="${LANG:-C.UTF-8}" TMPDIR="$tmp/t" XDG_STATE_HOME="$tmp/state" \
  XDG_CONFIG_HOME="$tmp/config" HERDR_LIVE_RUNTIME_DIR="$tmp/rt" \
  HERDR_LIVE_CONFIG="$tmp/config.toml" HERDR_LIVE_CLIENT_LOG="$tmp/client.log" "\$@"
X
chmod +x "$tmp/x.sh"
x="$tmp/x.sh"

! "$x" sh -c 'command -v erl || command -v elixir || command -v mix || command -v cargo' >/dev/null ||
  fail "erl, elixir, mix or cargo on the smoke PATH"
echo "PASS: no erl, elixir, mix or cargo on PATH"

out=$("$x" "$bin" --version 2>&1)
[ "$out" = "herdr-live $v" ] || fail "--version: $out (wanted herdr-live $v)"
echo "PASS: --version prints herdr-live $v"

# shellcheck disable=SC2016 # expanded by the inner sh
"$x" sh -c 'cd / && HERDR_LIVE_HEADLESS=1 exec "$0"' "$bin" </dev/null >"$tmp/start.out" 2>&1 &
pid=$!
i=0
until "$x" "$bin" ping >"$tmp/ping" 2>&1; do
  i=$((i + 1))
  kill -0 "$pid" 2>/dev/null || fail "broker exited: $(cat "$tmp/start.out")"
  [ "$i" -lt 40 ] || fail "no ping within 20 s: $(cat "$tmp/ping")"
  sleep 0.5
done
grep -q "\"version\":\"$v\"" "$tmp/ping" || fail "ping: $(cat "$tmp/ping") (wanted version $v)"
echo "PASS: ping answers within 20 s with version $v"
[ ! -s "$tmp/start.out" ] || fail "launcher wrote to its stdout/stderr: $(cat "$tmp/start.out")"

# a second start on the same runtime dir says so on stderr and exits 2 (not silently into the log)
"$x" "$bin" </dev/null >"$tmp/second.out" 2>"$tmp/second.err"
rc=$?
# shellcheck disable=SC2016 # literal backticks in the expected message
want='herdr-live is already running; use `herdr-live attach`'
[ "$rc" = 2 ] && [ "$(cat "$tmp/second.err")" = "$want" ] && [ ! -s "$tmp/second.out" ] ||
  fail "second start: exit $rc, stderr $(cat "$tmp/second.err") (wanted exit 2, $want)"
echo "PASS: a second start says it is already running (stderr, exit 2)"

ps -o command= -p "$pid" | grep -qF "$prefix/lib/herdr-live/releases/$v/bin/herdr_live start" ||
  fail "broker argv is not pinned to releases/$v: $(ps -o command= -p "$pid")"
"$x" "$bin" status 2>&1 | grep -qxF "vm_argv=$prefix/lib/herdr-live/releases/$v/bin/herdr_live start" ||
  fail "broker vm_argv is not pinned to releases/$v: $("$x" "$bin" status 2>&1 | grep '^vm_argv=')"
echo "PASS: broker VM argv pinned to releases/$v (current resolved)"

panes() { "$x" "$bin" pane list | grep -o '"pane_id":"[^"]*"' | sort -u; }
ids=$(panes)
[ "$(echo "$ids" | grep -c .)" = 1 ] || fail "pane list: $ids (wanted one pane)"
id=$(echo "$ids" | sed 's/.*:"\(.*\)"/\1/')
echo "PASS: one pane ($id)"

# the marker is split so the echoed command line never matches it
# shellcheck disable=SC2016 # expanded by the pane shell
"$x" "$bin" pane run "$id" 'echo "cw""d=$(pwd -P) rel=${RELEASE_ROOT:-none}${RELEASE_VSN:-}${ROOTDIR:-}${BINDIR:-} erl=$(command -v erl) path=$PATH"' >/dev/null ||
  fail "pane run"
"$x" "$bin" pane wait-output "$id" --match "cwd=" --timeout 10000 >/dev/null || fail "pane wait-output"
line=$("$x" "$bin" pane read "$id" --source recent | grep 'cwd=' | tail -n 1)
want="cwd=$tmp/home rel=none erl= path=/usr/bin:/bin"
[ "$line" = "$want" ] || fail "pane shell: $line (wanted $want)"
echo "PASS: pane shell starts in \$HOME (cwd / at launch), no RELEASE_*/ROOTDIR/BINDIR env, the caller's PATH (no erl)"

# a plugin action runs as a port child of the VM: same env rules as the pane shell
mkdir -p "$tmp/plugin"
cat >"$tmp/plugin/herdr-plugin.toml" <<P
id = "envcheck"
name = "envcheck"
version = "0.1.0"
min_herdr_version = "0.1.0"

[[actions]]
id = "env"
title = "env"
command = ["/bin/sh", "-c", "echo \\"rel=\${RELEASE_ROOT:-none}\${RELEASE_VSN:-}\${ROOTDIR:-}\${BINDIR:-} erl=\$(command -v erl) path=\$PATH\\" >'$tmp/plugin.out'"]
P
"$x" "$bin" plugin link "$tmp/plugin" >"$tmp/link" 2>&1 || fail "plugin link: $(cat "$tmp/link")"
"$x" "$bin" plugin action invoke envcheck.env >"$tmp/invoke" 2>&1 || fail "plugin action invoke: $(cat "$tmp/invoke")"
i=0
until [ -s "$tmp/plugin.out" ]; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || fail "plugin action wrote nothing in 10 s: $(cat "$tmp/invoke")"
  sleep 0.5
done
want="rel=none erl= path=/usr/bin:/bin"
[ "$(cat "$tmp/plugin.out")" = "$want" ] || fail "plugin action env: $(cat "$tmp/plugin.out") (wanted $want)"
echo "PASS: a plugin action (port child) gets the caller's PATH (no erl) and no RELEASE_*/ROOTDIR/BINDIR env"

"$x" "$bin" kernel-restart >"$tmp/kr" 2>&1 || fail "kernel-restart: $(cat "$tmp/kr")"
"$x" "$bin" ping >/dev/null 2>&1 || fail "no ping after kernel-restart"
[ "$(panes)" = "$ids" ] || fail "pane ids after kernel-restart: $(panes) (wanted $ids)"
echo "PASS: kernel-restart keeps pane $id"

p50=$(python3 - "$x" "$bin" <<'PY'
import subprocess, sys, time
ts = []
for _ in range(20):
    t = time.monotonic()
    subprocess.run([sys.argv[1], sys.argv[2], "ping"], check=True, capture_output=True)
    ts.append((time.monotonic() - t) * 1000)
print(int(sorted(ts)[9]))
PY
) || fail "timed pings"
load=$(uptime | sed 's/.*load averages*: *//')
[ "$p50" -lt 300 ] || fail "ping p50 ${p50} ms (wanted < 300), load $load"
echo "PASS: 20 pings p50 ${p50} ms (load $load)"

cat >"$tmp/attach.sh" <<A
echo \$\$ >"$tmp/attach.pid"
exec "$x" "$bin" attach
A
case $(uname) in
  Darwin) script -q /dev/null sh "$tmp/attach.sh" >/dev/null 2>&1 </dev/null & ;;
  *) script -qec "sh $tmp/attach.sh" /dev/null >/dev/null 2>&1 </dev/null & ;;
esac
spid=$!
i=0
until grep -qs 'remote: connected' "$tmp/client.log"; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "attach: no 'remote: connected' in 30 s: $(tail -n 20 "$tmp/client.log" 2>&1)"
  sleep 0.5
done
kill -TERM "$(cat "$tmp/attach.pid")"
i=0
while kill -0 "$spid" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 40 ] || fail "attach client still running 20 s after SIGTERM"
  sleep 0.5
done
echo "PASS: attach reaches the client socket, SIGTERM stops it"

vms=$(vm_pids)
kill -TERM "$pid"
i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "broker still running 30 s after SIGTERM"
  sleep 0.5
done
wait "$pid"
rc=$?
[ "$rc" = 0 ] || fail "broker exit status $rc (wanted 0)"
echo "PASS: SIGTERM stops the broker with status 0"

[ -n "$vms" ] || fail "log has no 'dynide-broker: started vm' line"
for p in $vms; do ! kill -0 "$p" 2>/dev/null || fail "vm pid $p still running"; done
left=$(ours)
[ -z "$left" ] || fail "processes left: $(ps -o pid= -o command= -p "$(echo "$left" | paste -sd, -)")"
echo "PASS: no vm or other process of this run left"
exit 0
