defmodule HerdrCli.Update do
  @moduledoc """
  `herdr-live update [--manifest URL] [--check] [--yes] [--no-restart]` (M18 R4, R5).

  Fetches the channel manifest and its `.sig` (`file://` or `http(s)://`, bodies capped:
  manifest 1 MiB, artifact its manifest `size`; redirects never leave https), verifies
  the signature against the release's `releases/<V>/update-keys/*.pub` (in a source tree
  only `$HERDR_LIVE_UPDATE_PUBKEY`), and with `--yes` installs the artifact for this OS
  and arch beside the running release under `<lib>/.update.lock`: download to
  `<lib>/.download/`, size and sha256 check, extract into `releases/.<V>.partial`, rename
  to `releases/<V>` (an existing `releases/<V>` that is that release is reused, never
  replaced). When a broker answers this instance (the runtime-dir env of `herdr-live
  kernel-restart`), `herdr_broker kernel-restart -- <lib>/releases/<V>/bin/herdr_live
  start` boots the new release; the broker keeps that VM argv only if the restart
  succeeds. `current` flips (a temp symlink renamed over it) only after that success, or
  when no instance runs, or with `--no-restart`; a failed restart leaves `current` and the
  broker on the old release and exits 1. After a flip, releases older than the previous
  two are pruned; dot-names in `releases/` (stage and partial dirs) are never touched.

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
    with :ok <- unmanaged(ctx),
         {:ok, cur} <- running_version(ctx),
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
        true -> install(m, opts, Map.put(ctx, :env, env))
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

  # a package manager (releases/managed-by: "homebrew", "nix") owns the install
  defp unmanaged(%{root: root}) do
    case File.read(Path.join(root, "releases/managed-by")) do
      {:ok, data} ->
        pm = data |> String.split("\n") |> hd() |> String.trim()
        pm = if pm == "", do: "a package manager", else: pm
        {:error, :managed_install, "managed by #{pm}; update with your package manager"}

      {:error, _} ->
        :ok
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

  defp start_http("http" <> _ = url) do
    with {:ok, _} <- Application.ensure_all_started([:inets, :ssl]),
         :ok <- if(String.starts_with?(url, "https:"), do: :public_key.cacerts_load(), else: :ok) do
      :ok
    else
      {:error, r} -> fetch_error(url, "cannot start the http client: #{inspect(r, limit: 10)}")
    end
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
    case http_get(url, @max_manifest, {:mem, []}) do
      {:error, :too_big} -> fetch_error(url, "over #{@max_manifest} bytes")
      other -> other
    end
  end

  defp fetch(url),
    do: fetch_error(url, "unsupported URL scheme (want file://, http:// or https://)")

  defp download("file://" <> _ = url, dest, size) do
    path = URI.decode(URI.parse(url).path || "")

    with {:ok, %{size: ^size}} <- File.stat(path),
         :ok <- File.cp(path, dest) do
      :ok
    else
      {:ok, %{size: n}} ->
        {:error, :size_mismatch, "#{url} is #{n} bytes, the manifest says #{size}"}

      {:error, r} ->
        fetch_error(url, :file.format_error(r))
    end
  end

  defp download("http" <> _ = url, dest, size) do
    case File.open(dest, [:write, :binary, :raw]) do
      {:ok, dev} ->
        res = http_get(url, size, {:file, dev})
        File.close(dev)

        case res do
          {:ok, _} ->
            :ok

          {:error, :too_big} ->
            {:error, :size_mismatch, "#{url} is over the manifest's #{size} bytes"}

          e ->
            e
        end

      {:error, r} ->
        {:error, :install_failed, "cannot write #{dest}: #{:file.format_error(r)}"}
    end
  end

  defp download(url, _dest, _size),
    do: fetch_error(url, "unsupported URL scheme (want file://, http:// or https://)")

  @http_timeout 300_000
  @max_hops 5

  # GET `url` into `sink` ({:mem, iodata} or {:file, device}), at most `max` body bytes
  # (Content-Length checked first, then a running count). Redirects are followed here,
  # at most @max_hops, never from https to anything else.
  defp http_get(url, max, sink, hops \\ 0) do
    opts = [sync: false, stream: :self, body_format: :binary]

    case :httpc.request(:get, {String.to_charlist(url), []}, http_opts(url), opts) do
      {:ok, ref} -> response(ref, url, max, sink, hops)
      {:error, r} -> fetch_error(url, why(r))
    end
  end

  defp response(ref, url, max, sink, hops) do
    receive do
      {:http, {^ref, :stream_start, headers}} ->
        if content_length(headers) > max,
          do: cancel(ref),
          else: body(ref, url, max, sink, 0)

      {:http, {^ref, {{_, 200, _}, _, data}}} when byte_size(data) > max ->
        {:error, :too_big}

      {:http, {^ref, {{_, 200, _}, _, data}}} ->
        with {:ok, sink} <- put(sink, data), do: {:ok, finish(sink)}

      {:http, {^ref, {{_, status, _}, headers, _}}} when status in [301, 302, 303, 307, 308] ->
        redirect(url, location(headers), max, sink, hops)

      {:http, {^ref, {{_, status, _}, _, _}}} ->
        fetch_error(url, "HTTP #{status}")

      {:http, {^ref, {:error, r}}} ->
        fetch_error(url, why(r))
    after
      @http_timeout ->
        :httpc.cancel_request(ref)
        fetch_error(url, "no response in #{div(@http_timeout, 1000)} s")
    end
  end

  defp body(ref, url, max, sink, n) do
    receive do
      {:http, {^ref, :stream, data}} when n + byte_size(data) > max -> cancel(ref)
      {:http, {^ref, :stream, data}} -> more(ref, url, max, put(sink, data), n + byte_size(data))
      {:http, {^ref, :stream_end, _}} -> {:ok, finish(sink)}
      {:http, {^ref, {:error, r}}} -> fetch_error(url, why(r))
    after
      @http_timeout ->
        :httpc.cancel_request(ref)
        fetch_error(url, "stalled for #{div(@http_timeout, 1000)} s")
    end
  end

  defp more(ref, url, max, {:ok, sink}, n), do: body(ref, url, max, sink, n)

  defp more(ref, _url, _max, error, _n) do
    :httpc.cancel_request(ref)
    error
  end

  defp cancel(ref) do
    :httpc.cancel_request(ref)
    {:error, :too_big}
  end

  defp put({:mem, acc}, data), do: {:ok, {:mem, [acc, data]}}

  defp put({:file, dev} = sink, data) do
    case :file.write(dev, data) do
      :ok ->
        {:ok, sink}

      {:error, r} ->
        {:error, :install_failed, "cannot write the download: #{:file.format_error(r)}"}
    end
  end

  defp finish({:mem, acc}), do: IO.iodata_to_binary(acc)
  defp finish({:file, _}), do: :file

  defp content_length(headers) do
    with {_, v} <- List.keyfind(headers, ~c"content-length", 0),
         {n, ""} <- Integer.parse(List.to_string(v)) do
      n
    else
      _ -> 0
    end
  end

  defp location(headers) do
    case List.keyfind(headers, ~c"location", 0) do
      {_, v} -> List.to_string(v)
      nil -> nil
    end
  end

  defp redirect(url, nil, _max, _sink, _hops), do: fetch_error(url, "redirect without a location")

  defp redirect(url, _to, _max, _sink, hops) when hops >= @max_hops,
    do: fetch_error(url, "more than #{@max_hops} redirects")

  defp redirect(url, to, max, sink, hops) do
    with {:ok, next} <- redirect_target(url, to),
         :ok <- start_http(next),
         do: http_get(next, max, sink, hops + 1)
  end

  @doc false
  # where a redirect from `url` to Location `to` may go: never from https to anything else
  @spec redirect_target(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :fetch_failed, String.t()}
  def redirect_target(url, to) do
    next = url |> URI.merge(to) |> URI.to_string()

    cond do
      String.starts_with?(url, "https:") and not String.starts_with?(next, "https:") ->
        fetch_error(url, "refusing a redirect from https to #{next}")

      not String.starts_with?(next, ["http:", "https:"]) ->
        fetch_error(url, "refusing a redirect to #{next}")

      true ->
        {:ok, next}
    end
  end

  defp http_opts("https" <> _) do
    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    [ssl: ssl] ++ http_opts("http")
  end

  defp http_opts(_), do: [timeout: @http_timeout, connect_timeout: 10_000, autoredirect: false]

  # httpc's {:failed_connect, [{:to_address, _}, {family, opts, reason}]}: the reason
  defp why({:failed_connect, [_, {_, _, r}]}), do: inspect(r, limit: 10)
  defp why(r), do: inspect(r, limit: 10)

  defp fetch_error(url, why), do: {:error, :fetch_failed, "cannot fetch #{url}: #{why}"}

  # -- install ----------------------------------------------------------------

  defp install(m, opts, ctx) do
    v = m["version"]

    with {:ok, lib, prev} <- layout(ctx),
         {:ok, art} <- pick(m, ctx) do
      locked(lib, fn -> place_and_activate(art, lib, prev, v, opts, ctx) end)
    end
  end

  defp place_and_activate(art, lib, prev, v, opts, ctx) do
    with :ok <- place(art, lib, v), do: activate(lib, prev, v, opts, ctx)
  end

  # one update per prefix at a time; the lock goes when this run ends (a killed run leaves
  # it: the message names the file)
  defp locked(lib, fun, retry \\ true) do
    lock = Path.join(lib, ".update.lock")

    case File.open(lock, [:write, :exclusive]) do
      {:ok, dev} ->
        IO.write(dev, "#{:os.getpid()}\n")
        File.close(dev)

        try do
          fun.()
        after
          File.rm(lock)
        end

      {:error, :eexist} ->
        holder = lock |> File.read() |> ok_text() |> String.trim()

        if retry and stale?(holder) do
          # ponytail: two runs taking over the same stale lock at once can both win;
          # an O_EXCL rename dance would close it if that ever matters
          :file.write(
            :standard_error,
            "herdr-live: update lock #{lock} held by pid #{holder}, which is gone: taking it over\n"
          )

          File.rm(lock)
          locked(lib, fun, false)
        else
          {:error, :locked,
           "another update is running (pid #{holder}, #{lock}; remove it if no update runs)"}
        end

      {:error, r} ->
        {:error, :install_failed, "cannot create #{lock}: #{:file.format_error(r)}"}
    end
  end

  defp ok_text({:ok, text}), do: text
  defp ok_text(_), do: ""

  # gone: `kill -0` says no such process (EPERM, another user's live pid, is not stale)
  defp stale?(pid) do
    kill = System.find_executable("kill")

    pid =~ ~r/\A[0-9]+\z/ and kill != nil and
      case System.cmd(kill, ["-0", pid], stderr_to_stdout: true) do
        {_, 0} -> false
        {text, _} -> text =~ ~r/no such process/i
      end
  end

  # releases/<v>: an existing dir is reused when it is that release (an earlier update
  # whose restart failed, or the release a broker runs), never removed or replaced
  defp place(art, lib, v) do
    dest = Path.join([lib, "releases", v])

    cond do
      not File.exists?(dest) ->
        with {:ok, tarball} <- fetch_artifact(art, lib, v), do: unpack(tarball, lib, v)

      release_dir?(dest, v) ->
        :ok

      true ->
        {:error, :install_failed,
         "#{dest} exists but is not the herdr-live #{v} release; remove it and retry"}
    end
  end

  defp release_dir?(dir, v) do
    with {:ok, data} <- File.read(Path.join(dir, "releases/start_erl.data")),
         [_, ^v] <- String.split(data) do
      File.regular?(Path.join(dir, "bin/herdr-live")) and
        File.regular?(Path.join(dir, "bin/herdr_live"))
    else
      _ -> false
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
         "#{root} is not an install.sh layout (<prefix>/lib/herdr-live/current -> releases/<V>), so it cannot update itself"}
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
         :ok <- download(url, dest, size) do
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
           true <- release_dir?(Path.join(partial, top), v) do
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

  # `current` flips only once the new release runs (or nothing runs): a failed restart
  # leaves it, and the broker's VM argv, on the old release
  defp activate(lib, prev, v, opts, ctx) do
    # the running release's broker client speaks the running broker's protocol
    broker = Path.join([lib, "releases", prev, "bin/herdr_broker"])
    done = "updated #{prev} -> #{v}\n"

    case System.cmd(broker, ["status"], stderr_to_stdout: true) do
      {text, 0} when opts.no_restart ->
        flipped(
          lib,
          [prev, v | running(text)],
          v,
          done <> "restart skipped (--no-restart); run herdr-live kernel-restart to boot #{v}\n"
        )

      {text, 0} ->
        kernel_restart(broker, lib, [prev, v | running(text)], {prev, v, done}, ctx)

      {_, 2} ->
        flipped(lib, [prev, v], v, done <> "no running instance, restart skipped\n")

      {text, code} ->
        {:error, :broker_unreachable,
         "the broker did not answer status (exit #{code}: #{String.trim(text)}); releases/#{v} is installed, current still points at #{prev}; retry herdr-live update"}
    end
  end

  @doc false
  # The release a broker's VMs boot from (its status `vm_argv=` line): pruning keeps it.
  # A `current/bin/herdr_live` argv is `current` (prev at this point): nothing extra.
  @spec running(String.t()) :: [String.t()]
  def running(status) do
    case Regex.run(~r{^vm_argv=.*/releases/([^/\n]+)/bin/herdr_live start$}m, status) do
      [_, rel] -> [rel]
      nil -> []
    end
  end

  defp flipped(lib, keep, v, text) do
    with :ok <- flip(lib, v) do
      prune(lib, keep)
      {:ok, text}
    end
  end

  defp kernel_restart(broker, lib, keep, {prev, v, done}, ctx) do
    vm = [Path.join([lib, "releases", v, "bin/herdr_live"]), "start"]

    case System.cmd(broker, ["kernel-restart", "--" | vm], stderr_to_stdout: true) do
      {text, 0} ->
        switched(lib, keep, {prev, v, done <> "kernel-restart: " <> text}, ctx)

      {text, code} ->
        {:error, :restart_failed,
         "kernel-restart into #{v} failed (exit #{code}: #{String.trim(text)}); current still points at #{prev}, the running session stays on #{prev}; releases/#{v} is kept"}
    end
  end

  # `current` flips only once the instance answers as <v>
  defp switched(lib, keep, {prev, v, text}, ctx) do
    case Map.get(ctx, :ping, &api_version/1).(ctx.env) do
      {:ok, ^v} ->
        with {:error, _, msg} <- flipped(lib, keep, v, text) do
          {:error, :install_failed, "the instance runs #{v}, but #{msg}"}
        end

      other ->
        {:error, :restart_did_not_switch,
         "kernel-restart reported ok but ping answers #{inspect(other, limit: 10)}, not #{v}; current still points at #{prev}"}
    end
  end

  # the version the instance's API reports (the same socket rule as every other verb)
  defp api_version(env) do
    with {:ok, s} <- HerdrCli.Client.connect(HerdrCli.Client.socket_path(env), 5000) do
      reply = HerdrCli.Client.call(s, "ping", %{}, 10_000)
      :gen_tcp.close(s)

      case reply do
        {:ok, %{"result" => %{"version" => v}}} -> {:ok, v}
        other -> other
      end
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
