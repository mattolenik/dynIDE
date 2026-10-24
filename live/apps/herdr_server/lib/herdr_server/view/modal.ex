defmodule HerdrServer.View.Modal do
  @moduledoc """
  Node building shared by every modal kind (pure). The server places the region, as for
  every other region; the client draws inside it. Layout convention (the terminal
  rasterizer follows it):

    * `panel/3`: herdr's centred popup, `w x h` clipped to the size minus 4 columns and
      2 rows. The panel has a 1-cell border; content rows are inside it.
    * Content children in order, one row each from the first inner row: `:text` nodes
      (`:title`, `{:line, n}`), an `:input` on inner row 2 at the earliest (a gap after
      the title). Its text is drawn from inner column 1, starting at grapheme
      `props.offset`, so the field's cursor stays visible (`input/2`).
    * The `:actions` group is the row after the content, inner row 3 at the earliest,
      buttons centred with 2 blanks between them.
    * `menu_rect/3`: a context menu at `at`, `max(label + 4, 14)` wide and one row per
      entry plus the border, moved left / up to stay on screen.

  `cursor/1` gives `{focus_path, scene_cursor}` for a modal with an `:input`
  (`%{x, y, shape: :bar}`), or nil when the panel is too small to show it.
  """

  alias HerdrScene.Scene.Node
  alias HerdrServer.App.Modal.TextField

  @type size :: %{cols: pos_integer, rows: pos_integer}

  @spec panel(size, pos_integer, pos_integer) :: HerdrScene.Scene.rect()
  def panel(%{cols: c, rows: r}, w, h) do
    w = min(w, max(c - 4, 0))
    h = min(h, max(r - 2, 0))
    %{x: div(c - w, 2), y: div(r - h, 2), w: w, h: h}
  end

  @spec menu_rect(%{x: integer, y: integer}, [binary], size) :: HerdrScene.Scene.rect()
  def menu_rect(%{x: x, y: y}, labels, %{cols: c, rows: r}) do
    w =
      labels
      |> Enum.map(&String.length/1)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(4)
      |> max(14)
      |> min(c)

    h = min(length(labels) + 2, r)
    %{x: x |> min(c - w) |> max(0), y: y |> min(r - h) |> max(0), w: w, h: h}
  end

  @doc "A `:modal` region; `dim: true` (every centred modal dims the frame)."
  @spec modal(atom, HerdrScene.Scene.rect(), :default | :danger, [Node.t()]) :: Node.t()
  def modal(kind, rect, tone, children),
    do: %Node{
      role: :modal,
      rect: rect,
      props: %{kind: kind, tone: tone, dim: true},
      children: children
    }

  @spec title(binary, atom) :: Node.t()
  def title(text, token \\ :strong), do: %Node{role: :text, id: :title, text: text, token: token}

  @spec line(non_neg_integer, binary) :: Node.t()
  def line(n, text), do: %Node{role: :text, id: {:line, n}, text: text}

  @doc "The `:input` for `field` in a panel of width `w`, scrolled so the cursor shows."
  @spec input(TextField.t(), non_neg_integer) :: Node.t()
  def input(%{text: text, cursor: c}, w) do
    visible = max(input_width(w) - 1, 0)
    offset = max(c - visible, 0)
    %Node{role: :input, id: :input, text: text, props: %{cursor: c, offset: offset}}
  end

  @doc "Buttons `{id, label, key, mods}`; the first is primary."
  @spec actions([{atom, binary, atom | binary, [atom]}]) :: Node.t()
  def actions(buttons) do
    children =
      buttons
      |> Enum.with_index()
      |> Enum.map(fn {{id, label, key, mods}, i} ->
        props = %{action: id, key: key, mods: mods, primary: i == 0}
        %Node{role: :button, id: id, text: label, props: props}
      end)

    %Node{role: :group, id: :actions, children: children}
  end

  @spec cursor(Node.t() | nil) :: {[term], map} | nil
  def cursor(%Node{id: id, rect: r, children: children}) do
    case Enum.find(children, &(&1.role == :input)) do
      %Node{props: %{cursor: c, offset: o}} when r.h >= 5 and r.w >= 4 ->
        x = r.x + 2 + c - o

        if x < r.x + r.w - 1,
          do: {[id, :input], %{x: x, y: r.y + 3, shape: :bar}}

      _ ->
        nil
    end
  end

  def cursor(nil), do: nil

  # inner width minus the leading blank
  defp input_width(w), do: max(w - 3, 0)
end
