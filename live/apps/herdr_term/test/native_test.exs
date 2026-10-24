defmodule HerdrTerm.NativeTest do
  use ExUnit.Case, async: true

  alias HerdrTerm.Native.{Blit, Tty}

  test "the nif loads and open reports errors as posix atoms" do
    assert Tty.open(%{path: "/nonexistent"}) == {:error, :enoent}
    # A regular file opens but is no terminal (/dev/null is :enodev on macOS).
    file =
      Path.join(System.tmp_dir!(), "herdr_term_not_a_tty_#{System.unique_integer([:positive])}")

    File.write!(file, "")
    assert Tty.open(%{path: file}) == {:error, :enotty}
    File.rm!(file)
  end

  test "blit rejects an unknown cursor shape before reaching the tty" do
    assert Blit.frame(make_ref(), [], %{cursor: nil, shape: :beam, repaint: false}) ==
             {:error, :bad_frame}
  end
end
