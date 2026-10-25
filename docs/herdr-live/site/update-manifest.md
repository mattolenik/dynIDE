# Update manifest

`herdr-live update` reads a channel manifest: a JSON file plus a detached signature. No
channel is published yet; the release's default URL
(`releases/<V>/update.url`, `https://updates.herdr-live.invalid/stable/manifest.json`) is
a placeholder that never resolves. Point the updater at a manifest with `--manifest URL`
or `HERDR_LIVE_UPDATE_URL`.

## Files

| File | Content |
|---|---|
| `manifest.json` | the manifest, schema 1 (below) |
| `manifest.json.sig` | base64 of the 64-byte ed25519 signature over the exact bytes of `manifest.json` (a trailing newline is ignored) |

The signature is fetched from the manifest URL with `.sig` appended. URLs may be
`file://`, `http://` or `https://` (TLS peer and hostname verified against the OS CA
store). The manifest is at most 1 MiB.

## Schema 1

```json
{
  "schema": 1,
  "channel": "stable",
  "version": "0.1.1",
  "released": "2026-10-25T00:00:00Z",
  "notes_url": "https://example.invalid/notes/0.1.1",
  "artifacts": [
    {"os": "macos", "arch": "aarch64", "url": "https://example.invalid/herdr-live-0.1.1-macos-aarch64.tar.gz",
     "sha256": "<64 lowercase hex>", "size": 12552919}
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `schema` | yes | `1`. Any other value is refused as `unsupported_schema`. |
| `channel` | yes | string, informational (`stable`) |
| `version` | yes | the release version: semver, `[0-9A-Za-z._+-]+`; it names `releases/<version>/` |
| `released` | no | ISO 8601 time, informational |
| `notes_url` | no | release notes link, informational |
| `artifacts` | yes | non-empty list, one per platform |
| `artifacts[].os` | yes | `macos` or `linux` |
| `artifacts[].arch` | yes | `aarch64` or `x86_64` |
| `artifacts[].url` | yes | the tarball from `build.sh` (`herdr-live-<V>-<os>-<arch>.tar.gz`, top dir `herdr-live-<V>/`) |
| `artifacts[].sha256` | yes | lowercase hex sha256 of the tarball |
| `artifacts[].size` | yes | tarball size in bytes |

Unknown fields are ignored and covered by the signature like the rest. `agent_manifests`
(a detection-manifest bundle) is not part of schema 1 yet.

## Trust

The signature is checked before the JSON is parsed. Trusted keys ship inside the
release: `releases/<V>/update-keys/*.pub`, each the base64 of a raw 32-byte ed25519
public key. `build.sh` copies `HERDR_LIVE_UPDATE_PUBKEY` (a `.pub` file) there, else the
dev key from `live/scripts/release/keygen.sh` when it exists. A release built with no key
refuses every update (`no_trusted_keys`); there is no trust on first use. In a source
checkout, `herdr-live update --check` trusts only `HERDR_LIVE_UPDATE_PUBKEY`.

## What an update does

One update runs per prefix at a time (`<prefix>/lib/herdr-live/.update.lock`, removed
when the run ends; a killed run leaves it, and the refusal names it).

1. Fetch and verify the manifest; compare `version` with the running release
   (`Version.compare`; `--check` stops here and prints `update available <v>` or
   `up to date <v>`; without `--yes` nothing is installed).
2. Unless `releases/<v>/` already holds that release (an earlier update whose restart
   failed: it is reused, never replaced), download the artifact for this OS and arch to
   `<prefix>/lib/herdr-live/.download/` (at most its manifest `size`; redirects are
   followed by the updater, at most 5, never from https to anything else), check size and
   sha256, extract into `releases/.<v>.partial` (only regular files and directories under
   `herdr-live-<v>/`), check `releases/start_erl.data` names `<v>`, rename to
   `releases/<v>`.
3. If a broker answers on this instance (the runtime dir rule of `kernel-restart`), run
   `herdr_broker kernel-restart -- <prefix>/lib/herdr-live/releases/<v>/bin/herdr_live start`:
   the restart target boots the new release and adopts every pane. The broker keeps that
   VM argv for later standbys, crash handoffs and restarts only if the restart succeeds.
4. Then flip `current` to `releases/<v>` atomically (a temp symlink renamed over it). With
   no instance (`no running instance, restart skipped`) or `--no-restart`, the flip
   happens without a restart. A broker that does not answer `status` is a refusal
   (`broker_unreachable`, `current` unchanged).
5. If the restart fails, the broker thaws the old VM and keeps its old argv; `current` is
   not touched and `releases/<v>` stays for a retry; exit 1 with `restart_failed`.
6. After a flip, releases older than the previous two are removed. Dot-names in
   `releases/` are never touched.

`herdr-live kernel-restart` in a release restarts into `<prefix>/lib/herdr-live/current`
the same way, so after `--no-restart` it boots the new version. The running broker binary
is not replaced; a full stop and start picks up a new one.

## Exit codes and errors

0 updated, up to date, or `--check`; 1 refused; 2 usage. A refusal prints one JSON object
on stderr, `{"code": "...", "message": "..."}`, with `code` one of `no_trusted_keys`,
`no_manifest_url`, `fetch_failed`, `bad_signature`, `bad_schema`, `unsupported_schema`,
`not_installed`, `no_artifact`, `locked`, `size_mismatch`, `sha256_mismatch`,
`bad_tarball`, `install_failed`, `broker_unreachable`, `restart_failed`. Every refusal
leaves `current` as it was.

## Making a manifest

```sh
live/scripts/release/keygen.sh                       # dev pair in live/_build/release/keys/
live/scripts/release/build.sh --version 0.1.1        # tarball, built trusting that key
elixir live/scripts/release/make_manifest.exs --key live/_build/release/keys/dev-update.key \
  --url-base https://host/path live/_build/release/herdr-live-0.1.1-*.tar.gz
```

`make_manifest.exs` writes `manifest.json` and `manifest.json.sig` beside the first
tarball (or `--out DIR`); all tarballs must be one version. The dev key is for local
checks only and is never committed.
