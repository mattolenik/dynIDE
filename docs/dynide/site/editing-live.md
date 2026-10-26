# Editing dynIDE live

This is a source-checkout feature. The 0.1.0 release is built with hot reload off, so a
release install cannot be edited while it runs. Clone the repository and run
`just dynide-run` (or `dynide/bin/dynide`) instead.

In a checkout, an edit under `dynide/apps/**` is recompiled and loaded into the running
instance in under a second, without losing terminals, scrollback or layout. A bad edit is
rolled back automatically and never takes the instance down. Kernel (Rust) changes go
through `dynide kernel-restart`.

Everything else is in [editing-live.md](../editing-live.md): the loop, what reloads and
what needs `kernel-restart`, fan-out cost, state shape changes, the guard boundary,
rollback, test-on-save, telemetry and troubleshooting by log grep.
