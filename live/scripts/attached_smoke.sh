#!/bin/sh
# Smoke test: herdr-live boots with the terminal client attached (no
# HERDR_LIVE_HEADLESS) under a pty, logs 'herdr-live started' and
# 'terminal client started', stops on SIGTERM with status 0 and leaves the tty
# settings unchanged. Shares launcher_smoke.sh. Usage: attached_smoke.sh [-v]
SMOKE_ATTACHED=1 exec "$(dirname "$0")/launcher_smoke.sh" "$@"
