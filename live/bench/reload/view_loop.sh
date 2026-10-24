#!/usr/bin/env bash
# Slice-1 reload metric: view_loop.
# Insert an infinite loop in View.compute at 97 columns, then resize the client to 97:
# resize -> 97-column scene after the 50ms budget, rollback and re-run on the old code.
# Target < budget + 100ms; asserts no dropped resize and a {:rolled_back} notice.
# Usage: live/bench/reload/view_loop.sh [--iterations N]. Prints a RESULT line; fails if
# live/apps is left dirty.
set -euo pipefail
cd "$(dirname "$0")/../.."
# compile first: a task recompiled by its own run keeps running old code (blocks purges)
MIX_ENV=test mix compile
MIX_ENV=test mix herdr.reload_bench view_loop "$@"
git diff --quiet -- apps || { echo "reload bench view_loop: live/apps left dirty" >&2; git diff --stat -- apps >&2; exit 1; }
