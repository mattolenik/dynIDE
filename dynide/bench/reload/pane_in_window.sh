#!/usr/bin/env bash
# Slice-1 reload metric: pane_in_window.
# Real HerdrReload.Server: batch K's App.Actions corrupts state the old code also fails
# on; a pane is split inside K's window, then the failing event: event -> restored
# scene. Asserts the spawned pane adopted into "scratch", every keeper id mapped, no
# orphan Pane.Server, a state-restored notice.
# Usage: dynide/bench/reload/pane_in_window.sh [--iterations N]. Prints a RESULT line;
# fails if
# dynide/apps is left dirty.
set -euo pipefail
cd "$(dirname "$0")/../.."
# compile first: a task recompiled by its own run keeps running old code (blocks purges)
MIX_ENV=test mix compile
MIX_ENV=test mix herdr.reload_bench pane_in_window "$@"
git diff --quiet -- apps || { echo "reload bench pane_in_window: dynide/apps left dirty" >&2; git diff --stat -- apps >&2; exit 1; }
