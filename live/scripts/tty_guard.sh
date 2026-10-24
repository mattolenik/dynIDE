#!/bin/sh
# Runs a command that drives the controlling terminal (herdr-live, live-demo) and
# restores that terminal afterwards, whatever the cause, including kill -9 of
# the command, which no destructor survives. Usage: tty_guard.sh [-s] cmd [args...]
#
# Saves `stty -g` first and puts it back after the command exits. When the
# command exits non-zero it also writes the restore sequence (M2 ruling 6: kitty
# pop, mouse/paste/focus off, SGR/cursor reset, autowrap on, leave the alt
# screen); a zero exit restored the terminal itself. HUP, INT, QUIT and TERM
# sent to this script are forwarded to the command as TERM (a graceful VM stop)
# and the script waits for it. Exits with the command's status; with -s, a
# signal that reached this script turns a zero status into 1 (live-demo).
# Without a controlling terminal it just runs the command.
set -u
signal_fails=0
[ "${1:-}" = -s ] && { signal_fails=1; shift; }
saved=$({ stty -g </dev/tty; } 2>/dev/null) || exec "$@"
sig=0
# Async: a non-interactive sh keeps it in our process group (SIGWINCH and tty
# access stay with it); stdin is the caller's (herdr-live and live-demo use /dev/null).
"$@" <&0 &
child=$!
trap 'sig=1; kill -TERM "$child" 2>/dev/null' HUP INT QUIT TERM
status=
while [ -z "$status" ]; do
  wait "$child"
  st=$?
  # a trapped signal interrupts wait; an unreaped child still answers kill -0
  kill -0 "$child" 2>/dev/null || status=$st
done
[ "$signal_fails" = 1 ] && [ "$sig" = 1 ] && [ "$status" = 0 ] && status=1
stty "$saved" </dev/tty
# ponytail: the kitty pop also runs when the VM died before pushing; harmless
# on the alt screen it never left, could pop a main-screen flag otherwise.
[ "$status" = 0 ] ||
  printf '\033[<u\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1016l\033[?2004l\033[?1004l\033]8;;\033\\\033[0m\033[0 q\033[?25h\033[?7h\033[?1049l' >/dev/tty
exit "$status"
