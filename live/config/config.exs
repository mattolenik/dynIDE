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
config :herdr_reload, HerdrReload,
  enabled: config_env() == :dev,
  scan_local_funs: config_env() != :prod

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
         do: [tty: HerdrTerm.Kernel.Fake.Tty, blit: HerdrTerm.Kernel.Fake.Blit, sigwinch: false],
         else: [tty: HerdrTerm.Native.Tty, blit: HerdrTerm.Native.Blit, sigwinch: true]
       )

# Headless (no terminal client children) in test; HERDR_LIVE_HEADLESS=1 does
# the same at runtime. Frames are at least min_frame_interval_ms apart.
config :herdr_term, headless: config_env() == :test, min_frame_interval_ms: 6
