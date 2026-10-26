defmodule DynideScene.SceneSample do
  @moduledoc false
  alias DynideScene.Scene
  alias DynideScene.Scene.{Node, Overlay, Pane}

  def build do
    mode = %Node{role: :text, id: :mode, text: "NORMAL", token: :accent}

    status = %Node{
      role: :status,
      id: :status,
      rect: %{x: 0, y: 23, w: 80, h: 1},
      children: [mode]
    }

    %Scene{
      size: %{cols: 80, rows: 24},
      panes: [
        %Pane{
          id: 1,
          rect: %{x: 0, y: 0, w: 40, h: 23},
          border: %{rect: %{x: 0, y: 0, w: 40, h: 23}, edges: [:right], title: "one"},
          rows: {:ref, 1, 0},
          cursor: %{x: 1, y: 2, shape: :block, visible: true},
          overlays: [%Overlay{kind: :dim, args: %{reason: :inactive}}]
        },
        %Pane{id: 2, rect: %{x: 41, y: 0, w: 39, h: 23}, rows: {:inline, [{0, "abc"}]}}
      ],
      chrome: %Node{role: :root, id: :root, children: [status]},
      focus: %{pane: 1, chrome: nil},
      cursor: %{x: 1, y: 2, shape: :bar}
    }
  end
end
