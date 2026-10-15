# Fork notes

This is [mattolenik/herdr](https://github.com/mattolenik/herdr), a fork of
[herdrdev/herdr](https://github.com/herdrdev/herdr). It tracks upstream
`master` and carries the commits below on top. Each entry is one commit.

## Commits

### `e99e995b` fix: pause native graphics after geometry retirement

Dragging a split border while a pane produced kitty graphics made every pane
progressively laggier until the client reattached. Retiring an in-flight
native upload on a geometry change permanently disabled native graphics for
the connection, and a drag retires the upload on nearly every geometry
update. Geometry churn now triggers a short cooldown instead of a permanent
disable; only rejections and timeouts still disable native delivery. The
client tracks retirements with a per-generation watermark rather than
individual tombstones so repeated retirements cannot exhaust them.

### `027183d5` feat: install local builds with herdr update --from

`herdr update --from <path>` installs a binary you built yourself through the
same path as a published release: atomic rename over the installed binary,
then the usual running-server handling and optional `--handoff`. The version
comes from running the binary with `--version`, so it matches what the
handoff import reports. `just install-local` builds release with channel
`dev` and a build id derived from the git SHA, then calls `herdr update --from`.
Unix only.

### `d29706f3` feat: forward mouse back and forward buttons to panes

Mouse buttons 8 and 9 (SGR 128/129, Windows XBUTTON1/XBUTTON2) were dropped
because crossterm cannot represent them. They now travel as a dedicated raw
event, are hit-tested against the pane or popup under the pointer, and are
encoded through libghostty as buttons eight and nine. The private protocol
gains Back/Forward buttons, moving `PROTOCOL_VERSION` to 23, and
`terminal.mouse` accepts `back` and `forward`.

### `4588fafa` fix: keep compatible servers running when installing a local build

The plain update path leaves a running server alone only when the release
declares an endpoint generation that matches the server's. Local builds
left it unset, which the updater treats as "restart required". Local builds
now carry the updater's own endpoint generation, so a compatible server stays
up and only the client reconnects, the same as for releases.

### `041430ea` feat: re-exec the client into the new binary after live handoff

When a live handoff kicks an attached TUI off the server, the client used to
exit and ask you to run `herdr` again. It now waits for the new server and
replaces itself with the installed binary using `exec`, with the same
arguments it was started with. Readiness is detected by the client socket's
inode changing, since the new server binds a fresh socket file and the old
server may report the same version. Times out after two minutes and falls
back to the old message. The shutdown reason the server sends during handoff
is a shared constant. `just install-local` also appends a timestamp to the
build id so every local build has a distinct version string.

### `f26b74ee` feat: skip update checks for local builds

The background update check that produces the "update ready" menu entry is
skipped when the compiled-in channel is neither `stable` nor `preview`.
`herdr update` on the command line still works on a local build, and the
`HERDR_FAKE_UPDATE_VERSION` test hook still fires.

## Workflow

```bash
just install-local            # build and install over the herdr on PATH
just install-local --handoff  # same, and migrate running servers live
```

Bootstrapping on a machine whose installed herdr predates `--from`: delete the
installed binary and copy the build in. Do not `cp` over it in place; macOS
caches the code signature per inode and will SIGKILL the result.
