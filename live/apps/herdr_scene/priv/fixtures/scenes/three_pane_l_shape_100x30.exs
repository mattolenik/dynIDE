%HerdrScene.Scene{
  size: %{rows: 30, cols: 100},
  chrome: %HerdrScene.Scene.Node{
    role: :root,
    id: :root,
    rect: nil,
    text: nil,
    token: nil,
    props: %{},
    children: [
      %HerdrScene.Scene.Node{
        role: :status,
        id: :status,
        rect: %{x: 0, y: 29, h: 1, w: 100},
        text: nil,
        token: nil,
        props: %{},
        children: [
          %HerdrScene.Scene.Node{
            role: :text,
            id: :mode,
            rect: nil,
            text: "TERMINAL",
            token: :default,
            props: %{mode: :terminal},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :tabs,
            id: :tabs,
            rect: nil,
            text: nil,
            token: nil,
            props: %{},
            children: [
              %HerdrScene.Scene.Node{
                role: :tab,
                id: {:tab, 1},
                rect: nil,
                text: "1",
                token: nil,
                props: %{active: true, index: 1},
                children: []
              }
            ]
          },
          %HerdrScene.Scene.Node{
            role: :text,
            id: :title,
            rect: nil,
            text: "",
            token: :muted,
            props: %{},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :text,
            id: :hint,
            rect: nil,
            text: "ctrl+b",
            token: :muted,
            props: %{key: "b", mods: [:ctrl]},
            children: []
          }
        ]
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, []},
        rect: %{x: 50, y: 0, h: 29, w: 1},
        text: nil,
        token: nil,
        props: %{path: [], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true]},
        rect: %{x: 50, y: 15, h: 1, w: 50},
        text: nil,
        token: nil,
        props: %{path: [true], direction: :vertical},
        children: []
      }
    ]
  },
  cursor: nil,
  panes: [
    %HerdrScene.Scene.Pane{
      id: 1,
      rect: %{x: 1, y: 1, h: 27, w: 48},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 0, y: 0, h: 29, w: 50}
      },
      rows: {:ref, 1, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 2,
      rect: %{x: 51, y: 1, h: 13, w: 48},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 50, y: 0, h: 15, w: 50}
      },
      rows: {:ref, 2, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 3,
      rect: %{x: 51, y: 16, h: 12, w: 48},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 50, y: 15, h: 14, w: 50}
      },
      rows: {:ref, 3, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    }
  ],
  focus: %{pane: 3, chrome: nil}
}
