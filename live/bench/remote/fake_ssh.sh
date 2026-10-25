#!/bin/sh
# Stand-in for ssh in tests and benches (M16): ignores ssh options and the host and runs the
# remote command (`<remote_bin> attach-relay [session]`) locally. When
# HERDR_LIVE_FAKE_SSH_PIDFILE is set it records its own pid first (exec keeps the pid, so
# that pid is the relay's), so a test can kill the relay to simulate a network drop.
while [ $# -gt 0 ]; do
  case $1 in
    -o | -p | -i | -l | -F | -J | -L | -R | -D | -E | -S) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
[ $# -ge 2 ] || { echo "fake_ssh: expected <host> <command...>" >&2; exit 255; }
shift # the host
[ -z "${HERDR_LIVE_FAKE_SSH_PIDFILE:-}" ] || echo $$ >"$HERDR_LIVE_FAKE_SSH_PIDFILE"
exec "$@"
