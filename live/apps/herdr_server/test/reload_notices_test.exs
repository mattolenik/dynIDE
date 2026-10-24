defmodule HerdrServer.ReloadNoticesTest do
  # Reload events reach a fake client's scene as the status line's :notice child.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrScene.{Protocol, Scene}
  alias HerdrServer.App.Store
  alias HerdrServer.ReloadNotices

  setup do
    reset()
    old = Application.get_env(:herdr_server, :notice_ms)
    start_supervised!(HerdrReload.Notices)
    # resubscribe now instead of waiting for the bridge's retry tick
    send(ReloadNotices, :subscribe)
    :sys.get_state(ReloadNotices)

    on_exit(fn ->
      if old,
        do: Application.put_env(:herdr_server, :notice_ms, old),
        else: Application.delete_env(:herdr_server, :notice_ms)

      reset()
    end)
  end

  defp reset do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(HerdrServer.Client.Supervisor),
        do: DynamicSupervisor.terminate_child(HerdrServer.Client.Supervisor, pid)

    Store.reset()
  end

  defp client do
    parent = self()

    pid =
      spawn(fn ->
        info = %{
          kind: :term,
          transport: :ref,
          size: %{cols: 80, rows: 24},
          cell_px: nil,
          caps: %{},
          client: self()
        }

        send(parent, {:attached, self(), GenServer.call(Protocol.endpoint(), {:attach, info})})
        relay(parent)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:attached, ^pid, {:ok, _session, _}}
    assert_receive {^pid, {:scene, _}}, 500
    pid
  end

  defp relay(parent) do
    receive do
      msg -> send(parent, {self(), msg})
    end

    relay(parent)
  end

  defp notice_node(%Scene{chrome: chrome}) do
    status = Enum.find(chrome.children, &(&1.id == :status))
    Enum.find(status.children, &(&1.id == :notice))
  end

  defp next_notice(c) do
    assert_receive {^c, {:scene, s}}, 500
    notice_node(s)
  end

  defp diag,
    do: %{file: Path.join(File.cwd!(), "lib/foo.ex"), position: {12, 3}, message: "undefined x"}

  test "each reload event kind becomes a status notice with its token" do
    c = client()

    cases = [
      {{:compile_error, [diag()]}, :error, "lib/foo.ex:12: undefined x"},
      {{:loaded, 4, [A, B]}, :muted, "reloaded 2 modules"},
      {{:rolled_back, 3, [A], :manual}, :warning, "rolled back batch 3 (1 modules): manual"},
      {{:rejected, Foo.Bar, [:state, :x]}, :warning, "rejected: local fun from Foo.Bar at"},
      {{:purge_blocked, Foo, [self()]}, :warning, "purge blocked: Foo"}
    ]

    for {event, token, prefix} <- cases do
      HerdrReload.Notices.broadcast(event)
      assert_receive {^c, {:notice, %{text: text, source: :reload}}}, 500
      assert String.starts_with?(text, prefix), "#{inspect(event)}: #{text}"
      assert String.length(text) <= 80
      assert %{role: :text, token: ^token, text: ^text} = next_notice(c)
    end
  end

  test "a rollback reason from the guard is summarised and truncated" do
    reason = {:raise, RuntimeError.exception(String.duplicate("x", 200)), []}
    {:warning, text} = ReloadNotices.format({:rolled_back, 7, [A, B], reason})
    assert text =~ "rolled back batch 7 (2 modules): ** (RuntimeError) xxx"
    assert String.length(text) == 80
  end

  test "info and warning notices expire; an error stays until replaced" do
    Application.put_env(:herdr_server, :notice_ms, info: 30, warning: 60)
    c = client()

    HerdrReload.Notices.broadcast({:loaded, 1, [A]})
    assert %{token: :muted} = next_notice(c)
    assert next_notice(c) == nil

    HerdrReload.Notices.broadcast({:compile_error, [diag()]})
    assert %{token: :error} = next_notice(c)
    refute_receive {^c, {:scene, _}}, 150

    HerdrReload.Notices.broadcast({:loaded, 2, [A]})
    assert %{token: :muted, text: "reloaded 1 modules"} = next_notice(c)
    assert next_notice(c) == nil
  end

  test "a non-reload protocol notice also renders and expires" do
    Application.put_env(:herdr_server, :notice_ms, info: 30, warning: 30)
    c = client()
    [{session, _}] = Registry.lookup(HerdrServer.Client.Registry, :clients)
    send(session, {:notice, %{level: :error, text: "could not start pane 2"}})
    assert_receive {^c, {:notice, %{level: :error}}}
    assert %{token: :error, text: "could not start pane 2"} = next_notice(c)
    # only reload errors are sticky
    assert next_notice(c) == nil
  end
end
