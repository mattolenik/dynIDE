defmodule HerdrCli.UpdateTest do
  # stderr capture is global: not beside other async tests that write to stderr
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias HerdrCli.Update

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    lib = Path.join(tmp, "pre fix/lib/herdr-live")
    for v <- ~w(0.0.8 0.0.9 0.1.0), do: fake_release(Path.join([lib, "releases", v]), v, pub)
    File.mkdir_p!(Path.join(lib, "releases/.stage.123"))
    File.ln_s!("releases/0.1.0", Path.join(lib, "current"))
    tarball = make_tarball(tmp, "0.1.1", pub)
    # the instance answers ping as the new version unless a test says otherwise
    ctx = %{
      root: Path.join(lib, "current"),
      os: "macos",
      arch: "aarch64",
      ping: fn _ -> {:ok, "0.1.1"} end
    }

    {:ok, tmp: tmp, lib: lib, pub: pub, priv: priv, tarball: tarball, ctx: ctx}
  end

  # a release root: start_erl.data, update keys, a launcher, a VM script and a fake broker
  # whose status and kernel-restart exit codes come from files beside it (default: no
  # instance); kernel-restart records its arguments in bin/restart_args
  defp fake_release(dir, v, pub) do
    File.mkdir_p!(Path.join([dir, "releases", v, "update-keys"]))
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join(dir, "releases/start_erl.data"), "16.0 #{v}\n")

    File.write!(
      Path.join([dir, "releases", v, "update-keys/test.pub"]),
      Base.encode64(pub) <> "\n"
    )

    File.write!(Path.join(dir, "bin/herdr-live"), "#!/bin/sh\n")
    File.write!(Path.join(dir, "bin/herdr_live"), "#!/bin/sh\n")
    broker = Path.join(dir, "bin/herdr_broker")

    File.write!(broker, """
    #!/bin/sh
    d=$(dirname "$0")
    case $1 in
      status) cat "$d/status_text" 2>/dev/null; exit $(cat "$d/status" 2>/dev/null || echo 2) ;;
      kernel-restart) shift; echo "$*" >"$d/restart_args"; echo "restarted"; exit $(cat "$d/restart" 2>/dev/null || echo 0) ;;
    esac
    """)

    File.chmod!(broker, 0o755)
    File.chmod!(Path.join(dir, "bin/herdr-live"), 0o755)
  end

  defp make_tarball(tmp, v, pub) do
    stage = Path.join(tmp, "stage")
    fake_release(Path.join(stage, "herdr-live-#{v}"), v, pub)
    tar = Path.join(tmp, "herdr-live-#{v}-macos-aarch64.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar),
        [{~c"herdr-live-#{v}", String.to_charlist(Path.join(stage, "herdr-live-#{v}"))}],
        [:compressed]
      )

    tar
  end

  defp write_manifest(tmp, tarball, priv, over \\ %{}) do
    data = File.read!(tarball)

    art = %{
      "os" => "macos",
      "arch" => "aarch64",
      "url" => "file://" <> URI.encode(tarball),
      "sha256" => Base.encode16(:crypto.hash(:sha256, data), case: :lower),
      "size" => byte_size(data)
    }

    m = %{
      "schema" => 1,
      "channel" => "stable",
      "version" => "0.1.1",
      "released" => "2026-10-25T00:00:00Z",
      "artifacts" => [Map.merge(art, over)]
    }

    path = Path.join(tmp, "manifest.json")
    bytes = JSON.encode!(m)
    File.write!(path, bytes)

    File.write!(
      path <> ".sig",
      Base.encode64(:crypto.sign(:eddsa, :none, bytes, [priv, :ed25519]))
    )

    "file://" <> URI.encode(path)
  end

  defp update(argv, ctx) do
    me = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(me, {:code, Update.run(argv, %{}, ctx)}) end)
        send(me, {:out, out})
      end)

    assert_received {:code, code}
    assert_received {:out, out}
    {code, out, err}
  end

  defp current(lib), do: File.read_link!(Path.join(lib, "current"))

  test "a sha256 mismatch refuses and leaves current", c do
    url = write_manifest(c.tmp, c.tarball, c.priv, %{"sha256" => String.duplicate("0", 64)})
    {code, _out, err} = update(["--manifest", url, "--yes"], c.ctx)
    assert code == 1
    assert %{"code" => "sha256_mismatch"} = JSON.decode!(err)
    assert current(c.lib) == "releases/0.1.0"
    refute File.exists?(Path.join(c.lib, "releases/0.1.1"))
    refute File.exists?(Path.join(c.lib, ".download"))
  end

  test "a manifest signed by an unknown key refuses and leaves current", c do
    {_, other} = :crypto.generate_key(:eddsa, :ed25519)
    url = write_manifest(c.tmp, c.tarball, other)
    {code, _out, err} = update(["--manifest", url, "--yes"], c.ctx)
    assert code == 1
    assert %{"code" => "bad_signature"} = JSON.decode!(err)
    assert current(c.lib) == "releases/0.1.0"
  end

  test "a release with no update keys refuses every update", c do
    File.rm_rf!(Path.join(c.lib, "releases/0.1.0/releases/0.1.0/update-keys"))
    url = write_manifest(c.tmp, c.tarball, c.priv)
    {code, _out, err} = update(["--manifest", url, "--yes"], c.ctx)
    assert code == 1
    assert %{"code" => "no_trusted_keys"} = JSON.decode!(err)
  end

  test "a managed install refuses update and --check, naming the package manager", c do
    flat = Path.join(c.tmp, "libexec")
    fake_release(flat, "0.1.0", c.pub)
    File.write!(Path.join(flat, "releases/managed-by"), "homebrew\n")
    ctx = %{c.ctx | root: flat}
    url = write_manifest(c.tmp, c.tarball, c.priv)

    for flags <- [["--yes"], ["--check"]] do
      {code, _out, err} = update(["--manifest", url | flags], ctx)
      assert code == 1

      assert %{
               "code" => "managed_install",
               "message" => "managed by homebrew; update with your package manager"
             } =
               JSON.decode!(err)
    end
  end

  test "a flat install without the marker is not an install.sh layout", c do
    flat = Path.join(c.tmp, "libexec")
    fake_release(flat, "0.1.0", c.pub)
    url = write_manifest(c.tmp, c.tarball, c.priv)
    {code, _out, err} = update(["--manifest", url, "--yes"], %{c.ctx | root: flat})
    assert code == 1
    assert %{"code" => "not_installed", "message" => msg} = JSON.decode!(err)
    assert msg =~ "not an install.sh layout"
    refute msg =~ "install it with install.sh"
  end

  test "--check prints update available, and up to date when not newer", c do
    url = write_manifest(c.tmp, c.tarball, c.priv)
    assert {0, "update available 0.1.1\n", ""} = update(["--manifest", url, "--check"], c.ctx)
    assert current(c.lib) == "releases/0.1.0"
    # the running release is 0.1.1 itself
    File.rename!(
      Path.join(c.lib, "current/releases/0.1.0"),
      Path.join(c.lib, "current/releases/0.1.1")
    )

    File.write!(Path.join(c.lib, "current/releases/start_erl.data"), "16.0 0.1.1\n")
    assert {0, "up to date 0.1.1\n", ""} = update(["--manifest", url, "--check"], c.ctx)
  end

  test "without --yes nothing is installed", c do
    url = write_manifest(c.tmp, c.tarball, c.priv)
    assert {0, out, ""} = update(["--manifest", url], c.ctx)
    assert out =~ "--yes"
    assert current(c.lib) == "releases/0.1.0"
  end

  test "success flips current, restarts the instance and prunes", c do
    File.write!(Path.join(c.lib, "releases/0.1.0/bin/status"), "0")
    url = write_manifest(c.tmp, c.tarball, c.priv)
    {code, out, err} = update(["--manifest", url, "--yes"], c.ctx)
    assert {code, err} == {0, ""}
    assert out =~ "updated 0.1.0 -> 0.1.1"
    assert out =~ "kernel-restart: restarted"
    vm = Path.join(c.lib, "releases/0.1.1/bin/herdr_live")
    assert File.read!(Path.join(c.lib, "releases/0.1.0/bin/restart_args")) == "-- #{vm} start\n"
    assert current(c.lib) == "releases/0.1.1"
    assert File.regular?(Path.join(c.lib, "current/bin/herdr-live"))
    assert {:ok, %{mode: mode}} = File.stat(Path.join(c.lib, "current/bin/herdr_broker"))
    assert Bitwise.band(mode, 0o100) != 0

    assert c.lib |> Path.join("releases") |> File.ls!() |> Enum.sort() ==
             ~w(.stage.123 0.0.9 0.1.0 0.1.1)

    refute File.exists?(Path.join(c.lib, ".download"))
  end

  test "no running instance installs and skips the restart", c do
    url = write_manifest(c.tmp, c.tarball, c.priv)
    {0, out, ""} = update(["--manifest", url, "--yes"], c.ctx)
    assert out =~ "no running instance, restart skipped"
    assert current(c.lib) == "releases/0.1.1"
  end

  test "a failed kernel-restart leaves current and the new release; a retry reuses it", c do
    File.write!(Path.join(c.lib, "releases/0.1.0/bin/status"), "0")
    File.write!(Path.join(c.lib, "releases/0.1.0/bin/restart"), "1")
    url = write_manifest(c.tmp, c.tarball, c.priv)
    {code, _out, err} = update(["--manifest", url, "--yes"], c.ctx)
    assert code == 1
    assert %{"code" => "restart_failed", "message" => msg} = JSON.decode!(err)
    assert msg =~ "current still points at 0.1.0"
    assert current(c.lib) == "releases/0.1.0"
    assert File.dir?(Path.join(c.lib, "releases/0.1.1"))
    # nothing is pruned after a failed update
    assert File.dir?(Path.join(c.lib, "releases/0.0.8"))
    refute File.exists?(Path.join(c.lib, ".update.lock"))

    # the retry downloads nothing: the artifact url is gone, releases/0.1.1 is reused
    File.write!(Path.join(c.lib, "releases/0.1.0/bin/restart"), "0")
    File.rm!(c.tarball)
    {0, out, ""} = update(["--manifest", url, "--yes"], c.ctx)
    assert out =~ "updated 0.1.0 -> 0.1.1"
    assert current(c.lib) == "releases/0.1.1"
  end

  test "an existing releases/<v> that is not that release is refused, never replaced", c do
    junk = Path.join(c.lib, "releases/0.1.1")
    File.mkdir_p!(junk)
    File.write!(Path.join(junk, "keep"), "x")
    url = write_manifest(c.tmp, c.tarball, c.priv)
    {1, _out, err} = update(["--manifest", url, "--yes"], c.ctx)
    assert %{"code" => "install_failed"} = JSON.decode!(err)
    assert File.read!(Path.join(junk, "keep")) == "x"
    assert current(c.lib) == "releases/0.1.0"
  end

  test "a restart that reports ok but leaves the old version answering does not flip", c do
    File.write!(Path.join(c.lib, "releases/0.1.0/bin/status"), "0")
    url = write_manifest(c.tmp, c.tarball, c.priv)
    ctx = %{c.ctx | ping: fn _ -> {:ok, "0.1.0"} end}
    {1, _out, err} = update(["--manifest", url, "--yes"], ctx)
    assert %{"code" => "restart_did_not_switch"} = JSON.decode!(err)
    assert current(c.lib) == "releases/0.1.0"
    assert File.dir?(Path.join(c.lib, "releases/0.1.1"))
  end

  test "--no-restart flips current, and prune keeps the release the broker is pinned to", c do
    fake_release(Path.join(c.lib, "releases/0.0.7"), "0.0.7", c.pub)
    bin = Path.join(c.lib, "releases/0.1.0/bin")
    File.write!(Path.join(bin, "status"), "0")
    vm = Path.join(c.lib, "releases/0.0.7/bin/herdr_live")
    File.write!(Path.join(bin, "status_text"), "vm_argv=#{vm} start\n")
    url = write_manifest(c.tmp, c.tarball, c.priv)
    {0, out, ""} = update(["--manifest", url, "--yes", "--no-restart"], c.ctx)
    assert out =~ "restart skipped (--no-restart)"
    refute File.exists?(Path.join(bin, "restart_args"))
    assert current(c.lib) == "releases/0.1.1"
    # kept: new, replaced, the pinned 0.0.7, and the newest other (0.0.9); 0.0.8 goes
    assert c.lib |> Path.join("releases") |> File.ls!() |> Enum.sort() ==
             ~w(.stage.123 0.0.7 0.0.9 0.1.0 0.1.1)
  end

  test "a broker that does not answer status leaves current and exits 1", c do
    File.write!(Path.join(c.lib, "releases/0.1.0/bin/status"), "1")
    url = write_manifest(c.tmp, c.tarball, c.priv)
    {1, _out, err} = update(["--manifest", url, "--yes"], c.ctx)
    assert %{"code" => "broker_unreachable"} = JSON.decode!(err)
    assert current(c.lib) == "releases/0.1.0"
    refute File.exists?(Path.join(c.lib, "releases/0.1.0/bin/restart_args"))
  end

  test "a held update lock refuses and is left alone", c do
    lock = Path.join(c.lib, ".update.lock")
    File.write!(lock, "#{System.pid()}\n")
    url = write_manifest(c.tmp, c.tarball, c.priv)
    {1, _out, err} = update(["--manifest", url, "--yes"], c.ctx)
    assert %{"code" => "locked"} = JSON.decode!(err)
    assert File.exists?(lock)
    assert current(c.lib) == "releases/0.1.0"
  end

  test "a lock whose pid is gone is taken over", c do
    {dead, 0} = System.cmd("sh", ["-c", "echo $$"])
    lock = Path.join(c.lib, ".update.lock")
    File.write!(lock, dead)
    url = write_manifest(c.tmp, c.tarball, c.priv)
    {0, out, err} = update(["--manifest", url, "--yes"], c.ctx)
    assert err =~ "held by pid #{String.trim(dead)}, which is gone: taking it over"
    assert out =~ "updated 0.1.0 -> 0.1.1"
    refute File.exists?(lock)
  end

  test "prune keeps the release the running broker boots from", c do
    fake_release(Path.join(c.lib, "releases/0.0.7"), "0.0.7", c.pub)
    bin = Path.join(c.lib, "releases/0.1.0/bin")
    File.write!(Path.join(bin, "status"), "0")
    vm = Path.join(c.lib, "releases/0.0.8/bin/herdr_live")
    File.write!(Path.join(bin, "status_text"), "phase=idle\nvm_argv=#{vm} start\n")
    url = write_manifest(c.tmp, c.tarball, c.priv)
    {0, _out, ""} = update(["--manifest", url, "--yes"], c.ctx)
    # kept: new, replaced, the broker's 0.0.8, and the newest other (0.0.9); 0.0.7 goes
    assert c.lib |> Path.join("releases") |> File.ls!() |> Enum.sort() ==
             ~w(.stage.123 0.0.8 0.0.9 0.1.0 0.1.1)
  end

  test "running/1 reads the release from vm_argv" do
    assert Update.running(
             "a=1\nvm_argv=/p re/lib/herdr-live/releases/0.0.8/bin/herdr_live start\n"
           ) == ["0.0.8"]

    assert Update.running("vm_argv=/p/lib/herdr-live/current/bin/herdr_live start\n") == []
    assert Update.running("") == []
  end

  test "a redirect never leaves https" do
    assert {:error, :fetch_failed, msg} =
             Update.redirect_target("https://a/m.json", "http://b/m.json")

    assert msg =~ "refusing a redirect from https"

    assert {:error, :fetch_failed, _} =
             Update.redirect_target("http://a/m.json", "file:///etc/passwd")

    assert {:ok, "https://a/x.json"} = Update.redirect_target("https://a/m.json", "/x.json")

    assert {:ok, "https://b/m.json"} =
             Update.redirect_target("http://a/m.json", "https://b/m.json")
  end

  # a one-connection-at-a-time HTTP/1.1 stub on 127.0.0.1: path => {status, headers, body}
  defp recv_head(s, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, data} <- :gen_tcp.recv(s, 0, 5000), do: recv_head(s, acc <> data)
    end
  end

  defp http_manifest(c, base, art_path) do
    data = File.read!(c.tarball)

    m = %{
      "schema" => 1,
      "channel" => "stable",
      "version" => "0.1.1",
      "artifacts" => [
        %{
          "os" => "macos",
          "arch" => "aarch64",
          "url" => base <> art_path,
          "sha256" => Base.encode16(:crypto.hash(:sha256, data), case: :lower),
          "size" => byte_size(data)
        }
      ]
    }

    bytes = JSON.encode!(m)
    sig = Base.encode64(:crypto.sign(:eddsa, :none, bytes, [c.priv, :ed25519]))
    {bytes, sig, data}
  end

  test "http: an artifact over the manifest size is cut off (Content-Length and streamed)", c do
    routes = fn base ->
      {bytes, sig, data} = http_manifest(c, base, "/cl.tar.gz")
      {bytes2, sig2, _} = http_manifest(c, base, "/stream.tar.gz")
      big = data <> String.duplicate("x", 100_000)

      %{
        "/m.json" => {200, [{"content-length", byte_size(bytes)}], bytes},
        "/m.json.sig" => {200, [{"content-length", byte_size(sig)}], sig},
        "/m2.json" => {200, [{"content-length", byte_size(bytes2)}], bytes2},
        "/m2.json.sig" => {200, [{"content-length", byte_size(sig2)}], sig2},
        # a lying Content-Length is refused before the body
        "/cl.tar.gz" => {200, [{"content-length", byte_size(big)}], big},
        # no Content-Length: the running count stops it
        "/stream.tar.gz" => {200, [], big}
      }
    end

    # the routes need the port, so the stub serves a table filled after listen
    {:ok, agent} = Agent.start_link(fn -> %{} end)
    base = http_stub_dynamic(agent)
    Agent.update(agent, fn _ -> routes.(base) end)

    for m <- ["/m.json", "/m2.json"] do
      {1, _out, err} = update(["--manifest", base <> m, "--yes"], c.ctx)
      # the cap, not the after-the-fact size check
      assert %{"code" => "size_mismatch", "message" => msg} = JSON.decode!(err), m
      assert msg =~ "over the manifest's", msg
      assert current(c.lib) == "releases/0.1.0"
      refute File.exists?(Path.join(c.lib, "releases/0.1.1"))
    end

    {1, _out, err} = update(["--manifest", base <> "/missing.json", "--check"], c.ctx)
    assert %{"code" => "fetch_failed", "message" => msg} = JSON.decode!(err)
    assert msg =~ "HTTP 404"
  end

  defp http_stub_dynamic(agent) do
    {:ok, l} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(l)
    pid = spawn_link(fn -> serve_dynamic(l, agent) end)
    :ok = :gen_tcp.controlling_process(l, pid)
    on_exit(fn -> Process.exit(pid, :kill) end)
    "http://127.0.0.1:#{port}"
  end

  defp serve_dynamic(l, agent) do
    serve_once(l, Agent.get(agent, & &1))
    serve_dynamic(l, agent)
  end

  defp serve_once(l, routes) do
    {:ok, s} = :gen_tcp.accept(l)
    {:ok, req} = recv_head(s, "")
    [_, path | _] = String.split(req, " ", parts: 3)
    {status, headers, body} = Map.get(routes, path, {404, [], ""})
    head = Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end)
    _ = :gen_tcp.send(s, ["HTTP/1.1 #{status} X\r\n", head, "connection: close\r\n\r\n", body])
    :gen_tcp.close(s)
  end

  for {name, entry} <- [
        {"outside herdr-live-<V>/", :dotdot},
        {"a symlink", :symlink},
        {"an absolute name", :absolute}
      ] do
    test "a tarball entry that is #{name} is refused", c do
      tar = evil_tarball(c.tmp, unquote(entry))
      url = write_manifest(c.tmp, tar, c.priv)
      {1, _out, err} = update(["--manifest", url, "--yes"], c.ctx)
      assert %{"code" => "bad_tarball"} = JSON.decode!(err)
      assert current(c.lib) == "releases/0.1.0"

      assert c.lib |> Path.join("releases") |> File.ls!() |> Enum.sort() ==
               ~w(.stage.123 0.0.8 0.0.9 0.1.0)
    end
  end

  # the good 0.1.1 tree plus one bad entry
  defp evil_tarball(tmp, kind) do
    stage = Path.join(tmp, "stage/herdr-live-0.1.1")
    File.write!(Path.join(tmp, "x"), "x")
    File.ln_s!("/etc/passwd", Path.join(tmp, "link"))

    bad =
      case kind do
        :dotdot -> {~c"herdr-live-0.1.1/../x", Path.join(tmp, "x")}
        :symlink -> {~c"herdr-live-0.1.1/bin/link", Path.join(tmp, "link")}
        :absolute -> {~c"/tmp/herdr-live-evil", Path.join(tmp, "x")}
      end

    tar = Path.join(tmp, "evil-#{kind}.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar),
        [{~c"herdr-live-0.1.1", String.to_charlist(stage)}, bad]
        |> Enum.map(fn {n, p} -> {n, to_charlist(p)} end),
        [:compressed]
      )

    tar
  end

  test "usage errors exit 2", c do
    assert {2, "", err} = update(["--bogus"], c.ctx)
    assert err =~ "usage: herdr-live update"
  end
end
