#!/bin/sh
# Smoke test: herdr-live must boot headless (HERDR_LIVE_HEADLESS=1) under a pty,
# stop on SIGTERM with status 0, leave the tty settings untouched, and print
# nothing to the terminal.
# Usage: launcher_smoke.sh [-v]    (SMOKE_TIMEOUT seconds to boot, default 600)
# The attached (terminal client) launch is attached_smoke.sh.
set -u
verbose=0
[ "${1:-}" = "-v" ] && verbose=1
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
timeout=${SMOKE_TIMEOUT:-600}

# shellcheck disable=SC2329 # invoked via trap
cleanup() {
  if [ -s "$tmp/pid" ]; then kill -KILL "$(cat "$tmp/pid")" 2>/dev/null; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

dump() {
  echo "--- log"; cat "$tmp/log/herdr-live.log" 2>&1
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
HERDR_LIVE_HEADLESS=1 HERDR_LIVE_LOG="$tmp/log/herdr-live.log" "$root/bin/herdr-live" &
pid=\$!
echo "\$pid" >"$tmp/pid"
i=0
until grep -qs 'herdr-live started' "$tmp/log/herdr-live.log"; do
  i=\$((i + 1))
  if [ "\$i" -gt $((timeout * 2)) ] || ! alive "\$pid"; then
    kill -KILL "\$pid" 2>/dev/null
    echo timeout >"$tmp/status"
    stty -a >"$tmp/after"
    exit 0
  fi
  sleep 0.5
done
kill -TERM "\$pid"
i=0
while alive "\$pid" && [ "\$i" -lt 80 ]; do
  i=\$((i + 1))
  [ "\$i" -gt 60 ] && kill -KILL "\$pid" 2>/dev/null
  sleep 0.5
done
wait "\$pid"
echo \$? >"$tmp/status"
stty -a >"$tmp/after"
INNER

case $(uname) in
  Darwin) script -q /dev/null "${SMOKE_SH:-sh}" "$tmp/inner.sh" >"$tmp/transcript" 2>&1 </dev/null ;;
  *) script -qec "${SMOKE_SH:-sh} $tmp/inner.sh" /dev/null >"$tmp/transcript" 2>&1 </dev/null ;;
esac

log="$tmp/log/herdr-live.log"
[ -s "$tmp/status" ] || fail "inner script did not finish"
[ "$(cat "$tmp/status")" = 0 ] || fail "exit status $(cat "$tmp/status") (wanted 0); log: $(tail -n 20 "$log" 2>&1)"
echo "PASS: exit status 0"
[ -s "$tmp/before" ] || fail "no stty dump (pty missing?)"
cmp -s "$tmp/before" "$tmp/after" || fail "stty changed: $(diff "$tmp/before" "$tmp/after")"
echo "PASS: tty settings unchanged"
grep -q 'herdr-live started' "$log" || fail "log lacks 'herdr-live started'"
grep -q 'herdr-live stopped' "$log" || fail "log lacks 'herdr-live stopped'"
echo "PASS: log has started and stopped"
! grep -q 'terminal client started' "$log" || fail "headless run started a terminal client"
echo "PASS: headless, no terminal client"
# Darwin script(1) echoes "^D" plus backspaces when its own stdin hits EOF; that is script, not the VM.
[ -z "$(tr -d '\r\n\b' <"$tmp/transcript" | sed 's/^\^D//')" ] || fail "terminal output: $(cat "$tmp/transcript")"
echo "PASS: terminal transcript empty"

[ "$verbose" = 1 ] && dump
exit 0
