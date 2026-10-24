#!/usr/bin/env bash
# Slice-1 reload metric: view.
# Edit View.compute's chrome (a status text node with a unique marker per save); save ->
# {:loaded} and save -> visible. Target < 500ms p95.
# Usage: live/bench/reload/view.sh [--iterations N]. Prints a RESULT line; fails if
# live/apps is left dirty.
set -euo pipefail
cd "$(dirname "$0")/../.."
# compile first: a task recompiled by its own run keeps running old code (blocks purges)
MIX_ENV=test mix compile
MIX_ENV=test mix herdr.reload_bench view "$@"
git diff --quiet -- apps || { echo "reload bench view: live/apps left dirty" >&2; git diff --stat -- apps >&2; exit 1; }
