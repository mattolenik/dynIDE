defmodule DynideServer.Client.State do
  @moduledoc """
  State of one attached client connection (used by `Client.Session`). `mode` and
  `swallow` are this client's input state (`Client.Keys`); `keybinds` caches the app's
  keybinds from the last app the session saw, `capture` whether its top modal captures
  keys (`App.Modal.capturing?/1`); `runtime` is the last
  `DynideServer.RuntimeStatus` the session got from `ReloadNotices` (shared facts, copied
  here so the pure View reads only its client). `toasts` are this client's queued
  notifications (`Client.Toasts`, newest first), `focused` its outer terminal's last
  `{:focus, bool}` report (nil: unknown), `pending_alerts` the delayed alert per pane
  (`pane_id => ref`: a newer alert for the pane replaces it; a stale timer is dropped).
  `pointer` is this client's `Client.Pointer` (selection, link hover, gestures;
  transient, not mirrored) and
  `pointer_refs` the session's pointer timers (`:autoscroll` ref, `:expire` `{ref, selection}`).
  `facts` is `pane_id => %{scrolled, scroll, alt_screen}` that the session gathers
  (`PointerIo.scene_facts/2`) before `View.compute`, only for scrolled panes and the
  selection's pane, so the pure View reads no ETS. `copy` is this client's
  `Client.CopyMode` while its mode is `:copy` (not mirrored). `facts_tick` throttles
  repaints for `{:pane_facts, id}`. `graphics` is `pane_id => [placement]`
  (`Pane.Facts.graphics/1`) the session gathers for the active tab's panes before
  `View.compute`, panes without placements left out.
  `window_title` is the `title set` override of the window title
  (nil: the `ui.window_title` template), `hostname` is read once at attach.
  `drag` is this client's tab or workspace drag, `%{from: path, over: path}` (the
  dragged chrome path and the one under the pointer, same kind) or nil: `View` puts the
  `drop_marker` prop on `over` for this client only. Not mirrored (a re-attach ends it).
  `navigate` is this client's workspace navigate preview while its mode is `:navigate`,
  `%{ids, at}` (workspace ids in sidebar order, the previewed index; `Client.Keys` moves
  it, the session refreshes `ids` from each app): `View.Sidebar` marks that item
  `selected`. Not mirrored.
  """

  defstruct [
    :kind,
    :transport,
    :size,
    :cell_px,
    :caps,
    :client,
    viewports: %{},
    hover: nil,
    mode: :terminal,
    swallow: MapSet.new(),
    keybinds: nil,
    capture: false,
    notice: nil,
    runtime: nil,
    last_scene: nil,
    monitor: nil,
    store_monitor: nil,
    held: nil,
    toasts: [],
    pending_alerts: %{},
    focused: nil,
    pointer: %DynideServer.Client.Pointer{},
    pointer_refs: %{},
    facts: %{},
    copy: nil,
    facts_tick: nil,
    graphics: %{},
    window_title: nil,
    hostname: nil,
    drag: nil,
    navigate: nil
  ]

  @type t :: %__MODULE__{
          kind: term(),
          transport: term(),
          size: term(),
          cell_px: {pos_integer(), pos_integer()} | nil,
          caps: term(),
          client: pid() | nil,
          viewports: map(),
          hover: term(),
          mode: :terminal | :prefix | :resize | :copy | :navigate,
          swallow: MapSet.t(),
          keybinds: DynideServer.App.Keybinds.t() | nil,
          capture: boolean(),
          notice: nil | %{level: atom(), text: String.t(), ref: reference()},
          runtime: DynideServer.RuntimeStatus.t() | nil,
          last_scene: term(),
          monitor: reference() | nil,
          store_monitor: reference() | nil,
          held: [tuple()] | nil,
          toasts: [DynideServer.Client.Toasts.toast()],
          pending_alerts: %{optional(pos_integer()) => reference()},
          focused: boolean() | nil,
          pointer: DynideServer.Client.Pointer.t(),
          pointer_refs: map(),
          facts: map(),
          copy: DynideServer.Client.CopyMode.t() | nil,
          facts_tick: DynideServer.Throttle.t(),
          graphics: %{optional(pos_integer()) => [DynideScene.Scene.Graphic.t()]},
          window_title: binary() | nil,
          hostname: binary() | nil,
          drag: %{from: [term()], over: [term()]} | nil,
          navigate: %{ids: [term()], at: non_neg_integer()} | nil
        }
end
