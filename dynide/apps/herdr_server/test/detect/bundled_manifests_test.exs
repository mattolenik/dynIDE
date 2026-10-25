defmodule HerdrServer.Detect.BundledManifestsTest do
  @moduledoc """
  PCRE vetting: every bundled manifest (copied verbatim from herdr, written for
  Rust `regex`) must parse and compile under Erlang `:re` (PCRE2 10.47).

  Rejected construct: Rust's `\\uXXXX` / `\\u{X}` code point escapes (cursor,
  droid, qodercli, hermes, kimi, antigravity), which PCRE2 does not support.
  `Manifest.compile_regex/1` rewrites them to `\\x{...}`; the manifests are
  unchanged. Everything else (`\\x{...}`, `\\p{Alphabetic}`, `(?i)`/`(?m)`/`(?s)`
  flags) compiles as written.
  """
  use ExUnit.Case, async: true

  alias HerdrServer.Detect.{Manifest, Manifests}

  files = Path.wildcard(Path.join(Path.expand("../../priv/detect/manifests", __DIR__), "*.toml"))

  test "all 22 herdr manifests are bundled" do
    assert length(Path.wildcard(Path.join(Manifests.bundled_dir(), "*.toml"))) == 22
    # one entry per id: no two files claim the same agent
    assert map_size(Manifests.load(Manifests.bundled_dir(), "/nonexistent")) == 22
  end

  for path <- files do
    @path path
    test "#{Path.basename(path)} parses and compiles under :re" do
      assert {:ok, %Manifest{}} = Manifest.parse(File.read!(@path))
    end
  end
end
