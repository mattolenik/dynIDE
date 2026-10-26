//! NIF glue for `DynideTerm.Native`. Kept thin: behaviour lives in `tty`,
//! which is tested without the BEAM.

#[cfg(unix)]
mod blit;
#[cfg(unix)]
mod cell;
#[cfg(unix)]
mod desktop;
#[cfg(unix)]
mod graphics;
#[cfg(unix)]
mod output;
#[cfg(unix)]
mod probe;
#[cfg(unix)]
mod tty;

#[cfg(unix)]
mod nif {
    use crate::blit::validate_rows;
    use crate::graphics::{Medium, Op};
    use crate::output::{FrameJob, OutputStats, WRITE_QUEUE_BYTES};
    use crate::tty::{Event, Inner, Sink, TtyResource};
    use rustler::types::binary::{Binary, OwnedBinary};
    use rustler::{Atom, Decoder, Encoder, Env, LocalPid, NifResult, OwnedEnv, ResourceArc, Term};
    use std::panic::{catch_unwind, AssertUnwindSafe};

    mod atoms {
        rustler::atoms! {
            ok, error, tty_input, exit, tty, hangup, panic, backpressure, bad_frame, tty_resumed,
            restored, os_error, eperm, enoent, eintr, eio, enxio, ebadf, eagain, enomem, eacces,
            ebusy, enodev, enotdir, eisdir, einval, enfile, emfile, enotty, unavailable, bad_url,
            upload, place, delete_placement, delete_image, delete_all, id, format, width, height,
            data, medium, rgb, rgba, png, direct, file, placement, x, y, cols, rows, src, off, z,
        }
    }

    /// An `io::Error` for Elixir: the lowercase posix atom (`:enoent`) for
    /// common errnos, `{:os_error, n}` for other errnos, else the message.
    struct Posix(std::io::Error);

    impl Encoder for Posix {
        fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
            let Some(n) = self.0.raw_os_error() else {
                return self.0.to_string().encode(env);
            };
            let name = match n {
                libc::EPERM => atoms::eperm(),
                libc::ENOENT => atoms::enoent(),
                libc::EINTR => atoms::eintr(),
                libc::EIO => atoms::eio(),
                libc::ENXIO => atoms::enxio(),
                libc::EBADF => atoms::ebadf(),
                libc::EAGAIN => atoms::eagain(),
                libc::ENOMEM => atoms::enomem(),
                libc::EACCES => atoms::eacces(),
                libc::EBUSY => atoms::ebusy(),
                libc::ENODEV => atoms::enodev(),
                libc::ENOTDIR => atoms::enotdir(),
                libc::EISDIR => atoms::eisdir(),
                libc::EINVAL => atoms::einval(),
                libc::ENFILE => atoms::enfile(),
                libc::EMFILE => atoms::emfile(),
                libc::ENOTTY => atoms::enotty(),
                n => return (atoms::os_error(), n).encode(env),
            };
            name.encode(env)
        }
    }

    impl rustler::Resource for TtyResource {}

    /// Sends events to an Erlang process from a kernel thread.
    struct PidSink(LocalPid);

    fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
        match OwnedBinary::new(bytes.len()) {
            Some(mut owned) => {
                owned.as_mut_slice().copy_from_slice(bytes);
                Binary::from_owned(owned, env).encode(env)
            }
            // Allocation failure: deliver an empty binary rather than nothing.
            None => "".encode(env),
        }
    }

    fn encode<'a>(env: Env<'a>, event: &Event) -> Term<'a> {
        match event {
            Event::Input(bytes) => (atoms::tty_input(), binary(env, bytes)).encode(env),
            Event::Hangup => (atoms::exit(), atoms::tty(), atoms::hangup()).encode(env),
            Event::Resumed => {
                rustler::types::tuple::make_tuple(env, &[atoms::tty_resumed().encode(env)])
            }
            Event::Panic(reason) => (
                atoms::exit(),
                atoms::tty(),
                (atoms::panic(), reason.as_str()),
            )
                .encode(env),
        }
    }

    impl Sink for PidSink {
        fn send(&mut self, event: Event) {
            // A dead subscriber is not an error; the owner will resubscribe.
            let _ = OwnedEnv::new().send_and_clear(&self.0, |env| encode(env, &event));
        }
    }

    /// Opens the tty on a kernel thread (the probe waits up to 250 ms) and
    /// replies `{tag, {:ok, tty} | {:error, reason}}` to the caller.
    #[rustler::nif]
    fn tty_open(
        env: Env,
        path: String,
        kitty_flags: u16,
        tag: Term,
    ) -> Result<Atom, rustler::Error> {
        let caller = env.pid();
        let mut owned = OwnedEnv::new();
        let tag = owned.save(tag);
        let spawned = std::thread::Builder::new()
            .name("dynide-tty-open".into())
            .spawn(move || {
                // Opening and wrapping run under catch_unwind; only the send is outside.
                let result = catch_unwind(AssertUnwindSafe(|| {
                    Inner::open_path(&path, kitty_flags, None)
                        .map(|inner| ResourceArc::new(TtyResource::new(inner)))
                }));
                // If the caller is gone the resource is dropped here, which restores the tty.
                let _ = owned.send_and_clear(&caller, |env| {
                    let reply = match result {
                        Ok(Ok(tty)) => (atoms::ok(), tty).encode(env),
                        Ok(Err(err)) => (atoms::error(), Posix(err)).encode(env),
                        Err(_) => {
                            (atoms::error(), (atoms::panic(), "tty open panicked")).encode(env)
                        }
                    };
                    (tag.load(env), reply).encode(env)
                });
            });
        match spawned {
            Ok(_) => Ok(atoms::ok()),
            Err(err) => Err(rustler::Error::Term(Box::new(Posix(err)))),
        }
    }

    // Dirty IO: the restore write may poll the host for up to 100 ms.
    #[rustler::nif(schedule = "DirtyIo")]
    fn tty_restore(tty: ResourceArc<TtyResource>) -> Atom {
        // Best effort by contract: a tty that cannot be reset has nothing left to undo.
        let _ = tty.inner.restore();
        atoms::ok()
    }

    /// Ruling 7: stops the VM's process group and returns after SIGCONT.
    /// Dirty IO for the restore and re-enter writes (100 ms budget each).
    /// `:ok` exactly when `{:tty_resumed}` follows, so a waiter cannot hang.
    #[rustler::nif(schedule = "DirtyIo")]
    fn tty_suspend(tty: ResourceArc<TtyResource>) -> Result<Atom, rustler::Error> {
        match tty.inner.suspend() {
            Ok(true) => Ok(atoms::ok()),
            Ok(false) => Err(rustler::Error::Term(Box::new(atoms::restored()))),
            Err(err) => Err(rustler::Error::Term(Box::new(Posix(err)))),
        }
    }

    /// Raises the posix reason when TIOCGWINSZ fails (the fd is no tty).
    #[rustler::nif]
    fn tty_size(tty: ResourceArc<TtyResource>) -> Result<(u16, u16, u16, u16), rustler::Error> {
        tty.inner
            .size()
            .map_err(|err| rustler::Error::RaiseTerm(Box::new(Posix(err))))
    }

    #[rustler::nif]
    fn tty_subscribe(env: Env, tty: ResourceArc<TtyResource>, pid: LocalPid) -> Atom {
        // Buffered input goes out from this scheduler thread via the caller's env.
        tty.inner.subscribe(Box::new(PidSink(pid)), |event| {
            let _ = env.send(&pid, encode(env, &event));
        });
        atoms::ok()
    }

    /// Enqueues bytes for the output thread: a copy and a lock, never a wait.
    /// More than `WRITE_QUEUE_BYTES` at once can never fit and is refused
    /// before copying. After restore the bytes are discarded and this is `:ok`.
    #[rustler::nif]
    fn tty_write<'a>(env: Env<'a>, tty: ResourceArc<TtyResource>, bytes: Binary) -> Term<'a> {
        let queued = if bytes.len() > WRITE_QUEUE_BYTES {
            Err(crate::output::Backpressure)
        } else {
            tty.inner.output.write(bytes.as_slice().to_vec())
        };
        match queued {
            Ok(()) => atoms::ok().encode(env),
            Err(_) => (atoms::error(), atoms::backpressure()).encode(env),
        }
    }

    #[rustler::nif]
    fn tty_stats(tty: ResourceArc<TtyResource>) -> OutputStats {
        tty.inner.output.stats()
    }

    fn bad<T>() -> NifResult<T> {
        Err(rustler::Error::BadArg)
    }

    fn pos(n: u32) -> NifResult<u32> {
        if n > 0 {
            Ok(n)
        } else {
            bad()
        }
    }

    fn field<'a, T: Decoder<'a>>(map: Term<'a>, key: Atom) -> NifResult<T> {
        map.map_get(key)?.decode()
    }

    /// One `Native.Blit` graphics op (see its typedoc); anything else is `BadArg`.
    fn decode_op(term: Term) -> NifResult<Op> {
        if let Ok(atom) = term.decode::<Atom>() {
            return if atom == atoms::delete_all() {
                Ok(Op::DeleteAll)
            } else {
                bad()
            };
        }
        let items = rustler::types::tuple::get_tuple(term)?;
        let Some((tag, args)) = items.split_first() else {
            return bad();
        };
        let tag: Atom = tag.decode()?;
        match args {
            [m] if tag == atoms::upload() => {
                let format = match field::<Atom>(*m, atoms::format())? {
                    f if f == atoms::rgb() => 24,
                    f if f == atoms::rgba() => 32,
                    f if f == atoms::png() => 100,
                    _ => return bad(),
                };
                let medium = match field::<Atom>(*m, atoms::medium())? {
                    f if f == atoms::direct() => Medium::Direct,
                    f if f == atoms::file() => Medium::File,
                    _ => return bad(),
                };
                let data: Binary = field(*m, atoms::data())?;
                if data.is_empty() {
                    return bad();
                }
                Ok(Op::Upload {
                    id: pos(field(*m, atoms::id())?)?,
                    format,
                    width: pos(field(*m, atoms::width())?)?,
                    height: pos(field(*m, atoms::height())?)?,
                    // ponytail: copies image data on a normal scheduler (~1 ms per 8 MiB);
                    // keep the env binary alive instead if uploads show up in latency.
                    data: data.as_slice().to_vec(),
                    medium,
                })
            }
            [m] if tag == atoms::place() => Ok(Op::Place {
                id: pos(field(*m, atoms::id())?)?,
                placement: pos(field(*m, atoms::placement())?)?,
                x: field(*m, atoms::x())?,
                y: field(*m, atoms::y())?,
                cols: pos(field(*m, atoms::cols())?)?,
                rows: pos(field(*m, atoms::rows())?)?,
                src: field(*m, atoms::src())?,
                off: field(*m, atoms::off())?,
                z: field(*m, atoms::z())?,
            }),
            [i, p] if tag == atoms::delete_placement() => {
                Ok(Op::DeletePlacement(pos(i.decode()?)?, pos(p.decode()?)?))
            }
            [i] if tag == atoms::delete_image() => Ok(Op::DeleteImage(pos(i.decode()?)?)),
            _ => bad(),
        }
    }

    /// Validates the frame's shape, copies the rows and hands them to the
    /// output thread (latest wins). Rows that pass the shape check but do not
    /// decode are dropped there and counted in `frames_dropped`.
    #[rustler::nif]
    fn blit_frame<'a>(
        env: Env<'a>,
        tty: ResourceArc<TtyResource>,
        rows: Vec<(u16, Binary)>,
        cursor: Option<(u16, u16)>,
        shape: u8,
        repaint: bool,
        graphics: Term<'a>,
    ) -> Term<'a> {
        let slices: Vec<(u16, &[u8])> = rows.iter().map(|(i, r)| (*i, r.as_slice())).collect();
        let graphics = graphics.decode::<Vec<Term>>().and_then(|ops| {
            ops.into_iter()
                .map(decode_op)
                .collect::<NifResult<Vec<_>>>()
        });
        let (true, Ok(graphics), Ok(_)) = (shape <= 6, graphics, validate_rows(&slices)) else {
            return (atoms::error(), atoms::bad_frame()).encode(env);
        };
        // ponytail: memcpy per frame; hold owned env binaries if profiling says so.
        let rows = slices.iter().map(|(i, r)| (*i, r.to_vec())).collect();
        tty.inner.output.submit_frame(FrameJob {
            rows,
            cursor,
            shape,
            repaint,
            graphics,
        });
        atoms::ok().encode(env)
    }

    fn desktop_result(env: Env, result: Result<(), crate::desktop::Error>) -> Term {
        match result {
            Ok(()) => atoms::ok().encode(env),
            Err(crate::desktop::Error::Unavailable) => {
                (atoms::error(), atoms::unavailable()).encode(env)
            }
            Err(crate::desktop::Error::BadUrl) => (atoms::error(), atoms::bad_url()).encode(env),
        }
    }

    /// Spawns the clipboard tool (fork/exec: dirty) and returns; a kernel thread
    /// writes `text` to its stdin and reaps it.
    #[rustler::nif(schedule = "DirtyIo")]
    fn desktop_clipboard_write<'a>(env: Env<'a>, text: Binary) -> Term<'a> {
        desktop_result(
            env,
            crate::desktop::clipboard_write(text.as_slice().to_vec()),
        )
    }

    /// Spawns `open` / `xdg-open` for an http(s) URL; a kernel thread reaps it.
    #[rustler::nif(schedule = "DirtyIo")]
    fn desktop_open_url<'a>(env: Env<'a>, url: String) -> Term<'a> {
        desktop_result(env, crate::desktop::open_url(&url))
    }

    /// Spawns the desktop notifier (osascript / notify-send); a kernel thread reaps it.
    #[rustler::nif(schedule = "DirtyIo")]
    fn desktop_notify<'a>(env: Env<'a>, title: String, body: String) -> Term<'a> {
        desktop_result(env, crate::desktop::notify(&title, &body))
    }

    /// Spawns an audio player for `path`; a kernel thread reaps it.
    #[rustler::nif(schedule = "DirtyIo")]
    fn desktop_play<'a>(env: Env<'a>, path: String) -> Term<'a> {
        desktop_result(env, crate::desktop::play(&path))
    }

    #[rustler::nif]
    fn tty_kitty_keyboard(tty: ResourceArc<TtyResource>) -> Option<u16> {
        tty.inner.kitty()
    }
}

#[cfg(unix)]
fn load(env: rustler::Env, _info: rustler::Term) -> bool {
    env.register::<tty::TtyResource>().is_ok()
}

#[cfg(unix)]
rustler::init!("Elixir.DynideTerm.Native", load = load);
