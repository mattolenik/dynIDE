#!/usr/bin/env bash
# Slice-1 reload metric: scene_field.
# Add a field to HerdrScene.Scene.Node; save -> {:loaded} and the fan-out across
# herdr_scene/herdr_server/herdr_term.
# Usage: dynide/bench/reload/scene_field.sh [--iterations N]. Prints a RESULT line; fails
# if
# dynide/apps is left dirty.
set -euo pipefail
cd "$(dirname "$0")/../.."
# compile first: a task recompiled by its own run keeps running old code (blocks purges)
MIX_ENV=test mix compile
MIX_ENV=test mix herdr.reload_bench scene_field "$@"
git diff --quiet -- apps || { echo "reload bench scene_field: dynide/apps left dirty" >&2; git diff --stat -- apps >&2; exit 1; }
