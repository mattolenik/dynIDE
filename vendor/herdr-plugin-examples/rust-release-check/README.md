# Rust Release Check

This example shows a plugin that needs an install-time build step.

```toml
[[build]]
command = ["cargo", "build", "--release"]
```

Install builds the binary before Herdr registers the plugin. The action then
runs `./target/release/rust-release-check`, reads `HERDR_PLUGIN_CONTEXT_JSON`,
and checks whether the focused/workspace Git tree has uncommitted changes.

Requires `cargo` and `git` on the user's machine.
