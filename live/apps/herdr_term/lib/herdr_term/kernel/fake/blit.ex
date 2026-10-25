defmodule HerdrTerm.Kernel.Fake.Blit do
  @moduledoc """
  In-memory `HerdrTerm.Kernel.Blit` over a `Fake.Tty`. `frame/3` checks the
  frame shape like the real blitter (`{:error, :bad_frame}`, nothing
  recorded) and is O(rows) map updates; rows decode to text only in `screen/1`.
  Graphics ops are recorded as given (`graphics` in each frame); an op of
  unknown shape is `{:error, :bad_frame}`.
  """
  @behaviour HerdrTerm.Kernel.Blit

  alias HerdrScene.Cell

  @max_frames 1000
  @shapes [:default, :block_blink, :block, :underline_blink, :underline, :bar_blink, :bar]

  @impl true
  def frame(tty, rows, %{cursor: cursor, shape: shape, repaint: repaint} = opts) do
    graphics = Map.get(opts, :graphics, [])

    if shape in @shapes and valid?(rows) and is_list(graphics) and Enum.all?(graphics, &op?/1),
      do: record(tty, rows, cursor, repaint, graphics),
      else: {:error, :bad_frame}
  end

  # Shape only; the real blitter also checks field types and ranges.
  defp op?({:upload, %{id: _, format: f, width: _, height: _, data: d, medium: m}}),
    do: f in [:rgb, :rgba, :png] and is_binary(d) and m in [:direct, :file]

  defp op?({:place, %{id: _, placement: _, x: _, y: _, cols: _, rows: _, src: _, off: _, z: _}}),
    do: true

  defp op?({:delete_placement, i, p}), do: is_integer(i) and is_integer(p)
  defp op?({:delete_image, i}), do: is_integer(i)
  defp op?(:delete_all), do: true
  defp op?(_), do: false

  defp valid?([{0, first} | _] = rows) do
    cols = Cell.cols(first)

    cols > 0 and
      rows
      |> Enum.with_index()
      |> Enum.all?(fn {{n, row}, i} -> n == i and Cell.cols(row) == cols end)
  end

  defp valid?(_rows), do: false

  defp record(tty, rows, cursor, repaint, graphics) do
    at = System.monotonic_time(:nanosecond)

    info = %{
      at: at,
      rows: Enum.map(rows, &elem(&1, 0)),
      cursor: cursor,
      repaint: repaint,
      graphics: graphics
    }

    subs =
      Agent.get_and_update(tty, fn s ->
        screen = if repaint, do: %{}, else: s.screen
        screen = Enum.reduce(rows, screen, fn {n, row}, acc -> Map.put(acc, n, row) end)
        q = :queue.in(info, s.frames)

        {q, n} =
          if s.nframes >= @max_frames,
            do: {:queue.drop(q), s.nframes},
            else: {q, s.nframes + 1}

        {s.frame_subs,
         %{s | screen: screen, frames: q, nframes: n, frames_written: s.frames_written + 1}}
      end)

    for pid <- subs, do: send(pid, {:frame, tty, info})
    :ok
  end

  @doc "Decoded text per screen row (trailing spaces kept); unset rows are empty."
  @spec screen(pid) :: [binary]
  def screen(tty) do
    {{_, rows, _, _}, screen} = Agent.get(tty, &{&1.size, &1.screen})

    for n <- 0..(rows - 1)//1 do
      case screen do
        %{^n => row} -> HerdrTerm.Cells.to_text(row)
        _ -> ""
      end
    end
  end

  @spec frames(pid) :: [map]
  def frames(tty), do: tty |> Agent.get(& &1.frames) |> :queue.to_list()

  def subscribe_frames(tty, pid),
    do: Agent.update(tty, &%{&1 | frame_subs: [pid | &1.frame_subs]})
end
