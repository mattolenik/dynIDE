# herdr-live recipes (imported from the root justfile)

live_dir := source_directory()
live_crates := "herdr_kernel herdr_term"

# Elixir and Rust tests
live-test:
    cd '{{live_dir}}' && mix test
    cd '{{live_dir}}/apps/herdr_integration' && mix test --only real_kernel
    for c in {{live_crates}}; do (cd '{{live_dir}}/native'/$c && cargo test --locked) || exit 1; done

# Milestone gate: lint, types, tests, launcher and attached smokes, tty harness
# (M2 destructor and demo; herdr-live attached on the real kernels, then 15 panes + cat flood)
live-check:
    cd '{{live_dir}}' && mix deps.get
    cd '{{live_dir}}' && mix format --check-formatted
    cd '{{live_dir}}' && mix credo --strict
    cd '{{live_dir}}' && mix dialyzer
    for c in {{live_crates}}; do (cd '{{live_dir}}/native'/$c && cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings) || exit 1; done
    just --justfile '{{justfile()}}' live-test
    '{{live_dir}}/scripts/launcher_smoke.sh'
    '{{live_dir}}/scripts/attached_smoke.sh'
    python3 '{{live_dir}}/scripts/tty_harness.py' destructor
    python3 '{{live_dir}}/scripts/tty_harness.py' demo
    python3 '{{live_dir}}/scripts/tty_harness.py' herdr
    python3 '{{live_dir}}/scripts/tty_harness.py' herdr-stress

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

# Reload benchmarks (M4): phase 1 latency and guard overhead, then every slice-1
# reload metric script (bench/reload/*.sh; each prints a RESULT line)
live-bench-reload:
    cd '{{live_dir}}' && mix run bench/reload/reload_bench.exs && mix run bench/reload/guard_bench.exs
    for s in render view ui_field session_field scene_field view_loop closure pane_in_window cat15; do '{{live_dir}}'/bench/reload/$s.sh || exit 1; done
