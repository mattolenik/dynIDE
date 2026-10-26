# dynIDE recipes (imported from the root justfile)

dynide_dir := source_directory()
dynide_crates := "dynide_fdpass dynide_kernel dynide_term dynide_broker"

# Elixir and Rust tests
dynide-test:
    cd '{{dynide_dir}}' && mix test
    cd '{{dynide_dir}}/apps/dynide_integration' && mix test --only real_kernel
    for c in {{dynide_crates}}; do (cd '{{dynide_dir}}/native'/$c && cargo test --locked) || exit 1; done
    python3 -m unittest discover -s '{{dynide_dir}}/scripts' -p 'test_log_summary.py'

# Milestone gate: lint, types, tests, launcher, handoff and attached smokes, tty harness
# (M2 destructor and demo; dynide attached on the real kernels, then 15 panes + cat flood,
# then selfhost: edit, reload, rollback, kernel-restart; then persist: stop, start, same layout and cwds;
# then agent: the CLI from a pane; then plugins: two herdr example plugins unmodified)
dynide-check:
    cd '{{dynide_dir}}' && mix deps.get
    cd '{{dynide_dir}}' && mix format --check-formatted
    cd '{{dynide_dir}}' && mix credo --strict
    cd '{{dynide_dir}}' && mix dialyzer
    for c in {{dynide_crates}}; do (cd '{{dynide_dir}}/native'/$c && cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings) || exit 1; done
    just --justfile '{{justfile()}}' dynide-test
    '{{dynide_dir}}/scripts/launcher_smoke.sh'
    elixir '{{dynide_dir}}/bench/handoff/smoke.exs'
    '{{dynide_dir}}/scripts/attached_smoke.sh'
    python3 '{{dynide_dir}}/scripts/tty_harness.py' destructor
    python3 '{{dynide_dir}}/scripts/tty_harness.py' demo
    python3 '{{dynide_dir}}/scripts/tty_harness.py' dynide
    python3 '{{dynide_dir}}/scripts/tty_harness.py' dynide-stress
    python3 '{{dynide_dir}}/scripts/tty_harness.py' selfhost
    python3 '{{dynide_dir}}/scripts/tty_harness.py' persist
    python3 '{{dynide_dir}}/scripts/tty_harness.py' agent
    python3 '{{dynide_dir}}/scripts/tty_harness.py' plugins
    python3 '{{dynide_dir}}/scripts/tty_harness.py' remote
    python3 '{{dynide_dir}}/scripts/tty_harness.py' broker-kill

# Summarise a dynIDE log (reloads, rollbacks, handoffs, restores, session losses); args: [LOG ...] [--since ISO] [--json]
dynide-log-summary *args:
    python3 '{{dynide_dir}}/scripts/log_summary.py' {{args}}

# Compile, then run dynide
dynide-run:
    cd '{{dynide_dir}}' && mix compile
    exec '{{dynide_dir}}/bin/dynide'

# Throwaway tty/blit demo in this terminal (q quits, Ctrl-Z suspends)
dynide-demo:
    exec '{{dynide_dir}}/bin/dynide-demo'

# M3 benchmarks against the fake kernel (Elixir side only; judged at M6).
# Real server kernel: MIX_ENV=test mix dynide.bench --kernel real [--flood-mb N].
# The client side always blits to Fake.Blit (no real tty in CI); the real
# blitter's frame cost is M2's (docs/dynide/results/m2.md).
dynide-bench:
    cd '{{dynide_dir}}' && MIX_ENV=test mix dynide.bench

# M6 gate: keystroke -> glass in a real pty, herdr (the herdr-reference tag build, or HERDR_BIN) then dynide (GLASS lines)
dynide-bench-glass:
    cd '{{dynide_dir}}' && mix compile
    python3 '{{dynide_dir}}/bench/gate/glass.py' herdr --n 500
    python3 '{{dynide_dir}}/bench/gate/glass.py' dynide --n 500

# M9 exit evidence: terminal-fidelity checks in a real pty (PASS/FAIL per check), then reflow against herdr
dynide-bench-fidelity:
    cd '{{dynide_dir}}' && mix compile
    python3 '{{dynide_dir}}/bench/fidelity/fidelity.py'
    python3 '{{dynide_dir}}/bench/fidelity/reflow.py'

# M10 exit evidence: kitty placements per pane against herdr in a real pty (PASS/FAIL per step)
dynide-bench-graphics:
    cd '{{dynide_dir}}' && mix compile
    python3 '{{dynide_dir}}/bench/graphics/graphics.py'

# OS-only scheduler-stall floor (M6 gate): BEAM probe next to 15 pty cats, no herdr code
dynide-bench-os-floor:
    '{{dynide_dir}}/bench/gate/os_floor.sh'

# Reload benchmarks (M4): phase 1 latency and guard overhead, then every slice-1
# reload metric script (bench/reload/*.sh; each prints a RESULT line)
dynide-bench-reload:
    cd '{{dynide_dir}}' && mix run bench/reload/reload_bench.exs && mix run bench/reload/guard_bench.exs
    for s in render view ui_field session_field scene_field view_loop closure pane_in_window cat15; do '{{dynide_dir}}'/bench/reload/$s.sh || exit 1; done

# M5 handoff benches (headless): kill -9 with 15 panes, typing through kernel-restart
dynide-bench-handoff:
    elixir '{{dynide_dir}}/bench/handoff/kill9.exs'
    elixir '{{dynide_dir}}/bench/handoff/typing.exs'

# M16 remote attach bench (headless instance per transport): typing latency over the unix
# client socket and over the fake_ssh.sh relay, then a 15-pane flood. Args: keys= flood= mb= panes= only=
dynide-bench-remote *args:
    elixir '{{dynide_dir}}/bench/remote/bench.exs' unix {{args}}
    elixir '{{dynide_dir}}/bench/remote/bench.exs' relay {{args}}

# M18: the self-contained release tarball and .sha256 in dynide/_build/release; args: [--version V] [--out DIR]
dynide-release *args:
    '{{dynide_dir}}/scripts/release/build.sh' {{args}}

# M18: install the release (built first unless a tarball is given) under a temp prefix and smoke it in a clean env
dynide-release-smoke *args:
    '{{dynide_dir}}/scripts/release/release_smoke.sh' {{args}}

# M18: install the release tarballs into a fresh macOS HOME/prefix and a clean ubuntu:24.04 container (podman)
dynide-release-install-check *args:
    '{{dynide_dir}}/scripts/release/fresh_install_check.sh' {{args}}
