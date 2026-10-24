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
        rect: %{x: 100, y: 0, h: 49, w: 1},
        text: nil,
        token: nil,
        props: %{path: [], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false]},
        rect: %{x: 0, y: 25, h: 1, w: 100},
        text: nil,
        token: nil,
        props: %{path: [false], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false, false]},
        rect: %{x: 0, y: 13, h: 1, w: 100},
        text: nil,
        token: nil,
        props: %{path: [false, false], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false, false, false]},
        rect: %{x: 0, y: 7, h: 1, w: 100},
        text: nil,
        token: nil,
        props: %{path: [false, false, false], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false, false, true]},
        rect: %{x: 0, y: 19, h: 1, w: 100},
        text: nil,
        token: nil,
        props: %{path: [false, false, true], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false, true]},
        rect: %{x: 50, y: 25, h: 24, w: 1},
        text: nil,
        token: nil,
        props: %{path: [false, true], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false, true, false]},
        rect: %{x: 25, y: 25, h: 24, w: 1},
        text: nil,
        token: nil,
        props: %{path: [false, true, false], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [false, true, true]},
        rect: %{x: 50, y: 37, h: 1, w: 50},
        text: nil,
        token: nil,
        props: %{path: [false, true, true], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true]},
        rect: %{x: 150, y: 0, h: 49, w: 1},
        text: nil,
        token: nil,
        props: %{path: [true], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true, false]},
        rect: %{x: 125, y: 0, h: 49, w: 1},
        text: nil,
        token: nil,
        props: %{path: [true, false], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true, false, false]},
        rect: %{x: 100, y: 25, h: 1, w: 25},
        text: nil,
        token: nil,
        props: %{path: [true, false, false], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true, false, true]},
        rect: %{x: 138, y: 0, h: 49, w: 1},
        text: nil,
        token: nil,
        props: %{path: [true, false, true], direction: :horizontal},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true, true]},
        rect: %{x: 150, y: 25, h: 1, w: 50},
        text: nil,
        token: nil,
        props: %{path: [true, true], direction: :vertical},
        children: []
      },
      %HerdrScene.Scene.Node{
        role: :divider,
        id: {:divider, [true, true, false]},
        rect: %{x: 175, y: 0, h: 25, w: 1},
        text: nil,
        token: nil,
        props: %{path: [true, true, false], direction: :horizontal},
        children: []
      }
    ]
  },
  cursor: nil,
  panes: [
    %HerdrScene.Scene.Pane{
      id: 1,
      rect: %{x: 1, y: 1, h: 5, w: 98},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 0, y: 0, h: 7, w: 100}
      },
      rows: {:ref, 1, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 9,
      rect: %{x: 1, y: 8, h: 4, w: 98},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 0, y: 7, h: 6, w: 100}
      },
      rows: {:ref, 9, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 5,
      rect: %{x: 1, y: 14, h: 4, w: 98},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 0, y: 13, h: 6, w: 100}
      },
      rows: {:ref, 5, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 13,
      rect: %{x: 1, y: 20, h: 4, w: 98},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 0, y: 19, h: 6, w: 100}
      },
      rows: {:ref, 13, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 3,
      rect: %{x: 1, y: 26, h: 22, w: 23},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 0, y: 25, h: 24, w: 25}
      },
      rows: {:ref, 3, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 14,
      rect: %{x: 26, y: 26, h: 22, w: 23},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 25, y: 25, h: 24, w: 25}
      },
      rows: {:ref, 14, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 8,
      rect: %{x: 51, y: 26, h: 10, w: 48},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 50, y: 25, h: 12, w: 50}
      },
      rows: {:ref, 8, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 15,
      rect: %{x: 51, y: 38, h: 10, w: 48},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 50, y: 37, h: 12, w: 50}
      },
      rows: {:ref, 15, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 2,
      rect: %{x: 101, y: 1, h: 23, w: 23},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 100, y: 0, h: 25, w: 25}
      },
      rows: {:ref, 2, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 11,
      rect: %{x: 101, y: 26, h: 22, w: 23},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 100, y: 25, h: 24, w: 25}
      },
      rows: {:ref, 11, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 6,
      rect: %{x: 126, y: 1, h: 47, w: 11},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 125, y: 0, h: 49, w: 13}
      },
      rows: {:ref, 6, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 12,
      rect: %{x: 139, y: 1, h: 47, w: 10},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 138, y: 0, h: 49, w: 12}
      },
      rows: {:ref, 12, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 4,
      rect: %{x: 151, y: 1, h: 23, w: 23},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 150, y: 0, h: 25, w: 25}
      },
      rows: {:ref, 4, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 10,
      rect: %{x: 176, y: 1, h: 23, w: 23},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 175, y: 0, h: 25, w: 25}
      },
      rows: {:ref, 10, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    },
    %HerdrScene.Scene.Pane{
      id: 7,
      rect: %{x: 151, y: 26, h: 22, w: 48},
      border: %{
        title: nil,
        edges: [:top, :bottom, :left, :right],
        rect: %{x: 150, y: 25, h: 24, w: 50}
      },
      rows: {:ref, 7, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    }
  ],
  focus: %{pane: 15, chrome: nil}
}
