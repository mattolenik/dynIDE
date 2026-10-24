# herdr-live recipes (imported from the root justfile)

live_dir := source_directory()
live_crates := "herdr_kernel herdr_term"

# Elixir and Rust tests
live-test:
    cd '{{live_dir}}' && mix test
    for c in {{live_crates}}; do (cd '{{live_dir}}/native'/$c && cargo test --locked) || exit 1; done

# Milestone gate: lint, types, tests, launcher smoke
live-check:
    cd '{{live_dir}}' && mix deps.get
    cd '{{live_dir}}' && mix format --check-formatted
    cd '{{live_dir}}' && mix credo --strict
    cd '{{live_dir}}' && mix dialyzer
    for c in {{live_crates}}; do (cd '{{live_dir}}/native'/$c && cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings) || exit 1; done
    just --justfile '{{justfile()}}' live-test
    '{{live_dir}}/scripts/launcher_smoke.sh'

# Compile, then run herdr-live
live-run:
    cd '{{live_dir}}' && mix compile
    exec '{{live_dir}}/bin/herdr-live'

# Placeholder until slice-1 metrics
live-bench:
    @echo 'live-bench: no benchmarks yet (M0 placeholder; slice-1 metrics land in M6)'

# Reload latency and guard overhead benchmarks (M4)
live-bench-reload:
    cd '{{live_dir}}' && mix run bench/reload/reload_bench.exs && mix run bench/reload/guard_bench.exs
