defmodule DynideServer.App.UpgradeTest do
  use ExUnit.Case, async: true

  import DynideServer.ViewHelpers

  alias DynideScene.Scene
  alias DynideServer.App.{Focus, Keybinds, Session, Store, Ui, Upgrade}
  alias DynideServer.Client.State
  alias DynideServer.View

  @new_ui [:sidebar, :tab_bar, :indicators, :confirm_close, :onboarding, :toast, :sound] ++
            [:prompt_new_tab_name, :pane_borders]

  # an app as the M7 mirror or a pre-M13 handoff carry holds it
  defp old_app do
    app = fresh(80, 24)
    kb = Keybinds.default()
    ui = struct(Ui, %{keybinds: kb, status: %{show_hints: true}, theme: :default})
    ui = Enum.reduce(@new_ui, ui, &Map.delete(&2, &1))
    session = Map.delete(app.session, :size)
    %{app | ui: ui, session: session, focus: Map.delete(%Focus{pane: 1}, :modal)}
  end

  test "upgrade old app" do
    app = Upgrade.app(old_app())
    client = %State{size: %{cols: 80, rows: 24}, transport: :ref, mode: :terminal}
    assert :ok = app |> View.compute(client) |> Scene.validate()

    assert %Ui{theme: %{name: "catppuccin"}, sidebar: %{width: 26}, keybinds: %Keybinds{}} =
             app.ui

    assert app.ui.pane_borders == :auto
    assert app.ui.tab_bar == %{position: :top, hide_single: false}

    assert %Session{size: %{cols: 80, rows: 24}} = app.session
    assert %Focus{pane: 1, modal: []} = app.focus
  end

  test "an app without id counters gets them above every workspace and tab id" do
    app = old_app()
    [ws] = app.session.workspaces
    ws = %{ws | id: 4, tabs: [%{hd(ws.tabs) | id: 9}], active_tab: 9}
    s = %{app.session | workspaces: [ws], active_workspace: 4}
    old = %{app | session: Map.drop(s, [:next_workspace_id, :next_tab_id])}

    for up <- [Upgrade.app(old), elem(Store.code_change(nil, %{app: old}, nil), 1).app] do
      assert {up.session.next_workspace_id, up.session.next_tab_id} == {5, 10}
    end
  end

  test "nested prefs merge key by key and keep set values" do
    ui = %{%Ui{} | sidebar: %{width: 30}, theme: %{name: "dracula"}, keybinds: nil}
    app = Upgrade.app(%{session: %Session{}, focus: %Focus{}, ui: ui})
    assert app.ui.sidebar == %{%Ui{}.sidebar | width: 30}
    assert app.ui.theme == %{%Ui{}.theme | name: "dracula"}
    assert app.ui.keybinds == Keybinds.default()
  end

  test "an upgraded app is a fixed point" do
    app = fresh(80, 24)
    assert Upgrade.app(app) == app
  end

  test "the Store's code_change and a carried entry upgrade the app" do
    assert {:ok, %Store{app: %{ui: %Ui{sidebar: %{width: 26}}}}} =
             Store.code_change(nil, %{app: old_app()}, nil)

    assert {:ok, %Store{app: nil}} = Store.code_change(nil, %{}, nil)

    blob = :erlang.term_to_binary(%{v: 1, app: old_app(), kernel_ids: [{1, 7}]})
    assert {%{ui: %Ui{theme: %{name: "catppuccin"}}}, [{1, 7}]} = Store.Carry.adoption(blob)
  end
end
