#!/usr/bin/env bash
# Verification command for the autofork workflow (fork-only).
#
# Runs on a bare ubuntu runner after every rebase and review fix, so it installs
# the same toolchain CI uses (Zig 0.16.0, just, cargo-nextest, Bun) into the
# ignored target/ directory, then runs the Linux CI lint and test recipes.
set -euo pipefail

cd "$(dirname "$0")/.."

ZIG_VERSION=0.16.0
BUN_VERSION=1.3.14
TOOLS="$PWD/target/autofork-tools"
mkdir -p "$TOOLS/bin"
export PATH="$TOOLS/bin:$HOME/.cargo/bin:$PATH"

arch=$(uname -m)
case "$arch" in
  x86_64) zig_arch=x86_64; bun_arch=x64 ;;
  aarch64|arm64) zig_arch=aarch64; bun_arch=aarch64 ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac

if [[ ! -x "$TOOLS/zig/zig" ]]; then
  echo "installing zig $ZIG_VERSION"
  mkdir -p "$TOOLS/zig"
  curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-$zig_arch-linux-$ZIG_VERSION.tar.xz" \
    | tar -xJ --strip-components=1 -C "$TOOLS/zig"
fi
export ZIG="$TOOLS/zig/zig"
[[ "$("$ZIG" version)" == "$ZIG_VERSION" ]] || { echo "zig $ZIG_VERSION required" >&2; exit 1; }

if ! command -v just >/dev/null; then
  echo "installing just"
  curl --proto '=https' --tlsv1.2 -fsSL https://just.systems/install.sh | bash -s -- --to "$TOOLS/bin"
fi

if ! command -v cargo-nextest >/dev/null; then
  echo "installing cargo-nextest"
  curl -fsSL https://get.nexte.st/latest/linux | tar -xz -C "$TOOLS/bin"
fi

if ! command -v bun >/dev/null; then
  echo "installing bun $BUN_VERSION"
  curl -fsSL https://bun.sh/install | BUN_INSTALL="$TOOLS/bun" bash -s -- "bun-v$BUN_VERSION" >/dev/null
  ln -sf "$TOOLS/bun/bin/bun" "$TOOLS/bin/bun"
fi

# rust-toolchain.toml pins the compiler; rustup installs it on first use.
export CARGO_INCREMENTAL=1
just lint
just ci-tests 'all()'
