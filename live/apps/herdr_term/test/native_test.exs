defmodule HerdrTerm.NativeTest do
  use ExUnit.Case, async: true

  alias HerdrTerm.Native.{Blit, Tty}

  test "the nif loads and open reports errors as posix atoms" do
    assert Tty.open(%{path: "/nonexistent"}) == {:error, :enoent}
    # A regular file opens but is no terminal (/dev/null is :enodev on macOS).
    file =
      Path.join(System.tmp_dir!(), "herdr_term_not_a_tty_#{System.unique_integer([:positive])}")

    File.write!(file, "")
    assert Tty.open(%{path: file}) == {:error, :enotty}
    File.rm!(file)
  end

  test "blit rejects an unknown cursor shape before reaching the tty" do
    assert Blit.frame(make_ref(), [], %{cursor: nil, shape: :beam, repaint: false}) ==
             {:error, :bad_frame}
  end

  test "frame takes graphics ops; a malformed op or op list is :bad_frame" do
    {:ok, tty} = Tty.open(%{path: pty_path()})
    rows = [{0, HerdrTerm.Cells.text("ab", HerdrTerm.Cells.style([]))}]
    opts = %{cursor: nil, shape: :default, repaint: false}

    place =
      {:place,
       %{
         id: 10_001,
         placement: 1,
         x: 0,
         y: 0,
         cols: 2,
         rows: 1,
         src: {0, 0, 0, 0},
         off: {0, 0},
         z: 0
       }}

    upload =
      {:upload,
       %{id: 10_001, format: :rgba, width: 1, height: 1, data: <<0, 0, 0, 0>>, medium: :direct}}

    ops = [upload, place, {:delete_placement, 10_001, 1}, {:delete_image, 10_001}, :delete_all]
    assert Blit.frame(tty, rows, opts) == :ok
    assert Blit.frame(tty, rows, Map.put(opts, :graphics, ops)) == :ok

    for bad <- [
          [{:place, %{}}],
          [{:place, %{elem(place, 1) | cols: 0}}],
          [{:upload, %{elem(upload, 1) | format: :jpeg}}],
          [{:upload, %{elem(upload, 1) | data: ""}}],
          [{:delete_image, -1}],
          [:delete_some],
          :delete_all
        ] do
      assert Blit.frame(tty, rows, Map.put(opts, :graphics, bad)) == {:error, :bad_frame},
             inspect(bad)
    end

    assert Enum.any?(1..100, fn _ ->
             Process.sleep(10)
             Tty.stats(tty).graphics_bytes > 0
           end)

    assert %{file_transport: :unknown} = Tty.stats(tty)
    Tty.restore(tty)
  end

  # The slave of a pty that `script` holds open and relays to this process;
  # the port and its `sleep` go away when the test exits.
  defp pty_path do
    sh = "echo pid=$$; tty; exec sleep 30"

    args =
      if match?({:unix, :darwin}, :os.type()),
        do: ["-q", "/dev/null", "/bin/sh", "-c", sh],
        else: ["-qfc", sh, "/dev/null"]

    port = Port.open({:spawn_executable, System.find_executable("script")}, [:binary, args: args])

    {pid, path} = read_pty(port, "")

    on_exit(fn ->
      System.cmd("kill", [pid])
      if Port.info(port), do: Port.close(port)
    end)

    path
  end

  defp read_pty(port, acc) do
    case Regex.run(~r/pid=(\d+)\s+(\/dev\/\S+)/, acc) do
      [_, pid, path] ->
        {pid, path}

      nil ->
        receive do
          {^port, {:data, data}} -> read_pty(port, acc <> data)
        after
          2000 -> flunk("no pty from script: #{inspect(acc)}")
        end
    end
  end
end
