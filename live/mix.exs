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
        include_executables_for: [:unix],
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
    update_files(release.version_path)
    release
  end

  # `herdr-live update` (R5): the trusted key ($HERDR_LIVE_UPDATE_PUBKEY, else the dev key
  # from scripts/release/keygen.sh when present) and the default manifest URL (a placeholder:
  # no channel is published). No key: update-keys/ is empty and every update is refused.
  @update_url "https://updates.herdr-live.invalid/stable/manifest.json"
  defp update_files(dir) do
    keys = Path.join(dir, "update-keys")
    File.rm_rf!(keys)
    File.mkdir_p!(keys)
    File.write!(Path.join(dir, "update.url"), @update_url <> "\n")

    env = System.get_env("HERDR_LIVE_UPDATE_PUBKEY", "")
    pub = if env == "", do: "_build/release/keys/dev-update.pub", else: env

    if env == "" and not File.regular?(pub) do
      Mix.shell().info("no update key (HERDR_LIVE_UPDATE_PUBKEY, #{pub}): updates refused")
    else
      b64 = File.read!(pub) |> String.trim()

      match?({:ok, <<_::binary-size(32)>>}, Base.decode64(b64)) ||
        Mix.raise("#{pub}: not a base64 raw 32-byte ed25519 public key")

      File.write!(Path.join(keys, Path.basename(pub)), b64 <> "\n")

      if env == "",
        do:
          Mix.shell().info(
            "release trusts the DEV update key #{pub} (set HERDR_LIVE_UPDATE_PUBKEY for a real one)"
          )
    end
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
