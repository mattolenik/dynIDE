defmodule DynideIntegration.ChromeClickTest do
  @moduledoc """
  Chrome mouse end to end (fake kernel, real client): host-tty SGR mouse bytes go
  through the client's `Hit` routing to `{:chrome, ...}` and the server's `App.Chrome`.
  """
  use ExUnit.Case, async: false

  alias DynideIntegration.Driver
  alias DynideScene.Scene.Node
  alias DynideServer.Kernel.Fake.Keeper
  alias DynideServer.Pane.Rows
  alias DynideTerm.Client

  setup do
    Driver.reset()
  end

  test "a click on tab 1's cell switches the active tab" do
    c = Driver.start_client({120, 40})
    # c asks for the tab's name; Enter keeps the suggested one
    Driver.type(c, "\x02c\r")
    assert wait(fn -> active_tab(c) == {:tab, 2} end)

    r = hit_rect(c, [:tabs, {:tab, 1}])
    press_release(c, r.x + 1, r.y)
    assert wait(fn -> active_tab(c) == {:tab, 1} end)
  end

  test "dragging the pane divider 10 cells right resizes both panes" do
    c = Driver.start_client({120, 40})
    Driver.type(c, "\x02v")
    assert wait(fn -> length(Driver.scene(c).panes) == 2 end)
    Driver.quiesce(c)
    [a0, b0] = pane_cols(c)

    r = hit_rect(c, [{:divider, []}])
    y = r.y + 2
    Driver.type(c, sgr(0, r.x, y, "M"))
    Driver.type(c, sgr(32, r.x + 5, y, "M"))
    Driver.type(c, sgr(32, r.x + 10, y, "M"))
    Driver.type(c, sgr(0, r.x + 10, y, "m"))

    assert wait(fn -> pane_cols(c) == [a0 + 10, b0 - 10] end)
    # the kernel side followed: each fake vt has the scene pane's width
    for %{id: id, rect: rect} <- Driver.scene(c).panes,
        do: assert(wait(fn -> vt_cols(id) == rect.w end))
  end

  defp sgr(b, x, y, fin), do: "\e[<#{b};#{x + 1};#{y + 1}#{fin}"
  defp press_release(c, x, y), do: Driver.type(c, sgr(0, x, y, "M") <> sgr(0, x, y, "m"))

  defp hit_rect(c, path) do
    input = Client.input(c)
    true = wait(fn -> Enum.any?(:sys.get_state(input).hits, &(&1.path == path)) end)
    Enum.find(:sys.get_state(input).hits, &(&1.path == path)).rect
  end

  defp active_tab(c) do
    tabs = Node.find(Driver.scene(c).chrome, [:tabs])
    Enum.find_value(tabs.children, fn n -> if n.role == :tab and n.props.active, do: n.id end)
  end

  defp pane_cols(c),
    do: Driver.scene(c).panes |> Enum.sort_by(& &1.rect.x) |> Enum.map(& &1.rect.w)

  defp vt_cols(id) do
    {:ok, %{vt: vt}} = Keeper.lookup(Rows.kernel_id(id))
    :sys.get_state(vt).cols
  end

  defp wait(fun, n \\ 100) do
    cond do
      fun.() -> true
      n == 0 -> false
      true -> Process.sleep(20) && wait(fun, n - 1)
    end
  end
end
