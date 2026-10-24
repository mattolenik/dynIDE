#!/bin/sh
# Smoke test: herdr-live boots with the terminal client attached (no
# HERDR_LIVE_HEADLESS) on the real /dev/tty of a script(1) pty, sized 120x40.
# Run 1: logs 'terminal client started', paints a frame (alt screen entered,
# TERMINAL status), stops on SIGTERM with status 0 and 'herdr-live stopped',
# the transcript ends with the restore (alt screen left, modes reset) and the
# tty settings are unchanged. Run 2: kill -9 of the VM; scripts/tty_guard.sh
# restores the tty settings and writes the restore sequence.
# Usage: attached_smoke.sh [-v]    (SMOKE_TIMEOUT seconds to boot, default 600)
set -u
verbose=0
[ "${1:-}" = "-v" ] && verbose=1
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
timeout=${SMOKE_TIMEOUT:-600}

# shellcheck disable=SC2329 # invoked via trap
cleanup() {
  for f in "$tmp"/pid.*; do [ -s "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null; done
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
alive() { st=\$(ps -o stat= -p "\$1" 2>/dev/null); [ -n "\$st" ] && [ "\${st#Z}" = "\$st" ]; }
stty cols 120 rows 40
stty -a >"$tmp/before.\$run"
log="$tmp/log.\$run"
HERDR_LIVE_LOG="\$log" "$root/bin/herdr-live" &
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
if [ "\$2" = KILL ]; then
  # the VM is the guard's child (bin/herdr-live execs scripts/tty_guard.sh)
  vm=\$(pgrep -P "\$pid")
  echo "\$vm" >"$tmp/vm.\$run"
  kill -KILL \$vm
else
  kill -TERM "\$pid"
fi
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
# the transcript ends with leaving the alt screen (ignoring Darwin script(1)'s
# "^D" plus backspaces at EOF, and line ends)
ends_restored() {
  [ "$(LC_ALL=C tr -d '\r\n\b^D' <"$tmp/transcript.$1" | tail -c 8)" = "$(printf '\033[?1049l')" ]
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

in_pty kill KILL
[ -s "$tmp/vm.kill" ] || fail "kill: no VM pid found under the guard"
[ "$(cat "$tmp/status.kill")" = 137 ] || fail "kill: exit status $(cat "$tmp/status.kill") (wanted 137)"
echo "PASS: kill -9 of the VM: guard exits with the VM's status 137"
cmp -s "$tmp/before.kill" "$tmp/after.kill" || fail "kill: stty changed: $(diff "$tmp/before.kill" "$tmp/after.kill")"
ends_restored kill || fail "kill: transcript does not end with the guard's restore"
echo "PASS: kill -9 of the VM: guard restored the tty settings and wrote the restore sequence"

[ "$verbose" = 1 ] && dump
exit 0
