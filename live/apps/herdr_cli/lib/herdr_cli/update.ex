defmodule HerdrCli.Update do
  @moduledoc """
  `herdr-live update [--manifest URL] [--check] [--yes] [--no-restart]` (M18 R4, R5).

  Fetches the channel manifest and its `.sig` (`file://` or `http(s)://`), verifies the
  signature against the release's `releases/<V>/update-keys/*.pub` (in a source tree only
  `$HERDR_LIVE_UPDATE_PUBKEY`), and with `--yes` installs the artifact for this OS and arch
  beside the running release: download to `<lib>/.download/`, size and sha256 check,
  extract into `releases/.<V>.partial`, rename to `releases/<V>`, flip `current` (a temp
  symlink renamed over it), then `herdr_broker kernel-restart` when a broker answers this
  instance (the same runtime-dir env as `herdr-live kernel-restart`). A failed restart
  flips `current` back (the broker has thawed the old VM) and exits 1. After a good
  update, releases older than the previous two are pruned; dot-names in `releases/` (stage
  and partial dirs) are never touched.

  Manifest URL: `--manifest`, else `$HERDR_LIVE_UPDATE_URL`, else `releases/<V>/update.url`.
  Exit 0 updated or up to date, 1 refused (`{"code":..,"message":..}` on stderr), 2 usage.
  """

  alias HerdrCli.Output
  alias HerdrCli.Update.Manifest

  @usage "usage: herdr-live update [--manifest URL] [--check] [--yes] [--no-restart]\n"
  @switches [manifest: :string, check: :boolean, yes: :boolean, no_restart: :boolean]
  @max_manifest 1_048_576

  @typedoc """
  `root`: the release root the CLI runs from (as invoked, possibly through `current`);
  `os`/`arch`: the artifact to pick.
  """
  @type ctx :: %{root: String.t(), os: String.t(), arch: String.t()}

  @doc "The usage text."
  @spec usage() :: String.t()
  def usage, do: @usage

  @doc "Runs `argv` against `env` for this VM's release; returns the exit code."
  @spec run([String.t()], map()) :: 0 | 1 | 2
  def run(argv, env), do: run(argv, env, context())

  @doc false
  @spec run([String.t()], map(), ctx()) :: 0 | 1 | 2
  def run(argv, env, ctx) do
    case OptionParser.parse(argv, strict: [{:help, :boolean} | @switches], aliases: [h: :help]) do
      {[help: true], [], []} ->
        out(@usage)
        0

      {opts, [], []} ->
        report(
          update(
            Map.merge(%{check: false, yes: false, no_restart: false}, Map.new(opts)),
            env,
            ctx
          )
        )

      _ ->
        err(@usage)
        2
    end
  end

  defp report({:ok, text}) do
    out(text)
    0
  end

  defp report({:error, code, msg}) do
    err([Output.encode(%{"code" => to_string(code), "message" => msg}), ?\n])
    1
  end

  # ebin -> herdr_cli-<v> -> lib -> the release root (or _build/dev in a source tree)
  defp context do
    root =
      :code.which(__MODULE__) |> List.to_string() |> Path.join("../../../..") |> Path.expand()

    %{root: root, os: os(), arch: arch()}
  end

  defp os do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {_, name} -> Atom.to_string(name)
    end
  end

  defp arch do
    case :erlang.system_info(:system_architecture) |> List.to_string() |> String.split("-") do
      [a | _] when a in ["aarch64", "arm64"] -> "aarch64"
      [a | _] when a in ["x86_64", "amd64"] -> "x86_64"
      [a | _] -> a
    end
  end

  defp update(opts, env, ctx) do
    with {:ok, cur} <- running_version(ctx),
         {:ok, keys} <- keys(ctx, cur, env),
         {:ok, url} <- manifest_url(opts, ctx, cur, env),
         :ok <- start_http(url),
         {:ok, bytes} <- fetch(url),
         {:ok, sig} <- fetch(url <> ".sig"),
         {:ok, m} <- verify(bytes, sig, keys) do
      v = m["version"]

      cond do
        opts[:check] and Manifest.newer?(v, cur) -> {:ok, "update available #{v}\n"}
        not Manifest.newer?(v, cur) -> {:ok, "up to date #{cur}\n"}
        not opts[:yes] -> {:ok, "update available #{v}; run herdr-live update --yes to install\n"}
        true -> install(m, opts, ctx)
      end
    end
  end

  defp running_version(%{root: root}) do
    case File.read(Path.join(root, "releases/start_erl.data")) do
      {:ok, data} ->
        {:ok, data |> String.split() |> List.last()}

      # a source tree: mix.exs's version (keys from HERDR_LIVE_UPDATE_PUBKEY, --check only)
      {:error, _} ->
        mix = Path.join(root, "../../mix.exs")

        with {:ok, text} <- File.read(mix),
             [_, v] <- Regex.run(~r/^  @version "(.*)"$/m, text) do
          {:ok, v}
        else
          _ -> {:error, :not_a_release, "#{root} is neither a release nor a source tree"}
        end
    end
  end

  defp release?(%{root: root}), do: File.regular?(Path.join(root, "releases/start_erl.data"))

  defp keys(ctx, cur, env) do
    keys =
      for f <- key_files(ctx, cur, env),
          {:ok, b64} <- [File.read(f)],
          {:ok, <<_::binary-size(32)>> = k} <- [Base.decode64(String.trim(b64))],
          do: k

    if keys == [],
      do:
        {:error, :no_trusted_keys,
         "this build trusts no update key (built without HERDR_LIVE_UPDATE_PUBKEY or the dev key); every update is refused"},
      else: {:ok, keys}
  end

  defp key_files(ctx, cur, env) do
    dir = Path.join([ctx.root, "releases", cur, "update-keys"])

    cond do
      release?(ctx) -> for n <- ls(dir), String.ends_with?(n, ".pub"), do: Path.join(dir, n)
      env["HERDR_LIVE_UPDATE_PUBKEY"] in [nil, ""] -> []
      true -> [env["HERDR_LIVE_UPDATE_PUBKEY"]]
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end

  defp manifest_url(opts, ctx, cur, env) do
    file = Path.join([ctx.root, "releases", cur, "update.url"])

    cond do
      opts[:manifest] -> {:ok, opts[:manifest]}
      env["HERDR_LIVE_UPDATE_URL"] not in [nil, ""] -> {:ok, env["HERDR_LIVE_UPDATE_URL"]}
      File.regular?(file) -> {:ok, file |> File.read!() |> String.trim()}
      true -> {:error, :no_manifest_url, "no --manifest, HERDR_LIVE_UPDATE_URL or #{file}"}
    end
  end

  defp start_http("http" <> _) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
    :ok
  end

  defp start_http(_url), do: :ok

  defp verify(bytes, sig, keys) do
    case Manifest.verify(bytes, sig, keys) do
      {:ok, m} ->
        {:ok, m}

      {:error, :bad_signature} ->
        {:error, :bad_signature, "manifest signature does not verify with any trusted key"}

      {:error, :bad_schema} ->
        {:error, :bad_schema, "manifest is not a valid schema 1 manifest"}

      {:error, {:unsupported_schema, n}} ->
        {:error, :unsupported_schema, "manifest schema #{inspect(n)} is not supported (want 1)"}
    end
  end

  # -- fetch ------------------------------------------------------------------

  defp fetch("file://" <> _ = url) do
    path = URI.decode(URI.parse(url).path || "")

    case File.stat(path) do
      {:ok, %{size: n}} when n > @max_manifest -> fetch_error(url, "over #{@max_manifest} bytes")
      _ -> with {:error, r} <- File.read(path), do: fetch_error(url, :file.format_error(r))
    end
  end

  defp fetch("http" <> _ = url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, http_opts(url), body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} when byte_size(body) <= @max_manifest -> {:ok, body}
      {:ok, {{_, 200, _}, _, _}} -> fetch_error(url, "over #{@max_manifest} bytes")
      {:ok, {{_, status, _}, _, _}} -> fetch_error(url, "HTTP #{status}")
      {:error, r} -> fetch_error(url, why(r))
    end
  end

  defp fetch(url),
    do: fetch_error(url, "unsupported URL scheme (want file://, http:// or https://)")

  defp download("file://" <> _ = url, dest) do
    case File.cp(URI.decode(URI.parse(url).path || ""), dest) do
      :ok -> :ok
      {:error, r} -> fetch_error(url, :file.format_error(r))
    end
  end

  defp download("http" <> _ = url, dest) do
    case :httpc.request(:get, {String.to_charlist(url), []}, http_opts(url),
           stream: String.to_charlist(dest)
         ) do
      {:ok, :saved_to_file} -> :ok
      {:ok, {{_, status, _}, _, _}} -> fetch_error(url, "HTTP #{status}")
      {:error, r} -> fetch_error(url, why(r))
    end
  end

  defp download(url, _dest),
    do: fetch_error(url, "unsupported URL scheme (want file://, http:// or https://)")

  defp http_opts("https" <> _) do
    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    [ssl: ssl] ++ http_opts("http")
  end

  defp http_opts(_), do: [timeout: 300_000, connect_timeout: 10_000, autoredirect: true]

  # httpc's {:failed_connect, [{:to_address, _}, {family, opts, reason}]}: the reason
  defp why({:failed_connect, [_, {_, _, r}]}), do: inspect(r, limit: 10)
  defp why(r), do: inspect(r, limit: 10)

  defp fetch_error(url, why), do: {:error, :fetch_failed, "cannot fetch #{url}: #{why}"}

  # -- install ----------------------------------------------------------------

  defp install(m, opts, ctx) do
    v = m["version"]

    with {:ok, lib, prev} <- layout(ctx),
         {:ok, art} <- pick(m, ctx),
         {:ok, tarball} <- fetch_artifact(art, lib, v),
         :ok <- unpack(tarball, lib, v),
         :ok <- flip(lib, v) do
      restart(lib, prev, v, opts)
    end
  end

  # <lib>/current -> releases/<V> must exist: the CLI runs from <lib>/current or <lib>/releases/<V>
  defp layout(%{root: root} = ctx) do
    lib =
      case root |> Path.split() |> Enum.take(-2) do
        ["releases", _] -> root |> Path.dirname() |> Path.dirname()
        [_, "current"] -> Path.dirname(root)
        _ -> nil
      end

    with {:release, true} <- {:release, release?(ctx)},
         true <- lib != nil,
         {:ok, "releases/" <> prev} <- File.read_link(Path.join(lib, "current")) do
      {:ok, lib, prev}
    else
      {:release, false} ->
        {:error, :not_installed, "a source checkout updates with git; only --check works here"}

      _ ->
        {:error, :not_installed,
         "#{root} is not an installed release (<prefix>/lib/herdr-live/current -> releases/<V>); install it with install.sh"}
    end
  end

  defp pick(m, ctx) do
    case Manifest.pick(m, ctx.os, ctx.arch) do
      {:ok, a} ->
        {:ok, a}

      {:error, :no_artifact} ->
        {:error, :no_artifact,
         "manifest #{m["version"]} has no artifact for #{ctx.os}-#{ctx.arch}"}
    end
  end

  defp fetch_artifact(%{"url" => url, "size" => size, "sha256" => sha}, lib, v) do
    dir = Path.join(lib, ".download")
    dest = Path.join(dir, "herdr-live-#{v}.tar.gz")
    File.rm_rf(dir)

    with :ok <- File.mkdir_p(dir),
         :ok <- start_http(url),
         :ok <- download(url, dest) do
      got = sha256(dest)
      got_size = File.stat!(dest).size

      cond do
        got_size != size ->
          File.rm_rf(dir)
          {:error, :size_mismatch, "#{url} is #{got_size} bytes, the manifest says #{size}"}

        got != sha ->
          File.rm_rf(dir)
          {:error, :sha256_mismatch, "#{url} has sha256 #{got}, the manifest says #{sha}"}

        true ->
          {:ok, dest}
      end
    else
      {:error, r} when is_atom(r) ->
        {:error, :install_failed, "cannot create #{dir}: #{:file.format_error(r)}"}

      e ->
        e
    end
  end

  defp sha256(path) do
    File.stream!(path, 65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # extract beside the target, then rename into place; only regular files and dirs under
  # herdr-live-<V>/ (no links, no absolute or .. names)
  defp unpack(tarball, lib, v) do
    top = "herdr-live-#{v}"
    rels = Path.join(lib, "releases")
    partial = Path.join(rels, ".#{v}.partial")
    dest = Path.join(rels, v)
    tar = String.to_charlist(tarball)
    File.rm_rf(partial)

    result =
      with {:ok, entries} <- :erl_tar.table(tar, [:compressed, :verbose]),
           :ok <- safe_entries(entries, top),
           :ok <- File.mkdir_p(partial),
           :ok <- :erl_tar.extract(tar, [:compressed, {:cwd, String.to_charlist(partial)}]),
           {:ok, data} <- File.read(Path.join([partial, top, "releases/start_erl.data"])),
           [_, ^v] <- String.split(data),
           true <- File.regular?(Path.join([partial, top, "bin/herdr-live"])) do
        File.rm_rf(dest)
        :file.rename(Path.join(partial, top), dest)
      else
        {:error, :unsafe, name} ->
          {:error, :bad_tarball,
           "tarball entry #{inspect(name)} is outside #{top}/ or not a file or dir"}

        other ->
          {:error, :bad_tarball,
           "tarball is not the herdr-live #{v} release: #{inspect(other, limit: 10)}"}
      end

    File.rm_rf(partial)
    File.rm_rf(Path.dirname(tarball))

    case result do
      :ok ->
        :ok

      {:error, r} when is_atom(r) ->
        {:error, :install_failed, "cannot install #{dest}: #{:file.format_error(r)}"}

      e ->
        e
    end
  end

  defp safe_entries(entries, top) do
    Enum.find_value(entries, :ok, fn {name, type, _, _, _, _, _} ->
      if unsafe?(Path.split(List.to_string(name)), type, top),
        do: {:error, :unsafe, List.to_string(name)}
    end)
  end

  defp unsafe?([top | rest], type, top) when type in [:regular, :directory], do: ".." in rest
  defp unsafe?(_parts, _type, _top), do: true

  # atomic: a temp symlink renamed over `current` (rename(2) replaces the link itself)
  @doc false
  @spec flip(String.t(), String.t()) :: :ok | {:error, atom(), String.t()}
  def flip(lib, v) do
    tmp = Path.join(lib, ".current.#{:os.getpid()}")
    File.rm(tmp)

    with :ok <- File.ln_s("releases/#{v}", tmp),
         :ok <- :file.rename(tmp, Path.join(lib, "current")) do
      :ok
    else
      {:error, r} ->
        File.rm(tmp)

        {:error, :install_failed,
         "cannot point #{lib}/current at releases/#{v}: #{:file.format_error(r)}"}
    end
  end

  # -- restart ----------------------------------------------------------------

  defp restart(lib, prev, v, opts) do
    done = "updated #{prev} -> #{v}\n"

    # the running release's broker client speaks the running broker's protocol
    broker = Path.join([lib, "releases", prev, "bin/herdr_broker"])

    if opts[:no_restart] do
      pruned(
        lib,
        prev,
        v,
        done <> "restart skipped (--no-restart); run herdr-live kernel-restart to boot #{v}\n"
      )
    else
      case System.cmd(broker, ["status"], stderr_to_stdout: true) do
        {_, 0} ->
          kernel_restart(broker, lib, prev, v, done)

        {_, 2} ->
          pruned(lib, prev, v, done <> "no running instance, restart skipped\n")

        {text, _} ->
          pruned(
            lib,
            prev,
            v,
            done <>
              "broker did not answer (#{String.trim(text)}), restart skipped; run herdr-live kernel-restart\n"
          )
      end
    end
  end

  defp pruned(lib, prev, v, text) do
    prune(lib, [prev, v])
    {:ok, text}
  end

  defp kernel_restart(broker, lib, prev, v, done) do
    case System.cmd(broker, ["kernel-restart"], stderr_to_stdout: true) do
      {text, 0} ->
        pruned(lib, prev, v, done <> "kernel-restart: " <> text)

      {text, code} ->
        # the broker SIGKILLed the target, and nothing boots through releases/<v> any more
        back =
          case flip(lib, prev) do
            :ok ->
              File.rm_rf(Path.join([lib, "releases", v]))
              "current flipped back to #{prev}"

            {:error, _, msg} ->
              msg
          end

        {:error, :restart_failed,
         "kernel-restart into #{v} failed (exit #{code}: #{String.trim(text)}); #{back}; the running session stays on #{prev}"}
    end
  end

  # keep the new release, the one it replaced and one more; never a dot-name or a non-semver dir
  defp prune(lib, keep) do
    rels = Path.join(lib, "releases")

    for(
      n <- ls(rels),
      not String.starts_with?(n, ".") and n not in keep,
      {:ok, ver} <- [Version.parse(n)],
      File.dir?(Path.join(rels, n)),
      do: {ver, n}
    )
    |> Enum.sort_by(&elem(&1, 0), {:desc, Version})
    |> Enum.drop(1)
    |> Enum.each(fn {_, n} -> File.rm_rf(Path.join(rels, n)) end)
  end

  defp out(text), do: :file.write(:standard_io, text)
  defp err(text), do: :file.write(:standard_error, text)
end
