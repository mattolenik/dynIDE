# M10 manual checklist (human, GUI terminal): kitty graphics

The scripted check (`just live-bench-graphics`, see [m10.md](m10.md)) runs both
multiplexers in a fake host over a pty and compares placements structurally. It cannot
see pixels. This checklist covers what only a real terminal shows, against herdr built
from the tag `herdr-reference` (`live/bench/gate/herdr_ref.sh` prints its path).

Record at the top: terminal and version, OS, date, commit (`git rev-parse --short HEAD`).

```
terminal:            version:            OS:            commit:            date:
```

Conventions: `[ ] pass  [ ] fail` boxes. Run in a kitty-graphics terminal: Ghostty
first (it is the only host where the `t=t` file transport is enabled), then kitty.
Start herdr-live with `just live-run` (prefix `ctrl-b`; `ctrl-b v` / `ctrl-b -` split,
`ctrl-b c` then Enter new tab, `ctrl-b n` / `ctrl-b p` next/previous tab, `ctrl-b q` quits), herdr in
a second window at the same size. **Screenshots**: for every row marked **[shot]**, take
one screenshot of each window (macOS: `cmd-shift-4`, space, click the window) and save
them as `docs/herdr-live/results/m10-screens/<row>-herdr.png` and `<row>-live.png`.

Prepare once: `python3 live/bench/graphics/draw.py --help` works; have one PNG photo
(`~/Pictures/x.png` or any) and one large image (over 8 MiB decoded, e.g. a 2000x1500
photo) at hand.

Known deviations from herdr (a row that shows one of these is a pass):
- herdr keeps the last column of each pane free (scrollbar gutter); herdr-live uses it
  and only hides it while scrolled back (M9 ruling 2), so an image clipped at the pane's
  right edge is one column wider in herdr-live.
- A dimming modal (confirm, prompt, settings) hides every image while it is open; herdr
  crops images around the modal box.
- An image that scrolls off or whose tab is hidden is deleted on the host and uploaded
  again when it comes back (herdr keeps up to 16 offscreen images).
- Several placements of one image without an explicit `p=` id whose ghostty ids collide
  with an explicit `p=` of the same image show only one (rare, see m10.md Known gaps).

## A. Placement

| # | Step | Expected | Result |
|---|---|---|---|
| A1 | `ctrl-b v`; left pane: `kitten icat ~/Pictures/x.png` **[shot]** | The image appears at the prompt in the left pane only, clipped at the pane edge, same size and position as herdr's. | [ ] pass  [ ] fail |
| A2 | Right pane: `python3 live/bench/graphics/draw.py` **[shot]** | A grid of images and one unicode-placeholder image, all inside the right pane; no garbage glyphs where the placeholder is. | [ ] pass  [ ] fail |
| A3 | `kitten icat --place 200x10@5x2 ~/Pictures/x.png` in the narrow pane | The image is cropped at the pane's right edge, never drawn over the border or the sidebar. | [ ] pass  [ ] fail |
| A4 | Open the sidebar menu or a toast over an image (e.g. right-click a tab) **[shot]** | The menu/toast is drawn above the image; the image is cut around it with no seams. | [ ] pass  [ ] fail |
| A5 | Open a confirm modal (`ctrl-b x`) over an image, then cancel | The image disappears while the modal is open and comes back after. | [ ] pass  [ ] fail |

## B. Scroll, resize, tabs, close

| # | Step | Expected | Result |
|---|---|---|---|
| B1 | After A1, run `seq 1 20` so the image scrolls up partly off the pane **[shot]** | The visible part stays attached to its rows; the cut-off part is hidden, not drawn over the tab bar. | [ ] pass  [ ] fail |
| B2 | Wheel up over that pane until the image is back, then type a key | The image moves with the scrollback and returns to its place at the bottom. | [ ] pass  [ ] fail |
| B3 | Resize the window narrower and wider **[shot]** | Images stay in their panes, re-clipped; nothing is left behind where a pane used to be. | [ ] pass  [ ] fail |
| B4 | `ctrl-b c`, Enter (new tab), then back with `ctrl-b p` | The images vanish in the new tab and are back, identical, on return. | [ ] pass  [ ] fail |
| B5 | Close the image pane (`exit`) | The image goes away with it; no ghost image remains. | [ ] pass  [ ] fail |
| B6 | `ctrl-b b` toggles the sidebar with an image showing | The image moves with its pane's new rect; nothing is left at the old position. | [ ] pass  [ ] fail |

## C. Reload, restart, exit

| # | Step | Expected | Result |
|---|---|---|---|
| C1 | With an image showing, edit and save `live/apps/herdr_term/lib/herdr_term/client/term/render/graphics.ex` (add a comment) | Status shows a reload; the image stays (or flickers once), no second copy, no ghost. | [ ] pass  [ ] fail |
| C2 | Save a bad edit there (e.g. `raise "x"` at the top of `run/4`), then revert | The image disappears (pass skipped, rolled back), text keeps working, the image returns after the rollback or revert. | [ ] pass  [ ] fail |
| C3 | `ctrl-b q` with images on screen | The host terminal is left clean: no image remains on the main screen. | [ ] pass  [ ] fail |
| C4 | `herdr-live kernel-restart` with an image showing | Text survives; static images are gone (known gap: images do not cross a handoff) and come back when the program redraws (e.g. resize). | [ ] pass  [ ] fail |

## D. Hosts and transports

| # | Step | Expected | Result |
|---|---|---|---|
| D1 | In Ghostty: show the large image | It appears; `ls /tmp/herdr-live-kitty-$(id -u)/` is empty a moment later (the host consumed the temp file). | [ ] pass  [ ] fail |
| D2 | Run herdr-live in Terminal.app and `kitten icat` in a pane | No garbage characters on screen (Terminal.app ignores the APC commands); text works. | [ ] pass  [ ] fail |
| D3 | `herdr-live attach` from a second window (socket client), with the images on screen **[shot]** | The images show in the second client too, at its own size. | [ ] pass  [ ] fail |
| D4 | Same as D3 with the large image (over 8 MiB decoded) | The second client shows `[image WxH]` in its first row instead of the image; the first client shows the image. | [ ] pass  [ ] fail |
| D5 | Over ssh (`ssh localhost`, then `herdr-live attach`) | Images arrive over the socket and are sent inline (no `/tmp` files). | [ ] pass  [ ] fail |
| D6 | An image-heavy TUI if you have one (yazi with image preview, ranger with kitty previews, `chafa -f kitty`, `viu`) | Previews show in the right place and update while moving the selection; nothing left behind. | [ ] pass  [ ] fail |
