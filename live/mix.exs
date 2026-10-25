defmodule Live.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      # :mix for Reload's in-VM compiler and the `mix herdr_term.demo` task;
      # :ex_unit for test-only modules.
      dialyzer: [plt_core_path: "_build/#{Mix.env()}", plt_add_apps: [:mix, :ex_unit]]
    ]
  end

  # M18: the self-contained release (scripts/release/build.sh). Prod, so hot reload is
  # off (R1); herdr_cli is only loaded (bin/herdr-live runs it with erl -pa). crypto is
  # not listed: herdr_server needs it started (API token compare).
  # herdr_scene_html and herdr_integration are dev/test-only and stay out.
  defp releases do
    [
      herdr_live: [
        applications: [
          herdr_server: :permanent,
          herdr_term: :permanent,
          herdr_reload: :permanent,
          herdr_cli: :load,
          inets: :load,
          ssl: :load,
          public_key: :load
        ],
        include_erts: true,
        version: System.get_env("HERDR_LIVE_VERSION", @version),
        steps: [:assemble, &copy_extras/1]
      ]
    ]
  end

  # The launcher, its tty guard and the broker binary go in the release root, next to
  # the Mix release script (bin/herdr_live), plus OTP's no_dot_erlang.boot, which the
  # launcher's `erl -boot no_dot_erlang` CLI start finds in <root>/bin.
  defp copy_extras(release) do
    broker = "native/herdr_broker"
    args = ~w(build --release --locked --quiet --manifest-path #{broker}/Cargo.toml)
    {_, 0} = System.cmd("cargo", args, into: IO.stream())
    bin = Path.join(release.path, "bin")
    scripts = Path.join(release.path, "scripts")
    File.mkdir_p!(scripts)
    File.cp!("bin/herdr-live", Path.join(bin, "herdr-live"))
    File.cp!("#{broker}/target/release/herdr_broker", Path.join(bin, "herdr_broker"))
    File.cp!("scripts/tty_guard.sh", Path.join(scripts, "tty_guard.sh"))
    boot = "no_dot_erlang.boot"
    File.cp!(Path.join([:code.root_dir(), "bin", boot]), Path.join(bin, boot))
    release
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
