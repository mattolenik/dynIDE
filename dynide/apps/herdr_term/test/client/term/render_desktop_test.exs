defmodule HerdrTerm.Client.Term.RenderDesktopTest do
  # bell, clipboard, link opening and host colours through Render; the fake desktop and
  # the SSH env vars are VM-global
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrTerm.Client
  alias HerdrTerm.Kernel.Fake.{Desktop, Tty}
  alias HerdrTerm.Test.FakeServer

  @remote ~w(SSH_CONNECTION SSH_TTY VSCODE_IPC_HOOK_CLI)

  setup do
    saved = Map.new(@remote, &{&1, System.get_env(&1)})
    Enum.each(@remote, &System.delete_env/1)

    on_exit(fn ->
      Desktop.reset()
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end)

    Desktop.listen(self())
    ep = FakeServer.unique_name()
    FakeServer.start(self(), ep, {__MODULE__, :rows, []})
    sup = start_supervised!({Client, endpoint: ep})
    assert_receive {:attached, _, _session}
    tty = Client.tty(sup)
    %{render: Client.render(sup), tty: tty, base: Tty.written(tty)}
  end

  def rows(_id), do: nil

  defp written_since(tty, base) do
    w = Tty.written(tty)
    binary_part(w, byte_size(base), byte_size(w) - byte_size(base))
  end

  test "a bell rings the host terminal", %{render: render, tty: tty, base: base} do
    send(render, {:bell, 3})
    :sys.get_state(render)
    assert written_since(tty, base) == "\a"
  end

  test "clipboard text goes to the desktop tool", %{render: render} do
    send(render, {:clipboard, %{text: "copied", source: :pane}})
    assert_receive {:desktop, :clipboard_write, "copied"}
  end

  test "a clipboard write that cannot reach the host is logged", %{render: render} do
    System.put_env("SSH_TTY", "/dev/pts/1")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(render, {:clipboard, %{text: String.duplicate("x", 200_000), source: :pane}})
        :sys.get_state(render)
      end)

    assert log =~ "clipboard"
    assert log =~ "too_large"
  end

  test "a non-UTF-8 url is ignored", %{render: render} do
    send(render, {:open_url, "https://x/" <> <<0xFF>>})
    :sys.get_state(render)
    refute_received {:desktop, :open_url, _}
    assert Process.alive?(render)
  end

  test "only http(s) urls are opened", %{render: render} do
    send(render, {:open_url, "file:///etc/passwd"})
    send(render, {:open_url, "https://example.com/a"})
    assert_receive {:desktop, :open_url, "https://example.com/a"}
    refute_received {:desktop, :open_url, "file:///etc/passwd"}
  end

  test "host colours land in the theme; a bad shape is ignored", %{render: render} do
    send(render, {:host_colors, %{fg: {255, 255, 255}, bg: nil}})
    assert :sys.get_state(render).theme.host == %{fg: {255, 255, 255}, bg: nil}
    send(render, {:host_colors, %{fg: {256, 0, 0}, bg: nil}})
    send(render, {:host_colors, %{fg: "white"}})
    assert :sys.get_state(render).theme.host == %{fg: {255, 255, 255}, bg: nil}
  end

  test "host colours survive a theme refresh (appearance change from caps)", %{render: render} do
    send(render, {:scene, HerdrScene.Fixture.load("single_pane_80x24")})
    send(render, {:host_colors, %{fg: {0, 0, 0}, bg: {255, 255, 255}}})
    send(render, {:caps, %{scheme: :light, colors: %{bg: {255, 255, 255}}}})
    state = :sys.get_state(render)
    assert state.appearance == :light
    assert state.theme.host == %{fg: {0, 0, 0}, bg: {255, 255, 255}}
  end
end
