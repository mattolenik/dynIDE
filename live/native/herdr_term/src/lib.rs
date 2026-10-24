fn greeting() -> &'static str {
    "herdr_term"
}

#[rustler::nif]
fn hello() -> &'static str {
    greeting()
}

rustler::init!("Elixir.HerdrTerm.Native");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greeting_is_crate_name() {
        assert_eq!(greeting(), "herdr_term");
    }
}
