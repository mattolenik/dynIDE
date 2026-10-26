#!/usr/bin/env bash
# Slice-1 reload metric: closure.
# App.Actions puts a local fun into state on a paste: event -> {:rejected} notice; then
# a second reload of App.Actions. Asserts the Store and Pane.Server pids unchanged, no
# purge_blocked, no fun in state.
# Usage: dynide/bench/reload/closure.sh [--iterations N]. Prints a RESULT line; fails if
# dynide/apps is left dirty.
set -euo pipefail
cd "$(dirname "$0")/../.."
# compile first: a task recompiled by its own run keeps running old code (blocks purges)
MIX_ENV=test mix compile
MIX_ENV=test mix dynide.reload_bench closure "$@"
git diff --quiet -- apps || { echo "reload bench closure: dynide/apps left dirty" >&2; git diff --stat -- apps >&2; exit 1; }
