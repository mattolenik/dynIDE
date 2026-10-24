defmodule HerdrTerm.Client.Term.Input.ParseMousePasteTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Event
  alias HerdrTerm.Client.Term.Input.Parse

  defp m(kind, button, x, y, mods \\ []),
    do: {:mouse, %{kind: kind, button: button, x: x, y: y, mods: mods, px: nil}}

  defp run(chunks, t \\ Parse.new()) do
    {evs, t} =
      Enum.reduce(chunks, {[], t}, fn c, {acc, t} ->
        {e, t} = Parse.events(c, t)
        {acc ++ e, t}
      end)

    {more, t} = Parse.flush(t)
    {evs ++ more, t}
  end

  defp win(kinds) do
    Enum.reduce(kinds, Parse.new(), &Parse.open_window(&2, &1, 1000))
  end

  defp bytes(bin), do: for(<<b <- bin>>, do: <<b>>)

  # {input, window kinds, expected events}
  defp vectors do
    [
      {"\e[<0;1;1M", [], [m(:press, :left, 0, 0)]},
      {"\e[<0;10;5m", [], [m(:release, :left, 9, 4)]},
      {"\e[<1;3;4M", [], [m(:press, :middle, 2, 3)]},
      {"\e[<2;3;4M", [], [m(:press, :right, 2, 3)]},
      {"\e[<4;1;1M", [], [m(:press, :left, 0, 0, [:shift])]},
      {"\e[<24;1;1M", [], [m(:press, :left, 0, 0, [:alt, :ctrl])]},
      {"\e[<32;2;2M", [], [m(:drag, :left, 1, 1)]},
      {"\e[<35;2;2M", [], [m(:move, :none, 1, 1)]},
      {"\e[<64;2;2M", [], [m(:scroll, :wheel_up, 1, 1)]},
      {"\e[<65;2;2M", [], [m(:scroll, :wheel_down, 1, 1)]},
      {"\e[<66;2;2M", [], [m(:scroll, :wheel_left, 1, 1)]},
      {"\e[<67;2;2M", [], [m(:scroll, :wheel_right, 1, 1)]},
      {"\e[<68;2;2M", [], [m(:scroll, :wheel_up, 1, 1, [:shift])]},
      {"\e[<128;2;2M", [], []},
      {"\e[<129;2;2M", [], []},
      {"\e[<96;2;2M", [], []},
      {"\e[<0;0;1M", [], []},
      {"\e[<0;1;0M", [], []},
      {"\e[I", [], [{:focus, true}]},
      {"\e[O", [], [{:focus, false}]},
      {"\e[200~hi\e[A\r\e[201~", [], [{:paste, "hi\e[A\r"}]},
      {"\e[200~\e[201~a", [], [{:paste, ""}, Event.key("a", [], text: "a")]},
      {"\e[?62;22c", [:da1], [{:reply, :da1, [62, 22]}]},
      {"\e[?1u", [:kitty_flags], [{:reply, :kitty_flags, 1}]},
      {"\e[5;10R", [:cpr], [{:reply, :cpr, {5, 10}}]},
      {"\e]10;rgb:ffff/0000/0000\a", [:colors], [{:reply, :fg, {255, 0, 0}}]},
      {"\e]11;rgb:0/0/0\e\\", [:colors], [{:reply, :bg, {0, 0, 0}}]},
      # outside a window: dropped
      {"\e[?1u", [], []},
      {"\e[?62;22c", [], []},
      {"\e[5;10R", [], []},
      {"\e]10;rgb:0/0/0\a", [], []},
      {"\e[1;5R", [], [Event.key(:f3, [:ctrl])]},
      {"\e[R", [], [Event.key(:f3)]}
    ]
  end

  test "vectors whole and byte-by-byte" do
    for {bin, kinds, want} <- vectors() do
      assert {^want, _} = run([bin], win(kinds)), inspect(bin)
      assert {^want, _} = run(bytes(bin), win(kinds)), "split " <> inspect(bin)
    end
  end

  test "paste over many chunks, longer than the CSI cap, yields one event" do
    body = String.duplicate("x\e[A\r", 100)

    chunks = [
      "\e[20",
      "0~" <> binary_part(body, 0, 7),
      binary_part(body, 7, 300),
      binary_part(body, 307, 193) <> "\e[2",
      "01~z"
    ]

    assert {[{:paste, ^body}, {:key, %{key: "z"}}], _} = run(chunks)
  end

  test "a paste past paste_max is emitted so far and stays in paste mode" do
    max = Parse.paste_max()
    big = :binary.copy("a", max)

    {[{:paste, first}], t} = run(["\e[200~" <> big, "bc"])
    assert byte_size(first) == max + 2 - 5
    assert t.paste != nil
    assert {[{:paste, rest}, {:key, %{key: "z"}}], %{paste: nil}} = run(["\r\e[201~z"], t)
    assert first <> rest == big <> "bc\r"
  end

  test "kitty reply sets kitty flag only inside a window" do
    assert {[_], %{kitty: true}} = run(["\e[?1u"], win([:kitty_flags]))
    assert {[], %{kitty: false}} = run(["\e[?1u"])
  end

  test "DA1 reply closes all windows" do
    {_, t} = run(["\e[?62c"], win([:da1, :kitty_flags, :colors, :cpr]))
    assert t.windows == %{}
    assert {[], _} = run(["\e[?1u"], t)
  end

  test "windows expire" do
    t = Parse.expire_windows(win([:kitty_flags]), 1000)
    assert t.windows == %{}
    assert {[], _} = run(["\e[?1u"], t)
    assert win([:cpr]) |> Parse.expire_windows(999) |> Map.fetch!(:windows) |> map_size() == 1
  end

  test "oversize OSC reply is dropped and parsing resumes after it" do
    big = "\e]10;" <> String.duplicate("a", 300)
    assert {[{:key, %{key: "k"}}], %{skip: false}} = run([big, "bb\a", "k"], win([:colors]))
    assert {[{:key, %{key: "k"}}], _} = run([big <> "\a" <> "k"], win([:colors]))
    # ST split across chunks inside the skip state
    assert {[{:key, %{key: "k"}}], _} = run([big, "\e", "\\k"], win([:colors]))
  end

  test "alt+] is still a key" do
    assert {[{:key, %{key: "]", mods: [:alt]}}], _} = run(["\e]"])
  end
end
