# herdr reference chrome inventory (input to M13)

Surveyed from tag `herdr-reference` (paths relative to its root; line numbers approximate).
Rendering lives in the client (`src/client/shell/*`); `src/ui/*` holds shared helpers.
Glyphs and labels are quoted as they appear in the source. This is the reference for the
M13 side-by-side review; herdr-live ports behaviour, never code.

## 1. Screen layout
`src/client/shell/config.rs:385` `layout()`
- Mobile mode when `cols <= ui.mobile_width_threshold` (64): 2-row header, no sidebar, no tab bar.
- Desktop: sidebar at x=0, full height, width `ui.sidebar_width` 26 clamped [18, 36], capped at cols-1.
- Collapsed sidebar: 4 cols (`compact`, default) or 0 (`hidden`); `ui.sidebar_start_collapsed` false.
- Tab bar: one row across the main area, top by default (`ui.tab_bar_position` top|bottom); hidden when rows<=1 or `hide_tab_bar_when_single_tab` with one tab.
- No permanent status bar: a one-row "mode bar" is painted over the bottom pane row while not in Terminal mode (`render.rs:31`), hidden while an overlay is open.
- Sidebar right edge: a `│` column in `surface_dim`, also the resize handle.
- Minimum pane 2 rows x 4 cols (`src/pane.rs:74`).

## 2. Sidebar
Expanded (`client/shell/sidebar.rs:200-455`, `ui/sidebar.rs:22-77`): content width-1, split by `sidebar_section_split` 0.5 (0.1-0.9), each section >= 3 rows.
- "spaces" section: header `" spaces"` (overlay0 bold), blank row, scrollable list, footer `" new"` (left, NewWorkspace) and `"menu"` right-aligned (global menu; `"● menu"` with accent dot on attention).
- "agents" section: `─` divider row (draggable split), header `" agents"` with right-aligned sort label `"grouped"`/`"priority"` (click toggles), body; empty `" no matching agents"` only under an agent view.
- `«` at (right-2, bottom-1) collapses; `»` bottom-centre expands. Scrollbars `▕`, wheel one entry per notch.
- Space row tokens default `[["state_icon","workspace"],["branch","git_status"]]`; agent rows `[["state_icon","machine","workspace","tab"],["agent"]]` (`ui/sidebar/tokens.rs`, `config/sidebar.rs`). Separators `" · "` (overlay0), a single space after `state_icon`; missing values drop with their separator; flexible tokens truncate with `…`.
- State indicators (`client/shell.rs:178-235`): blocked `●`/`×` red (prio 4), done `●`/`✓` teal (3), working `●`/`◐` yellow (2), idle `○` green (1), unknown `·` overlay0 (0). Default "dots"; `ui.status_indicators="symbols"`.
- Row backgrounds: focused workspace `active_row_bg`; no hover highlight.
- Collapsed: index padded to 2 then status icon; `─`; agents list at height >= 7.
- Mouse (`mouse.rs:1933-2200`): click `«`/`»`; drag `│` to resize (width = column+1, clamped; double-click resets); drag agents divider; click workspace focuses on release; drag >= 1 cell reorders; click agent focuses its pane; right-click workspace menu. Width/split/collapse stored per client in JSON state, not config.
- Keyboard: navigate mode `prefix+w`: up/down move, 1..9 jump, enter opens, esc leaves.

## 3. Tabs and workspaces
- Workspace = project container (sidebar "space") owning tabs; tab = pane layout. Tab bar shows the focused workspace's tabs. Workspace default name from cwd (fallback `"workspace"`); tab default name its 1-based index.
- Tab bar (`client/shell/tabs.rs`): bg `panel_bg`; each tab is the label centred in label+4 (min 8), 1-cell gap; focused `panel_bg` on `accent`; others `overlay0` on `surface0`; no index prefix, no close buttons; `" + "` new-tab button after the last tab; overflow `" < "`/`" > "` and `…`.
- Mouse: click focuses on release; drag reorders; wheel = previous/next tab; right-click tab menu; `+` runs NewTab with a `"new tab"` name prompt (prefilled next number).
- Rename via context menu or `prefix+shift+t` (tab), `prefix+shift+w` (workspace), `prefix+shift+p` (pane).

## 4. Panes, borders, splits
`src/ui/panes.rs`: `ui.pane_borders` auto (borders with >1 pane)|always|off; `pane_gaps` true (own box per pane); square box glyphs `┌┐└┘│─`; focused border `accent`, others `overlay0`; no inactive dim. Title in the top border at x+1 as `" label "`, truncated to width-4 with `…`, accent bold when focused. Scrollbar gutter `▐` (M9).
Split drag (`server/client_shell.rs:573`, `mouse.rs:441`): hit zone the divider (with gaps the 2 cells either side), grab offset kept, ratio clamped 0.1-0.9, sent at most every 33 ms plus a final value on release.

## 5. Overlays
- Panel: square border in accent (red for close confirmation), bg `panel_bg`, centred, clipped to area minus 4 cols and 2 rows. Opening a modal dims the whole frame (except Go to and menus). One overlay at a time (`state.rs:583`). Layout: header / content / footer / actions (`ui/widgets.rs:38`). Buttons are labels like `" ↵ save "`; primary panel-bg on accent, secondary `text` on `surface0` bold.
- Onboarding (`ui/onboarding.rs`, `overlays.rs:540`): width max(hint+5, 64), height 16. Lines `"  herdr"` (bold), `"  terminal workspace manager for coding agents"` (muted), `"  this is a mouse-first terminal."`, `"  click the sidebar to switch workspaces, drag pane"`, `"  borders to resize, right-click for context menus."`, `"  <prefix> enters prefix mode · ? shows keybinds and settings"`, `"  next: install optional agent integrations for more reliable state"`, button `" ↵ continue "`. Dismissed by Enter/Right/l/click; Esc does not dismiss. Continuing writes `onboarding = false`.
- Release notes / product announcement: out of scope for herdr-live (no releases yet).
- Rename / new name (56x7): titles `"new workspace"`, `"rename workspace"`, `"new tab"`, `"rename tab"`, `"rename pane"`; input row on surface0; buttons `" ↵ save "`, `" ^c clear "`, `" esc cancel "`; click outside cancels.
- Close confirmation (64x6, red border): `" Close workspace?"`, detail `" <name> — 1 pane"`/`"N panes"`; buttons `" ↵ confirm "` (red), `" esc cancel "`; only when `ui.confirm_close` (true) and the action removes a whole workspace.
- Keybinds help (76x22, `prefix+?`): title `"keybinds"`, `" esc close "`, search `" / press / to filter by command or shortcut"`, groups `global`, `navigation`, `workspaces / tabs`, `panes`, `custom`; unbound shows `unset`; footer `" search / · scroll j/k/↑↓/pgup/pgdn · close esc/enter"`; empty `" no matching keybinds"`.
- Go to navigator (`prefix+g`), worktree overlays: out of M13 scope (need M11 agents / git).
- Context menus (`context_menu.rs`): at click position, width max label+4 (min 14), highlighted row accent bg, hover moves highlight, Up/Down/Enter/Esc, click outside closes. Tab: `New tab`, `Rename`, `Close`. Workspace: `Rename`, `Close`. Pane: `Rename pane`, `Clear pane name`, `Swap with focused pane`, `Split right`, `Split down`, `Zoom`, ..., `Close pane`.
- Global menu (`global_menu.rs`): above the sidebar `menu` launcher; items `settings`, `keybinds`, `reload config`, `detach`.

## 6. Settings
`settings.rs`, `settings_overlay.rs`: `prefix+s` or global menu; 76x22; title `" settings"`; section tabs `theme · indicators · sound · toasts · integrations`; a `─` rule; choice rows `" ▸ label ✓"`.
- theme: 18 built-ins, cursor live-previews, Esc restores, apply writes `[theme] name`.
- indicators: `"agent status indicators"` / `"choose color dots or distinct symbols for each state"` / `"color dots  ● ● ● ○ ·"`, `"distinct symbols  × ◐ ✓ ○ ·"`.
- sound: `"sound alerts"` / `"play sounds when agents change state in background"` / `on`, `off`.
- toasts: `"notification popups"` / `"choose where background popup notifications should appear"` / `off`, `inside herdr`, `via terminal`, `via system`.
- Buttons `" ↵ apply "`, `" esc close "`, hint `" ↑↓ select  tab section"`. Keys Tab/→/l, BackTab/←/h, ↑↓/j/k, Enter/Space applies. Choice fields only (no keybind capture in herdr).
- Persistence: in-place TOML upsert into config.toml (`config/write.rs`), then reload.

## 7. Theme
Palette tokens (`app/state.rs:30-75`): accent, panel_bg, sidebar_bg, active_row_bg, selection_bg, surface0, surface1, surface_dim, overlay0, overlay1, text, subtext0, mauve, green, yellow, red, blue, teal, peach. Default catppuccin (Mocha). Built-ins (`config/theme.rs:4`): catppuccin, catppuccin-latte, terminal, tokyo-night, tokyo-night-day, dracula, nord, gruvbox, gruvbox-light, one-dark, one-light, solarized, solarized-light, kanagawa, kanagawa-lotus, rose-pine, rose-pine-dawn, vesper. Host detection (`terminal_theme.rs`): OSC 10/11, DSR `CSI ?996n` (`?997;1n` dark, `;2n` light), else OSC 11 luminance 299R+587G+114B >= 128000 is light; COLORFGBG not used. `theme.auto_switch` uses `light_name`/`dark_name`.

## 8. Config file
TOML at `~/.config/herdr/config.toml` (`HERDR_CONFIG_PATH` overrides). Invalid values fall back with a diagnostic. Reload manual (`prefix+shift+r`, menu). Key syntax (`config/keybinds.rs:1290`): `+`-joined modifiers `ctrl`/`control`, `alt`/`option`/`meta`, `shift`, `cmd`/`command`/`super`; keys single chars (uppercase implies shift), `space`, `enter`/`return`, `esc`/`escape`, `tab`, `backspace`, arrows, `f1..`; named punctuation `minus`, `comma`, `period`, `slash`, `backslash`, `quote`, `semicolon`, `colon`, `plus`, ...; `prefix+X` means after the prefix; values may be arrays.
Default `[keys]`: prefix `ctrl+b`; help `prefix+?`; settings `prefix+s`; detach `prefix+q`; reload_config `prefix+shift+r`; new_workspace `prefix+shift+n`; rename_workspace `prefix+shift+w`; close_workspace `prefix+shift+d`; workspace_picker `prefix+w`; new_tab `prefix+c`; rename_tab `prefix+shift+t`; previous_tab `prefix+p`; next_tab `prefix+n`; switch_tab `prefix+1..9`; close_tab `prefix+shift+x`; rename_pane `prefix+shift+p`; focus_pane_* `prefix+h/j/k/l`; swap_pane_* `prefix+shift+h/j/k/l`; cycle_pane_next/previous `prefix+tab`/`prefix+shift+tab`; split_vertical `prefix+v`; split_horizontal `prefix+minus`; close_pane `prefix+x`; zoom `prefix+z`; resize_mode `prefix+r`; toggle_sidebar `prefix+b`.

## 9. Notifications and sound
Triggers (`app/actions.rs:22-140`): blocked -> `"<agent> needs attention"` (Request sound); working/blocked -> idle `"<agent> finished"` (Done sound); body `"<workspace> · <n>[ · <tab>]"`. Pane BEL is forwarded as a bell to the outer terminal, not a toast. Policy (`notification_policy.rs`): delay `ui.toast.delay_seconds` 1; target active (focused tab) suppresses toasts and the Done sound while the outer terminal is focused; queue 8; visible 8 s (attention), 5 s (finished). Delivery `ui.toast.delivery` off|herdr|terminal|system; in-app card bottom-right, border overlay0, `●` red/blue, width text+6; click focuses the pane. Terminal delivery OSC 9 / OSC 99. Sound: built-in done/request sounds through afplay/paplay...; `[ui.sound] enabled` true, `path`, `done_path`, `request_path`; no external hook command.

## 10. Mode bar
`render.rs:31-230`: PREFIX `" PREFIX "` pill then `esc cancel  <prefix> send prefix  w workspace nav  ? keybinds`; NAVIGATE; RESIZE pill then `h/l width  j/k height  esc done`; ERROR pill; config diagnostics yellow at top right.

## 11. Mouse affordances
Hover feedback only for menu rows (and link hover, M9). Sidebar buttons `" new"`, `"menu"`, `«`/`»`; tab bar `" + "`, `" < "`/`" > "`; modal buttons clickable; clicking outside a modal cancels (except onboarding); toasts focus their pane; drag targets sidebar width, section split, workspace and tab reorder, pane splits; right-click opens workspace/tab/pane menus. `ui.mouse_capture=false` removes chrome hit targets.
