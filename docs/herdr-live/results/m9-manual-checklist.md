# M9 manual checklist (human, GUI terminal): terminal fidelity

The scripted checks (`just live-bench-fidelity`, see [m9.md](m9.md)) run in a fake host
over a pty. They cannot judge look and feel, the real system clipboard, a real browser,
or real host themes. This checklist covers those, item by item, against herdr's
behaviour. herdr's behaviour is taken from the tag `herdr-reference` (research notes
`.superpowers/sdd/m9/research/*.md`, not committed). Rows marked **[human judges]**
need a judgement of look or feel, not just a yes/no.

Record at the top: terminal and version, OS, host theme (light/dark), date, commit
(`git rev-parse --short HEAD`).

```
terminal:            version:            OS:            theme:            commit:            date:
```

Conventions: `[ ] pass  [ ] fail` boxes. "Window A" is the GUI terminal under test (run
it in Ghostty or iTerm2 first; section M repeats the clipboard items in Terminal.app).
Start with `just live-run` in window A (prefix `ctrl-b`; `ctrl-b v` / `ctrl-b -` split,
`ctrl-b c` new tab, `ctrl-b q` quits). Run it outside any other herdr-live instance.
Prepare once: `seq 1 5000 > /tmp/m9-seq.txt` and `head -c 4194304 /dev/urandom | base64 > /tmp/m9-big.txt`
(about 5.6 MB of text). For the ssh items you need `ssh localhost` working.

Known deviations from herdr are listed in section N. A row that shows one of those is a
pass.

## A. Scrollback: wheel, keys, scrollbar

| # | Step | herdr does | Result |
|---|---|---|---|
| A1 | In a shell pane: `cat /tmp/m9-seq.txt`, then wheel up 3 notches | Each notch scrolls 3 lines (9 total). Earlier numbers show; the prompt is off screen. | [ ] pass  [ ] fail |
| A2 | Look at the rightmost column while scrolled back **[human judges]** | A scrollbar: track `▕`, thumb `▐` in the focused pane; unfocused pane thumb `▕`. Thumb length and position look proportional. herdr reserves a gutter column; herdr-live draws over the last content column (ruling 2), so the last character of long lines is hidden while scrolled. Note whether the look is acceptable: ______ | [ ] pass  [ ] fail |
| A3 | In a pane run `while :; do date; sleep 0.2; done`, then wheel up a few notches and watch for 10 s; then try the same with `yes` **[human judges flicker]** | The viewport stays pinned on the rows you scrolled to while new output arrives; the thumb creeps as history grows. No flicker; with `yes` the rest of the UI stays responsive. | [ ] pass  [ ] fail |
| A4 | Scrolled back, type a key (e.g. `x`) | The pane snaps to the bottom and the key reaches the shell (it is not lost). | [ ] pass  [ ] fail |
| A5 | At a shell prompt: press PageUp, then PageDown | PageUp scrolls one full pane height of host scrollback; PageDown back. Nothing typed at the prompt. | [ ] pass  [ ] fail |
| A6 | In `less /tmp/m9-seq.txt` (and in `vim`): PageUp/PageDown and the wheel | The keys go to the program (it pages itself); the wheel scrolls the program (alternate screen: arrow keys per notch), not the host scrollback. No scrollbar. | [ ] pass  [ ] fail |
| A7 | Scrolled back: click on the scrollbar track high up, then drag the thumb | Track click centres the thumb on the click row; dragging the thumb keeps the grab offset and follows smoothly **[human judges smoothness]**. | [ ] pass  [ ] fail |
| A8 | Two panes: wheel over the unfocused pane | It gets focus and scrolls. | [ ] pass  [ ] fail |

## B. Mouse selection and copy-on-select

| # | Step | herdr does | Result |
|---|---|---|---|
| B1 | `echo hello world`, drag over `hello` | Selection appears while dragging; on release it is copied and cleared. Notice "copied to clipboard". In another app, paste: `hello`. | [ ] pass  [ ] fail |
| B2 | Selection colour **[human judges]**, under a dark host theme and a light one | Not inverse when the host answered its colours: host background mixed 28% toward white (dark host) or black (light host), text black or white for contrast. Note readability: ______ | [ ] pass  [ ] fail |
| B3 | Double-click `world` | Word selected, copied, highlight kept about 500 ms. Double-click a URL: the whole URL without trailing `.,)` etc. Double-click inside `"/a b/c"`: the quoted path. | [ ] pass  [ ] fail |
| B4 | Double-click then drag | Extends by whole words both ways; copied and cleared on release. | [ ] pass  [ ] fail |
| B5 | Two side-by-side panes: start a drag in the left pane, move the pointer into the right pane | The selection stays clamped to the left pane's rectangle (does not cross into the neighbour). | [ ] pass  [ ] fail |
| B6 | `cat /tmp/m9-seq.txt`; start a drag and move the pointer onto the pane's top row, then above the pane | Autoscroll: on the edge row 1 line per ~30 ms; beyond the edge a first jump of 3-15 lines; the selection grows into history. Back inside, it stops. Wheel during the drag scrolls and extends. | [ ] pass  [ ] fail |
| B7 | Make a selection, then resize window A / switch focus to another pane | The selection is cleared (geometry change, focus move). | [ ] pass  [ ] fail |
| B8 | In `htop` or `vim` with `:set mouse=a`: drag | The child gets the drag (vim visual selection); no host selection. | [ ] pass  [ ] fail |
| B9 | Clipboard into the real host clipboard **[human judges]** (local session, no ssh): select text, paste it into another macOS app | Arrives via `pbcopy` (Linux: wl-copy, xclip or xsel). | [ ] pass  [ ] fail |
| B10 | OSC 52 over ssh: in window A, `ssh localhost`, then run `live/bin/herdr-live` (or `just live-run`) on the remote side; select text | With `SSH_TTY` set the client writes OSC 52 only. Ghostty/iTerm2 (OSC 52 allowed) put it in the local clipboard. | [ ] pass  [ ] fail |

## C. Copy mode

`ctrl-b [` enters copy mode. The status line shows `COPY` in the accent colour.

| # | Step | herdr does | Result |
|---|---|---|---|
| C1 | `cat /tmp/m9-seq.txt`, `ctrl-b [` | Copy cursor (accent, bold, inverse cell) at the terminal cursor. | [ ] pass  [ ] fail |
| C2 | `h j k l`, arrows, `C-u C-d`, `C-b C-f`, PageUp/PageDown, `g`, `G`, `0`, `$`, `^` | Cursor moves as in herdr/vi; the viewport follows to keep it visible; `g` goes to the top of history. | [ ] pass  [ ] fail |
| C3 | `w b e W B E`, `{ }` on a few lines of prose (`man ls`, then `q`, then scroll) | Word motions over whitespace/separator/word classes; `{ }` to the nearest blank row. | [ ] pass  [ ] fail |
| C4 | `v`, move, `y` | Character selection shown; `y` copies and exits; scroll returns to where you entered (or to the bottom if you entered there). Paste elsewhere: the text. | [ ] pass  [ ] fail |
| C5 | `V`, `j j`, Enter | Line selection over full rows; Enter copies whole lines. | [ ] pass  [ ] fail |
| C6 | `/4321` Enter, then `n`, `N`; `?12` Enter | Status shows `/4321` while typing. Matches underlined, the current one accent and inverse. `n`/`N` step. Smart case: `/Foo` is case-sensitive, `/foo` is not. | [ ] pass  [ ] fail |
| C7 | `/zzzz-not-there` Enter on a long history (`seq 1 20000`) | Notice "no match for zzzz-not-there". Time it feels **[human judges]**: ______ (benched, see m9.md). | [ ] pass  [ ] fail |
| C8 | Search, then `y` with no selection | Copies the current match. | [ ] pass  [ ] fail |
| C9 | Esc (once: clears selection and search), Esc again (exits); `q` exits | As described. | [ ] pass  [ ] fail |
| C10 | In copy mode, click another pane | herdr pauses copy mode and resumes it when focus returns; herdr-live **ends** copy mode (deviation N5). | [ ] pass  [ ] fail |

## D. Links

| # | Step | herdr does | Result |
|---|---|---|---|
| D1 | `echo 'see https://example.com/a_(b) and (https://example.com/x).'`; hold Ctrl and move over each URL **[human judges hover feel]** | Underline under the URL while Ctrl is held and the pointer is on it (balanced `)` kept, trailing `).` not); any other mouse event clears it. | [ ] pass  [ ] fail |
| D2 | Ctrl+click the URL | Opens in the default browser on this machine (`open` / `xdg-open`). The click is not passed to the shell. | [ ] pass  [ ] fail |
| D3 | OSC 8 link: `printf '\e]8;;https://example.com/osc8\e\\osc8 link\e]8;;\e\\\n'`; Ctrl+hover, Ctrl+click | Hover underlines the run; Ctrl+click opens `https://example.com/osc8`. | [ ] pass  [ ] fail |
| D4 | Unsafe link: `printf '\e]8;;file:///etc/passwd\e\\file link\e]8;;\e\\\n'`; Ctrl+click | Never opened (only http/https). | [ ] pass  [ ] fail |
| D5 | Ctrl+click a URL in `vim` with `mouse=a` | Still opens (Ctrl+click wins over child mouse tracking). | [ ] pass  [ ] fail |
| D6 | A URL soft-wrapped over two rows (narrow pane) | Hover and click cover both rows. (Heuristic: the text-URL join across rows can join unrelated full-width text; known gap.) | [ ] pass  [ ] fail |

## E. Child OSC 52, bell, title and cwd

| # | Step | herdr does | Result |
|---|---|---|---|
| E1 | `printf '\e]52;c;%s\a' "$(printf child-clip \| base64)"`, then paste elsewhere | The host clipboard holds `child-clip` (local: pbcopy; ssh: OSC 52). Only the foreground client gets it. | [ ] pass  [ ] fail |
| E2 | `printf '\e]52;c;?\a'` | Nothing happens: clipboard reads are never answered. | [ ] pass  [ ] fail |
| E3 | `printf '\a'` (and `sleep 2; printf '\a'` while focused on another pane) | The host terminal rings (sound or visual bell per its settings) in both cases. | [ ] pass  [ ] fail |
| E4 | Split, then in one pane `printf '\e]2;my-title\a'` | The title shows in that pane's top border; with one pane, in the status row. | [ ] pass  [ ] fail |
| E5 | `cd /tmp` in a zsh pane, `ctrl-b q`, `just live-run` again | herdr uses the OSC 7 cwd for the pane. herdr-live tracks it in `Pane.Facts` but shows it nowhere yet; persistence uses the shell's process cwd first and the OSC 7 cwd as fallback, so the pane restarts in `/tmp` either way. Informational. | [ ] pass  [ ] fail |

## F. Colours and host theme

| # | Step | herdr does | Result |
|---|---|---|---|
| F1 | Dark host theme: open `vim` (with `:syntax on`), `nvim`, `htop` **[human judges]** | Colours match the same programs run directly in window A (the panes get the host's fg, bg and 256-colour palette, so programs that ask with OSC 10/11/4 see the real host colours). | [ ] pass  [ ] fail |
| F2 | Light host theme: same programs **[human judges]** | Same. `nvim` picks `background=light` (it asks OSC 11). | [ ] pass  [ ] fail |
| F3 | With herdr-live running, flip the OS theme (System Settings > Appearance) in a terminal that follows it (Ghostty, iTerm2 with auto theme) **[human judges]** | The host reports the change (mode 2031); herdr-live re-queries the colours and updates every pane. A program with mode 2031 on (nvim 0.10+) gets the `CSI ? 997 ; n n` report and switches. | [ ] pass  [ ] fail |
| F4 | In a pane: `printf '\e]11;?\e\\'; read -t1 -rs x; printf '%q\n' "$x"` (bash) | Prints the host background as `rgb:rrrr/gggg/bbbb`. | [ ] pass  [ ] fail |

## G. Cursor shape

| # | Step | herdr does | Result |
|---|---|---|---|
| G1 | In vim: insert mode then normal mode (needs `let &t_SI = "\e[6 q"`, `let &t_EI = "\e[2 q"`, or nvim's defaults) | Bar in insert, block in normal. | [ ] pass  [ ] fail |
| G2 | `printf '\e[3 q'`, then `printf '\e[0 q'` | Underline, then back to your own terminal cursor style. | [ ] pass  [ ] fail |
| G3 | Quit herdr-live | Your own cursor style is back. | [ ] pass  [ ] fail |

## H. Bracketed paste

| # | Step | herdr does | Result |
|---|---|---|---|
| H1 | Copy `/tmp/m9-big.txt` (about 5.6 MB) to the clipboard (`pbcopy < /tmp/m9-big.txt`). In a pane run `cat > /tmp/m9-pasted.txt`, paste with Cmd-V, wait, then Ctrl-D. Then `cmp /tmp/m9-big.txt /tmp/m9-pasted.txt` | herdr rejects pastes over 1 MiB; herdr-live writes up to 16 MiB through a retrying queue (ruling 3), so `cmp` prints nothing. Typing during the paste lands after it. Note how long it took: ______ | [ ] pass  [ ] fail |
| H2 | Paste a multi-line snippet at a zsh/bash prompt | The shell receives it as one bracketed paste (not executed line by line). | [ ] pass  [ ] fail |
| H3 | Paste a 20 MB file | Notice "paste rejected: N bytes (max 16777216)"; nothing is written. | [ ] pass  [ ] fail |
| H4 | Start a big paste into `cat`, press Ctrl-C while it is still flowing | Ctrl-C is queued behind the paste (order kept), so it cannot cancel it (deviation N6). The paste completes, then cat stops. | [ ] pass  [ ] fail |

## I. Focus reports

| # | Step | herdr does | Result |
|---|---|---|---|
| I1 | Two panes. In one: `vim -c 'au FocusGained * echo "gained"' -c 'au FocusLost * echo "lost"'` (vim needs `set t_fe=... ` only in some builds; nvim works out of the box). Click the other pane, then back | `lost` when you leave, `gained` when you return. | [ ] pass  [ ] fail |
| I2 | Same, but switch window A to another app and back | The pane gets lost/gained from the host's own focus reports. | [ ] pass  [ ] fail |
| I3 | Without vim: `printf '\e[?1004h'; cat -v`, switch panes | `^[[O` when leaving, `^[[I` when returning. Ctrl-C, then `printf '\e[?1004l'`. | [ ] pass  [ ] fail |

## J. Query roundtrips

| # | Step | herdr does | Result |
|---|---|---|---|
| J1 | `python3 live/bench/fidelity/child_queries.py /tmp/m9-q.txt; cat /tmp/m9-q.txt` in a pane | DA1 `\x1b[?62;22c`, DA2 `\x1b[>1;0;0c`, DSR 5n `\x1b[0n`, 6n `\x1b[<row>;<col>R`, XTVERSION `libghostty`, kitty `\x1b[?0u`, DECRQM 2004, OSC 11 with the host bg, XTGETTCAP TN `xterm-256color`. All answered, none leak to the screen. | [ ] pass  [ ] fail |

## K. Resize reflow

| # | Step | herdr does | Result |
|---|---|---|---|
| K1 | Print a long line: `python3 -c 'print("x"*300)'`, plus some `seq 1 50`; narrow window A a lot, then widen it back | The long line rewraps at the narrow width and is restored on widen; no lost or duplicated rows; the prompt stays at the bottom. (Scripted against herdr in `reflow.py`.) | [ ] pass  [ ] fail |
| K2 | Scrolled back by ~20 lines, resize | The offset from the bottom is kept (same rows near the bottom). | [ ] pass  [ ] fail |
| K3 | `htop` or `vim` during a resize | Redraws at the new size without debris. | [ ] pass  [ ] fail |

## L. Keys (legacy fallbacks)

| # | Step | herdr does | Result |
|---|---|---|---|
| L1 | In a plain shell (`cat -v`): Ctrl-Shift-A, Ctrl-I, Ctrl-M, Ctrl-[, Shift-Enter, Cmd-C | `^A`, tab, enter, Esc; Shift-Enter is a plain enter; Cmd chords are dropped (not typed as `c`). | [ ] pass  [ ] fail |
| L2 | Same in a kitty-protocol program (e.g. `kitty +kitten show_key -m kitty` if available, or nvim with `:map <S-CR>`) | Shift-Enter is distinguished (`CSI 13;2 u`). | [ ] pass  [ ] fail |

## M. Host terminals

| # | Step | herdr does | Result |
|---|---|---|---|
| M1 | Repeat B1, B9, E1 in **Terminal.app** (no OSC 52) **[human judges]** | Local: pbcopy works (no OSC 52 needed). Over ssh (B10 in Terminal.app): OSC 52 is ignored by Terminal.app, so nothing reaches the clipboard. herdr behaves the same. | [ ] pass  [ ] fail |
| M2 | Repeat B2, F1-F3 in Terminal.app | Terminal.app answers OSC 10/11/4 but not mode 2031 (no live theme flip); colours otherwise right. | [ ] pass  [ ] fail |
| M3 | Repeat A1, B1, D2, F1 in iTerm2 and in Ghostty **[human judges]** | Same results; note any terminal-specific artefact: ______ | [ ] pass  [ ] fail |

## N. Known deviations from herdr (verify they are as described, not worse)

| # | Deviation | Check | Result |
|---|---|---|---|
| N1 | One viewport per pane (ruling 1): with two clients on one pane, scrolling in one scrolls the other (tmux-like). Needs M16 for a second terminal; an in-VM second client is not available by hand. | Skip unless a second client exists. | [ ] as described  [ ] skipped |
| N2 | No scrollbar gutter (ruling 2): the scrollbar covers the last content column while scrolled back. | A2. | [ ] as described |
| N3 | Pastes up to 16 MiB, embedded `ESC[201~` removed (ruling 3): herdr rejects over 1 MiB and passes the marker. | H1, H3. | [ ] as described |
| N4 | Foreground client = the latest to send slow-path input or attach (ruling 4). | Single client: always yours. | [ ] as described |
| N5 | Focus move ends copy mode (herdr pauses it). | C10. | [ ] as described |
| N6 | Ctrl-C cannot cancel a paste that is still queued. | H4. | [ ] as described |
| N7 | A steady block cursor set with `CSI 2 q` shows as your own cursor style (ruling 6). | `printf '\e[2 q'` with a bar as your terminal's cursor: you see the bar. | [ ] as described |
| N8 | Host colours: a host that answers nothing gets no colours for 5 s, then none; partial answers unset the missing ones. | Informational. | [ ] as described |
| N9 | Copy mode: new output does not clear search matches; geometry change does not drop the copy selection. | Informational. | [ ] as described |
| N10 | macOS Option-as-Alt with non-ASCII text in a legacy pane (Alt+Shift+ö -> `ESC Ö` in herdr) is not ported. | Informational. | [ ] as described |
| N11 | The pane focus report always sends Gained to the new pane (herdr sends Lost when the host window is unfocused). | Informational. | [ ] as described |

Notes:

## Sign-off

- [ ] Every step above passed, or each failure is recorded in the notes with the step id.
- Verdict: ______  Signed: ______  Date: ______
