defmodule DynideTerm.Client.Term.RenderSoundTest do
  # Fake.Desktop is VM-global (Render is the caller): not async
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideScene.Fixture
  alias DynideTerm.Client
  alias DynideTerm.Kernel.Fake.{Blit, Desktop, Tty}
  alias DynideTerm.Test.FakeServer

  @wait 2_000

  def rows(_id, _agent), do: nil

  setup do
    ep = FakeServer.unique_name()
    FakeServer.start(self(), ep, {__MODULE__, :rows, [nil]})
    sup = start_supervised!({Client, endpoint: ep})
    assert_receive {:attached, _, _session}, @wait
    tty = Client.tty(sup)
    Blit.subscribe_frames(tty, self())
    on_exit(&Desktop.reset/0)
    %{render: Client.render(sup), tty: tty}
  end

  defp scene(render, props) do
    s = Fixture.load("single_pane_80x24")
    send(render, {:scene, %{s | chrome: %{s.chrome | props: Map.merge(s.chrome.props, props)}}})
    assert_receive {:frame, _, _}, @wait
  end

  defp alert(render, sound) do
    a = %{kind: :notification, level: :done, title: "pi", body: "w", pane: 1, sound: sound}
    send(render, {:alert, a})
    _ = :sys.get_state(render)
  end

  defp builtin(name), do: Path.join([:code.priv_dir(:dynide_term), "sounds", name])

  test "without a command the built-in sound plays, no BEL", %{render: render, tty: tty} do
    Desktop.listen(self())
    scene(render, %{sound: %{enabled: true}})
    alert(render, :request)
    path = builtin("request.mp3")
    assert_received {:desktop, :play, ^path}
    assert File.regular?(path)
    refute Tty.written(tty) =~ "\a"
  end

  test "no player: BEL", %{render: render, tty: tty} do
    Desktop.listen(self(), {:error, :unavailable})
    scene(render, %{sound: %{enabled: true}})
    alert(render, :done)
    assert_received {:desktop, :play, _}
    assert Tty.written(tty) =~ "\a"
  end

  @tag :tmp_dir
  test "a configured path plays when it is a file, else the built-in", %{
    render: render,
    tmp_dir: dir
  } do
    Desktop.listen(self())
    file = Path.join(dir, "d.mp3")
    File.write!(file, "x")
    scene(render, %{sound: %{enabled: true, done_path: file, request_path: dir <> "/nope"}})
    alert(render, :done)
    assert_received {:desktop, :play, ^file}
    alert(render, :request)
    path = builtin("request.mp3")
    assert_received {:desktop, :play, ^path}
  end

  @tag :tmp_dir
  test "an inline client ignores paths from the wire", %{render: render, tmp_dir: dir} do
    Desktop.listen(self())
    file = Path.join(dir, "d.mp3")
    File.write!(file, "x")
    :sys.replace_state(render, &%{&1 | transport: :inline})
    scene(render, %{sound: %{enabled: true, done_path: file}})
    alert(render, :done)
    path = builtin("done.mp3")
    assert_received {:desktop, :play, ^path}
  end

  test "system delivery calls the desktop notifier", %{render: render, tty: tty} do
    Desktop.listen(self())
    scene(render, %{toast: %{delivery: :system}, sound: %{enabled: false}})
    alert(render, :done)
    assert_received {:desktop, :notify, {"pi", "w"}}
    refute Tty.written(tty) =~ "\e]9"
  end
end
