defmodule DynideServer.Handoff.LinkTest do
  use ExUnit.Case, async: false

  alias DynideServer.Handoff.{Link, Notice, State}
  alias DynideServer.Native.{Keeper, Pty, Vt}
  alias DynideServer.Native.Link, as: NLink

  test "init is :ignore without DYNIDE_BROKER_SOCK" do
    assert System.get_env("DYNIDE_BROKER_SOCK") == nil
    assert Link.init([]) == :ignore
    refute Link.enabled?()
    assert Link.hold("k", "b", []) == :ok
    assert Link.restored() == :ok
    assert Link.take_adopted("pane/") == []
  end

  test "init is :ignore with an empty DYNIDE_BROKER_SOCK (a plugin pane's blanked env)" do
    System.put_env("DYNIDE_BROKER_SOCK", "")
    on_exit(fn -> System.delete_env("DYNIDE_BROKER_SOCK") end)
    assert Link.init([]) == :ignore
  end

  test "parse_fresh reads the FRESH body" do
    assert Link.parse_fresh(<<>>) == :boot
    assert Link.parse_fresh(<<0>>) == :boot
    assert Link.parse_fresh(<<1>>) == :fallback
    assert Link.parse_fresh(<<2>>) == :boot
    assert Link.parse_fresh(<<1, 0>>) == :boot
  end

  test "fresh_reason is nil without a broker" do
    assert Link.fresh_reason() == nil
  end

  test "hold is sent before open replies" do
    path =
      Path.join(
        System.tmp_dir!(),
        "hh-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
      )

    {:ok, l} = :gen_tcp.listen(0, ifaddr: {:local, path}, mode: :binary, active: false)
    {:ok, link} = NLink.connect(path, self())
    {:ok, peer} = :gen_tcp.accept(l, 5_000)
    :persistent_term.put({Link, :link}, link)

    on_exit(fn ->
      :persistent_term.erase({Link, :link})
      NLink.close(link)
      :gen_tcp.close(l)
      File.rm(path)
    end)

    spec = %{
      cmd: "/bin/sh",
      args: [],
      env: [],
      cwd: nil,
      cols: 80,
      rows: 24,
      max_scrollback: 1000,
      subscriber: nil
    }

    {:ok, id} = Keeper.open(spec)
    # already on the socket when open returns: no waiting
    assert {:ok, <<len::32, 0x02, 1>>} = :gen_tcp.recv(peer, 6, 0)
    {:ok, body} = :gen_tcp.recv(peer, len - 2, 1000)
    key = "pane/#{id}"
    assert {^key, blob} = NLink.parse_key(body)
    {:ok, %{os_pid: os_pid}} = Keeper.lookup(id)

    assert {:ok, %{v: 1, id: ^id, os_pid: ^os_pid, vt: nil, cols: 80, rows: 24}} =
             State.decode(blob)

    :ok = Keeper.close(id)
    assert {:ok, <<_::32, 0x04, 0>>} = :gen_tcp.recv(peer, 6, 1000)
    {:ok, drop} = :gen_tcp.recv(peer, byte_size(key) + 2, 1000)
    assert NLink.parse_key(drop) == {key, ""}
  end

  defp frame(peer) do
    {:ok, <<len::32, kind, _nfds>>} = :gen_tcp.recv(peer, 6, 5000)
    {:ok, body} = if len > 2, do: :gen_tcp.recv(peer, len - 2, 5000), else: {:ok, ""}
    {kind, body}
  end

  # Starts the Link against a fake broker that answers HELLO with `answer`.
  defp start_link_with(answer) do
    path =
      Path.join(
        System.tmp_dir!(),
        "hb-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
      )

    {:ok, l} = :gen_tcp.listen(0, ifaddr: {:local, path}, mode: :binary, active: false)
    System.put_env("DYNIDE_BROKER_SOCK", path)
    System.put_env("DYNIDE_GEN", "7")

    on_exit(fn ->
      System.delete_env("DYNIDE_BROKER_SOCK")
      System.delete_env("DYNIDE_GEN")
      :persistent_term.erase({Link, :link})
      :gen_tcp.close(l)
      File.rm(path)
    end)

    starter = Task.async(fn -> Link.start_link([]) end)
    {:ok, peer} = :gen_tcp.accept(l, 5_000)
    os_pid = String.to_integer(System.pid())
    assert frame(peer) == {0x01, <<7::64, os_pid::32>>}
    :ok = :gen_tcp.send(peer, answer)
    {:ok, pid} = Task.await(starter)
    {pid, peer}
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  defp request(peer, ref, term) do
    req = :erlang.term_to_binary(term)
    :ok = :gen_tcp.send(peer, [<<byte_size(req) + 10::32, 0x47, 0, ref::64>>, req])
  end

  defp reply(peer) do
    {0x07, <<ref::64, reply::binary>>} = frame(peer)
    {ref, :erlang.binary_to_term(reply)}
  end

  test "hello, fresh, request and prepare/thaw against a fake broker" do
    {pid, peer} = start_link_with(<<2::32, 0x41, 0>>)
    assert Link.enabled?()
    assert Link.adopt_reason() == nil
    assert Link.fresh_reason() == :boot
    assert Link.restored() == :ok

    request(peer, 42, :ping)
    assert reply(peer) == {42, :pong}

    :ok = Notice.subscribe()
    :ok = :gen_tcp.send(peer, <<2::32, 0x44, 0>>)
    assert_receive {:handoff, %{phase: :begin, gen: 7}}, 5000
    # final UPDATEs for every pane, then PREPARED
    assert {0x06, ""} =
             Enum.find(Stream.repeatedly(fn -> frame(peer) end), &(elem(&1, 0) != 0x03))

    :ok = :gen_tcp.send(peer, <<2::32, 0x46, 0>>)
    assert_receive {:handoff, %{phase: :aborted, gen: 7}}, 5000

    stop(pid)
  end

  test "a FRESH body of 1 is a fallback restore" do
    {pid, _peer} = start_link_with(<<3::32, 0x41, 0, 1>>)
    assert Link.adopt_reason() == nil
    assert Link.fresh_reason() == :fallback
    stop(pid)
  end

  test "a request between FRESH and restored/0 runs only after restored/0" do
    {pid, peer} = start_link_with(<<2::32, 0x41, 0>>)
    request(peer, 1, :ping)
    request(peer, 2, :panes)
    # nothing runs before the app is up
    assert {:error, :timeout} = :gen_tcp.recv(peer, 1, 300)
    assert Link.restored() == :ok
    assert {1, :pong} = reply(peer)
    assert {2, panes} = reply(peer)
    assert is_list(panes)
    request(peer, 3, :ping)
    assert reply(peer) == {3, :pong}
    stop(pid)
  end

  test "preload makes a blob with not-yet-loaded struct atoms decode with :safe" do
    blob = Base.encode64(:erlang.term_to_binary(%DynideServer.App.Session{}))
    ebins = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    # a fresh VM: only the code path, nothing of the umbrella loaded yet
    script = """
    blob = Base.decode64!(#{inspect(blob)})
    try_decode = fn -> try do :erlang.binary_to_term(blob, [:safe]) && :ok rescue _ -> :fail end end
    before = try_decode.()
    DynideServer.Handoff.Link.preload()
    IO.puts("\#{before} \#{try_decode.()}")
    """

    args = Enum.flat_map(ebins, &["-pa", &1]) ++ ["-e", script]
    {out, 0} = System.cmd(System.find_executable("elixir"), args)
    assert String.trim(out) == "fail ok"
  end

  test "prepare waits for the local client to stop and publishes the phase" do
    {pid, peer} = start_link_with(<<2::32, 0x41, 0>>)
    on_exit(fn -> :persistent_term.erase(DynideScene.Protocol.handoff_key()) end)
    :ok = Notice.subscribe()
    test = self()

    # stands in for dynide_term's local client: stops 300 ms after the :begin notice
    local =
      spawn(fn ->
        Process.register(self(), DynideScene.Protocol.local_client_name())
        send(test, :registered)

        receive do
          :stop -> Process.sleep(300)
        end
      end)

    assert_receive :registered
    ref = Process.monitor(local)
    :ok = :gen_tcp.send(peer, <<2::32, 0x44, 0>>)
    assert_receive {:handoff, %{phase: :begin}}, 5000
    assert :persistent_term.get(DynideScene.Protocol.handoff_key()) == :begin
    send(local, :stop)

    assert {0x06, ""} =
             Enum.find(Stream.repeatedly(fn -> frame(peer) end), &(elem(&1, 0) != 0x03))

    # PREPARED only after the local client is gone
    assert_received {:DOWN, ^ref, :process, ^local, _}

    :ok = :gen_tcp.send(peer, <<2::32, 0x46, 0>>)
    assert_receive {:handoff, %{phase: :aborted}}, 5000
    assert :persistent_term.get(DynideScene.Protocol.handoff_key()) == :aborted
    assert Link.restored() == :ok
    assert :persistent_term.get(DynideScene.Protocol.handoff_key(), nil) == nil
    stop(pid)
  end

  defmodule BoomCtl do
    alias DynideServer.Handoff.Ctl
    def handle(:boom), do: raise("boom")
    def handle(req), do: Ctl.handle(req)
  end

  test "ctl requests run in order and a raising one still gets a reply" do
    Application.put_env(:dynide_server, DynideServer.Handoff, snapshot_ms: 1000, ctl: BoomCtl)

    on_exit(fn ->
      Application.put_env(:dynide_server, DynideServer.Handoff, snapshot_ms: 1000)
    end)

    {pid, peer} = start_link_with(<<2::32, 0x41, 0>>)
    assert Link.restored() == :ok

    request(peer, 1, :ping)
    request(peer, 2, :boom)
    request(peer, 3, {:text, -1})
    request(peer, 4, :ping)
    assert reply(peer) == {1, :pong}
    assert {2, {:error, {:crashed, {%RuntimeError{message: "boom"}, _}}}} = reply(peer)
    assert reply(peer) == {3, :error}
    assert reply(peer) == {4, :pong}
    stop(pid)
  end

  test "carried input is staged before RESTORED and written after it" do
    spec = %{
      cmd: "/bin/sh",
      args: [],
      env: [{"PS1", "$ "}, {"ENV", ""}],
      cwd: nil,
      cols: 80,
      rows: 24,
      max_scrollback: 1000,
      subscriber: nil
    }

    {:ok, id} = Keeper.open(spec)
    {:ok, row} = Keeper.lookup(id)

    blob =
      State.build(id, row, [])
      |> Map.merge(%{id: 450, pending_input: "echo carried-$((1+2))\n"})
      |> State.encode()

    {:ok, fd} = Pty.dup_fd(row.pty)
    Pty.freeze(row.pty)
    :ok = Pty.release(row.pty)

    # ADOPT_END, count 0, graceful
    {pid, peer} = start_link_with(<<7::32, 0x43, 0, 0::32, 0>>)
    assert Link.adopt_reason() == :graceful
    assert Link.fresh_reason() == nil
    :ok = Keeper.adopt_entries([{"pane/450", blob, [fd]}])

    assert {0x03, body} = frame(peer)
    assert {"pane/450", staged} = NLink.parse_key(body)
    assert {:ok, %{id: 450, pending_input: ""}} = State.decode(staged)

    {:ok, %{vt: vt}} = Keeper.lookup(450)
    Process.sleep(300)
    refute Vt.read_text(vt, :screen) =~ "carried-3"

    assert Link.restored() == :ok
    assert frame(peer) == {0x05, <<0::32>>}
    assert wait_text(vt, "carried-3")
    Keeper.close(450)
    stop(pid)
  end

  defmodule SlowCtl do
    alias DynideServer.Handoff.Ctl

    def handle({:sleep, ms}) do
      send(:link_test_slow_ctl, :ctl_running)
      Process.sleep(ms) && :slept
    end

    def handle(req), do: Ctl.handle(req)
  end

  # frames other than UPDATE (every pane's final state) until PREPARED
  defp until_prepared(peer, acc \\ []) do
    case frame(peer) do
      {0x03, _} -> until_prepared(peer, acc)
      {0x06, _} = f -> Enum.reverse([f | acc])
      f -> until_prepared(peer, [f | acc])
    end
  end

  defp next_reply(peer) do
    case frame(peer) do
      {0x07, <<ref::64, reply::binary>>} -> {ref, :erlang.binary_to_term(reply)}
      _ -> next_reply(peer)
    end
  end

  test "prepare lets running ctl requests finish; later ones wait for thaw" do
    Application.put_env(:dynide_server, DynideServer.Handoff, snapshot_ms: 1000, ctl: SlowCtl)

    on_exit(fn ->
      Application.put_env(:dynide_server, DynideServer.Handoff, snapshot_ms: 1000)
    end)

    on_exit(fn -> :persistent_term.erase(DynideScene.Protocol.handoff_key()) end)
    {pid, peer} = start_link_with(<<2::32, 0x41, 0>>)
    assert Link.restored() == :ok

    Process.register(self(), :link_test_slow_ctl)
    request(peer, 1, {:sleep, 400})
    # PREPARE only once request 1 runs: a request still queued would wait for THAW
    assert_receive :ctl_running, 10_000
    :ok = :gen_tcp.send(peer, <<2::32, 0x44, 0>>)
    request(peer, 2, :ping)

    # the running request answers before PREPARED, the later one not before THAW
    assert [{0x07, <<1::64, r1::binary>>}, {0x06, ""}] = until_prepared(peer)
    assert :erlang.binary_to_term(r1) == :slept
    assert {:error, :timeout} = :gen_tcp.recv(peer, 1, 300)

    :ok = :gen_tcp.send(peer, <<2::32, 0x46, 0>>)
    assert next_reply(peer) == {2, :pong}
    stop(pid)
  end

  # Runs `fun` in a task while collecting every frame the peer gets, until it returns.
  defp during(peer, fun), do: collect(peer, Task.async(fun), [])

  defp collect(peer, t, acc) do
    case :gen_tcp.recv(peer, 6, 100) do
      {:ok, <<len::32, kind, _>>} ->
        {:ok, body} = if len > 2, do: :gen_tcp.recv(peer, len - 2, 5000), else: {:ok, ""}
        collect(peer, t, [{kind, body} | acc])

      {:error, :timeout} ->
        if Task.yield(t, 0), do: Enum.reverse(acc), else: collect(peer, t, acc)
    end
  end

  defp updates(frames, key) do
    for {0x03, body} <- frames,
        {^key, blob} <- [NLink.parse_key(body)],
        {:ok, st} <- [State.decode(blob)],
        do: st.pending_input
  end

  test "thaw clears the input held in the broker before writing it back" do
    path =
      Path.join(
        System.tmp_dir!(),
        "hh-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
      )

    {:ok, l} = :gen_tcp.listen(0, ifaddr: {:local, path}, mode: :binary, active: false)
    {:ok, link} = NLink.connect(path, self())
    {:ok, peer} = :gen_tcp.accept(l, 5_000)
    :persistent_term.put({Link, :link}, link)

    on_exit(fn ->
      :persistent_term.erase({Link, :link})
      NLink.close(link)
      :gen_tcp.close(l)
      File.rm(path)
    end)

    spec = %{
      cmd: "/bin/sh",
      args: ["-c", "stty raw -echo; echo raw-ready; sleep 30"],
      env: [],
      cwd: nil,
      cols: 80,
      rows: 24,
      max_scrollback: 1000,
      subscriber: nil
    }

    {:ok, id} = Keeper.open(spec)
    {:ok, %{pty: pty, vt: vt}} = Keeper.lookup(id)
    # raw first: a cooked tty discards input past its line limit, so nothing would queue
    assert wait_text(vt, "raw-ready"), "the child never put its tty in raw mode"
    # the child never reads: most of it stays in the writer queue
    :ok = Pty.write(pty, String.duplicate("a", 65_536))
    key = "pane/#{id}"

    assert [pending] = updates(during(peer, &Keeper.prepare/0), key)
    assert pending != ""
    assert updates(during(peer, &Keeper.thaw/0), key) == [""]
    :ok = Keeper.close(id)
  end

  # bounded at 10 s: a shell under host load starts slowly, a missing text still fails
  defp wait_text(vt, s, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    cond do
      Vt.read_text(vt, :screen) =~ s -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && wait_text(vt, s, deadline)
    end
  end
end
