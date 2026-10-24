//! NIF glue for `HerdrTerm.Native`. Kept thin: behaviour lives in `tty`,
//! which is tested without the BEAM.

#[cfg(unix)]
mod probe;
#[cfg(unix)]
mod tty;

#[cfg(unix)]
mod nif {
    use crate::tty::{Event, Inner, Sink, TtyResource};
    use rustler::types::binary::{Binary, OwnedBinary};
    use rustler::{Atom, Encoder, Env, LocalPid, OwnedEnv, ResourceArc, Term};
    use std::panic::{catch_unwind, AssertUnwindSafe};

    mod atoms {
        rustler::atoms! { ok, error, tty_input, exit, tty, hangup, panic }
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
            .name("herdr-tty-open".into())
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
                        Ok(Err(err)) => (atoms::error(), err.to_string()).encode(env),
                        Err(_) => {
                            (atoms::error(), (atoms::panic(), "tty open panicked")).encode(env)
                        }
                    };
                    (tag.load(env), reply).encode(env)
                });
            });
        match spawned {
            Ok(_) => Ok(atoms::ok()),
            Err(err) => Err(rustler::Error::Term(Box::new(err.to_string()))),
        }
    }

    #[rustler::nif]
    fn tty_restore(tty: ResourceArc<TtyResource>) -> Atom {
        // Best effort by contract: a tty that cannot be reset has nothing left to undo.
        let _ = tty.inner.restore();
        atoms::ok()
    }

    #[rustler::nif]
    fn tty_size(tty: ResourceArc<TtyResource>) -> Result<(u16, u16, u16, u16), rustler::Error> {
        tty.inner
            .size()
            .map_err(|err| rustler::Error::RaiseTerm(Box::new(err.to_string())))
    }

    #[rustler::nif]
    fn tty_subscribe(env: Env, tty: ResourceArc<TtyResource>, pid: LocalPid) -> Atom {
        // Buffered input goes out from this scheduler thread via the caller's env.
        tty.inner.subscribe(Box::new(PidSink(pid)), |event| {
            let _ = env.send(&pid, encode(env, &event));
        });
        atoms::ok()
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
rustler::init!("Elixir.HerdrTerm.Native", load = load);
