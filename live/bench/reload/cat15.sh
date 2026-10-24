#!/usr/bin/env bash
# Slice-1 reload metric: cat15.
# Real server kernel, 15 /bin/sh panes looping `cat` over an 8MiB file; the View chrome
# edit's save -> visible while they run.
# Usage: live/bench/reload/cat15.sh [--iterations N]. Prints a RESULT line; fails if
# live/apps is left dirty.
set -euo pipefail
cd "$(dirname "$0")/../.."
# compile first: a task recompiled by its own run keeps running old code (blocks purges)
MIX_ENV=test mix compile
MIX_ENV=test mix herdr.reload_bench cat15 "$@"
git diff --quiet -- apps || { echo "reload bench cat15: live/apps left dirty" >&2; git diff --stat -- apps >&2; exit 1; }
