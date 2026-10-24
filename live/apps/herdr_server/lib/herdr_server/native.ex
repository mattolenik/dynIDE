defmodule HerdrServer.Native do
  @moduledoc """
  Rustler NIF module backed by the `herdr_kernel` crate. Call it through the
  `HerdrServer.Native.Vt` and `HerdrServer.Native.Pty` facades.

  ERTS runs with SIGCHLD ignored and `SA_NOCLDWAIT` set, which auto-reaps children
  and would lose their exit statuses, so loading resets SIGCHLD to `SIG_DFL`. Loading
  fails only if auto-reaping persists after that; ERTS reports it as "Library
  load-call unsuccessful".
  """
  use Rustler,
    otp_app: :herdr_server,
    crate: :herdr_kernel,
    path: "../../native/herdr_kernel",
    # Enables the test-only NIFs at load; the same .so serves every Mix env.
    load_data: Mix.env() == :test

  # Stubs: arguments are term() so opaque facade types pass through without
  # breaking opacity; the facades carry the precise specs.

  @doc false
  @spec vt_new(term, term, term) :: {:ok, reference}
  def vt_new(_cols, _rows, _max_scrollback), do: err()
  @doc false
  @spec vt_encode_snapshot(term) :: binary
  def vt_encode_snapshot(_vt), do: err()
  @doc false
  @spec vt_restore(term, term) :: {:ok, reference} | {:error, binary}
  def vt_restore(_bytes, _max_scrollback), do: err()
  @doc false
  @spec vt_feed(term, term) :: non_neg_integer
  def vt_feed(_vt, _bytes), do: err()
  @doc false
  @spec vt_resize(term, term, term, term) :: :ok
  def vt_resize(_vt, _cols, _rows, _px), do: err()
  @doc false
  @spec vt_dirty_rows(term) :: {non_neg_integer, [{non_neg_integer, binary}]}
  def vt_dirty_rows(_vt), do: err()
  @doc false
  @spec vt_gen(term) :: non_neg_integer
  def vt_gen(_vt), do: err()
  @doc false
  @spec vt_rows_since(term, term) :: {non_neg_integer, [{non_neg_integer, binary}]}
  def vt_rows_since(_vt, _gen), do: err()
  @doc false
  @spec vt_full_rows(term) :: {non_neg_integer, [{non_neg_integer, binary}]}
  def vt_full_rows(_vt), do: err()
  @doc false
  @spec vt_read_text(term, term, term, term) :: binary
  def vt_read_text(_vt, _range, _first, _last), do: err()
  @doc false
  @spec vt_scrollbar(term) :: map
  def vt_scrollbar(_vt), do: err()
  @doc false
  @spec vt_size(term) :: {pos_integer, pos_integer}
  def vt_size(_vt), do: err()
  @doc false
  @spec vt_scroll_to(term, term) :: :ok
  def vt_scroll_to(_vt, _offset), do: err()
  @doc false
  @spec vt_mode(term, term) :: boolean | {:stale, boolean}
  def vt_mode(_vt, _mode), do: err()
  @doc false
  @spec vt_kitty_keyboard_flags(term) :: non_neg_integer | {:stale, non_neg_integer}
  def vt_kitty_keyboard_flags(_vt), do: err()
  @doc false
  @spec vt_link_at(term, term, term) :: map | nil
  def vt_link_at(_vt, _x, _y), do: err()
  @doc false
  @spec vt_graphics_placements(term) :: [map]
  def vt_graphics_placements(_vt), do: err()
  @doc false
  @spec vt_cursor(term) :: map | nil
  def vt_cursor(_vt), do: err()
  @doc false
  @spec vt_encode_key(term, term) :: binary
  def vt_encode_key(_vt, _event), do: err()
  @doc false
  @spec vt_encode_mouse(term, term) :: binary | nil
  def vt_encode_mouse(_vt, _event), do: err()
  @doc false
  @spec vt_encode_focus(term, term) :: binary
  def vt_encode_focus(_vt, _focused), do: err()

  @doc false
  @spec pty_spawn(term, term, term, term, term, term, term, term) ::
          {:ok, reference, pos_integer} | {:error, atom | {atom, term}}
  def pty_spawn(_vt, _id, _cmd, _args, _env, _cwd, _cols, _rows), do: err()
  @doc false
  @spec pty_write(term, term) :: :ok | {:error, :backpressure | :closed | :too_large}
  def pty_write(_pty, _data), do: err()
  @doc false
  @spec pty_resize(term, term, term, term) :: :ok
  def pty_resize(_pty, _cols, _rows, _px), do: err()
  @doc false
  @spec pty_kill(term, term) :: :ok
  def pty_kill(_pty, _signal), do: err()
  @doc false
  @spec pty_subscribe(term, term) :: :ok
  def pty_subscribe(_pty, _pid), do: err()
  @doc false
  @spec pty_set_hidden(term, term) :: :ok
  def pty_set_hidden(_pty, _hidden), do: err()
  @doc false
  @spec pty_adopt(term, term, term, term, term, term, term, term) ::
          {:ok, reference} | {:error, atom | {atom, term}}
  def pty_adopt(_vt, _id, _fd, _os_pid, _exited, _title, _pwd, _start_time), do: err()
  @doc false
  @spec pty_dup_fd(term) :: {:ok, reference} | {:error, atom | {atom, term}}
  def pty_dup_fd(_pty), do: err()
  @doc false
  @spec pty_freeze(term) :: binary
  def pty_freeze(_pty), do: err()
  @doc false
  @spec pty_take_pending(term) :: binary
  def pty_take_pending(_pty), do: err()
  @doc false
  @spec pty_thaw(term) :: :ok | {:error, :released | atom | {atom, term}}
  def pty_thaw(_pty), do: err()
  @doc false
  @spec pty_release(term) :: :ok | {:error, :not_frozen}
  def pty_release(_pty), do: err()
  @doc false
  @spec pty_info(term) :: map
  def pty_info(_pty), do: err()

  @doc false
  @spec link_connect(term, term) :: {:ok, reference} | {:error, atom}
  def link_connect(_path, _owner), do: err()
  @doc false
  @spec link_send(term, term, term, term) :: :ok | {:error, atom | binary}
  def link_send(_link, _kind, _body, _fds), do: err()
  @doc false
  @spec link_close(term) :: :ok
  def link_close(_link), do: err()

  # Test only: makes the pane's reader panic holding the vt core lock.
  # `{:error, :disabled}` outside the test env.
  @doc false
  @spec test_inject_reader_panic(term) :: :ok | {:error, :disabled}
  def test_inject_reader_panic(_pty), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
