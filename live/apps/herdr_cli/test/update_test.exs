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
    ctx = %{root: Path.join(lib, "current"), os: "macos", arch: "aarch64"}
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
      status) exit $(cat "$d/status" 2>/dev/null || echo 2) ;;
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
    File.write!(lock, "1\n")
    url = write_manifest(c.tmp, c.tarball, c.priv)
    {1, _out, err} = update(["--manifest", url, "--yes"], c.ctx)
    assert %{"code" => "locked"} = JSON.decode!(err)
    assert File.exists?(lock)
    assert current(c.lib) == "releases/0.1.0"
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
