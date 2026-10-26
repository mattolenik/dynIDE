//! Foreground job of a pane's terminal: the processes of one process group, with names
//! and argv. Ported from herdr's `src/platform/{macos,linux}.rs`. Bounded: at most
//! `MAX_PROCS` processes, `MAX_ARGS` argv entries each at most `MAX_ARG` bytes.

use rustler::NifMap;

pub const MAX_PROCS: usize = 64;
pub const MAX_ARGS: usize = 64;
pub const MAX_ARG: usize = 4096;

#[derive(Debug, Clone, PartialEq, Eq, NifMap)]
pub struct Process {
    pub pid: u32,
    pub name: String,
    pub argv: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, NifMap)]
pub struct Job {
    pub pgid: u32,
    /// The group is the pane child's own: nothing runs in the foreground.
    pub shell: bool,
    pub processes: Vec<Process>,
}

/// The processes in group `pgid`, or None when none can be read.
pub fn foreground_job(pgid: u32, shell_pid: u32) -> Option<Job> {
    if pgid == 0 {
        return None;
    }
    let processes = group_processes(pgid, shell_pid);
    (!processes.is_empty()).then_some(Job {
        pgid,
        shell: pgid == shell_pid,
        processes,
    })
}

/// Lossy UTF-8, cut to at most `MAX_ARG` bytes on a char boundary.
fn arg(bytes: &[u8]) -> String {
    let mut s = String::from_utf8_lossy(&bytes[..bytes.len().min(MAX_ARG + 3)]).into_owned();
    if s.len() > MAX_ARG {
        let mut end = MAX_ARG;
        while !s.is_char_boundary(end) {
            end -= 1;
        }
        s.truncate(end);
    }
    s
}

/// NUL-separated strings, at most `MAX_ARGS`.
#[cfg(any(target_os = "linux", test))]
fn split_args(bytes: &[u8]) -> Vec<String> {
    let bytes = bytes.strip_suffix(&[0]).unwrap_or(bytes);
    if bytes.is_empty() {
        return Vec::new();
    }
    bytes.split(|&b| b == 0).take(MAX_ARGS).map(arg).collect()
}

#[cfg(target_os = "macos")]
const PROC_PGRP_ONLY: u32 = 2;

#[cfg(target_os = "macos")]
fn group_processes(pgid: u32, _shell_pid: u32) -> Vec<Process> {
    let mut pids = vec![0 as libc::pid_t; MAX_PROCS];
    let size = std::mem::size_of_val(pids.as_slice()) as libc::c_int;
    // SAFETY: the buffer holds `size` bytes of pid_t.
    let got = unsafe { libc::proc_listpids(PROC_PGRP_ONLY, pgid, pids.as_mut_ptr().cast(), size) };
    let n = (got.max(0) as usize / std::mem::size_of::<libc::pid_t>()).min(MAX_PROCS);
    let mut pids: Vec<u32> = pids[..n]
        .iter()
        .filter(|&&p| p > 0)
        .map(|&p| p as u32)
        .collect();
    pids.sort_unstable();
    pids.into_iter()
        .filter_map(|pid| {
            Some(Process {
                pid,
                name: proc_name(pid)?,
                argv: kern_procargs2(pid)
                    .map(|b| procargs2_argv(&b))
                    .unwrap_or_default(),
            })
        })
        .collect()
}

#[cfg(target_os = "macos")]
fn proc_name(pid: u32) -> Option<String> {
    let mut buf = [0u8; 256];
    // SAFETY: proc_name writes at most `buf.len()` bytes.
    let n = unsafe {
        libc::proc_name(
            pid as libc::c_int,
            buf.as_mut_ptr().cast(),
            buf.len() as u32,
        )
    };
    (n > 0).then(|| String::from_utf8_lossy(&buf[..n as usize]).into_owned())
}

/// Raw `sysctl(KERN_PROCARGS2)`: `[argc: i32][exec_path\0][\0 padding][argv\0...][env...]`.
#[cfg(target_os = "macos")]
fn kern_procargs2(pid: u32) -> Option<Vec<u8>> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid as libc::c_int];
    let mut size: libc::size_t = 0;
    // SAFETY: a size query with a null buffer.
    let r = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if r != 0 || size == 0 {
        return None;
    }
    let mut buf = vec![0u8; size];
    // SAFETY: `buf` holds `size` bytes; sysctl updates `size` to what it wrote.
    let r = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buf.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if r != 0 {
        return None;
    }
    buf.truncate(size);
    Some(buf)
}

#[cfg(any(target_os = "macos", test))]
fn procargs2_argv(buf: &[u8]) -> Vec<String> {
    let Some((argc, rest)) = buf.split_first_chunk::<4>() else {
        return Vec::new();
    };
    let argc = usize::try_from(i32::from_ne_bytes(*argc)).unwrap_or(0);
    // The exec path and its NUL are padded to 8 bytes (observed on macOS 26), so argv
    // starts at a known offset even when argv[0] is "". Skipping "all NULs" instead
    // would swallow an empty argv[0] and read the first env string as argv.
    let Some(exec_end) = rest.iter().position(|&b| b == 0) else {
        return Vec::new();
    };
    let start = (exec_end + 1).next_multiple_of(8);
    match rest.get(exec_end..start) {
        Some(pad) if pad.iter().all(|&b| b == 0) => {}
        _ => return Vec::new(),
    }
    rest[start..]
        .split(|&b| b == 0)
        .take(argc.min(MAX_ARGS))
        .map(arg)
        .collect()
}

/// Linux: the group's members among the pane's process tree (the shell and its
/// descendants via `/proc/<pid>/task/*/children`), plus the group leader read directly in
/// case it was reparented. A full `/proc` scan only when the kernel has no children files
/// (`CONFIG_PROC_CHILDREN` off).
#[cfg(target_os = "linux")]
fn group_processes(pgid: u32, shell_pid: u32) -> Vec<Process> {
    let pids = if shell_pid != 0 && has_children_files() {
        let mut pids = tree_pids(shell_pid);
        pids.push(pgid);
        pids
    } else {
        all_pids()
    };
    group_members(pids, pgid)
}

/// The lowest `MAX_PROCS` of `pids` whose process group is `pgid`.
#[cfg(target_os = "linux")]
fn group_members(mut pids: Vec<u32>, pgid: u32) -> Vec<Process> {
    pids.sort_unstable();
    pids.dedup();
    pids.into_iter()
        .filter_map(|pid| {
            let stat = std::fs::read(format!("/proc/{pid}/stat")).ok()?;
            let (pgrp, comm) = parse_stat(&stat)?;
            (pgrp == pgid).then(|| Process {
                pid,
                name: comm,
                argv: std::fs::read(format!("/proc/{pid}/cmdline"))
                    .map(|b| split_args(&b))
                    .unwrap_or_default(),
            })
        })
        .take(MAX_PROCS)
        .collect()
}

#[cfg(target_os = "linux")]
fn has_children_files() -> bool {
    static HAS: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *HAS.get_or_init(|| std::path::Path::new("/proc/thread-self/children").exists())
}

/// Every pid in `/proc`: O(host processes).
#[cfg(target_os = "linux")]
fn all_pids() -> Vec<u32> {
    std::fs::read_dir("/proc").map_or_else(
        |_| Vec::new(),
        |dir| {
            dir.filter_map(|e| e.ok()?.file_name().to_str()?.parse().ok())
                .collect()
        },
    )
}

/// `root` and its descendants, breadth first.
// ponytail: capped at TREE_CAP pids, so a huge build tree under the shell can hide a
// group member past the cap; raise it if that shows up.
#[cfg(target_os = "linux")]
fn tree_pids(root: u32) -> Vec<u32> {
    const TREE_CAP: usize = 4096;
    let mut pids = vec![root];
    let mut i = 0;
    while i < pids.len() && pids.len() < TREE_CAP {
        let pid = pids[i];
        i += 1;
        let Ok(tasks) = std::fs::read_dir(format!("/proc/{pid}/task")) else {
            continue;
        };
        for task in tasks.filter_map(Result::ok) {
            let mut path = task.path();
            path.push("children");
            if let Ok(list) = std::fs::read_to_string(path) {
                pids.extend(
                    list.split_ascii_whitespace()
                        .filter_map(|p| p.parse::<u32>().ok()),
                );
            }
        }
    }
    pids.truncate(TREE_CAP);
    pids
}

/// `pid (comm) state ppid pgrp ...`; comm may hold spaces and parens, so split at the
/// last `)`.
#[cfg(any(target_os = "linux", test))]
fn parse_stat(stat: &[u8]) -> Option<(u32, String)> {
    let open = stat.iter().position(|&b| b == b'(')?;
    let close = stat.iter().rposition(|&b| b == b')')?;
    let comm = String::from_utf8_lossy(stat.get(open + 1..close)?).into_owned();
    let rest = std::str::from_utf8(stat.get(close + 1..)?).ok()?;
    let pgrp = rest.split_ascii_whitespace().nth(2)?.parse().ok()?;
    Some((pgrp, comm))
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn group_processes(_pgid: u32, _shell_pid: u32) -> Vec<Process> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn procargs2_skips_exec_path_and_padding() {
        let mut buf = 2i32.to_ne_bytes().to_vec();
        buf.extend_from_slice(b"/bin/sleep\0\0\0\0\0\0sleep\x0030\0PATH=/bin\0");
        assert_eq!(procargs2_argv(&buf), ["sleep", "30"]);
        assert!(procargs2_argv(b"\x01").is_empty());
        // unexpected layout (no padding): nothing rather than a guess
        let mut bad = 2i32.to_ne_bytes().to_vec();
        bad.extend_from_slice(b"/bin/sleep\0sleep\x0030\0");
        assert!(procargs2_argv(&bad).is_empty());
    }

    #[test]
    fn procargs2_empty_argv0_never_reads_env() {
        let mut buf = 2i32.to_ne_bytes().to_vec();
        buf.extend_from_slice(b"/bin/sleep\0\0\0\0\0\0\x0030\0SECRET=s\0");
        assert_eq!(procargs2_argv(&buf), ["", "30"]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn real_empty_argv0_never_reads_env() {
        use std::os::unix::process::CommandExt;
        let mut child = std::process::Command::new("/bin/sleep")
            .arg0("")
            .arg("30")
            .env_clear()
            .env("SECRET", "s")
            .spawn()
            .expect("spawn");
        let end = std::time::Instant::now() + std::time::Duration::from_secs(2);
        let argv = loop {
            let argv = kern_procargs2(child.id())
                .map(|b| procargs2_argv(&b))
                .unwrap_or_default();
            // before exec completes the buffer is the test binary's
            if argv.last().map(String::as_str) == Some("30") || std::time::Instant::now() > end {
                break argv;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        };
        let _ = child.kill();
        let _ = child.wait();
        assert_eq!(argv, ["", "30"]);
    }

    #[test]
    fn args_are_bounded() {
        let long = vec![b'a'; MAX_ARG + 10];
        let mut many = Vec::new();
        for _ in 0..MAX_ARGS + 5 {
            many.extend_from_slice(&long);
            many.push(0);
        }
        let argv = split_args(&many);
        assert_eq!(argv.len(), MAX_ARGS);
        assert!(argv.iter().all(|a| a.len() == MAX_ARG));
        // a multibyte char straddling the cut is dropped, not split
        let mut s = vec![b'a'; MAX_ARG - 1];
        s.extend_from_slice("é".as_bytes());
        assert_eq!(arg(&s).len(), MAX_ARG - 1);
    }

    #[test]
    fn stat_with_parens_in_comm() {
        assert_eq!(
            parse_stat(b"42 (a) b) S 1 77 77 0"),
            Some((77, "a) b".to_string()))
        );
    }

    /// The tree walk finds what the full scan finds: a shell group (shell, sleep) and,
    /// under it, a second group from `setsid` (sh, two sleeps).
    #[cfg(target_os = "linux")]
    #[test]
    fn tree_walk_matches_full_scan() {
        use std::os::unix::process::CommandExt;
        let mut sh = std::process::Command::new("/bin/sh")
            .args([
                "-c",
                "setsid sh -c 'sleep 30 & sleep 30; wait' & sleep 30 & wait",
            ])
            .process_group(0)
            .spawn()
            .expect("spawn");
        let shell = sh.id();
        let end = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while tree_pids(shell).len() < 6 && std::time::Instant::now() < end {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let mut groups: Vec<u32> = tree_pids(shell)
            .into_iter()
            .filter_map(|p| parse_stat(&std::fs::read(format!("/proc/{p}/stat")).ok()?))
            .map(|(g, _)| g)
            .collect();
        groups.sort_unstable();
        groups.dedup();
        let result: Vec<_> = groups
            .iter()
            .map(|&g| (group_processes(g, shell), group_members(all_pids(), g)))
            .collect();
        for &g in &groups {
            // SAFETY: plain syscall on groups this test created.
            unsafe { libc::killpg(g as libc::pid_t, libc::SIGKILL) };
        }
        let _ = sh.wait();
        assert_eq!(groups.len(), 2, "{groups:?}");
        let sizes: Vec<_> = result.iter().map(|(tree, _)| tree.len()).collect();
        assert_eq!(sizes, [2, 3], "{result:?}");
        for (tree, scan) in result {
            assert_eq!(tree, scan);
        }
    }

    /// `cargo test --release probe_cost -- --ignored --nocapture`: per-probe cost over 15
    /// process groups (each `sh` plus two `sleep`s); on Linux also the full `/proc` scan.
    #[test]
    #[ignore]
    fn probe_cost() {
        use std::os::unix::process::CommandExt;
        let mut kids: Vec<_> = (0..15)
            .map(|_| {
                std::process::Command::new("/bin/sh")
                    .args(["-c", "sleep 30 & sleep 30 & wait"])
                    .process_group(0)
                    .spawn()
                    .expect("spawn")
            })
            .collect();
        std::thread::sleep(std::time::Duration::from_millis(200));
        let time = |f: &dyn Fn(u32) -> usize| {
            let mut us = Vec::new();
            for _ in 0..20 {
                for k in &kids {
                    let t = std::time::Instant::now();
                    assert_eq!(f(k.id()), 3);
                    us.push(t.elapsed().as_micros());
                }
            }
            us.sort_unstable();
            format!(
                "probes={} p50_us={} p95_us={} max_us={}",
                us.len(),
                us[us.len() / 2],
                us[us.len() * 95 / 100],
                us[us.len() - 1]
            )
        };
        let probe = time(&|g| foreground_job(g, g).map_or(0, |j| j.processes.len()));
        #[cfg(target_os = "linux")]
        let scan = time(&|g| group_members(all_pids(), g).len());
        #[cfg(not(target_os = "linux"))]
        let scan = "n/a".to_string();
        for k in &mut kids {
            // SAFETY: plain syscall on the child's own group.
            unsafe { libc::killpg(k.id() as libc::pid_t, libc::SIGKILL) };
            let _ = k.wait();
        }
        let host = std::fs::read_dir("/proc").map_or(0, |d| d.count());
        eprintln!("PROBE_COST probe {probe} | full_scan {scan} | proc_entries={host}");
    }

    #[test]
    fn own_group_is_found() {
        // SAFETY: plain syscall.
        let pgid = unsafe { libc::getpgrp() } as u32;
        let job = foreground_job(pgid, 0).expect("job");
        assert!(!job.shell);
        let me = std::process::id();
        let p = job.processes.iter().find(|p| p.pid == me).expect("self");
        assert!(!p.name.is_empty() && !p.argv.is_empty());
    }
}
