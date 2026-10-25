defmodule HerdrServer.Handoff.State do
  @moduledoc """
  The per-pane `HandoffState` blob the broker holds (`docs/herdr-live/plans/m5.md`,
  "HandoffState blob"): ETF of a map with `v: 1`. `build/3` reads the kernel; the
  rest is pure.
  """

  alias HerdrServer.Native.{Pty, Vt}

  # pixels carried per pane, the kitty transmission cap
  @gfx_cap 16 * 1024 * 1024
  # snapshot + kitty replay; the link frame cap is 64 MiB
  @gfx_frame_max 48 * 1024 * 1024

  @type t :: %{
          optional(:cmd) => [binary] | nil,
          optional(:gfx) => binary,
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
          start_time: non_neg_integer | nil,
          pending_input: binary,
          vt: binary | nil,
          taken_at: integer
        }

  @doc """
  The state of keeper row `row` as pane `id`. Options: `vt: false` leaves the snapshot
  out (the HOLD blob), `pending_input:` (default `""`), `gfx: true` adds the kitty
  replay (`Vt.graphics_replay/2`) when it fits beside the snapshot. Raises `ErlangError` when
  ghostty refuses the snapshot.
  """
  @spec build(pos_integer, map, keyword) :: t
  def build(id, %{vt: vt, pty: pty, os_pid: os_pid} = row, opts) do
    info = Pty.info(pty)
    {cols, rows} = Vt.size(vt)
    snap = if Keyword.get(opts, :vt, true), do: Vt.encode_snapshot(vt)

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
      # optional key (v stays 1): absent in older blobs, then adopt skips the check
      start_time: info.start_time,
      # optional key (v stays 1): the spawn command, metadata only; absent -> row cmd nil
      cmd: Map.get(row, :cmd),
      pending_input: Keyword.get(opts, :pending_input, ""),
      vt: snap,
      taken_at: System.system_time(:millisecond)
    }
    |> put_gfx(vt, snap, Keyword.get(opts, :gfx, false))
  end

  # optional key (v stays 1): absent in older blobs and when nothing is carried
  defp put_gfx(st, vt, snap, true) when is_binary(snap) do
    case Vt.graphics_replay(vt, @gfx_cap) do
      "" -> st
      gfx when byte_size(gfx) + byte_size(snap) <= @gfx_frame_max -> Map.put(st, :gfx, gfx)
      _ -> st
    end
  end

  defp put_gfx(st, _vt, _snap, _gfx), do: st

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
