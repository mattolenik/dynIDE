#!/bin/sh
# Dev update signing key pair (M18 R5). Usage: keygen.sh [DIR]
# Writes DIR/dev-update.key (0600, base64 of the raw 32-byte ed25519 private key) and
# DIR/dev-update.pub (0644, base64 of the raw 32-byte public key); DIR defaults to
# dynide/_build/release/keys (git-ignored, never committed). An existing pair is kept.
# Prints the .pub path. Needs erl on PATH (a dev machine).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dir=${1:-$here/../../_build/release/keys}
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
if [ -f "$dir/dev-update.key" ] && [ -f "$dir/dev-update.pub" ]; then
  echo "$dir/dev-update.pub"
  exit 0
fi
(umask 077 && erl -noshell -eval '
  [Dir] = init:get_plain_arguments(),
  {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
  ok = file:write_file(filename:join(Dir, "dev-update.key.tmp"), [base64:encode(Priv), $\n]),
  ok = file:write_file(filename:join(Dir, "dev-update.pub.tmp"), [base64:encode(Pub), $\n]),
  halt(0).' -extra "$dir")
chmod 600 "$dir/dev-update.key.tmp"
chmod 644 "$dir/dev-update.pub.tmp"
mv "$dir/dev-update.key.tmp" "$dir/dev-update.key"
mv "$dir/dev-update.pub.tmp" "$dir/dev-update.pub"
echo "$dir/dev-update.pub"
