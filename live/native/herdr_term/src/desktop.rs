//! Clipboard and URL opening on the client machine through native tools. The
//! tool is spawned on the calling (dirty) thread so "no tool" is answered
//! synchronously; a kernel thread then feeds its stdin and reaps it.

use std::io::{self, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::process::{Child, Command, Stdio};

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
const OPENER: Tool = &["open"];

#[cfg(target_os = "linux")]
const OPENER: Tool = &["xdg-open"];

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
const OPENER: Tool = &[];

/// Spawns the first tool that starts (null stdout/stderr, extra trailing arg
/// `arg`), with a piped stdin when `input` is given, and hands the child to a
/// thread that writes `input`, closes stdin and waits.
fn run(tools: &[&[&str]], arg: Option<&str>, input: Option<Vec<u8>>) -> Result<(), Error> {
    let child = tools
        .iter()
        .find_map(|tool| {
            let (prog, args) = tool.split_first()?;
            Command::new(prog)
                .args(args)
                .args(arg)
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
    // ponytail: if the thread cannot start the child is never reaped (one zombie per failure).
    reap(child, input).map_err(|_| Error::Unavailable)
}

fn reap(mut child: Child, input: Option<Vec<u8>>) -> io::Result<()> {
    std::thread::Builder::new()
        .name("herdr-desktop".into())
        .spawn(move || {
            // Nobody to report to: a failing tool is the same as a slow one.
            let _ = catch_unwind(AssertUnwindSafe(|| {
                if let (Some(bytes), Some(mut stdin)) = (input, child.stdin.take()) {
                    let _ = stdin.write_all(&bytes);
                }
                let _ = child.wait();
            }));
        })
        .map(|_| ())
}

pub fn clipboard_write(text: Vec<u8>) -> Result<(), Error> {
    run(&clipboard_tools(env_set), None, Some(text))
}

pub fn safe_url(url: &str) -> bool {
    url.starts_with("http://") || url.starts_with("https://")
}

pub fn open_url(url: &str) -> Result<(), Error> {
    if !safe_url(url) {
        return Err(Error::BadUrl);
    }
    run(&[OPENER], Some(url), None)
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
            run(&[&["/nonexistent/herdr-tool"]], None, None),
            Err(Error::Unavailable)
        );
        assert_eq!(run(&[], None, Some(b"x".to_vec())), Err(Error::Unavailable));
    }

    #[test]
    fn falls_through_to_the_next_tool_and_feeds_stdin() {
        let dir = std::env::temp_dir().join(format!("herdr-desktop-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("tmp dir");
        let out = dir.join("out");
        let script = format!("cat > '{}'", out.display());
        let tools: [&[&str]; 2] = [&["/nonexistent/herdr-tool"], &["sh", "-c", &script]];
        assert_eq!(run(&tools, None, Some(b"hello".to_vec())), Ok(()));
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
        assert_eq!(
            run(&[&["sh", "-c", &script]], Some("https://x"), None),
            Ok(())
        );
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

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_uses_pbcopy() {
        assert_eq!(clipboard_tools(|_| false), vec![&["pbcopy"][..]]);
    }
}
