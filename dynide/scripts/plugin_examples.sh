#!/usr/bin/env bash
# Prints the dir holding herdr's example plugins at the pinned commit (ruling R7: they have no
# upstream licence, so they are fetched, never vendored). Cache:
# ${XDG_CACHE_HOME:-$HOME/.cache}/dynide/plugin-examples/18709cd.
# DYNIDE_OFFLINE=1 forbids fetching. Exit 3 with "SKIP: ..." when neither cache nor network.
set -u
sha=18709cdc851dd63ed0543eb8388343a5446fd8d8
dir="${XDG_CACHE_HOME:-$HOME/.cache}/dynide/plugin-examples/18709cd"

ok() { [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$sha" ] \
  && [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; }

if ! ok; then
  if [ "${DYNIDE_OFFLINE:-}" = 1 ]; then
    echo "SKIP: no cached plugin examples at $dir and DYNIDE_OFFLINE=1" >&2
    exit 3
  fi
  tmp="$dir.tmp.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp" \
    && git -C "$tmp" init -q \
    && git -C "$tmp" fetch -q --depth 1 https://github.com/ogulcancelik/herdr-plugin-examples.git "$sha" \
    && git -C "$tmp" checkout -q --detach FETCH_HEAD \
    && [ "$(git -C "$tmp" rev-parse HEAD)" = "$sha" ] \
    || { rm -rf "$tmp"; echo "SKIP: no network and no cache for plugin examples" >&2; exit 3; }
  rm -rf "$dir"
  mv "$tmp" "$dir"
fi
echo "$dir"
