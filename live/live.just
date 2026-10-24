# herdr-live recipes (imported from the root justfile)

live_dir := source_directory()
live_crates := "herdr_fdpass herdr_kernel herdr_term herdr_broker"

# Elixir and Rust tests
live-test:
    cd '{{live_dir}}' && mix test
    cd '{{live_dir}}/apps/herdr_integration' && mix test --only real_kernel
    for c in {{live_crates}}; do (cd '{{live_dir}}/native'/$c && cargo test --locked) || exit 1; done
    python3 -m unittest discover -s '{{live_dir}}/scripts' -p 'test_log_summary.py'

# Milestone gate: lint, types, tests, launcher, handoff and attached smokes, tty harness
# (M2 destructor and demo; herdr-live attached on the real kernels, then 15 panes + cat flood,
# then selfhost: edit, reload, rollback, kernel-restart; then persist: stop, start, same layout and cwds;
# then agent: the CLI from a pane)
live-check:
    cd '{{live_dir}}' && mix deps.get
    cd '{{live_dir}}' && mix format --check-formatted
    cd '{{live_dir}}' && mix credo --strict
    cd '{{live_dir}}' && mix dialyzer
    for c in {{live_crates}}; do (cd '{{live_dir}}/native'/$c && cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings) || exit 1; done
    just --justfile '{{justfile()}}' live-test
    '{{live_dir}}/scripts/launcher_smoke.sh'
    elixir '{{live_dir}}/bench/handoff/smoke.exs'
    '{{live_dir}}/scripts/attached_smoke.sh'
    python3 '{{live_dir}}/scripts/tty_harness.py' destructor
    python3 '{{live_dir}}/scripts/tty_harness.py' demo
    python3 '{{live_dir}}/scripts/tty_harness.py' herdr
    python3 '{{live_dir}}/scripts/tty_harness.py' herdr-stress
    python3 '{{live_dir}}/scripts/tty_harness.py' selfhost
    python3 '{{live_dir}}/scripts/tty_harness.py' persist
    python3 '{{live_dir}}/scripts/tty_harness.py' agent

# Summarise a herdr-live log (reloads, rollbacks, handoffs, restores, session losses); args: [LOG ...] [--since ISO] [--json]
live-log-summary *args:
    python3 '{{live_dir}}/scripts/log_summary.py' {{args}}

# Compile, then run herdr-live
live-run:
    cd '{{live_dir}}' && mix compile
    exec '{{live_dir}}/bin/herdr-live'

# Throwaway tty/blit demo in this terminal (q quits, Ctrl-Z suspends)
live-demo:
    exec '{{live_dir}}/bin/live-demo'

# M3 benchmarks against the fake kernel (Elixir side only; judged at M6).
# Real server kernel: MIX_ENV=test mix herdr.bench --kernel real [--flood-mb N].
# The client side always blits to Fake.Blit (no real tty in CI); the real
# blitter's frame cost is M2's (docs/herdr-live/results/m2.md).
live-bench:
    cd '{{live_dir}}' && MIX_ENV=test mix herdr.bench

# M6 gate: keystroke -> glass in a real pty, herdr (the herdr-reference tag build, or HERDR_BIN) then herdr-live (GLASS lines)
live-bench-glass:
    cd '{{live_dir}}' && mix compile
    python3 '{{live_dir}}/bench/gate/glass.py' herdr --n 500
    python3 '{{live_dir}}/bench/gate/glass.py' herdr-live --n 500

# OS-only scheduler-stall floor (M6 gate): BEAM probe next to 15 pty cats, no herdr code
live-bench-os-floor:
    '{{live_dir}}/bench/gate/os_floor.sh'

# Reload benchmarks (M4): phase 1 latency and guard overhead, then every slice-1
# reload metric script (bench/reload/*.sh; each prints a RESULT line)
live-bench-reload:
    cd '{{live_dir}}' && mix run bench/reload/reload_bench.exs && mix run bench/reload/guard_bench.exs
    for s in render view ui_field session_field scene_field view_loop closure pane_in_window cat15; do '{{live_dir}}'/bench/reload/$s.sh || exit 1; done

# M5 handoff benches (headless): kill -9 with 15 panes, typing through kernel-restart
live-bench-handoff:
    elixir '{{live_dir}}/bench/handoff/kill9.exs'
    elixir '{{live_dir}}/bench/handoff/typing.exs'
