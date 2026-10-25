%HerdrScene.Scene{
  size: %{rows: 24, cols: 80},
  chrome: %HerdrScene.Scene.Node{
    role: :root,
    id: :root,
    rect: nil,
    text: nil,
    token: nil,
    props: %{
      mouse: true,
      sound: %{enabled: true},
      toast: %{delivery: :herdr},
      indicators: :dots,
      theme: %{
        name: "catppuccin",
        auto_switch: false,
        dark: "catppuccin",
        light: "catppuccin-latte"
      }
    },
    children: [
      %HerdrScene.Scene.Node{
        role: :sidebar,
        id: :sidebar,
        rect: %{x: 0, y: 0, h: 23, w: 4},
        text: nil,
        token: nil,
        props: %{collapsed: true},
        children: [
          %HerdrScene.Scene.Node{
            role: :section,
            id: :spaces,
            rect: nil,
            text: nil,
            token: nil,
            props: %{},
            children: [
              %HerdrScene.Scene.Node{
                role: :list,
                id: :list,
                rect: nil,
                text: nil,
                token: nil,
                props: %{offset: 0},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :item,
                    id: {:workspace, 1},
                    rect: nil,
                    text: nil,
                    token: nil,
                    props: %{active: true, index: 1},
                    children: [
                      %HerdrScene.Scene.Node{
                        role: :group,
                        id: {:line, 0},
                        rect: nil,
                        text: nil,
                        token: nil,
                        props: %{},
                        children: [
                          %HerdrScene.Scene.Node{
                            role: :badge,
                            id: :state,
                            rect: nil,
                            text: nil,
                            token: nil,
                            props: %{state: :unknown, kind: :agent_state},
                            children: []
                          },
                          %HerdrScene.Scene.Node{
                            role: :text,
                            id: :workspace,
                            rect: nil,
                            text: "1",
                            token: nil,
                            props: %{},
                            children: []
                          }
                        ]
                      }
                    ]
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :button,
                id: :new,
                rect: nil,
                text: "new",
                token: nil,
                props: %{action: :new_workspace},
                children: []
              },
              %HerdrScene.Scene.Node{
                role: :button,
                id: :menu,
                rect: nil,
                text: "menu",
                token: nil,
                props: %{action: :global_menu, attention: false},
                children: []
              }
            ]
          },
          %HerdrScene.Scene.Node{
            role: :section,
            id: :agents,
            rect: nil,
            text: nil,
            token: nil,
            props: %{},
            children: [
              %HerdrScene.Scene.Node{
                role: :list,
                id: :list,
                rect: nil,
                text: nil,
                token: nil,
                props: %{offset: 0},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :item,
                    id: {:pane, 1},
                    rect: nil,
                    text: nil,
                    token: nil,
                    props: %{active: true},
                    children: [
                      %HerdrScene.Scene.Node{
                        role: :group,
                        id: {:line, 0},
                        rect: nil,
                        text: nil,
                        token: nil,
                        props: %{},
                        children: [
                          %HerdrScene.Scene.Node{
                            role: :badge,
                            id: :state,
                            rect: nil,
                            text: nil,
                            token: nil,
                            props: %{state: :unknown, kind: :agent_state},
                            children: []
                          },
                          %HerdrScene.Scene.Node{
                            role: :text,
                            id: :workspace,
                            rect: nil,
                            text: "1",
                            token: nil,
                            props: %{},
                            children: []
                          }
                        ]
                      },
                      %HerdrScene.Scene.Node{
                        role: :group,
                        id: {:line, 1},
                        rect: nil,
                        text: nil,
                        token: nil,
                        props: %{},
                        children: [
                          %HerdrScene.Scene.Node{
                            role: :text,
                            id: :agent,
                            rect: nil,
                            text: "terminal",
                            token: nil,
                            props: %{},
                            children: []
                          }
                        ]
                      }
                    ]
                  }
                ]
              }
            ]
          },
          %HerdrScene.Scene.Node{
            role: :button,
            id: :toggle,
            rect: nil,
            text: nil,
            token: nil,
            props: %{action: :toggle_sidebar, collapsed: true},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :divider,
            id: :edge,
            rect: %{x: 3, y: 0, h: 23, w: 1},
            text: nil,
            token: nil,
            props: %{target: :sidebar_width, direction: :horizontal},
            children: []
          }
        ]
      },
      %HerdrScene.Scene.Node{
        role: :tabs,
        id: :tabs,
        rect: %{x: 4, y: 0, h: 1, w: 76},
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
        role: :status,
        id: :status,
        rect: %{x: 0, y: 23, h: 1, w: 80},
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
      rect: %{x: 4, y: 1, h: 22, w: 76},
      border: nil,
      rows: {:ref, 1, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    }
  ],
  focus: %{pane: 1, chrome: nil}
}
