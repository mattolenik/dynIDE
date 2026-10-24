pub mod cell;
#[cfg(unix)]
pub mod exitwatch;
pub mod input;
#[cfg(unix)]
pub mod link;
#[cfg(unix)]
mod nif;
#[cfg(unix)]
pub mod pty;
pub mod splitter;
pub mod vt;

#[cfg(unix)]
rustler::init!("Elixir.HerdrServer.Native", load = nif::load);
#[cfg(not(unix))]
rustler::init!("Elixir.HerdrServer.Native");
