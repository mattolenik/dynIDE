#!/bin/sh
# Smoke test: herdr-live boots with the terminal client attached (no
# HERDR_LIVE_HEADLESS) on the real /dev/tty of a script(1) pty, sized 120x40.
# Run 1: logs 'terminal client started', paints a frame (alt screen entered,
# TERMINAL status), then one graceful `herdr-live kernel-restart`: the old
# client restores the tty, the new VM adopts the app (Store) and its client
# starts and puts the tty back in raw mode. It stops on SIGTERM with status 0
# and 'herdr-live stopped', the transcript ends with the restore (alt screen
# left, modes reset) and the tty settings are unchanged. Run 2: kill -9 of the
# primary VM; the broker hands off to a new VM that adopts the app and whose
# client repaints, then SIGTERM stops it with status 0, the tty settings
# unchanged and the restore at the end. Run 3: tty_guard.sh (still used by
# live-demo) on an early non-zero exit.
# Usage: attached_smoke.sh [-v]    (SMOKE_TIMEOUT seconds to boot, default 600)
set -u
verbose=0
[ "${1:-}" = "-v" ] && verbose=1
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
timeout=${SMOKE_TIMEOUT:-600}

# VM pids from the broker's 'started vm' log lines
vm_pids() { sed -n 's/.*herdr-broker: started vm .* pid=\([0-9]*\) .*/\1/p' "$@" 2>/dev/null; }
# shellcheck disable=SC2329 # invoked via trap
cleanup() {
  for f in "$tmp"/pid.*; do [ -s "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null; done
  vm_pids "$tmp"/log.* | while read -r p; do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

dump() {
  for run in term kill; do
    echo "--- $run log"; cat "$tmp/log.$run" 2>&1
    echo "--- $run transcript"; od -c "$tmp/transcript.$run" | tail -n 20
  done
}
fail() {
  echo "FAIL: $*" >&2
  [ "$verbose" = 1 ] && dump
  exit 1
}

# Inner script: runs inside the pty. $1 = run name, $2 = how to stop (TERM or KILL).
cat >"$tmp/inner.sh" <<INNER
run=\$1
if [ "\$2" = EARLY ]; then
  stty cols 120 rows 40
  stty -a >"$tmp/before.\$run"
  "$root/scripts/tty_guard.sh" sh -c 'exit 3'
  echo \$? >"$tmp/status.\$run"
  stty -a >"$tmp/after.\$run"
  exit 0
fi
alive() { st=\$(ps -o stat= -p "\$1" 2>/dev/null); [ -n "\$st" ] && [ "\${st#Z}" = "\$st" ]; }
stty cols 120 rows 40
stty -a >"$tmp/before.\$run"
log="$tmp/log.\$run"
# session files (M8) under the run dir, never the real session
export HERDR_LIVE_STATE_DIR="$tmp/state.\$run"
HERDR_LIVE_RUNTIME_DIR="$tmp/rt.\$run" HERDR_LIVE_API="$tmp/ctl.\$run" HERDR_LIVE_LOG="\$log" "$root/bin/herdr-live" &
pid=\$!
echo "\$pid" >"$tmp/pid.\$run"
i=0
ready() { grep -qs 'herdr-live started' "\$log" && grep -qs 'terminal client started' "\$log"; }
until ready; do
  i=\$((i + 1))
  if [ "\$i" -gt $((timeout * 2)) ] || ! alive "\$pid"; then
    kill -KILL "\$pid" 2>/dev/null
    echo timeout >"$tmp/status.\$run"
    exit 0
  fi
  sleep 0.5
done
sleep 1
if [ "\$2" = TERM ]; then
  HERDR_LIVE_RUNTIME_DIR="$tmp/rt.\$run" HERDR_LIVE_API="$tmp/ctl.\$run" "$root/bin/herdr-live" kernel-restart >"$tmp/restart.\$run" 2>&1
  echo \$? >"$tmp/restart_status.\$run"
  i=0
  until [ "\$(grep -c 'terminal client started' "\$log")" -ge 2 ]; do
    i=\$((i + 1))
    [ "\$i" -gt 120 ] && break
    sleep 0.5
  done
  sleep 1
  stty -a >"$tmp/mid.\$run"
fi
if [ "\$2" = KILL ]; then
  # bin/herdr-live execs the broker; kill -9 its primary VM, wait for the
  # handoff and the new VM's client, then stop the broker like run 1
  vm=\$(HERDR_LIVE_RUNTIME_DIR="$tmp/rt.\$run" HERDR_LIVE_API="$tmp/ctl.\$run" "$root/bin/herdr-live" status | sed -n 's/^primary_pid=//p')
  echo "\$vm" >"$tmp/vm.\$run"
  kill -KILL "\$vm"
  i=0
  until grep -qs 'herdr-broker: handoff crash' "\$log" && [ "\$(grep -c 'terminal client started' "\$log")" -ge 2 ]; do
    i=\$((i + 1))
    [ "\$i" -gt 120 ] && break
    sleep 0.5
  done
  sleep 1
fi
kill -TERM "\$pid"
i=0
while alive "\$pid" && [ "\$i" -lt 80 ]; do
  i=\$((i + 1))
  [ "\$i" -gt 60 ] && kill -KILL "\$pid" 2>/dev/null
  sleep 0.5
done
wait "\$pid"
echo \$? >"$tmp/status.\$run"
stty -a >"$tmp/after.\$run"
INNER

in_pty() {
  case $(uname) in
    Darwin) script -q /dev/null "${SMOKE_SH:-sh}" "$tmp/inner.sh" "$1" "$2" >"$tmp/transcript.$1" 2>&1 </dev/null ;;
    *) script -qec "${SMOKE_SH:-sh} $tmp/inner.sh $1 $2" /dev/null >"$tmp/transcript.$1" 2>&1 </dev/null ;;
  esac
  [ -s "$tmp/status.$1" ] || fail "$1: inner script did not finish"
  [ -s "$tmp/before.$1" ] || fail "$1: no stty dump (pty missing?)"
}

has() { LC_ALL=C grep -q "$(printf %b "$2")" "$tmp/transcript.$1"; }
# occurrences of the fixed string $2 in run $1's transcript
count() { LC_ALL=C grep -oF "$(printf %b "$2")" "$tmp/transcript.$1" | wc -l | tr -d ' '; }
# the promoted VM adopted the app from the broker (M3 Store adoption)
adopted_app() {
  grep -q 'handoff: adopted app with panes \[[0-9]' "$1" || fail "$2: log lacks 'handoff: adopted app with panes [..]'"
  ! grep -q 'unusable app/store entry' "$1" || fail "$2: $(grep 'unusable app/store entry' "$1")"
}
# the transcript ends with leaving the alt screen (ignoring Darwin script(1)'s
# "^D" plus backspaces at EOF, and line ends)
ends_restored() {
  [ "$(LC_ALL=C tr -d '\r\n\b' <"$tmp/transcript.$1" | LC_ALL=C sed 's/\^D//g' | tr -d '\n' | tail -c 8)" = "$(printf '\033[?1049l')" ]
}

in_pty term TERM
log="$tmp/log.term"
[ "$(cat "$tmp/status.term")" = 0 ] || fail "term: exit status $(cat "$tmp/status.term") (wanted 0); log: $(tail -n 20 "$log" 2>&1)"
echo "PASS: SIGTERM: exit status 0"
grep -q 'terminal client started' "$log" || fail "log lacks 'terminal client started'"
grep -q 'herdr-live stopped' "$log" || fail "log lacks 'herdr-live stopped'"
echo "PASS: SIGTERM: log has herdr-live started, terminal client started, herdr-live stopped"
has term '\033\\[?1049h' || fail "transcript lacks the alt screen enable"
has term 'TERMINAL' || fail "transcript lacks a rendered frame (TERMINAL status)"
echo "PASS: SIGTERM: alt screen entered and a frame with the TERMINAL status painted"
has term '\033\\[?1049l' || fail "transcript lacks the alt screen disable"
ends_restored term || fail "output after the restore: $(tail -c 64 "$tmp/transcript.term" | od -c)"
has term '\033\\[?1006l' || fail "transcript lacks the mouse mode reset"
echo "PASS: SIGTERM: transcript ends with the restore (alt screen left, modes reset)"
cmp -s "$tmp/before.term" "$tmp/after.term" || fail "term: stty changed: $(diff "$tmp/before.term" "$tmp/after.term")"
echo "PASS: SIGTERM: tty settings unchanged"
[ "$(cat "$tmp/restart_status.term" 2>/dev/null)" = 0 ] && grep -q '^ok' "$tmp/restart.term" ||
  fail "kernel-restart: status $(cat "$tmp/restart_status.term" 2>/dev/null): $(cat "$tmp/restart.term" 2>/dev/null)"
grep -q 'herdr-broker: handoff graceful' "$log" || fail "kernel-restart: log lacks 'herdr-broker: handoff graceful'"
[ "$(grep -c 'terminal client started' "$log")" -ge 2 ] || fail "kernel-restart: the new VM started no terminal client"
adopted_app "$log" kernel-restart
echo "PASS: kernel-restart: graceful handoff, app adopted, the new VM's client started"
[ "$(count term '\033[?1049h')" -ge 2 ] && [ "$(count term '\033[?1049l')" -ge 2 ] ||
  fail "kernel-restart: the old client did not restore the tty before the new one took it"
grep -q -- '-icanon' "$tmp/mid.term" || fail "kernel-restart: tty not raw under the new client: $(cat "$tmp/mid.term")"
echo "PASS: kernel-restart: old client restored the tty, the new client re-entered raw mode"
left=$(vm_pids "$log" | while read -r p; do kill -0 "$p" 2>/dev/null && echo "$p"; done)
[ -z "$left" ] || fail "kernel-restart: vm pids still running: $left"
echo "PASS: kernel-restart: no vm left"

in_pty kill KILL
log="$tmp/log.kill"
[ -n "$(cat "$tmp/vm.kill" 2>/dev/null)" ] || fail "kill: no primary_pid in the broker status"
grep -q 'herdr-broker: handoff crash' "$log" || fail "kill: log lacks 'herdr-broker: handoff crash'"
[ "$(grep -c 'terminal client started' "$log")" -ge 2 ] || fail "kill: the new VM started no terminal client"
adopted_app "$log" kill
[ "$(cat "$tmp/status.kill")" = 0 ] || fail "kill: exit status $(cat "$tmp/status.kill") (wanted 0); log: $(tail -n 20 "$log" 2>&1)"
echo "PASS: kill -9 of the VM: broker handed off, app adopted, the new VM's client started, SIGTERM exit status 0"
cmp -s "$tmp/before.kill" "$tmp/after.kill" || fail "kill: stty changed: $(diff "$tmp/before.kill" "$tmp/after.kill")"
ends_restored kill || fail "kill: transcript does not end with the restore"
echo "PASS: kill -9 of the VM: tty settings unchanged, transcript ends with the restore"
left=$(vm_pids "$log" | while read -r p; do kill -0 "$p" 2>/dev/null && echo "$p"; done)
[ -z "$left" ] || fail "kill: vm pids still running: $left"
echo "PASS: kill -9 of the VM: no vm left"

in_pty early EARLY
[ "$(cat "$tmp/status.early")" = 3 ] || fail "early: exit status $(cat "$tmp/status.early") (wanted 3)"
cmp -s "$tmp/before.early" "$tmp/after.early" || fail "early: stty changed: $(diff "$tmp/before.early" "$tmp/after.early")"
esc=$(printf '\033')
has early '\033\\[<u' || fail "early: no kitty pop in the guard's restore"
LC_ALL=C sed "s/${esc}\[?1049h${esc}\[<u//g" "$tmp/transcript.early" | LC_ALL=C grep -q "${esc}\[<u" &&
  fail "early: a kitty pop outside the alt-screen sandwich (would pop the main screen's stack)"
ends_restored early || fail "early: transcript does not end with the guard's restore"
echo "PASS: early non-zero exit: guard exits 3, stty unchanged, kitty pop only inside the alt-screen sandwich"

[ "$verbose" = 1 ] && dump
exit 0
