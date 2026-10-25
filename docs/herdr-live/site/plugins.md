# Plugins

herdr-live runs herdr's external-process plugins unchanged. A plugin is a directory with
a manifest; actions, startup hooks and event hooks run as OS processes (argv, no shell)
and drive herdr-live through the CLI and the environment. No plugin code is loaded into
the VM.

```sh
herdr-live plugin install <owner/repo[/subdir] | local dir>
herdr-live plugin update [<id> | owner/repo[/subdir]] [--ref REF] [--yes]
herdr-live plugin list
herdr-live plugin enable|disable <id>
herdr-live plugin log list
```

State: the registry is `<config>/herdr-live/plugins.json`, GitHub installs live under
`<config>/herdr-live/plugins/github-installations/`. Plugins run with your user's
privileges and can read `client.token`; install only plugins you trust (trust statement in
[m14.md](../results/m14.md)).

Tested with two unmodified examples from
[ogulcancelik/herdr-plugin-examples](https://github.com/ogulcancelik/herdr-plugin-examples)
at commit `18709cd`. The examples are not shipped in the tree; the plugins smoke fetches
that commit into `${XDG_CACHE_HOME:-~/.cache}/herdr-live/plugin-examples/18709cd` and
runs offline from that cache afterwards.

`plugin update` re-clones a GitHub install at its recorded ref (or `--ref`), checks the
plugin id is unchanged, shows the install preview (re-run with `--yes`), then builds it in
a fresh dir; on failure the old checkout stays registered. Linked and locally copied
plugins answer `not_applicable`.
Details, manifest rules and the full inventory: [m14.md](../results/m14.md).
