#!/usr/bin/env bash
# Prints the absolute path of a release `herdr` binary (the pre-prune Rust product).
# $HERDR_BIN (must be executable) wins; otherwise builds the `herdr-reference` tag from
# `git archive` under ${XDG_CACHE_HOME:-$HOME/.cache}/herdr-live/herdr-reference/<short sha>
# (reused once target/release/herdr exists).
# --print-dir prints the extracted source tree instead (exit 3 when HERDR_BIN is set and
# no tree exists).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/herdr-live/herdr-reference
mode=bin
[ "${1:-}" = "--print-dir" ] && mode=dir

if [ -n "${HERDR_BIN:-}" ]; then
  [ -x "$HERDR_BIN" ] || { echo "herdr_ref: HERDR_BIN=$HERDR_BIN is not executable" >&2; exit 1; }
  if [ "$mode" = bin ]; then
    echo "$HERDR_BIN"
    exit 0
  fi
  # a tree is only known when it was already extracted
  sha=$(git -C "$repo" rev-parse --short herdr-reference 2>/dev/null || true)
  if [ -n "$sha" ] && [ -d "$cache/$sha/src" ]; then echo "$cache/$sha"; exit 0; fi
  echo "herdr_ref: HERDR_BIN gives no source tree" >&2
  exit 3
fi

sha=$(git -C "$repo" rev-parse --short herdr-reference) ||
  { echo "herdr_ref: tag herdr-reference not found" >&2; exit 1; }
dir=$cache/$sha
if [ ! -d "$dir/src" ]; then
  mkdir -p "$dir.tmp.$$"
  git -C "$repo" archive herdr-reference | tar -x -C "$dir.tmp.$$"
  rm -rf "$dir"
  mv "$dir.tmp.$$" "$dir"
fi
if [ "$mode" = dir ]; then echo "$dir"; exit 0; fi
if [ ! -x "$dir/target/release/herdr" ]; then
  (cd "$dir" && cargo build --release --locked) >&2
fi
echo "$dir/target/release/herdr"
