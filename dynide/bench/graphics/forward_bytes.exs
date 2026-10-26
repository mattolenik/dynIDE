# M10 image forwarding bytes/s. From dynide/: MIX_ENV=test mix run bench/graphics/forward_bytes.exs [secs=10]
#
# Server on the fake kernel: one pane whose Fake.Vt placement gets a new image (new fp, new
# 200x200 rgba data, 160000 bytes) every 1/60 s via Fake.Vt.set_graphics plus one byte of
# pane output (the damage that republishes the pane's facts), for `secs` seconds per path.
#   local: a terminal client on the real DynideTerm.Native.Tty/Blit over a pty held by
#          `script` (pixel size set with TIOCSWINSZ, output relayed to this VM and dropped);
#          bytes = Tty.stats(tty).graphics_bytes delta (kitty escapes actually written,
#          direct t=d base64: TERM_PROGRAM is unset so the file transport is off).
#   socket: a remote client (Client.Socket + Remote.Conn, inline transport, fake tty);
#          bytes = sum of 4 + byte_size(term_to_binary(msg)) over every {:image, ...} the
#          client's Render receives (traced), i.e. the Wire frames.
# Prints one RESULT line per path, with uptime load before and after.
alias DynideServer.Client.Socket
alias DynideServer.Kernel.Fake.{Keeper, Pty, Vt}
alias DynideServer.Pane.Rows
alias DynideTerm.Client
alias DynideTerm.Remote.Conn

defmodule ForwardBytes do
  @w 200
  @h 200
  @tick_ms 16

  def load do
    {out, 0} = System.cmd("uptime", [])
    out |> String.split("load averages:") |> List.last() |> String.trim()
  end

  def until(fun, left \\ 5000) do
    cond do
      fun.() -> :ok
      left <= 0 -> raise "forward_bytes: timed out"
      true -> Process.sleep(10) && until(fun, left - 10)
    end
  end

  def placement(fp) do
    %{
      image: {7, fp},
      placement: 1,
      x: 0,
      y: 0,
      cols: 20,
      rows: 10,
      x_off: 0,
      y_off: 0,
      src: {0, 0, 0, 0},
      px: {0, 0},
      z: 0,
      size: {@w, @h},
      format: :rgba,
      bytes: @w * @h * 4
    }
  end

  def image(fp) do
    data = <<fp::32, 0::size((@w * @h * 4 - 4) * 8)>>
    %{format: :rgba, width: @w, height: @h, bytes: byte_size(data), data: data}
  end

  # replaces the pane's image every tick for `ms`; returns the number of replacements
  def replace(id, ms) do
    {:ok, %{vt: vt, pty: pty}} = Keeper.lookup(Rows.kernel_id(id))
    stop = System.monotonic_time(:millisecond) + ms
    replace(vt, pty, stop, 1)
  end

  defp replace(vt, pty, stop, fp) do
    if System.monotonic_time(:millisecond) >= stop do
      fp - 1
    else
      :ok = Vt.set_graphics(vt, [placement(fp)], %{7 => image(fp)})
      Pty.output(pty, "x")
      Process.sleep(@tick_ms)
      replace(vt, pty, stop, fp + 1)
    end
  end

  # the slave of a pty `script` holds open (200x50 cells, 2000x1000 px)
  def pty_path do
    winsz =
      "import fcntl,termios,struct; fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH',50,200,2000,1000))"

    sh = "python3 -c \"#{winsz}\"; echo pid=$$; tty; exec sleep 600"

    args =
      if match?({:unix, :darwin}, :os.type()),
        do: ["-q", "/dev/null", "/bin/sh", "-c", sh],
        else: ["-qfc", sh, "/dev/null"]

    port = Port.open({:spawn_executable, System.find_executable("script")}, [:binary, args: args])
    {pid, path} = read_pty(port, "")
    # a sink for the relayed output, so this process's mailbox stays small
    sink = spawn(fn -> sink() end)
    Port.connect(port, sink)
    {port, pid, path}
  end

  defp sink do
    receive do
      _ -> sink()
    end
  end

  defp read_pty(port, acc) do
    case Regex.run(~r/pid=(\d+)\s+(\/dev\/\S+)/, acc) do
      [_, pid, path] ->
        {pid, path}

      nil ->
        receive do
          {^port, {:data, data}} -> read_pty(port, acc <> data)
        after
          5000 -> raise "no pty from script: #{inspect(acc)}"
        end
    end
  end

  def counter(acc) do
    receive do
      {:trace, _, :receive, {:image, _, _, _} = msg} ->
        counter(acc + 4 + byte_size(:erlang.term_to_binary(msg)))

      {:get, from} ->
        send(from, {:count, acc})

      _ ->
        counter(acc)
    end
  end

  def result(path, bytes, ms, n, load0) do
    IO.puts(
      "RESULT path=#{path} bytes=#{bytes} secs=#{ms / 1000} bytes_per_s=#{round(bytes * 1000 / ms)} " <>
        "replacements=#{n} image_bytes=#{@w * @h * 4} load_before=#{inspect(load0)} load_after=#{inspect(load())}"
    )
  end
end

secs =
  Enum.find_value(System.argv(), 10, fn
    "secs=" <> s -> String.to_integer(s)
    _ -> nil
  end)

ms = secs * 1000
System.delete_env("TERM_PROGRAM")
DynideServer.App.Store.reset()

# -- local: real Tty/Blit on a pty ---------------------------------------------------
Application.put_env(:dynide_term, :kernel,
  tty: DynideTerm.Native.Tty,
  blit: DynideTerm.Native.Blit,
  desktop: DynideTerm.Kernel.Fake.Desktop,
  sigwinch: false
)

DynideTerm.Kernel.load()
{port, script_pid, path} = ForwardBytes.pty_path()
{:ok, local} = Client.start_link(id: make_ref(), tty_opts: %{path: path})
tty = Client.tty(local)
render = Client.render(local)
ForwardBytes.until(fn -> :sys.get_state(render).scene != nil end)
[%{id: id}] = :sys.get_state(render).scene.panes
load0 = ForwardBytes.load()
b0 = DynideTerm.Native.Tty.stats(tty).graphics_bytes
n = ForwardBytes.replace(id, ms)
b1 = DynideTerm.Native.Tty.stats(tty).graphics_bytes
ForwardBytes.result("local-tty", b1 - b0, ms, n, load0)
Supervisor.stop(local)
System.cmd("kill", [script_pid])
if Port.info(port), do: Port.close(port)

# -- socket: inline remote client -----------------------------------------------------
Application.put_env(:dynide_term, :kernel,
  tty: DynideTerm.Kernel.Fake.Tty,
  blit: DynideTerm.Kernel.Fake.Blit,
  desktop: DynideTerm.Kernel.Fake.Desktop,
  sigwinch: false
)

DynideTerm.Kernel.load()
dir = Path.join(File.cwd!(), "_build/bench/fwd#{System.unique_integer([:positive])}")
File.mkdir_p!(dir)
sock = Path.join(dir, "c.sock")
{:ok, _} = Socket.start_link(path: sock, token_path: Path.join(dir, "c.token"))
name = :fwd_conn

{:ok, _} =
  Conn.start_link(
    name: name,
    transport: {:unix, sock, Path.join(dir, "c.token")},
    session: nil,
    client_id: "fwd"
  )

{:ok, remote} =
  Client.start_link(
    id: make_ref(),
    endpoint: name,
    transport: :inline,
    tty_opts: %{size: {200, 50, 2000, 1000}}
  )

render = Client.render(remote)
ForwardBytes.until(fn -> :sys.get_state(render).scene != nil end)
counter = spawn(fn -> ForwardBytes.counter(0) end)
1 = :erlang.trace(render, true, [:receive, {:tracer, counter}])
load0 = ForwardBytes.load()
n = ForwardBytes.replace(id, ms)
Process.sleep(200)
:erlang.trace(render, false, [:receive])
send(counter, {:get, self()})
bytes = receive do: ({:count, c} -> c)
ForwardBytes.result("socket-image-frames", bytes, ms, n, load0)
File.rm_rf!(dir)
