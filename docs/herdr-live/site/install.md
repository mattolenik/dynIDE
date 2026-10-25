# Install

The 0.1.0 release targets macOS arm64 and Linux aarch64. Nothing is published yet:
you build the tarball locally.

## Build

<!-- m18: verify against task 1 -->
```sh
live/scripts/release/build.sh [--version V]
```

Produces `live/_build/release/herdr-live-<V>-<os>-<arch>.tar.gz` and a `.sha256` next to
it (`os` is `macos` or `linux`, `arch` is `aarch64`). Building needs the toolchain in
[AGENTS.md](../../../AGENTS.md) (Elixir 1.20.4 / OTP 29, Rust, Zig 0.16.0).

## Install

<!-- m18: verify against task 2 -->
```sh
live/scripts/release/install.sh [--prefix P] TARBALL
```

Default prefix is `~/.local`. Layout:

- `<P>/lib/herdr-live/releases/<V>/` the release
- `<P>/lib/herdr-live/current` symlink to the active release
- `<P>/bin/herdr-live` symlink to `current/bin/herdr-live`

Put `<P>/bin` on `PATH`. The prefix may contain spaces.

```sh
herdr-live --version   # <!-- m18: verify against task 1 -->
herdr-live             # start, or attach to the running instance
```

The release is a production build: hot reload is off, and there is no Erlang
distribution or remote shell. To edit herdr-live while it runs, use a source checkout
([editing-live.md](editing-live.md)).

## Update in place

<!-- m18: verify against task 3 -->
```sh
herdr-live update [--manifest URL] [--check] [--yes] [--no-restart]
```

`--check` only reports whether a newer version exists. Otherwise the update downloads the
tarball named in a signed manifest, verifies its sha256 and the manifest's ed25519
signature against the keys shipped in the release, installs it beside the old release,
flips `current`, and runs `kernel-restart` so the running sessions move to the new
version without losing terminals. If the restart fails, `current` is flipped back. With no
instance running it installs and says so. `--no-restart` leaves the running instance on
the old version until you restart it.

The broker process keeps running the old binary until a full stop and start; broker-side
fixes need that. Manifest format: [update-manifest.md](update-manifest.md). Keys and
signing: [signing.md](signing.md).
