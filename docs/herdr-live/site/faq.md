# FAQ

**Can I edit the release while it runs?** No. Hot reload is off in the release; use a
source checkout ([editing-live.md](editing-live.md)).

**Does a full quit keep my programs?** No. Layout, cwds and scrollback are restored;
programs are not. A kernel restart, a server crash, and `herdr-live update` keep them.

**The terminal looks broken after the broker was killed.** An attached launch restores
the tty even after `kill -9` of the broker. If you still see garbage, run `reset`.

**Where are the logs?** `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-live/herdr-live.log`
(`HERDR_LIVE_LOG`). Summarise with `live/scripts/log_summary.py` in a checkout.

**Two instances?** Give each its own `HERDR_LIVE_RUNTIME_DIR` and `HERDR_LIVE_LOG`.

**Is there a GUI?** Not in 0.1.0. The scene contract is built for one; the choice is
pending.

**Does it work with herdr's config and plugins?** Plugins yes
([plugins.md](plugins.md)). The config is `config.toml` in herdr-live's own directory.
