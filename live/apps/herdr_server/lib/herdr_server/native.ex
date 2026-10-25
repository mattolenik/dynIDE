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
  @spec vt_graphics_replay(term, term) :: binary
  def vt_graphics_replay(_vt, _cap), do: err()
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
  @spec vt_tail_ansi(term, term) :: binary | :alt_screen
  def vt_tail_ansi(_vt, _n), do: err()
  @doc false
  @spec vt_read_selection(term, term, term, term, term) :: binary
  def vt_read_selection(_vt, _x1, _y1, _x2, _y2), do: err()
  @doc false
  @spec vt_screen_rows(term, term, term) :: [{non_neg_integer, binary, boolean}]
  def vt_screen_rows(_vt, _first, _last), do: err()
  @doc false
  @spec vt_search(term, term, term) ::
          {:ok, [{non_neg_integer, non_neg_integer, pos_integer}], non_neg_integer | :done}
  def vt_search(_vt, _query, _opts), do: err()
  @doc false
  @spec vt_set_colors(term, term) :: :ok
  def vt_set_colors(_vt, _colors), do: err()
  @doc false
  @spec vt_set_color_scheme(term, term) :: :ok
  def vt_set_color_scheme(_vt, _scheme), do: err()
  @doc false
  @spec vt_modify_other_keys(term) :: boolean | {:stale, boolean}
  def vt_modify_other_keys(_vt), do: err()
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
  @spec vt_graphics_image(term, term) :: map | nil
  def vt_graphics_image(_vt, _image_id), do: err()
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
  @spec pty_cwd(term) :: binary | nil
  def pty_cwd(_pty), do: err()
  @doc false
  @spec pty_activity(term) :: non_neg_integer
  def pty_activity(_pty), do: err()
  @doc false
  @spec pty_foreground_pgid(term) :: pos_integer | nil
  def pty_foreground_pgid(_pty), do: err()
  @doc false
  @spec pty_foreground_job(term) :: map | nil
  def pty_foreground_job(_pty), do: err()

  @doc false
  @spec link_connect(term, term) :: {:ok, reference} | {:error, atom}
  def link_connect(_path, _owner), do: err()
  @doc false
  @spec fd_dup_raw(integer) :: {:ok, reference} | {:error, binary}
  def fd_dup_raw(_raw), do: err()
  @doc false
  @spec fd_into_raw(term) :: {:ok, non_neg_integer} | {:error, :consumed}
  def fd_into_raw(_fd), do: err()
  @doc false
  @spec fd_raw(term) :: {:ok, non_neg_integer} | {:error, :consumed}
  def fd_raw(_fd), do: err()
  @doc false
  @spec fd_close(term) :: :ok | {:error, :consumed}
  def fd_close(_fd), do: err()
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
