#!/usr/bin/env bash
# Slice-1 reload metric: session_field.
# Add a field to App.Session; save -> {:loaded} and the fan-out module count (the known-
# expensive case).
# Usage: dynide/bench/reload/session_field.sh [--iterations N]. Prints a RESULT line;
# fails if
# dynide/apps is left dirty.
set -euo pipefail
cd "$(dirname "$0")/../.."
# compile first: a task recompiled by its own run keeps running old code (blocks purges)
MIX_ENV=test mix compile
MIX_ENV=test mix dynide.reload_bench session_field "$@"
git diff --quiet -- apps || { echo "reload bench session_field: dynide/apps left dirty" >&2; git diff --stat -- apps >&2; exit 1; }
