defmodule HerdrTerm.NativeTest do
  use ExUnit.Case, async: true

  alias HerdrTerm.Native.{Blit, Tty}

  test "the nif loads and open reports a missing path" do
    assert {:error, reason} = Tty.open(%{path: "/nonexistent"})
    assert is_binary(reason)
  end

  test "blit rejects an unknown cursor shape before reaching the tty" do
    assert Blit.frame(make_ref(), [], %{cursor: nil, shape: :beam, repaint: false}) ==
             {:error, :bad_frame}
  end
end
