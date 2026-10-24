pub mod cell;
pub mod input;
pub mod splitter;
pub mod vt;

use rustler::Error;

/// Constructs and drops a ghostty terminal, returning the proof string.
fn greeting() -> Result<&'static str, String> {
    let _terminal = ghostty_vt::Terminal::new(80, 24, 0).map_err(|e| e.to_string())?;
    Ok("herdr_kernel ghostty 80x24")
}

#[rustler::nif]
fn hello() -> Result<&'static str, Error> {
    greeting().map_err(|e| Error::Term(Box::new(e)))
}

rustler::init!("Elixir.HerdrServer.Native");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greeting_builds_terminal() {
        assert_eq!(greeting(), Ok("herdr_kernel ghostty 80x24"));
    }
}
