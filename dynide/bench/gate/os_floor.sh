#!/usr/bin/env bash
# M6 gate: OS-only scheduler-stall floor. A BEAM probe (os_floor.exs) idle, then next
# to 15 parallel pty `cat`s of a 100 MiB file via script(1), with no herdr code.
# Prints per iteration: OS_FLOOR iter=N idle_max_ms=.. flood_max_ms=.. flood_wall_ms=..
# Usage: dynide/bench/gate/os_floor.sh   (env: ITERS=3, FLOOD_DUR_MS=12000)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
iters=${ITERS:-3}; dur=${FLOOD_DUR_MS:-12000}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/os_floor.XXXXXX")
pids=()
cleanup() {
  for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

python3 - "$tmp/flood100" <<'PY'
import sys
with open(sys.argv[1], 'w') as f:
    n = 0
    while f.tell() < 100 * 1024 * 1024:
        f.write(f'{n:010d} ' + 'x' * 52 + '\n'); n += 1
PY

now_ms() { python3 -c 'import time; print(int(time.monotonic()*1000))'; }
maxms() { sed -n 's/^probe max \([0-9.]*\) ms.*/\1/p' "$1" | head -1; }

# OS branch lives here, not in Elixir core.
flood_cat() {
  if [ "$(uname -s)" = Darwin ]; then
    script -q /dev/null cat "$tmp/flood100" > /dev/null
  else
    script -q -c "cat $tmp/flood100" /dev/null > /dev/null
  fi
}

for i in $(seq 1 "$iters"); do
  DUR_MS=4000 elixir "$here/os_floor.exs" > "$tmp/idle$i.txt" 2>&1
  DUR_MS=$dur elixir "$here/os_floor.exs" > "$tmp/flood$i.txt" 2>&1 &
  probe=$!; pids=("$probe")
  sleep 1
  start=$(now_ms); cats=()
  for _ in $(seq 1 15); do flood_cat & cats+=("$!"); done
  pids+=("${cats[@]}")
  wait "${cats[@]}"
  wall=$(( $(now_ms) - start ))
  wait "$probe"; pids=()
  echo "OS_FLOOR iter=$i idle_max_ms=$(maxms "$tmp/idle$i.txt") flood_max_ms=$(maxms "$tmp/flood$i.txt") flood_wall_ms=$wall"
done
