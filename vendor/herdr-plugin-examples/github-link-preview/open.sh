#!/usr/bin/env bash
set -euo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"
url="${HERDR_PLUGIN_CLICKED_URL:-}"

if [[ -z "$url" ]]; then
  echo "missing HERDR_PLUGIN_CLICKED_URL" >&2
  exit 0
fi

exec "$herdr_bin" plugin pane open \
  --plugin examples.github-link-preview \
  --entrypoint preview \
  --placement split \
  --direction right \
  --env "GITHUB_URL=$url" \
  --focus
