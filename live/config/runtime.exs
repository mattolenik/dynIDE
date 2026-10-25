import Config

# mix test inside a herdr-live pane inherits the live VM's broker/api env (portable-pty
# passes the base env), which would make the test VM talk to the live broker and halt.
# Test VMs never belong to an instance: drop the vars before the apps start.
if config_env() == :test do
  for v <- ~w(HERDR_BROKER_SOCK HERDR_LIVE_GEN HERDR_LIVE_API HERDR_LIVE_RUNTIME_DIR
              HERDR_LIVE_TEST_ON_SAVE),
      do: System.delete_env(v)
end

# Handoff (M5): a VM under herdr_broker (HERDR_BROKER_SOCK set) may be a warm standby.
# Its reload pipeline must not watch and compile beside the primary's, so herdr_server
# starts it (HerdrReload.Application.start_deferred/0) once this VM is the primary.
if config_env() != :test and System.get_env("HERDR_BROKER_SOCK") not in [nil, ""],
  do: config(:herdr_reload, HerdrReload, defer: true)

# M8: persistence only in a bin/herdr-live VM (broker socket set), never in test, and not
# with HERDR_LIVE_PERSIST=0. dir and name are raw env values (nil when unset);
# HerdrServer.Persist.Disk.config/0 applies the XDG fallback and validates the name.
config :herdr_server, HerdrServer.Persist,
  enabled:
    config_env() != :test and System.get_env("HERDR_BROKER_SOCK") not in [nil, ""] and
      System.get_env("HERDR_LIVE_PERSIST") != "0",
  dir: System.get_env("HERDR_LIVE_STATE_DIR"),
  name: System.get_env("HERDR_LIVE_SESSION")

# M7: run the changed module's tests before each reload (adds seconds per save).
# `herdr-live test-on-save on|off` flips it at runtime.
if System.get_env("HERDR_LIVE_TEST_ON_SAVE") == "1" do
  config :herdr_reload, HerdrReload, test_on_save: :gate
end

# M18: a release VM (bin/herdr_live) records its version for the API. Pane shells inherit
# the VM's real env (the kernel spawns them; System.delete_env does not reach that env), so
# the release script's RELEASE_* are blanked there: its `${VAR:-default}` reads "" as
# unset, and another Elixir release started from a pane does not boot as this one. erl's
# ROOTDIR/BINDIR/EMU/PROGNAME go the same way, and PATH is the launcher's caller's
# (HERDR_LIVE_PANE_PATH): erlexec put the bundled erts bin and the release bin/ first,
# which would shadow the user's erl/elixir/mix and bypass the install's `current` link.
if config_env() == :prod do
  config :herdr_server, :version, System.get_env("RELEASE_VSN")

  blank =
    for {k, _} <- System.get_env(),
        String.starts_with?(k, "RELEASE_") or k in ~w(ROOTDIR BINDIR EMU PROGNAME),
        do: {k, ""}

  path =
    case System.get_env("HERDR_LIVE_PANE_PATH") do
      nil -> []
      p -> [{"PATH", p}, {"HERDR_LIVE_PANE_PATH", ""}]
    end

  config :herdr_server, :pane_env, blank ++ path
end
