%HerdrScene.Scene{
  size: %{rows: 40, cols: 120},
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
        id: {:modal, 1},
        rect: %{x: 22, y: 9, h: 22, w: 76},
        text: nil,
        token: nil,
        props: %{kind: :keybinds, tone: :default, dim: true},
        children: [
          %HerdrScene.Scene.Node{
            role: :text,
            id: :title,
            rect: nil,
            text: "keybinds",
            token: :strong,
            props: %{},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :text,
            id: :subtitle,
            rect: nil,
            text: "press a key for rename_tab · esc cancels",
            token: :accent,
            props: %{},
            children: []
          },
          %HerdrScene.Scene.Node{
            role: :spacer,
            id: :filter,
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
            props: %{offset: 3, rows: 15},
            children: [
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "detach"},
                rect: nil,
                text: "detach",
                token: nil,
                props: %{selected: false},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+q",
                    token: nil,
                    props: %{prefix: true, key: "q", mods: []},
                    children: []
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "reload_config"},
                rect: nil,
                text: "reload config",
                token: nil,
                props: %{selected: false},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+shift+r",
                    token: nil,
                    props: %{prefix: true, key: "R", mods: []},
                    children: []
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :text,
                id: {:group, "navigation"},
                rect: nil,
                text: "navigation",
                token: :accent,
                props: %{},
                children: []
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "focus_pane_left"},
                rect: nil,
                text: "focus pane left",
                token: nil,
                props: %{selected: false},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+h",
                    token: nil,
                    props: %{prefix: true, key: "h", mods: []},
                    children: []
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "focus_pane_down"},
                rect: nil,
                text: "focus pane down",
                token: nil,
                props: %{selected: false},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+j",
                    token: nil,
                    props: %{prefix: true, key: "j", mods: []},
                    children: []
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "focus_pane_up"},
                rect: nil,
                text: "focus pane up",
                token: nil,
                props: %{selected: false},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+k",
                    token: nil,
                    props: %{prefix: true, key: "k", mods: []},
                    children: []
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "focus_pane_right"},
                rect: nil,
                text: "focus pane right",
                token: nil,
                props: %{selected: false},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+l",
                    token: nil,
                    props: %{prefix: true, key: "l", mods: []},
                    children: []
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "cycle_pane_next"},
                rect: nil,
                text: "cycle pane next",
                token: nil,
                props: %{selected: false},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+tab",
                    token: nil,
                    props: %{prefix: true, key: :tab, mods: []},
                    children: []
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "cycle_pane_previous"},
                rect: nil,
                text: "cycle pane previous",
                token: nil,
                props: %{selected: false},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+shift+tab",
                    token: nil,
                    props: %{prefix: true, key: :tab, mods: [:shift]},
                    children: []
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :text,
                id: {:group, "workspaces / tabs"},
                rect: nil,
                text: "workspaces / tabs",
                token: :accent,
                props: %{},
                children: []
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "new_workspace"},
                rect: nil,
                text: "new workspace",
                token: nil,
                props: %{selected: false},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+shift+n",
                    token: nil,
                    props: %{prefix: true, key: "N", mods: []},
                    children: []
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "rename_workspace"},
                rect: nil,
                text: "rename workspace",
                token: nil,
                props: %{selected: false},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+shift+w",
                    token: nil,
                    props: %{prefix: true, key: "W", mods: []},
                    children: []
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "close_workspace"},
                rect: nil,
                text: "close workspace",
                token: nil,
                props: %{selected: false},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+shift+d",
                    token: nil,
                    props: %{prefix: true, key: "D", mods: []},
                    children: []
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "new_tab"},
                rect: nil,
                text: "new tab",
                token: nil,
                props: %{selected: false},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+c",
                    token: nil,
                    props: %{prefix: true, key: "c", mods: []},
                    children: []
                  }
                ]
              },
              %HerdrScene.Scene.Node{
                role: :item,
                id: {:action, "rename_tab"},
                rect: nil,
                text: "rename tab",
                token: nil,
                props: %{selected: true},
                children: [
                  %HerdrScene.Scene.Node{
                    role: :keycap,
                    id: {:key, 0},
                    rect: nil,
                    text: "prefix+shift+t",
                    token: nil,
                    props: %{prefix: true, key: "T", mods: []},
                    children: []
                  }
                ]
              }
            ]
          },
          %HerdrScene.Scene.Node{
            role: :text,
            id: :hint,
            rect: nil,
            text: "search / · scroll j/k/↑↓/pgup/pgdn · rebind enter · close esc",
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
                id: :close,
                rect: nil,
                text: "close",
                token: nil,
                props: %{primary: true, action: :close, key: :escape, mods: []},
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
  focus: %{pane: 1, chrome: nil}
}
