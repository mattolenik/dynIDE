defmodule HerdrServer.Handoff.State do
  @moduledoc """
  The per-pane `HandoffState` blob the broker holds (`docs/herdr-live/plans/m5.md`,
  "HandoffState blob"): ETF of a map with `v: 1`. `build/3` reads the kernel; the
  rest is pure.
  """

  alias HerdrServer.Native.{Pty, Vt}

  @type t :: %{
          v: 1,
          id: pos_integer,
          os_pid: pos_integer,
          cols: pos_integer,
          rows: pos_integer,
          cell_px: {pos_integer, pos_integer} | nil,
          max_scrollback: non_neg_integer,
          hidden: boolean,
          title: binary | nil,
          pwd: binary | nil,
          exited: Pty.exit_status() | nil,
          pending_input: binary,
          vt: binary | nil,
          taken_at: integer
        }

  @doc """
  The state of keeper row `row` as pane `id`. Options: `vt: false` leaves the snapshot
  out (the HOLD blob), `pending_input:` (default `""`). Raises `ErlangError` when
  ghostty refuses the snapshot.
  """
  @spec build(pos_integer, map, keyword) :: t
  def build(id, %{vt: vt, pty: pty, os_pid: os_pid} = row, opts) do
    info = Pty.info(pty)
    {cols, rows} = Vt.size(vt)

    %{
      v: 1,
      id: id,
      os_pid: os_pid,
      cols: cols,
      rows: rows,
      # ponytail: Pane.Server resizes the pty without the Keeper, so the cell size is
      # unknown here; the next client resize sets it again.
      cell_px: nil,
      max_scrollback: Map.get(row, :max_scrollback, 10_000_000),
      hidden: info.hidden,
      title: info.title,
      pwd: info.pwd,
      exited: info.exited,
      pending_input: Keyword.get(opts, :pending_input, ""),
      vt: if(Keyword.get(opts, :vt, true), do: Vt.encode_snapshot(vt)),
      taken_at: System.system_time(:millisecond)
    }
  end

  @spec encode(t) :: binary
  def encode(state), do: :erlang.term_to_binary(state)

  @doc "`:error` for a blob that is not safe ETF or not `v: 1`."
  @spec decode(binary) :: {:ok, t} | :error
  def decode(bin) do
    case :erlang.binary_to_term(bin, [:safe]) do
      %{v: 1} = state -> {:ok, state}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end
end
