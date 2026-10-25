#!/usr/bin/env bash
# Run a command (default `just dynide-check`) on Linux in podman against a copy of
# this worktree. The worktree is mounted read-only at /src and copied to /work
# without host build outputs, so macOS artifacts never mix with Linux ones.
#   dynide/scripts/linux_check.sh                       # just dynide-check
#   dynide/scripts/linux_check.sh just dynide-bench-handoff
#   dynide/scripts/linux_check.sh 'cd dynide/native/herdr_kernel && cargo test --locked'
# LINUX_CHECK_OUT=<host dir> mounts it writable at /out (bench logs).
# LINUX_CHECK_IMAGE (default localhost/herdr-m6-check) and LINUX_CHECK_VOLUME_PREFIX
# (default herdr-m6: <prefix>-cargo, <prefix>-hex) name the image and cache volumes.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
image=${LINUX_CHECK_IMAGE:-localhost/herdr-m6-check}
vols=${LINUX_CHECK_VOLUME_PREFIX:-herdr-m6}

if ! podman image exists "$image"; then
  podman build -t "$image" -f "$here/linux/Containerfile" "$here/linux"
fi

cmd=${*:-just dynide-check}

exec podman run --rm ${LINUX_CHECK_TTY:+-t} \
  -v "$root:/src:ro" \
  -v "$vols-cargo:/root/.cargo/registry" \
  -v "$vols-hex:/root/.hex" \
  ${LINUX_CHECK_OUT:+-v "$LINUX_CHECK_OUT:/out"} \
  -e CARGO_BUILD_JOBS=4 \
  "$image" \
  bash -c 'set -e
    uname -a; nproc; cat /proc/loadavg
    rsync -a --exclude .git --exclude _build --exclude deps --exclude target \
      --exclude priv/native --exclude node_modules /src/ /work/
    cd /work && git init -q
    '"$cmd"
