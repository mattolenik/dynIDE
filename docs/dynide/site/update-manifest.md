# Update manifest

`dynide update` reads a channel manifest: a JSON file plus a detached signature. No
channel is published yet; the release's default URL
(`releases/<V>/update.url`, `https://updates.dynide.invalid/stable/manifest.json`) is
a placeholder that never resolves. Point the updater at a manifest with `--manifest URL`
or `DYNIDE_UPDATE_URL`.

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
    {"os": "macos", "arch": "aarch64", "url": "https://example.invalid/dynide-0.1.1-macos-aarch64.tar.gz",
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
| `artifacts[].url` | yes | the tarball from `build.sh` (`dynide-<V>-<os>-<arch>.tar.gz`, top dir `dynide-<V>/`) |
| `artifacts[].sha256` | yes | lowercase hex sha256 of the tarball |
| `artifacts[].size` | yes | tarball size in bytes |

Unknown fields are ignored and covered by the signature like the rest. `agent_manifests`
(a detection-manifest bundle) is not part of schema 1 yet.

## Trust

The signature is checked before the JSON is parsed. Trusted keys ship inside the
release: `releases/<V>/update-keys/*.pub`, each the base64 of a raw 32-byte ed25519
public key. `build.sh` copies `DYNIDE_UPDATE_PUBKEY` (a `.pub` file) there, else, only
with `--dev-key` (or `DYNIDE_DEV_KEY=1`), the dev key from
`dynide/scripts/release/keygen.sh`. A release built with no key
refuses every update (`no_trusted_keys`); there is no trust on first use. In a source
checkout, `dynide update --check` trusts only `DYNIDE_UPDATE_PUBKEY`.

## What an update does

One update runs per prefix at a time (`<prefix>/lib/dynide/.update.lock`, removed
when the run ends; it holds the run's OS pid, and a lock whose pid no longer exists is
taken over with a note on stderr: no `/proc/<pid>` on Linux, `kill -0` failing on macOS).

Downloads honour `http_proxy`, `https_proxy` and `no_proxy` (lower case first, then upper
case; a `.example.com` entry in `no_proxy` matches its subdomains).

1. Fetch and verify the manifest; compare `version` with the running release
   (`Version.compare`; `--check` stops here and prints `update available <v>` or
   `up to date <v>`; without `--yes` nothing is installed).
2. Unless `releases/<v>/` already holds that release (an earlier update whose restart
   failed: it is reused, never replaced), download the artifact for this OS and arch to
   `<prefix>/lib/dynide/.download/` (at most its manifest `size`; redirects are
   followed by the updater, at most 5, never from https to anything else), check size and
   sha256, extract into `releases/.<v>.partial` (only regular files and directories under
   `dynide-<v>/`), check `releases/start_erl.data` names `<v>`, rename to
   `releases/<v>`.
3. If a broker answers on this instance (the runtime dir rule of `kernel-restart`), its
   status `vm_argv=` must be `<prefix>/lib/dynide/releases/<x>/bin/dynide_vm start` for
   this prefix; a source checkout's broker or another prefix's release is refused
   (`foreign_broker`, `current` unchanged, nothing restarted). Then run
   `dynide_broker kernel-restart -- <prefix>/lib/dynide/releases/<v>/bin/dynide_vm start`:
   the restart target boots the new release and adopts every pane. The broker keeps that
   VM argv for later standbys, crash handoffs and restarts only if the restart succeeds.
   The updater then checks that `ping` reports `<v>`; if not, it refuses
   (`restart_did_not_switch`) and leaves `current`.
4. Then flip `current` to `releases/<v>` atomically (a temp symlink renamed over it). With
   no instance (`no running instance, restart skipped`) or `--no-restart`, the flip
   happens without a restart. A broker that does not answer `status` is a refusal
   (`broker_unreachable`, `current` unchanged).
5. If the restart fails, the broker thaws the old VM and keeps its old argv; `current` is
   not touched and `releases/<v>` stays for a retry; exit 1 with `restart_failed`.
6. After a flip, releases older than the previous two are removed, except the one the
   running broker boots from (its status `vm_argv=`) and any release a live process has in
   its argv (`ps -A -o args=` showing `.../dynide/releases/<n>/`: another instance on
   its own runtime dir pinned to it; detection only, nothing is killed; when `ps` cannot
   run, nothing is pruned). Dot-names in `releases/` are never touched.

In a release the broker's VM argv is always pinned to a resolved
`<prefix>/lib/dynide/releases/<x>/bin/dynide_vm start`, never `current`: a start
and a plain `dynide kernel-restart` resolve `current` at that moment. So `current`
decides what the next start or restart runs, standby and crash boots never change
version, and `--no-restart` only moves `current`. The running broker binary is not
replaced; a full stop and start picks up a new one.

## Exit codes and errors

0 updated, up to date, or `--check`; 1 refused; 2 usage. A refusal prints one JSON object
on stderr, `{"code": "...", "message": "..."}`. Every refusal leaves `current` as it was.

| code | meaning |
|---|---|
| `managed_install` | Homebrew or Nix owns this install (`releases/managed-by`); update with that package manager |
| `not_a_release` | the CLI runs from neither a release nor a source tree |
| `not_installed` | a source checkout (only `--check` works), or not the `install.sh` layout |
| `no_trusted_keys` | the release was built with no update key |
| `no_manifest_url` | no `--manifest`, `DYNIDE_UPDATE_URL` or `releases/<V>/update.url` |
| `fetch_failed` | the manifest, its `.sig` or the artifact could not be fetched (or a refused redirect) |
| `bad_signature`, `bad_schema`, `unsupported_schema` | the manifest does not verify or is not schema 1 |
| `no_artifact` | the manifest has no artifact for this OS and arch |
| `locked` | another update holds `.update.lock` |
| `size_mismatch`, `sha256_mismatch` | the download is not the manifest's artifact |
| `bad_tarball` | the tarball has entries outside `dynide-<v>/`, links, or is not release `<v>` |
| `install_failed` | a filesystem step failed, or `releases/<v>` exists and is not that release |
| `broker_unreachable` | a broker exists but did not answer `status`; `releases/<v>` is installed |
| `foreign_broker` | the broker on this runtime dir runs a source checkout or another prefix's release; nothing restarted, `releases/<v>` installed |
| `restart_failed` | kernel-restart into `<v>` failed; the old VM thawed, `releases/<v>` kept |
| `restart_did_not_switch` | kernel-restart reported ok but `ping` does not answer `<v>` |

After `restart_failed`, `broker_unreachable` or `foreign_broker`, fix the cause and re-run
`dynide update --yes`: the installed `releases/<v>` is reused. After
`restart_did_not_switch` the broker's VM argv already names `releases/<v>` while `current`
still names the old release. Re-running `dynide update --yes` completes the switch
(restart into `<v>`, ping, flip). A plain `dynide kernel-restart` resolves `current`
instead and returns the instance to the old release.

## Making a manifest

```sh
dynide/scripts/release/keygen.sh                       # dev pair in dynide/_build/release/keys/
dynide/scripts/release/build.sh --dev-key --version 0.1.1   # tarball trusting that key
elixir dynide/scripts/release/make_manifest.exs --key dynide/_build/release/keys/dev-update.key \
  --url-base https://host/path dynide/_build/release/dynide-0.1.1-*.tar.gz
```

`make_manifest.exs` writes `manifest.json` and `manifest.json.sig` beside the first
tarball (or `--out DIR`); all tarballs must be one version. The dev key is for local
checks only and is never committed.
