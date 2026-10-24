defmodule HerdrServer.View.Modal do
  @moduledoc """
  Node building shared by every modal kind (pure). The server places the region, as for
  every other region; the client draws inside it. Layout convention (the terminal
  rasterizer follows it):

    * `panel/3`: herdr's centred popup, `w x h` clipped to the size minus 4 columns and
      2 rows. The panel has a 1-cell border; content rows are inside it.
    * Content children in order from the first inner row: `:text` nodes (`:title`,
      `:subtitle`, `{:line, n}`) one row each, an `:input` on inner row 2 at the earliest
      (a gap after the title), drawn from inner column 1 starting at grapheme
      `props.offset` so the field's cursor stays visible (`input/2`). Generic pieces:
      a `:spacer` takes `props.rows` blank rows (`spacer/2`); a `:group` is one row of
      inline `:text` / `:keycap` children (`keycap/1`); a `:tabs` section row
      (`sections/2`) takes two rows (the tabs, then a rule); a `:list` takes `props.rows`
      rows (default: one per child) of `:text` headings and `:item`s, an item a choice
      (`props.selected`, `props.current`) or, with `:keycap` / `:text` children, a
      shortcut row (`list/3`, `choice/4`; `window/3` scrolls a list).
    * The `:actions` group is the row after the content, inner row 3 at the earliest,
      buttons centred with 2 blanks between them.
    * `menu_rect/3`: a context menu at `at`, `max(label + 4, 14)` wide and one row per
      entry plus the border, moved left / up to stay on screen.

  `cursor/1` gives `{focus_path, scene_cursor}` for a modal with an `:input`
  (`%{x, y, shape: :bar}`), or nil when the panel is too small to show it.
  """

  alias HerdrScene.Scene.Node
  alias HerdrServer.App.Modal.TextField
  alias HerdrServer.Config.Keys

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

  @spec text(term, binary, atom | nil) :: Node.t()
  def text(id, text, token \\ nil), do: %Node{role: :text, id: id, text: text, token: token}

  @spec spacer(term, non_neg_integer) :: Node.t()
  def spacer(id, rows \\ 1), do: %Node{role: :spacer, id: id, props: %{rows: rows}}

  @doc "Inner rows of a panel rect (inside the border)."
  @spec inner_rows(HerdrScene.Scene.rect()) :: non_neg_integer
  def inner_rows(%{h: h}), do: max(h - 2, 0)

  @doc "The `:tabs` section row: `{id, label}` pairs, tab ids `{:section, id}`."
  @spec sections(atom, [{atom, binary}]) :: Node.t()
  def sections(active, pairs) do
    tabs =
      pairs
      |> Enum.with_index()
      |> Enum.map(fn {{id, label}, i} ->
        %Node{
          role: :tab,
          id: {:section, id},
          text: label,
          props: %{index: i, active: id == active}
        }
      end)

    %Node{role: :tabs, id: :sections, children: tabs}
  end

  @doc "A `:list` of `rows` rows showing `children` from line `offset` on."
  @spec list([Node.t()], non_neg_integer, non_neg_integer) :: Node.t()
  def list(children, rows, offset) do
    shown = children |> Enum.drop(offset) |> Enum.take(rows)
    %Node{role: :list, id: :list, props: %{rows: rows, offset: offset}, children: shown}
  end

  @doc "A choice `:item` (extra props merged in)."
  @spec choice(term, binary, boolean, boolean, map) :: Node.t()
  def choice(id, label, selected, current, extra \\ %{}),
    do: %Node{
      role: :item,
      id: id,
      text: label,
      props: Map.merge(%{selected: selected, current: current}, extra)
    }

  @doc "A `:keycap` for a parsed key spec (`Config.Keys`), its text the spec."
  @spec keycap(%{prefix: boolean, key: term, mods: [atom]}, term) :: Node.t()
  def keycap(%{key: k, mods: m} = spec, id \\ :key),
    do: %Node{
      role: :keycap,
      id: id,
      text: Keys.format(spec),
      props: %{key: k, mods: m, prefix: spec.prefix}
    }

  @doc "Scroll offset that keeps line `at` of `count` visible in `rows` rows."
  @spec window(non_neg_integer, non_neg_integer, non_neg_integer) :: non_neg_integer
  def window(at, count, rows) do
    (at - rows + 1) |> max(0) |> min(max(count - rows, 0))
  end

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
