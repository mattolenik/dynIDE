defmodule HerdrIntegration.ModalTwoClientsTest do
  @moduledoc """
  A modal is shared session state: both attached clients see it, either can answer it,
  and keys typed in either never reach a pane while it is open.
  """
  use ExUnit.Case, async: false

  alias HerdrIntegration.Driver
  alias HerdrScene.{Cell, Scene}
  alias HerdrScene.Scene.Node
  alias HerdrServer.App.{Actions, Store}
  alias HerdrServer.App.Modal.{Confirm, Prompt}
  alias HerdrServer.Client.State
  alias HerdrServer.Kernel.Fake.{Keeper, Pty}
  alias HerdrServer.Pane.Rows
  alias HerdrServer.View
  alias HerdrTerm.Client.Term.Render.Compose
  alias HerdrTerm.Client.Term.Theme

  setup do
    Driver.reset()
  end

  test "A opens the rename prompt, B sees it, types into it and saves; no pane gets a key" do
    a = Driver.start_client({100, 30})
    b = Driver.start_client({80, 24})
    [pane] = Enum.map(Driver.scene(a).panes, & &1.id)

    Driver.type(a, "\x02T")
    assert wait(fn -> input_text(b) == "1" end)
    assert input_text(a) == "1"
    # both clients draw it: the title is on B's screen
    assert Driver.wait_screen(b, &Enum.any?(&1, fn row -> row =~ "rename tab" end))

    Driver.type(a, "a")
    assert wait(fn -> input_text(b) == "1a" end)
    Driver.type(b, "x")
    assert wait(fn -> input_text(a) == "1ax" end)
    Driver.type(b, "\r")
    assert wait(fn -> Node.find(Driver.scene(a).chrome, [{:modal, 1}]) == nil end)
    assert wait(fn -> Node.find(Driver.scene(b).chrome, [{:modal, 1}]) == nil end)

    [ws] = Store.snapshot().session.workspaces
    assert Enum.map(ws.tabs, & &1.name) == ["1ax"]
    assert Pty.writes(pty(pane)) == []

    # closed: typing reaches the pane again
    Driver.type(b, "z")
    assert wait(fn -> Pty.writes(pty(pane)) == ["z"] end)
  end

  test "an open prompt, confirm or menu validates and composes to full-width rows at every size" do
    app = elem(Actions.init(%{cols: 80, rows: 24}), 0)
    {prompt, []} = Prompt.rename_tab(app)
    {confirm, []} = Confirm.close_workspace(app)

    {menu, []} =
      Actions.apply(
        app,
        {:chrome, [:tabs, {:tab, 1}], {:right_click, %{x: 70, y: 20}}}
      )

    theme = Theme.default()

    for app <- [prompt, confirm, menu], c <- [1, 10, 20, 80], r <- [1, 3, 5, 24] do
      client = %State{size: %{cols: c, rows: r}, transport: :ref}
      scene = View.compute(app, client)
      assert :ok = Scene.validate(scene), "#{c}x#{r}"
      frame = Compose.frame(scene, %{}, theme)
      assert length(frame) == r
      assert Enum.all?(frame, fn {_, row} -> Cell.cols(row) == c end), "#{c}x#{r}"
    end
  end

  defp input_text(client) do
    case Node.find(Driver.scene(client).chrome, [{:modal, 1}, :input]) do
      %Node{text: t} -> t
      nil -> nil
    end
  end

  defp pty(id) do
    {:ok, %{pty: pty}} = Keeper.lookup(Rows.kernel_id(id))
    pty
  end

  defp wait(fun, n \\ 200) do
    cond do
      fun.() -> true
      n == 0 -> false
      true -> Process.sleep(10) && wait(fun, n - 1)
    end
  end
end
