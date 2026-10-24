#!/usr/bin/env bash
# M6 gate: one measurement round of every slice-1 metric, logs under OUT (default
# .superpowers/sdd/m6/runs/<os>-<tag>). Usage: live/bench/gate_round.sh <tag> [suite...]
# Suites: env m3fake m3real m3real120 osfloor reload handoff glass herdrref (default: all).
# Runs suites one after another; never in parallel with another bench.
set -uo pipefail
live=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$live/.." && pwd)
tag=${1:?tag}; shift
os=$(uname -s | tr '[:upper:]' '[:lower:]')
out=${OUT:-$root/.superpowers/sdd/m6/runs/$os-$tag}
mkdir -p "$out"
suites=${*:-env m3fake m3real m3real120 osfloor reload handoff glass herdrref}

envinfo() {
  echo "commit=${GATE_COMMIT:-$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo none)} dirty=$(git -C "$root" status --porcelain -- live 2>/dev/null | wc -l | tr -d ' ')"
  echo "date=$(date -u +%FT%TZ)"
  uname -a
  if [ "$os" = darwin ]; then
    sysctl -n machdep.cpu.brand_string hw.ncpu hw.memsize
    uptime
    ps -Ao pid,%cpu,comm -r | head -8
  else
    nproc; grep MemTotal /proc/meminfo; cat /proc/loadavg
  fi
}

load() { if [ "$os" = darwin ]; then echo "$(uptime | sed 's/.*load averages*: //') idle=$(top -l 1 -n 0 | sed -n 's/.*sys, \([0-9.]*%\) idle.*/\1/p')"; else cut -d' ' -f1-3 /proc/loadavg; fi; }

run() {
  local name=$1; shift
  echo "== $name start load=$(load) $(date +%T)" | tee -a "$out/summary.txt"
  ( cd "$live" && "$@" ) > "$out/$name.log" 2>&1
  local st=$?
  echo "== $name exit=$st end load=$(load) $(date +%T)" | tee -a "$out/summary.txt"
}

for s in $suites; do
  case $s in
    env) envinfo > "$out/env.txt" 2>&1 ;;
    m3fake) run m3fake env MIX_ENV=test mix herdr.bench ;;
    m3real) run m3real env MIX_ENV=test mix herdr.bench --kernel real ;;
    m3real120) run m3real120 env MIX_ENV=test mix herdr.bench --kernel real --size 120x40 ;;
    osfloor) run osfloor "$live/bench/gate/os_floor.sh" ;;
    reload) run reload just --justfile "$root/justfile" live-bench-reload ;;
    handoff) run handoff just --justfile "$root/justfile" live-bench-handoff ;;
    glass) run glass just --justfile "$root/justfile" live-bench-glass ;;
    herdrref) run herdrref bash -c "cd '$root' && cargo test --release --locked --bin herdr server::render_scale_benchmark::render_scale_profile -- --exact --ignored --nocapture --test-threads=1" ;;
    *) echo "unknown suite $s" >&2; exit 2 ;;
  esac
done
