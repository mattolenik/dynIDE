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
config :herdr_server, HerdrServer.Reload,
  enabled: config_env() == :dev,
  scan_local_funs: config_env() != :prod

# Kernel modules used by herdr_server (see HerdrServer.Kernel). The in-memory
# fakes are the test double and the default until the Rust NIFs land. To use
# the real kernel, point these at the NIF-backed modules implementing the
# HerdrServer.Kernel.{Vt,Pty,Keeper} behaviours, e.g. in config/prod.exs:
#
#     config :herdr_server, :kernel, vt: HerdrServer.Native.Vt, ...
#
# These are read with Application.compile_env, so recompile herdr_server after
# changing them.
config :herdr_server, :kernel,
  vt: HerdrServer.Kernel.Fake.Vt,
  pty: HerdrServer.Kernel.Fake.Pty,
  keeper: HerdrServer.Kernel.Fake.Keeper

# Host-terminal modules used by herdr_term (see HerdrTerm.Kernel). The
# in-memory fakes are the test double and the default until the Rust NIFs
# land; swap by pointing these at NIF-backed modules implementing the
# HerdrTerm.Kernel.{Tty,Blit} behaviours (e.g. in config/prod.exs). Read with
# Application.compile_env, so recompile herdr_term after changing them.
config :herdr_term, :kernel,
  tty: HerdrTerm.Kernel.Fake.Tty,
  blit: HerdrTerm.Kernel.Fake.Blit

# Headless (no terminal client children) in test; HERDR_LIVE_HEADLESS=1 does
# the same at runtime. Frames are at least min_frame_interval_ms apart.
config :herdr_term, headless: config_env() == :test, min_frame_interval_ms: 6
