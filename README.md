# herdr-live

herdr forked onto the BEAM: an Elixir server and clients over a Rust NIF kernel, so an
agent can edit the running multiplexer and see the change in under a second without
losing terminals, scrollback, or layout.

- Design, milestones, status and results: [docs/herdr-live/](docs/herdr-live/)
- Project rules: [AGENTS.md](AGENTS.md)
- Build and check: `just live-check`; run: `just live-run`
- The original Rust herdr product is kept as the git tag `herdr-reference`
  (`git archive herdr-reference`); see [FORK.md](FORK.md) for its fork notes.

Licensed under [Apache-2.0](LICENSE).
