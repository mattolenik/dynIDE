#!/usr/bin/env bash
# Run a command (default `just live-check`) on Linux in podman against a copy of
# this worktree. The worktree is mounted read-only at /src and copied to /work
# without host build outputs, so macOS artifacts never mix with Linux ones.
#   live/scripts/linux_check.sh                       # just live-check
#   live/scripts/linux_check.sh just live-bench-handoff
#   live/scripts/linux_check.sh 'cd live/native/herdr_kernel && cargo test --locked'
# LINUX_CHECK_OUT=<host dir> mounts it writable at /out (bench logs).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
image=localhost/herdr-m6-check

if ! podman image exists "$image"; then
  podman build -t "$image" -f "$here/linux/Containerfile" "$here/linux"
fi

cmd=${*:-just live-check}

exec podman run --rm ${LINUX_CHECK_TTY:+-t} \
  -v "$root:/src:ro" \
  -v herdr-m6-cargo:/root/.cargo/registry \
  -v herdr-m6-hex:/root/.hex \
  ${LINUX_CHECK_OUT:+-v "$LINUX_CHECK_OUT:/out"} \
  -e CARGO_BUILD_JOBS=4 \
  "$image" \
  bash -c 'set -e
    uname -a; nproc; cat /proc/loadavg
    rsync -a --exclude .git --exclude _build --exclude deps --exclude target \
      --exclude priv/native --exclude node_modules /src/ /work/
    cd /work && git init -q
    '"$cmd"
