%HerdrScene.Scene{
  size: %{rows: 40, cols: 120},
  chrome: %HerdrScene.Scene.Node{
    role: :root,
    id: :root,
    rect: nil,
    text: nil,
    token: nil,
    props: %{
      theme: %{
        name: "catppuccin",
        auto_switch: false,
        dark: "catppuccin",
        light: "catppuccin-latte"
      },
      indicators: :dots,
      mouse: true
    },
    children: [
      %HerdrScene.Scene.Node{
        role: :sidebar,
        id: :sidebar,
        rect: %{x: 0, y: 0, h: 39, w: 26},
        text: nil,
        token: nil,
        props: %{collapsed: false},
        children: [
          %HerdrScene.Scene.Node{
            role: :section,
            id: :spaces,
            rect: nil,
            text: "spaces",
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
            role: :divider,
            id: :split,
            rect: %{x: 0, y: 20, h: 1, w: 25},
            text: nil,
            token: nil,
            props: %{target: :sidebar_split, direction: :vertical},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :section,
            id: :agents,
            rect: nil,
            text: "agents",
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
            props: %{action: :toggle_sidebar, collapsed: false},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :divider,
            id: :edge,
            rect: %{x: 25, y: 0, h: 39, w: 1},
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
        rect: %{x: 26, y: 0, h: 1, w: 94},
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
      },
      %HerdrScene.Scene.Node{
        role: :modal,
        id: {:modal, 0},
        rect: %{x: 22, y: 9, h: 22, w: 76},
        text: nil,
        token: nil,
        props: %{kind: :settings, tone: :default, dim: true},
        children: [
          %HerdrScene.Scene.Node{
            role: :text,
            id: :title,
            rect: nil,
            text: "settings",
            token: :strong,
            props: %{},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :tabs,
            id: :sections,
            rect: nil,
            text: nil,
            token: nil,
            props: %{},
            children: [
              %HerdrScene.Scene.Node{
                role: :tab,
                id: {:section, :theme},
                rect: nil,
                text: "theme",
                token: nil,
                props: %{active: false, index: 0},
                children: []
              },
              %HerdrScene.Scene.Node{
                role: :tab,
                id: {:section, :indicators},
                rect: nil,
                text: "indicators",
                token: nil,
                props: %{active: true, index: 1},
                children: []
              },
              %HerdrScene.Scene.Node{
                role: :tab,
                id: {:section, :sound},
                rect: nil,
                text: "sound",
                token: nil,
                props: %{active: false, index: 2},
                children: []
              },
              %HerdrScene.Scene.Node{
                role: :tab,
                id: {:section, :toasts},
                rect: nil,
                text: "toasts",
                token: nil,
                props: %{active: false, index: 3},
                children: []
              }
            ]
          },
          %HerdrScene.Scene.Node{
            role: :spacer,
            id: :gap,
            rect: nil,
            text: nil,
            token: nil,
            props: %{rows: 1},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :text,
            id: :heading,
            rect: nil,
            text: "agent status indicators",
            token: :strong,
            props: %{},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :text,
            id: :description,
            rect: nil,
            text: "choose color dots or distinct symbols for each state",
            token: :muted,
            props: %{},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :spacer,
            id: :gap2,
            rect: nil,
            text: nil,
            token: nil,
            props: %{rows: 1},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :list,
            id: :list,
            rect: nil,
            text: nil,
            token: nil,
            props: %{offset: 0, rows: 11},
            children: [
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:choice, 0},
                rect: nil,
                text: "color dots",
                token: nil,
                props: %{selected: true, current: true, indicators: :dots},
                children: []
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:choice, 1},
                rect: nil,
                text: "distinct symbols",
                token: nil,
                props: %{selected: false, current: false, indicators: :symbols},
                children: []
              }
            ]
          },
          %HerdrScene.Scene.Node{
            role: :text,
            id: :hint,
            rect: nil,
            text: "↑↓ select  tab section",
            token: :muted,
            props: %{},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :group,
            id: :actions,
            rect: nil,
            text: nil,
            token: nil,
            props: %{},
            children: [
              %HerdrScene.Scene.Node{
                role: :button,
                id: :apply,
                rect: nil,
                text: "apply",
                token: nil,
                props: %{primary: true, action: :apply, key: :enter, mods: []},
                children: []
              },
              %HerdrScene.Scene.Node{
                role: :button,
                id: :close,
                rect: nil,
                text: "close",
                token: nil,
                props: %{primary: false, action: :close, key: :escape, mods: []},
                children: []
              }
            ]
          }
        ]
      }
    ]
  },
  cursor: nil,
  panes: [
    %HerdrScene.Scene.Pane{
      id: 1,
      rect: %{x: 26, y: 1, h: 38, w: 94},
      border: nil,
      rows: {:ref, 1, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    }
  ],
  focus: %{chrome: nil, pane: 1}
}
