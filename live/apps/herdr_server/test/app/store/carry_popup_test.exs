defmodule HerdrServer.App.Store.CarryPopupTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.App.{Actions, Commands, Modal, Store}
  alias HerdrServer.App.Modal.Popup
  alias HerdrServer.App.Store.Carry
  alias HerdrServer.Pane.Rows

  @size %{cols: 120, rows: 40}

  def open_popup(app) do
    {:ok, app, id, size} = Popup.open(app, %{})
    {app, [{:spawn, id, size, %{cwd: nil, replay: nil, cmd: "/bin/sh", identity: false}}]}
  end

  test "a carried app with a popup open lists the popup's pane for adoption" do
    {app, _} = Actions.init(@size)
    {app, _} = open_popup(app)
    id = Popup.find(app).pane
    blob = :erlang.term_to_binary(%{v: 1, app: app, kernel_ids: [{1, 10}, {id, 20}]})
    assert {_app, pairs} = Carry.adoption(blob)
    assert Enum.sort(pairs) == [{1, 10}, {id, 20}]
  end

  test "a popup pane the keeper lost is closed on adoption, which pops the popup" do
    Store.reset()
    on_exit(&Store.reset/0)
    :ok = Store.event({:resize, @size}, @size)
    {:ok, _, app} = Store.request({__MODULE__, :open_popup, []})
    id = Popup.find(app).pane

    # the new VM's adoption: the popup's kernel pane is gone
    {:ok, _app, sizes} = Carry.adopt_carried(app, [{id, nil}])
    refute Map.has_key?(sizes, id)

    assert Enum.any?(1..100, fn _ ->
             Modal.top(Store.snapshot()) == nil or (Process.sleep(10) && false)
           end)
  end

  test "closing the popup's owner tab (an API request) closes the popup" do
    Store.reset()
    on_exit(&Store.reset/0)
    :ok = Store.event({:resize, @size}, @size)
    {:ok, _, _} = Store.request({Commands, :create_tab, [1, nil, false]})
    {:ok, _, app} = Store.request({__MODULE__, :open_popup, []})
    %{pane: id, owner: {1, 1}} = Popup.find(app)
    # another tab's close leaves it
    {:ok, _, app} = Store.request({Commands, :close_tab, [1, 2]})
    assert Popup.find(app)
    {:ok, _, _} = Store.request({Commands, :create_tab, [1, nil, false]})
    {:ok, _, app} = Store.request({Commands, :close_tab, [1, 1]})
    assert Popup.find(app) == nil
    refute Rows.kernel_id(id)
  end
end
