# Remote attach

A second terminal, local or remote, attaches to the same session as another client. Each
client has its own size, prefix state, selection and hover; typing in one shows in the
other.

```sh
dynide attach                 # another terminal on this machine
dynide attach <host> [session]  # over ssh
dynide terminal attach <pane_id> [--host <host>]   # one pane
dynide terminal observe <pane_id> [--host <host>]  # read-only
dynide client list
```

## How it works

The server listens on `client.sock` (0600) beside the API socket, with a token in
`client.token` (0600). `attach <host>` runs `ssh -T -o BatchMode=yes <host> dynide
attach-relay`; the relay reads the token on the server host, so it never crosses the
network. ssh needs key or agent auth (no password prompt). Clipboard writes and links
open on the client machine.

A dropped connection is resumed within 60 s with the same session and no repeated input.
A server `kernel-restart` keeps remote clients attached.

If `dynide` is not on ssh's non-interactive `PATH`, or the server uses custom socket
paths, set `DYNIDE_REMOTE_BIN` to a wrapper that exports them (`DYNIDE_SSH`
selects the ssh binary).

The attach client runs a terminal-client VM on the machine you attach from. In a
source checkout that is `mix run`; see the [known limitations](release-notes.md#known-limitations)
for the release.

Threat model, bench numbers and limits: [m16.md](../results/m16.md).
