%DynideScene.Scene{
  size: %{rows: 24, cols: 80},
  chrome: %DynideScene.Scene.Node{
    role: :root,
    id: :root,
    rect: nil,
    text: nil,
    token: nil,
    props: %{
      mouse: true,
      sound: %{command: nil, enabled: true},
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
      %DynideScene.Scene.Node{
        role: :sidebar,
        id: :sidebar,
        rect: %{x: 0, y: 0, h: 23, w: 26},
        text: nil,
        token: nil,
        props: %{collapsed: false},
        children: [
          %DynideScene.Scene.Node{
            role: :section,
            id: :spaces,
            rect: nil,
            text: "spaces",
            token: nil,
            props: %{},
            children: [
              %DynideScene.Scene.Node{
                role: :list,
                id: :list,
                rect: nil,
                text: nil,
                token: nil,
                props: %{offset: 0},
                children: [
                  %DynideScene.Scene.Node{
                    role: :item,
                    id: {:workspace, 1},
                    rect: nil,
                    text: nil,
                    token: nil,
                    props: %{active: true, index: 1},
                    children: [
                      %DynideScene.Scene.Node{
                        role: :group,
                        id: {:line, 0},
                        rect: nil,
                        text: nil,
                        token: nil,
                        props: %{},
                        children: [
                          %DynideScene.Scene.Node{
                            role: :badge,
                            id: :state,
                            rect: nil,
                            text: nil,
                            token: nil,
                            props: %{state: :unknown, kind: :agent_state},
                            children: []
                          },
                          %DynideScene.Scene.Node{
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
              %DynideScene.Scene.Node{
                role: :button,
                id: :new,
                rect: nil,
                text: "new",
                token: nil,
                props: %{action: :new_workspace},
                children: []
              },
              %DynideScene.Scene.Node{
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
          %DynideScene.Scene.Node{
            role: :divider,
            id: :split,
            rect: %{x: 0, y: 12, h: 1, w: 25},
            text: nil,
            token: nil,
            props: %{target: :sidebar_split, direction: :vertical},
            children: []
          },
          %DynideScene.Scene.Node{
            role: :section,
            id: :agents,
            rect: nil,
            text: "agents",
            token: nil,
            props: %{},
            children: [
              %DynideScene.Scene.Node{
                role: :list,
                id: :list,
                rect: nil,
                text: nil,
                token: nil,
                props: %{offset: 0},
                children: [
                  %DynideScene.Scene.Node{
                    role: :item,
                    id: {:pane, 1},
                    rect: nil,
                    text: nil,
                    token: nil,
                    props: %{active: true},
                    children: [
                      %DynideScene.Scene.Node{
                        role: :group,
                        id: {:line, 0},
                        rect: nil,
                        text: nil,
                        token: nil,
                        props: %{},
                        children: [
                          %DynideScene.Scene.Node{
                            role: :badge,
                            id: :state,
                            rect: nil,
                            text: nil,
                            token: nil,
                            props: %{state: :unknown, kind: :agent_state},
                            children: []
                          },
                          %DynideScene.Scene.Node{
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
                      %DynideScene.Scene.Node{
                        role: :group,
                        id: {:line, 1},
                        rect: nil,
                        text: nil,
                        token: nil,
                        props: %{},
                        children: [
                          %DynideScene.Scene.Node{
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
              },
              %DynideScene.Scene.Node{
                role: :button,
                id: :sort,
                rect: nil,
                text: "grouped",
                token: nil,
                props: %{action: :toggle_agent_sort},
                children: []
              }
            ]
          },
          %DynideScene.Scene.Node{
            role: :button,
            id: :toggle,
            rect: nil,
            text: nil,
            token: nil,
            props: %{action: :toggle_sidebar, collapsed: false},
            children: []
          },
          %DynideScene.Scene.Node{
            role: :divider,
            id: :edge,
            rect: %{x: 25, y: 0, h: 23, w: 1},
            text: nil,
            token: nil,
            props: %{target: :sidebar_width, direction: :horizontal},
            children: []
          }
        ]
      },
      %DynideScene.Scene.Node{
        role: :tabs,
        id: :tabs,
        rect: %{x: 26, y: 0, h: 1, w: 54},
        text: nil,
        token: nil,
        props: %{},
        children: [
          %DynideScene.Scene.Node{
            role: :tab,
            id: {:tab, 1},
            rect: nil,
            text: "1",
            token: nil,
            props: %{active: true, index: 1, zoomed: false},
            children: []
          },
          %DynideScene.Scene.Node{
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
      %DynideScene.Scene.Node{
        role: :status,
        id: :status,
        rect: %{x: 0, y: 23, h: 1, w: 80},
        text: nil,
        token: nil,
        props: %{},
        children: [
          %DynideScene.Scene.Node{
            role: :text,
            id: :mode,
            rect: nil,
            text: "TERMINAL",
            token: :default,
            props: %{mode: :terminal},
            children: []
          },
          %DynideScene.Scene.Node{
            role: :text,
            id: :title,
            rect: nil,
            text: "",
            token: :muted,
            props: %{},
            children: []
          },
          %DynideScene.Scene.Node{
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
      %DynideScene.Scene.Node{
        role: :modal,
        id: {:modal, 1},
        rect: %{x: 8, y: 4, h: 16, w: 64},
        text: nil,
        token: nil,
        props: %{kind: :onboarding, tone: :default, dim: true},
        children: [
          %DynideScene.Scene.Node{
            role: :text,
            id: :title,
            rect: nil,
            text: "dynIDE",
            token: :strong,
            props: %{},
            children: []
          },
          %DynideScene.Scene.Node{
            role: :text,
            id: :subtitle,
            rect: nil,
            text: "terminal workspace manager for coding agents",
            token: :muted,
            props: %{},
            children: []
          },
          %DynideScene.Scene.Node{
            role: :spacer,
            id: :gap,
            rect: nil,
            text: nil,
            token: nil,
            props: %{rows: 1},
            children: []
          },
          %DynideScene.Scene.Node{
            role: :text,
            id: {:line, 0},
            rect: nil,
            text: "this is a mouse-first terminal.",
            token: nil,
            props: %{},
            children: []
          },
          %DynideScene.Scene.Node{
            role: :text,
            id: {:line, 1},
            rect: nil,
            text: "click the sidebar to switch workspaces, drag pane",
            token: nil,
            props: %{},
            children: []
          },
          %DynideScene.Scene.Node{
            role: :text,
            id: {:line, 2},
            rect: nil,
            text: "borders to resize, right-click for context menus.",
            token: nil,
            props: %{},
            children: []
          },
          %DynideScene.Scene.Node{
            role: :spacer,
            id: :gap2,
            rect: nil,
            text: nil,
            token: nil,
            props: %{rows: 1},
            children: []
          },
          %DynideScene.Scene.Node{
            role: :group,
            id: {:line, 3},
            rect: nil,
            text: nil,
            token: nil,
            props: %{},
            children: [
              %DynideScene.Scene.Node{
                role: :keycap,
                id: :prefix,
                rect: nil,
                text: "ctrl+b",
                token: nil,
                props: %{prefix: false, key: "b", mods: [:ctrl]},
                children: []
              },
              %DynideScene.Scene.Node{
                role: :text,
                id: :suffix,
                rect: nil,
                text: " enters prefix mode · ",
                token: nil,
                props: %{},
                children: []
              },
              %DynideScene.Scene.Node{
                role: :keycap,
                id: :help,
                rect: nil,
                text: "?",
                token: nil,
                props: %{prefix: false, key: "?", mods: []},
                children: []
              },
              %DynideScene.Scene.Node{
                role: :text,
                id: :help_text,
                rect: nil,
                text: " shows keybinds and settings",
                token: nil,
                props: %{},
                children: []
              }
            ]
          },
          %DynideScene.Scene.Node{
            role: :text,
            id: {:line, 4},
            rect: nil,
            text: "next: install optional agent integrations for more reliable state",
            token: nil,
            props: %{},
            children: []
          },
          %DynideScene.Scene.Node{
            role: :spacer,
            id: :fill,
            rect: nil,
            text: nil,
            token: nil,
            props: %{rows: 4},
            children: []
          },
          %DynideScene.Scene.Node{
            role: :group,
            id: :actions,
            rect: nil,
            text: nil,
            token: nil,
            props: %{},
            children: [
              %DynideScene.Scene.Node{
                role: :button,
                id: :continue,
                rect: nil,
                text: "continue",
                token: nil,
                props: %{
                  primary: true,
                  action: :continue,
                  key: :enter,
                  mods: []
                },
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
    %DynideScene.Scene.Pane{
      id: 1,
      rect: %{x: 26, y: 1, h: 22, w: 54},
      border: nil,
      rows: {:ref, 1, 0},
      cursor: nil,
      overlays: [],
      graphics: []
    }
  ],
  focus: %{pane: 1, chrome: nil}
}
