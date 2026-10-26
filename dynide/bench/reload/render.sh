#!/usr/bin/env bash
# Slice-1 reload metric: render.
# Edit Client.Term.Render.Compose (a tab label's text, unique marker per save); save ->
# {:loaded} and save -> first client frame showing the marker. Target < 500ms p95.
# Usage: dynide/bench/reload/render.sh [--iterations N]. Prints a RESULT line; fails if
# dynide/apps is left dirty.
set -euo pipefail
cd "$(dirname "$0")/../.."
# compile first: a task recompiled by its own run keeps running old code (blocks purges)
MIX_ENV=test mix compile
MIX_ENV=test mix dynide.reload_bench render "$@"
git diff --quiet -- apps || { echo "reload bench render: dynide/apps left dirty" >&2; git diff --stat -- apps >&2; exit 1; }
