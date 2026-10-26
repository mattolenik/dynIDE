# dynIDE

dynIDE is [herdr](https://github.com/ogulcancelik/herdr) rebuilt on the BEAM: an Elixir
server and terminal client over a Rust kernel that owns PTYs, the terminal parser and the
host tty. Sessions, terminals, scrollback and layout survive a kernel restart, a server
crash and an in-place update.

Version 0.1.0 is terminal-only. The GUI client (M15) is not included.

## Pages

- [Install](install.md): build a release tarball, install it, update it.
- [Quick start](quick-start.md): first run, keys, the CLI.
- [Editing dynIDE live](editing-live.md): the source-checkout feature; not in the release.
- [Socket API and CLI](api.md)
- [Plugins](plugins.md)
- [Remote attach](remote-attach.md)
- [FAQ](faq.md)
- [Release notes and known limitations](release-notes.md)
- [Update manifest](update-manifest.md) and [signing](signing.md)

## Design in one paragraph

The server owns sessions and state. Clients own a display and an input device. The kernel
owns bytes and OS resources on both sides. No raw PTY bytes enter the VM; the server emits
a scene (roles and content, never glyphs or colours) and each client draws it. Full rules:
[design.md](../design.md).
