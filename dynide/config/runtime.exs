import Config

# mix test inside a dynIDE pane inherits the live VM's broker/api env (portable-pty
# passes the base env), which would make the test VM talk to the live broker and halt.
# Test VMs never belong to an instance: drop the vars before the apps start.
if config_env() == :test do
  for v <- ~w(DYNIDE_BROKER_SOCK DYNIDE_GEN DYNIDE_API DYNIDE_RUNTIME_DIR
              DYNIDE_TEST_ON_SAVE),
      do: System.delete_env(v)
end

# Handoff (M5): a VM under dynide_broker (DYNIDE_BROKER_SOCK set) may be a warm standby.
# Its reload pipeline must not watch and compile beside the primary's, so dynide_server
# starts it (DynideReload.Application.start_deferred/0) once this VM is the primary.
if config_env() != :test and System.get_env("DYNIDE_BROKER_SOCK") not in [nil, ""],
  do: config(:dynide_reload, DynideReload, defer: true)

# M8: persistence only in a bin/dynide VM (broker socket set), never in test, and not
# with DYNIDE_PERSIST=0. dir and name are raw env values (nil when unset);
# DynideServer.Persist.Disk.config/0 applies the XDG fallback and validates the name.
config :dynide_server, DynideServer.Persist,
  enabled:
    config_env() != :test and System.get_env("DYNIDE_BROKER_SOCK") not in [nil, ""] and
      System.get_env("DYNIDE_PERSIST") != "0",
  dir: System.get_env("DYNIDE_STATE_DIR"),
  name: System.get_env("DYNIDE_SESSION")

# M7: run the changed module's tests before each reload (adds seconds per save).
# `dynide test-on-save on|off` flips it at runtime.
if System.get_env("DYNIDE_TEST_ON_SAVE") == "1" do
  config :dynide_reload, DynideReload, test_on_save: :gate
end

# M18: a release VM (bin/dynide_vm) records its version for the API, then gives every
# process it starts the launcher caller's env back. erlexec put the bundled erts bin and the
# release bin/ first on PATH (shadowing the user's erl/elixir/mix and bypassing the install's
# `current` link; the launcher saved the caller's PATH as DYNIDE_PANE_PATH), and the
# release scripts exported RELEASE_* (another Elixir release started from a child would
# boot as this one) and erl's ROOTDIR/BINDIR/EMU/PROGNAME. One list serves both kinds of
# child: port children (plugins, hooks, custom commands, git, sound, ssh) take the VM's
# env, edited here; pane shells come from the kernel, which reads the real process env
# that System.put_env/delete_env do not reach, so they get the same list as :pane_env
# (a nil value: the kernel removes the name).
if config_env() == :prod do
  config :dynide_server, :version, System.get_env("RELEASE_VSN")

  unset =
    for {k, _} <- System.get_env(),
        String.starts_with?(k, "RELEASE_") or
          k in ~w(ROOTDIR BINDIR EMU PROGNAME DYNIDE_PANE_PATH),
        do: {k, nil}

  child_env =
    case System.get_env("DYNIDE_PANE_PATH") do
      nil -> unset
      path -> [{"PATH", path} | unset]
    end

  for {k, v} <- child_env,
      do: if(v, do: System.put_env(k, v), else: System.delete_env(k))

  config :dynide_server, :pane_env, child_env
end
