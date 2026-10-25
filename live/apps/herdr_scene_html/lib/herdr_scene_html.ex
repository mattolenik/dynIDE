defmodule HerdrSceneHtml do
  @moduledoc """
  Dev-only proof that a second consumer can draw a scene with no terminal
  assumptions: `render/2` turns a `HerdrScene.Scene` into one self-contained
  HTML page (inline CSS, no JS). Nothing depends on this app.

  Cell rects become absolutely positioned boxes in `ch` (columns) and `em`
  (rows). Every chrome node is an element with `data-role`, `data-id` and
  `class="tok-<token>"`. Panes are grey boxes labelled with their id; inline
  rows are decoded to plain text. Widgets are native HTML.
  """

  alias HerdrScene.{Cell, Scene}
  alias HerdrScene.Scene.{Node, Pane}

  @row_em 1.5

  @themes %{
    dark: ~w(--bg:#1e1e2e --fg:#cdd6f4 --accent:#89b4fa --muted:#7f849c --focus:#f9e2af
             --warning:#fab387 --error:#f38ba8 --success:#a6e3a1 --info:#74c7ec
             --surface:#313244 --selected:#45475a --strong:#ffffff --inverse:#1e1e2e),
    light: ~w(--bg:#eff1f5 --fg:#4c4f69 --accent:#1e66f5 --muted:#8c8fa1 --focus:#df8e1d
              --warning:#fe640b --error:#d20f39 --success:#40a02b --info:#04a5e5
              --surface:#ccd0da --selected:#bcc0cc --strong:#000000 --inverse:#eff1f5)
  }

  @spec render(Scene.t(), keyword) :: iodata
  def render(%Scene{} = scene, opts \\ []) do
    theme = Keyword.get(opts, :theme, :dark)
    %{cols: cols, rows: rows} = scene.size

    [
      "<!doctype html><html><head><meta charset=\"utf-8\"><title>scene</title><style>",
      css(theme),
      "</style></head><body><div class=\"scene\" style=\"width:#{cols}ch;height:#{em(rows)}\">",
      Enum.map(scene.panes, &pane(&1, scene.focus)),
      chrome_node(scene.chrome, {0, 0}),
      "</div></body></html>"
    ]
  end

  defp css(theme) do
    [
      ":root{",
      Enum.join(@themes[theme] || @themes.dark, ";"),
      "}body{margin:1em;background:var(--bg);color:var(--fg);font:14px/#{@row_em} monospace}",
      ".scene{position:relative;overflow:hidden;background:var(--bg)}",
      ".scene>*,[data-rect]{position:absolute;box-sizing:border-box}",
      ".pane{background:#666;color:#eee;overflow:hidden;white-space:pre}",
      ".pane.focused{outline:2px solid var(--focus)}",
      "[data-role]{display:flex;flex-wrap:wrap;gap:0 1ch;align-items:center}",
      "[data-role=list],[data-role=section],[data-role=sidebar],[data-role=modal],",
      "[data-role=menu],[data-role=item],[data-role=toast]{flex-direction:column;align-items:stretch}",
      "[data-role=modal],[data-role=menu],[data-role=toast],[data-role=sidebar],",
      "[data-role=status]{background:var(--surface)}",
      "[data-role=modal].danger{outline:2px solid var(--error)}",
      "ul{list-style:none;margin:0;padding:0}",
      ".active{background:var(--selected)}",
      ".dot{display:inline-block;width:.8em;height:.8em;border-radius:50%;background:var(--muted)}",
      ".state-working .dot{background:var(--warning)}.state-blocked .dot{background:var(--error)}",
      ".state-idle .dot,.state-done .dot{background:var(--success)}",
      ".tok-accent{color:var(--accent)}.tok-muted{color:var(--muted)}.tok-focus{color:var(--focus)}",
      ".tok-warning{color:var(--warning)}.tok-error{color:var(--error)}.tok-info{color:var(--info)}",
      ".tok-success{color:var(--success)}.tok-strong{color:var(--strong);font-weight:bold}",
      ".tok-inverse{color:var(--inverse);background:var(--fg)}.tok-selected{background:var(--selected)}",
      ".tok-surface{background:var(--surface)}"
    ]
  end

  # panes

  defp pane(%Pane{id: id, rect: rect, rows: rows}, focus) do
    cls = if Map.get(focus, :pane) == id, do: "pane focused", else: "pane"

    [
      "<div class=\"#{cls}\" data-pane=\"#{esc(id)}\" style=\"#{box(rect)}\"><b>pane #{id}</b>\n",
      esc(inline_text(rows)),
      "</div>"
    ]
  end

  defp inline_text({:inline, rows}) do
    Enum.map_join(rows, "\n", fn {_n, packed} ->
      packed |> Cell.decode_row() |> Enum.map_join(&if(&1.glyph == "", do: " ", else: &1.glyph))
    end)
  end

  defp inline_text(_), do: ""

  # chrome

  # rects are scene cells; an element is placed against its nearest rect ancestor
  # (`origin`, the positioned box it sits in), so a nested rect lands where the scene says
  defp chrome_node(nil, _origin), do: []

  defp chrome_node(%Node{role: role} = n, origin) do
    {tag, extra} = widget(n)
    attrs = ~s( data-role="#{esc(role)}" data-id="#{esc(inspect(n.id))}" class="#{classes(n)}")
    attrs = if n.rect, do: attrs <> ~s( data-rect style="#{box(n.rect, origin)}"), else: attrs
    inner = if n.rect, do: {n.rect.x, n.rect.y}, else: origin

    case tag do
      "input" -> ["<input", attrs, ~s( value="#{esc(n.text || "")}">)]
      _ -> ["<#{tag}", attrs, extra, ">", body(n, inner), "</#{tag}>"]
    end
  end

  defp body(%Node{role: :badge, props: props}, _origin),
    do: [~s(<span class="dot" title="#{esc(inspect(props[:state]))}"></span>)]

  # a zoomed tab's marker, chosen here like every glyph
  defp body(%Node{role: :tab, props: %{zoomed: true}, text: text}, _origin),
    do: ["Z ", esc(text || "")]

  defp body(%Node{role: :list, children: kids}, origin),
    do: Enum.map(kids, &chrome_node(&1, origin))

  defp body(%Node{text: text, children: kids}, origin),
    do: [esc(text || ""), Enum.map(kids, &chrome_node(&1, origin))]

  defp widget(%Node{role: :button}), do: {"button", ~s( type="button")}
  defp widget(%Node{role: :input}), do: {"input", ""}
  defp widget(%Node{role: :list}), do: {"ul", ""}
  defp widget(%Node{role: :item}), do: {"li", ""}
  defp widget(%Node{role: :keycap}), do: {"kbd", ""}
  defp widget(%Node{role: r}) when r in [:text, :badge, :spacer], do: {"span", ""}
  defp widget(_), do: {"div", ""}

  defp classes(%Node{token: token, props: props, role: role}) do
    [
      "tok-#{token || :default}",
      if(props[:active] == true, do: "active"),
      if(props[:tone] == :danger, do: "danger"),
      if(role == :badge and props[:state], do: "state-#{props[:state]}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp box(rect, origin \\ {0, 0})

  defp box(%{x: x, y: y, w: w, h: h}, {ox, oy}),
    do: "left:#{x - ox}ch;top:#{em(y - oy)};width:#{w}ch;height:#{em(h)}"

  defp em(rows), do: "#{Float.round(rows * @row_em, 2)}em"

  defp esc(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
