# Signing and notarization

Nothing here has been run for real: the scripts have a `--dry-run` that prints every
command and contacts no one. A release built without these steps is ad-hoc signed and
Gatekeeper rejects it when it carries the quarantine flag.

## macOS prerequisites

1. An Apple Developer Program membership and a **Developer ID Application** certificate
   with its private key in your login keychain. Check:
   `security find-identity -v -p codesigning` lists
   `Developer ID Application: NAME (TEAMID)`. Use that full string as `--identity`.
2. Your 10-character team id (the part in parentheses).
3. A notarytool credentials profile, stored once (an app-specific password for your
   Apple ID, from appleid.apple.com):
   `xcrun notarytool store-credentials herdr-live-notary --apple-id YOU --team-id TEAMID`
4. The real update signing key pair (ed25519, same format as `keygen.sh`):
   `live/scripts/release/keygen.sh ~/secure/herdr-live-update` makes
   `dev-update.key` / `dev-update.pub` in that directory; keep the `.key` offline and
   backed up. Losing it means shipping a new release with a new key by hand.

## Entitlements

`live/rel/macos/entitlements.plist` is applied to every Mach-O with the hardened runtime
(`--options runtime`):

- `com.apple.security.cs.allow-jit`: the BEAM JIT maps writable-then-executable
  memory; without it `beam.smp` is expected to be killed under the hardened runtime when
  the JIT first maps code (expected, not verified here).
- `com.apple.security.cs.disable-library-validation` is **not** set. Library validation
  only requires that a loaded library be signed by Apple or by the same team id as the
  process. Every NIF (`herdr_kernel.so`, `herdr_term.so`, `crypto.so`, `asn1rt_nif.so`)
  and the bundled libcrypto are signed here with the same identity, so validation passes.
  Add the entitlement only if a future release loads a library signed by someone else.

## Release steps (macOS), in order

Run from `live/`. `V` is the version, `ID` the identity string, `TEAMID` as above.

```sh
# 1. build with the real public key as the trusted update key
HERDR_LIVE_UPDATE_PUBKEY=~/secure/herdr-live-update/dev-update.pub T=$(scripts/release/build.sh | tail -n 1)
V=$(basename $T | sed 's/^herdr-live-\(.*\)-macos-aarch64\.tar\.gz$/\1/')

# 2. unpack, sign every Mach-O (dry run first: add --dry-run)
rm -rf _build/signing && mkdir _build/signing && tar -xzf $T -C _build/signing
scripts/release/sign_macos.sh --identity "$ID" _build/signing/herdr-live-$V

# 3. repack the signed tree over the tarball and refresh its checksum
COPYFILE_DISABLE=1 tar --no-xattrs -C _build/signing -czf $T herdr-live-$V
(cd _build/release && shasum -a 256 "$(basename $T)" > "$(basename $T).sha256")

# 4. verify the signed tree and smoke-run it, so hardened-runtime launch failures
#    show before a notarization round trip
codesign --verify --strict --verbose=2 _build/signing/herdr-live-$V/erts-*/bin/beam.smp
codesign -dv --verbose=4 _build/signing/herdr-live-$V/bin/herdr_broker   # flags=0x10000(runtime), TeamIdentifier
spctl --assess --type execute --verbose _build/signing/herdr-live-$V/bin/herdr_broker
scripts/release/release_smoke.sh $T

# 5. notarize (uploads to Apple, waits for the verdict; dry run first)
scripts/release/notarize_macos.sh --keychain-profile herdr-live-notary $T

# 6. sign the update manifest with the real key (after building the Linux tarball too).
#    manifest.json and manifest.json.sig land beside the first tarball unless --out DIR
scripts/release/sign_manifest.sh --key ~/secure/herdr-live-update/dev-update.key \
  --url-base https://YOUR.HOST/stable $T [linux tarball ...]
```

Notes:

- Step 3 must come after step 2 and before step 5, so the notarized bytes are the shipped
  bytes. The `.sha256` and the manifest are computed from the final tarball.
- A bare executable or tarball **cannot be stapled** (stapling only covers app bundles,
  disk images and installer packages). Gatekeeper looks the ticket up online on first
  run; an offline first run of a quarantined binary may be refused. Downloads made with
  `curl` carry no quarantine flag and are not checked.
- `spctl --assess` on a bare command-line binary can say `rejected` or `source=Notarized
  Developer ID` depending on the macOS release; trust `notarytool` "Accepted" plus the
  `codesign -dv` runtime flag.
- The public key lives only in the release: `HERDR_LIVE_UPDATE_PUBKEY` at build time
  copies it to `releases/<V>/update-keys/`. Existing installs trust the key they were
  built with, so changing it needs a manual reinstall.

## Linux

There is no OS-level signing. Integrity comes from the signed update manifest (ed25519
over the manifest bytes, with the tarball sha256 inside it, see
[update-manifest.md](update-manifest.md)) and from the `.sha256` file next to each
tarball for manual installs (`shasum -a 256 -c`). Build on Linux, then run step 6.
