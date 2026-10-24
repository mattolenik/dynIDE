%HerdrScene.Scene{
  size: %{rows: 40, cols: 120},
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
        rect: %{x: 0, y: 39, h: 1, w: 120},
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
            props: %{},
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
            props: %{},
            children: []
          }
        ]
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, []},
        rect: %{x: 60, y: 0, h: 39, w: 1},
        text: nil,
        token: nil,
        props: %{path: [], direction: :horizontal},
        children: []
      }
    ]
  },
  cursor: nil,
  panes: [
    %HerdrScene.Scene.Pane{
      id: 1,
      rect: %{x: 1, y: 1, h: 37, w: 58},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 0, y: 0, h: 39, w: 60}
      },
      rows: {:ref, 1, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 2,
      rect: %{x: 61, y: 1, h: 37, w: 58},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 60, y: 0, h: 39, w: 60}
      },
      rows: {:ref, 2, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    }
  ],
  focus: %{pane: 2, chrome: nil}
}
