//! Clipboard, URL opening, desktop notifications and sound playback on the
//! client machine through native tools. The
//! tool is spawned on the calling (dirty) thread so "no tool" is answered
//! synchronously; a kernel thread then feeds its stdin and reaps it.

use std::io::{self, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// No tool for this platform/session could be spawned.
    Unavailable,
    /// Not an `http://` or `https://` URL.
    BadUrl,
}

type Tool = &'static [&'static str];

fn env_set(var: &str) -> bool {
    std::env::var_os(var).is_some_and(|v| !v.is_empty())
}

#[cfg(target_os = "macos")]
fn clipboard_tools(_env_set: impl Fn(&str) -> bool) -> Vec<Tool> {
    vec![&["pbcopy"]]
}

#[cfg(target_os = "linux")]
fn clipboard_tools(env_set: impl Fn(&str) -> bool) -> Vec<Tool> {
    let mut tools: Vec<Tool> = Vec::new();
    if env_set("WAYLAND_DISPLAY") {
        tools.push(&["wl-copy", "--type", "text/plain;charset=utf-8"]);
    }
    if env_set("DISPLAY") {
        tools.push(&["xclip", "-selection", "clipboard", "-in"]);
        tools.push(&["xsel", "--clipboard", "--input"]);
    }
    tools
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn clipboard_tools(_env_set: impl Fn(&str) -> bool) -> Vec<Tool> {
    Vec::new()
}

#[cfg(target_os = "macos")]
fn notify_tools(_env_set: impl Fn(&str) -> bool) -> Vec<Tool> {
    // `--` so a title starting with `-` is an argument, not an osascript option
    vec![&[
        "/usr/bin/osascript",
        "-e",
        "on run argv",
        "-e",
        "display notification (item 2 of argv) with title (item 1 of argv)",
        "-e",
        "end run",
        "--",
    ]]
}

#[cfg(target_os = "linux")]
fn notify_tools(env_set: impl Fn(&str) -> bool) -> Vec<Tool> {
    if env_set("DISPLAY") || env_set("WAYLAND_DISPLAY") {
        vec![&["notify-send", "--app-name", "herdr-live", "--"]]
    } else {
        Vec::new()
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn notify_tools(_env_set: impl Fn(&str) -> bool) -> Vec<Tool> {
    Vec::new()
}

/// osascript reads both argv items, so the body is always passed.
#[cfg(target_os = "macos")]
const NOTIFY_EMPTY_BODY: bool = true;

/// notify-send takes the body only when there is one.
#[cfg(not(target_os = "macos"))]
const NOTIFY_EMPTY_BODY: bool = false;

/// Trailing notifier arguments: title, then body (see `NOTIFY_EMPTY_BODY`).
fn notify_args<'a>(title: &'a str, body: &'a str) -> Vec<&'a str> {
    if NOTIFY_EMPTY_BODY || !body.is_empty() {
        vec![title, body]
    } else {
        vec![title]
    }
}

#[cfg(target_os = "macos")]
const PLAYERS: &[Tool] = &[&["afplay"]];

// herdr's list: mp3-capable players only (bare `aplay` plays mp3 bytes as PCM).
// ponytail: falls through only when a player cannot spawn, not when it exits
// non-zero (a `paplay` without mp3 support is silent); wait on the exit status
// in the reaper thread if that shows up.
#[cfg(target_os = "linux")]
const PLAYERS: &[Tool] = &[
    &["paplay"],
    &["pw-play"],
    &["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet"],
    &["mpg123", "-q"],
    &["mpv", "--no-video", "--really-quiet"],
];

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
const PLAYERS: &[Tool] = &[];

#[cfg(target_os = "macos")]
const OPENER: Tool = &["open"];

#[cfg(target_os = "linux")]
const OPENER: Tool = &["xdg-open"];

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
const OPENER: Tool = &[];

/// The argv `run` spawns for `tool` with trailing `args`.
fn argv<'a>(tool: &[&'a str], args: &[&'a str]) -> Vec<&'a str> {
    tool.iter().copied().chain(args.iter().copied()).collect()
}

/// Spawns the first tool that starts (null stdout/stderr, trailing `args`), with
/// a piped stdin when `input` is given, and hands the child to a thread that
/// writes `input`, closes stdin and waits.
fn run(tools: &[&[&str]], args: &[&str], input: Option<Vec<u8>>) -> Result<(), Error> {
    let child = tools
        .iter()
        .find_map(|tool| {
            let argv = argv(tool, args);
            let (prog, rest) = argv.split_first()?;
            Command::new(prog)
                .args(rest)
                .stdin(if input.is_some() {
                    Stdio::piped()
                } else {
                    Stdio::null()
                })
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .ok()
        })
        .ok_or(Error::Unavailable)?;
    reap(child, input).map_err(|_| Error::Unavailable)
}

/// Hands the child to a kernel thread that writes `input`, closes stdin and
/// waits. The thread lives as long as the tool: `xdg-open` may block until a
/// browser it started in the foreground exits. When no thread can start, the
/// child is killed and reaped here (no zombie, and a killed clipboard tool
/// never sets an empty clipboard), and the caller falls back.
fn reap(mut child: Child, input: Option<Vec<u8>>) -> io::Result<()> {
    let (tx, rx) = mpsc::channel::<(Child, Option<Vec<u8>>)>();
    let spawned = std::thread::Builder::new()
        .name("herdr-desktop".into())
        .spawn(move || {
            let Ok((mut child, input)) = rx.recv() else {
                return;
            };
            // Nobody to report to: a failing tool is the same as a slow one.
            let _ = catch_unwind(AssertUnwindSafe(|| {
                if let (Some(bytes), Some(mut stdin)) = (input, child.stdin.take()) {
                    let _ = stdin.write_all(&bytes);
                }
            }));
            let _ = child.wait();
        });
    let failed = match spawned {
        Ok(_) => match tx.send((child, input)) {
            Ok(()) => return Ok(()),
            // the thread is gone already: take the child back
            Err(mpsc::SendError((back, _))) => {
                child = back;
                io::Error::other("desktop thread exited")
            }
        },
        Err(err) => err,
    };
    let _ = child.kill();
    let _ = child.wait();
    Err(failed)
}

pub fn clipboard_write(text: Vec<u8>) -> Result<(), Error> {
    run(&clipboard_tools(env_set), &[], Some(text))
}

pub fn safe_url(url: &str) -> bool {
    url.starts_with("http://") || url.starts_with("https://")
}

pub fn open_url(url: &str) -> Result<(), Error> {
    if !safe_url(url) {
        return Err(Error::BadUrl);
    }
    run(&[OPENER], &[url], None)
}

/// A desktop notification: osascript on macOS, notify-send under X11/Wayland.
pub fn notify(title: &str, body: &str) -> Result<(), Error> {
    run(&notify_tools(env_set), &notify_args(title, body), None)
}

/// Plays an audio file with the first player that spawns; returns once spawned.
pub fn play(path: &str) -> Result<(), Error> {
    run(PLAYERS, &[path], None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_http_urls_open() {
        for bad in [
            "file:///etc/passwd",
            "mailto:a@b",
            "javascript:x",
            "",
            "HTTP://x",
        ] {
            assert_eq!(open_url(bad), Err(Error::BadUrl), "{bad}");
        }
        assert!(safe_url("http://x") && safe_url("https://x"));
    }

    #[test]
    fn no_tool_is_unavailable() {
        assert_eq!(
            run(&[&["/nonexistent/herdr-tool"]], &[], None),
            Err(Error::Unavailable)
        );
        assert_eq!(run(&[], &[], Some(b"x".to_vec())), Err(Error::Unavailable));
    }

    #[test]
    fn falls_through_to_the_next_tool_and_feeds_stdin() {
        let dir = std::env::temp_dir().join(format!("herdr-desktop-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("tmp dir");
        let out = dir.join("out");
        let script = format!("cat > '{}'", out.display());
        let tools: [&[&str]; 2] = [&["/nonexistent/herdr-tool"], &["sh", "-c", &script]];
        assert_eq!(run(&tools, &[], Some(b"hello".to_vec())), Ok(()));
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while std::fs::read(&out).ok().as_deref() != Some(b"hello".as_slice()) {
            assert!(std::time::Instant::now() < deadline, "tool never got stdin");
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn trailing_arg_is_passed() {
        let dir = std::env::temp_dir().join(format!("herdr-desktop-arg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("tmp dir");
        let out = dir.join("out");
        let script = format!("printf %s \"$0\" > '{}'", out.display());
        assert_eq!(run(&[&["sh", "-c", &script]], &["https://x"], None), Ok(()));
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while std::fs::read(&out).ok().as_deref() != Some(b"https://x".as_slice()) {
            assert!(std::time::Instant::now() < deadline, "arg not passed");
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_tools_follow_the_session() {
        let only = |set: &'static [&'static str]| move |v: &str| set.contains(&v);
        assert!(clipboard_tools(only(&[])).is_empty());
        let w = clipboard_tools(only(&["WAYLAND_DISPLAY"]));
        assert_eq!(w.iter().map(|t| t[0]).collect::<Vec<_>>(), ["wl-copy"]);
        let all = clipboard_tools(only(&["WAYLAND_DISPLAY", "DISPLAY"]));
        assert_eq!(
            all.iter().map(|t| t[0]).collect::<Vec<_>>(),
            ["wl-copy", "xclip", "xsel"]
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_notify_needs_a_display_and_ends_options() {
        let only = |set: &'static [&'static str]| move |v: &str| set.contains(&v);
        assert!(notify_tools(only(&[])).is_empty());
        for env in [&["DISPLAY"][..], &["WAYLAND_DISPLAY"]] {
            let tools = notify_tools(only(env));
            assert_eq!(
                argv(tools[0], &notify_args("-t", "b")),
                ["notify-send", "--app-name", "herdr-live", "--", "-t", "b"]
            );
            assert_eq!(
                argv(tools[0], &notify_args("t", "")),
                ["notify-send", "--app-name", "herdr-live", "--", "t"]
            );
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_players_are_mp3_capable() {
        let names: Vec<_> = PLAYERS.iter().map(|t| t[0]).collect();
        assert_eq!(names, ["paplay", "pw-play", "ffplay", "mpg123", "mpv"]);
        assert_eq!(
            argv(PLAYERS[2], &["/s.mp3"]),
            [
                "ffplay",
                "-nodisp",
                "-autoexit",
                "-loglevel",
                "quiet",
                "/s.mp3"
            ]
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_notify_and_play_argv() {
        let tools = notify_tools(|_| false);
        assert_eq!(
            argv(tools[0], &notify_args("-t", "")),
            [
                "/usr/bin/osascript",
                "-e",
                "on run argv",
                "-e",
                "display notification (item 2 of argv) with title (item 1 of argv)",
                "-e",
                "end run",
                "--",
                "-t",
                ""
            ]
        );
        assert_eq!(argv(PLAYERS[0], &["/s.mp3"]), ["afplay", "/s.mp3"]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_uses_pbcopy() {
        assert_eq!(clipboard_tools(|_| false), vec![&["pbcopy"][..]]);
    }
}
