#!/bin/sh
# Smoke test: dynIDE must boot headless (DYNIDE_HEADLESS=1) under a pty,
# stop on SIGTERM with status 0, leave the tty settings untouched, and print
# nothing to the terminal. It runs through the broker (gen 1 is primary), the
# SIGTERM stop is never a handoff, and no VM outlives the broker.
# Usage: launcher_smoke.sh [-v]    (SMOKE_TIMEOUT seconds to boot, default 600)
# The attached (terminal client) launch is attached_smoke.sh.
set -u
verbose=0
[ "${1:-}" = "-v" ] && verbose=1
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
printf 'onboarding = false\n' >"$tmp/config.toml"
timeout=${SMOKE_TIMEOUT:-600}

vm_pids() { sed -n 's/.*dynide-broker: started vm .* pid=\([0-9]*\) .*/\1/p' "$tmp/log/dynide.log" 2>/dev/null; }
# shellcheck disable=SC2329 # invoked via trap
cleanup() {
  if [ -s "$tmp/pid" ]; then kill -KILL "$(cat "$tmp/pid")" 2>/dev/null; fi
  for p in $(vm_pids); do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

dump() {
  echo "--- log"; cat "$tmp/log/dynide.log" 2>&1
  echo "--- stty before"; cat "$tmp/before" 2>&1
  echo "--- stty after"; cat "$tmp/after" 2>&1
}
fail() {
  echo "FAIL: $*" >&2
  [ "$verbose" = 1 ] && dump
  exit 1
}

# Inner script: runs inside the pty and must print nothing itself.
cat >"$tmp/inner.sh" <<INNER
alive() { st=\$(ps -o stat= -p "\$1" 2>/dev/null); [ -n "\$st" ] && [ "\${st#Z}" = "\$st" ]; }
stty -a >"$tmp/before"
export DYNIDE_API="$tmp/api.sock"
# session files (M8) under the run dir, never the real session
export DYNIDE_STATE_DIR="$tmp/state"
# the run's config file (M13): no first-run welcome modal
export DYNIDE_CONFIG="$tmp/config.toml"
DYNIDE_HEADLESS=1 DYNIDE_RUNTIME_DIR="$tmp/rt" DYNIDE_LOG="$tmp/log/dynide.log" "$root/bin/dynide" &
pid=\$!
echo "\$pid" >"$tmp/pid"
i=0
until grep -qs 'dynide started' "$tmp/log/dynide.log"; do
  i=\$((i + 1))
  if [ "\$i" -gt $((timeout * 2)) ] || ! alive "\$pid"; then
    kill -KILL "\$pid" 2>/dev/null
    echo timeout >"$tmp/status"
    stty -a >"$tmp/after"
    exit 0
  fi
  sleep 0.5
done
"$root/bin/dynide" rollback >"$tmp/rb_up" 2>&1; echo \$? >"$tmp/rb_up.status"
kill -TERM "\$pid"
i=0
while alive "\$pid" && [ "\$i" -lt 80 ]; do
  i=\$((i + 1))
  [ "\$i" -gt 60 ] && kill -KILL "\$pid" 2>/dev/null
  sleep 0.5
done
wait "\$pid"
echo \$? >"$tmp/status"
"$root/bin/dynide" rollback >"$tmp/rb_down" 2>&1; echo \$? >"$tmp/rb_down.status"
stty -a >"$tmp/after"
INNER

case $(uname) in
  Darwin) script -q /dev/null "${SMOKE_SH:-sh}" "$tmp/inner.sh" >"$tmp/transcript" 2>&1 </dev/null ;;
  *) script -qec "${SMOKE_SH:-sh} $tmp/inner.sh" /dev/null >"$tmp/transcript" 2>&1 </dev/null ;;
esac

log="$tmp/log/dynide.log"
[ -s "$tmp/status" ] || fail "inner script did not finish"
[ "$(cat "$tmp/status")" = 0 ] || fail "exit status $(cat "$tmp/status") (wanted 0); log: $(tail -n 20 "$log" 2>&1)"
echo "PASS: exit status 0"
[ -s "$tmp/before" ] || fail "no stty dump (pty missing?)"
cmp -s "$tmp/before" "$tmp/after" || fail "stty changed: $(diff "$tmp/before" "$tmp/after")"
echo "PASS: tty settings unchanged"
grep -q 'dynide started' "$log" || fail "log lacks 'dynide started'"
grep -q 'dynide stopped' "$log" || fail "log lacks 'dynide stopped'"
echo "PASS: log has started and stopped"
! grep -q 'terminal client started' "$log" || fail "headless run started a terminal client"
echo "PASS: headless, no terminal client"
[ "$(cat "$tmp/rb_up" 2>&1)" = "ok none" ] && [ "$(cat "$tmp/rb_up.status")" = 0 ] ||
  fail "rollback while running: $(cat "$tmp/rb_up" "$tmp/rb_up.status" 2>&1)"
echo "PASS: dynide rollback answers ok none"
grep -q '^{"error":{"code":"server_not_running",' "$tmp/rb_down" && [ "$(cat "$tmp/rb_down.status")" = 1 ] ||
  fail "rollback after stop: $(cat "$tmp/rb_down" "$tmp/rb_down.status" 2>&1)"
[ ! -e "$tmp/api.sock" ] || fail "api socket left behind"
echo "PASS: dynide rollback after stop exits 1, socket removed"
# Darwin script(1) echoes "^D" plus backspaces when its own stdin hits EOF; that is script, not the VM.
[ -z "$(tr -d '\r\n\b' <"$tmp/transcript" | sed 's/^\^D//')" ] || fail "terminal output: $(cat "$tmp/transcript")"
echo "PASS: terminal transcript empty"
grep -q 'dynide-broker: vm gen=1 is primary' "$log" || fail "log lacks 'dynide-broker: vm gen=1 is primary'"
echo "PASS: broker ran the vm"
grep -q 'dynide-broker: stopped' "$log" || fail "log lacks 'dynide-broker: stopped'"
! grep -q 'dynide-broker: handoff' "$log" || fail "sigterm ran a handoff: $(grep 'dynide-broker: handoff' "$log")"
echo "PASS: sigterm stopped without handoff"
[ -n "$(vm_pids)" ] || fail "log has no 'dynide-broker: started vm' line"
for p in $(vm_pids); do
  ! kill -0 "$p" 2>/dev/null || fail "vm pid $p still running"
done
echo "PASS: no vm left"

# An explicit empty verb is a usage error, never a (nested) server start.
DYNIDE_HEADLESS=1 DYNIDE_API="$tmp/e/api.sock" DYNIDE_RUNTIME_DIR="$tmp/e/rt" \
  DYNIDE_LOG="$tmp/e/dynide.log" "$root/bin/dynide" "" </dev/null >"$tmp/empty" 2>&1 &
epid=$!
i=0
while kill -0 "$epid" 2>/dev/null && [ "$i" -lt 120 ]; do i=$((i + 1)); sleep 0.5; done
if kill -0 "$epid" 2>/dev/null; then
  kill -KILL "$epid" 2>/dev/null
  fail "dynide \"\" still running after 60 s (started a server?)"
fi
wait "$epid"
estatus=$?
if [ "$estatus" != 2 ] || ! grep -q '^usage: dynide' "$tmp/empty"; then
  fail "dynide \"\": exit $estatus, $(cat "$tmp/empty")"
fi
[ ! -e "$tmp/e/dynide.log" ] || fail "dynide \"\" wrote a server log"
echo "PASS: dynide \"\" is a usage error (exit 2)"

[ "$verbose" = 1 ] && dump
exit 0
