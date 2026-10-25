# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Sample configuration:
#
#     config :logger, :default_handler,
#       level: :info
#
#     config :logger, :default_formatter,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#
# The default handler writes to the VM's stderr, which the launcher sends to the log file.
config :logger, :default_formatter, format: "$date $time [$level] $message\n"

config :herdr_reload, HerdrReload,
  enabled: config_env() == :dev,
  scan_local_funs: config_env() != :prod,
  test_on_save: :off

# The JSON socket API (M12). Off in test: tests start their own listener on a tmp path.
config :herdr_server, :api, enabled: config_env() != :test

# The client socket (M16): remote and socket clients. Off in test: tests start their own
# listener on a tmp path. A dropped session-mode client lingers grace_ms; frames to a
# socket client are at least frame_ms apart; one that reads nothing for stuck_ms is dropped.
config :herdr_server, :client_socket,
  enabled: config_env() != :test,
  grace_ms: 60_000,
  frame_ms: 8,
  stuck_ms: 30_000

# Handoff (M5): with a broker, changed panes are snapshotted to it this often.
config :herdr_server, HerdrServer.Handoff, snapshot_ms: 1000

# Workspace facts (M17): root-pane cwd polling for automatic names. Off in test: tests
# start their own with injected readers, so the shared Store's names stay put.
config :herdr_server, HerdrServer.WorkspaceFacts, enabled: config_env() != :test

# Persistence (M8): snapshot polling and scrollback cadence. runtime.exs sets `enabled`
# and the raw `dir`/`name` env values; HerdrServer.Persist.Disk.config/0 resolves them.
config :herdr_server, HerdrServer.Persist,
  enabled: false,
  dir: nil,
  name: nil,
  poll_ms: 1000,
  scrollback_ms: 60_000,
  scrollback_rows: 1000

# Kernel modules used by herdr_server (see HerdrServer.Kernel): M1's NIF-backed
# HerdrServer.Native.* in dev and prod, the in-memory fakes (the test double) in
# test. Read once when herdr_server starts; restart the app after changing them.
# HerdrServer.Native.Keeper always runs (first child); a fake keeper runs beside it.
config :herdr_server,
       :kernel,
       if(config_env() == :test,
         do: [
           vt: HerdrServer.Kernel.Fake.Vt,
           pty: HerdrServer.Kernel.Fake.Pty,
           keeper: HerdrServer.Kernel.Fake.Keeper
         ],
         else: [
           vt: HerdrServer.Native.Vt,
           pty: HerdrServer.Native.Pty,
           keeper: HerdrServer.Native.Keeper
         ]
       )

# Host-terminal modules used by herdr_term (see HerdrTerm.Kernel): M2's
# NIF-backed HerdrTerm.Native.* in dev and prod, the in-memory fakes (the test
# double) in test. `sigwinch` says the tty is real, so Tty.Owner handles
# SIGWINCH. Read once when herdr_term starts; restart the app after changing them.
config :herdr_term,
       :kernel,
       if(config_env() == :test,
         do: [
           tty: HerdrTerm.Kernel.Fake.Tty,
           blit: HerdrTerm.Kernel.Fake.Blit,
           desktop: HerdrTerm.Kernel.Fake.Desktop,
           sigwinch: false
         ],
         else: [
           tty: HerdrTerm.Native.Tty,
           blit: HerdrTerm.Native.Blit,
           desktop: HerdrTerm.Native.Desktop,
           sigwinch: true
         ]
       )

# Headless (no terminal client children) in test; HERDR_LIVE_HEADLESS=1 does
# the same at runtime. Frames are at least min_frame_interval_ms apart.
config :herdr_term, headless: config_env() == :test, min_frame_interval_ms: 6

# host colour query window (Client.Term.Input); shorter in tests
config :herdr_term, colors_window_ms: if(config_env() == :test, do: 1000, else: 5000)

# Config file (M13, HerdrServer.Config): tests read a fresh per-run file with onboarding
# off (so unrelated tests see no modal); written here because every app's tests start
# herdr_server, and modal tests may write to it. Tests needing another file set the path.
if config_env() == :test do
  test_config = Path.join(System.tmp_dir!(), "herdr-live-test-config-#{System.pid()}.toml")
  File.write!(test_config, "onboarding = false\n")
  config :herdr_server, :config_path, test_config
end

# Plugins (M14): the runtime for actions and hooks. Off in test: tests start their own.
config :herdr_server, :plugins, enabled: config_env() != :test

# Agent manifest hot reload watcher. Off in test: tests start their own with a tmp dir.
config :herdr_server, :detect_watcher, enabled: config_env() != :test
