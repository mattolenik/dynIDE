#!/usr/bin/env bash
# Slice-1 reload metric: ui_field.
# Add a field with a default to App.Ui (View shows its default) while 15 panes stream
# output from the fake kernel; save -> visible and the fan-out module count. Target < 1s
# p95.
# Usage: dynide/bench/reload/ui_field.sh [--iterations N]. Prints a RESULT line; fails if
# dynide/apps is left dirty.
set -euo pipefail
cd "$(dirname "$0")/../.."
# compile first: a task recompiled by its own run keeps running old code (blocks purges)
MIX_ENV=test mix compile
MIX_ENV=test mix dynide.reload_bench ui_field "$@"
git diff --quiet -- apps || { echo "reload bench ui_field: dynide/apps left dirty" >&2; git diff --stat -- apps >&2; exit 1; }
