%HerdrScene.Scene{
  size: %{rows: 50, cols: 200},
  chrome: %HerdrScene.Scene.Node{
    role: :root,
    id: :root,
    rect: nil,
    text: nil,
    token: nil,
    props: %{},
    children: [
      %HerdrScene.Scene.Node{
        role: :tabs,
        id: :tabs,
        rect: %{x: 26, y: 0, h: 1, w: 174},
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
            props: %{active: true, index: 1, zoomed: false},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :button,
            id: :new_tab,
            rect: nil,
            text: nil,
            token: nil,
            props: %{action: :new_tab},
            children: []
          }
        ]
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, []},
        rect: %{x: 113, y: 1, h: 48, w: 1},
        text: nil,
        token: nil,
        props: %{path: [], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false]},
        rect: %{x: 26, y: 25, h: 1, w: 87},
        text: nil,
        token: nil,
        props: %{path: [false], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false, false]},
        rect: %{x: 70, y: 1, h: 24, w: 1},
        text: nil,
        token: nil,
        props: %{path: [false, false], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false, false, false]},
        rect: %{x: 26, y: 13, h: 1, w: 44},
        text: nil,
        token: nil,
        props: %{path: [false, false, false], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false, false, true]},
        rect: %{x: 70, y: 13, h: 1, w: 43},
        text: nil,
        token: nil,
        props: %{path: [false, false, true], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false, true]},
        rect: %{x: 26, y: 37, h: 1, w: 87},
        text: nil,
        token: nil,
        props: %{path: [false, true], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false, true, false]},
        rect: %{x: 26, y: 31, h: 1, w: 87},
        text: nil,
        token: nil,
        props: %{path: [false, true, false], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false, true, true]},
        rect: %{x: 70, y: 37, h: 12, w: 1},
        text: nil,
        token: nil,
        props: %{path: [false, true, true], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true]},
        rect: %{x: 157, y: 1, h: 48, w: 1},
        text: nil,
        token: nil,
        props: %{path: [true], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true, false]},
        rect: %{x: 113, y: 25, h: 1, w: 44},
        text: nil,
        token: nil,
        props: %{path: [true, false], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true, false, false]},
        rect: %{x: 135, y: 1, h: 24, w: 1},
        text: nil,
        token: nil,
        props: %{path: [true, false, false], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true, false, true]},
        rect: %{x: 113, y: 37, h: 1, w: 44},
        text: nil,
        token: nil,
        props: %{path: [true, false, true], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true, true]},
        rect: %{x: 179, y: 1, h: 48, w: 1},
        text: nil,
        token: nil,
        props: %{path: [true, true], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true, true, false]},
        rect: %{x: 168, y: 1, h: 48, w: 1},
        text: nil,
        token: nil,
        props: %{path: [true, true, false], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :status,
        id: :status,
        rect: %{x: 0, y: 49, h: 1, w: 200},
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
      }
    ]
  },
  cursor: nil,
  panes: [
    %HerdrScene.Scene.Pane{
      id: 1,
      rect: %{x: 27, y: 2, h: 10, w: 42},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 26, y: 1, h: 12, w: 44}
      },
      rows: {:ref, 1, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 9,
      rect: %{x: 27, y: 14, h: 10, w: 42},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 26, y: 13, h: 12, w: 44}
      },
      rows: {:ref, 9, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 6,
      rect: %{x: 71, y: 2, h: 10, w: 41},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 70, y: 1, h: 12, w: 43}
      },
      rows: {:ref, 6, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 15,
      rect: %{x: 71, y: 14, h: 10, w: 41},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 70, y: 13, h: 12, w: 43}
      },
      rows: {:ref, 15, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 3,
      rect: %{x: 27, y: 26, h: 4, w: 85},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 26, y: 25, h: 6, w: 87}
      },
      rows: {:ref, 3, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 13,
      rect: %{x: 27, y: 32, h: 4, w: 85},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 26, y: 31, h: 6, w: 87}
      },
      rows: {:ref, 13, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 7,
      rect: %{x: 27, y: 38, h: 10, w: 42},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 26, y: 37, h: 12, w: 44}
      },
      rows: {:ref, 7, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 14,
      rect: %{x: 71, y: 38, h: 10, w: 41},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 70, y: 37, h: 12, w: 43}
      },
      rows: {:ref, 14, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 2,
      rect: %{x: 114, y: 2, h: 22, w: 20},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 113, y: 1, h: 24, w: 22}
      },
      rows: {:ref, 2, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 10,
      rect: %{x: 136, y: 2, h: 22, w: 20},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 135, y: 1, h: 24, w: 22}
      },
      rows: {:ref, 10, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 5,
      rect: %{x: 114, y: 26, h: 10, w: 42},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 113, y: 25, h: 12, w: 44}
      },
      rows: {:ref, 5, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 11,
      rect: %{x: 114, y: 38, h: 10, w: 42},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 113, y: 37, h: 12, w: 44}
      },
      rows: {:ref, 11, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 4,
      rect: %{x: 158, y: 2, h: 46, w: 9},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 157, y: 1, h: 48, w: 11}
      },
      rows: {:ref, 4, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 12,
      rect: %{x: 169, y: 2, h: 46, w: 9},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 168, y: 1, h: 48, w: 11}
      },
      rows: {:ref, 12, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 8,
      rect: %{x: 180, y: 2, h: 46, w: 19},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 179, y: 1, h: 48, w: 21}
      },
      rows: {:ref, 8, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    }
  ],
  focus: %{pane: 15, chrome: nil}
}
