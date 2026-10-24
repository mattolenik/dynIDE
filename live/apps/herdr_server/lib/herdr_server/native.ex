defmodule HerdrServer.Native do
  @moduledoc """
  Rustler NIF module backed by the `herdr_kernel` crate. Call it through the
  `HerdrServer.Native.Vt` and `HerdrServer.Native.Pty` facades.

  Loading fails if SIGCHLD is ignored or has `SA_NOCLDWAIT` (auto-reaping would
  lose child exit statuses); ERTS reports that as "Library load-call unsuccessful".
  """
  use Rustler,
    otp_app: :herdr_server,
    crate: :herdr_kernel,
    path: "../../native/herdr_kernel",
    features: if(Mix.env() == :test, do: ["test-nifs"], else: [])

  # Stubs: arguments are term() so opaque facade types pass through without
  # breaking opacity; the facades carry the precise specs.

  @doc false
  @spec vt_new(term, term, term) :: {:ok, reference}
  def vt_new(_cols, _rows, _max_scrollback), do: err()
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
          {:ok, reference, pos_integer} | {:error, binary}
  def pty_spawn(_vt, _id, _cmd, _args, _env, _cwd, _cols, _rows), do: err()
  @doc false
  @spec pty_write(term, term) :: :ok | {:error, :backpressure | :closed}
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

  if Mix.env() == :test do
    @doc "Test only: makes the pane's reader thread panic while holding the vt core lock."
    @spec test_inject_reader_panic(term) :: :ok
    def test_inject_reader_panic(_pty), do: err()
  end

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
