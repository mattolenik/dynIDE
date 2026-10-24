defmodule HerdrServer.Client.WordsTest do
  use ExUnit.Case, async: true
  alias HerdrScene.Cell
  alias HerdrServer.Client.Words

  @wide ~w(世 界 你 好 （ ） ： 、 。 ，)

  # One cell per grapheme; wide graphemes get a width-0 tail.
  defp cells(text) do
    text
    |> String.graphemes()
    |> Enum.flat_map(fn g ->
      if g in @wide,
        do: [%Cell{glyph: g, width: 2}, %Cell{glyph: "", width: 0}],
        else: [%Cell{glyph: if(g == " ", do: "", else: g)}]
    end)
  end

  defp col_of(text, needle) do
    {pre, _} = :binary.match(text, needle)

    text
    |> binary_part(0, pre)
    |> String.graphemes()
    |> Enum.map(&if(&1 in @wide, do: 2, else: 1))
    |> Enum.sum()
  end

  # The text of the selected columns, wide tails dropped.
  defp selected(text, click, offset \\ 0) do
    cs = cells(text)

    case Words.word_at(cs, col_of(text, click) + offset) do
      nil ->
        nil

      {a, b} ->
        cs
        |> Enum.slice(a..b)
        |> Enum.reject(&(&1.width == 0))
        |> Enum.map_join(&if(&1.glyph == "", do: " ", else: &1.glyph))
    end
  end

  test "url click trims trailing ).",
    do: assert(selected("see https://x.io/a).", "x.io") == "https://x.io/a")

  test "url span in columns" do
    assert Words.word_at(cells("see https://x.io/a)."), 6) == {4, 17}
  end

  test "token between separators" do
    assert selected("foo(bar)", "bar") == "bar"
    assert selected("foo(bar)", "foo") == "foo"
    assert selected("foo(bar)", "(") == nil
  end

  test "quoted path" do
    assert selected("path \"/a b/c\" x", "b/c") == "/a b/c"
    assert selected("path \"/a b/c\" x", "a b") == "/a b/c"
  end

  test "wide characters map to display columns" do
    cs = cells("世界 ok")
    assert Words.word_at(cs, 0) == {0, 3}
    assert Words.word_at(cs, 1) == {0, 3}
    assert Words.word_at(cs, 3) == {0, 3}
    assert Words.word_at(cs, 4) == nil
    assert Words.word_at(cs, 5) == {5, 6}
  end

  test "empty cell and out of range return nil" do
    assert Words.word_at(cells("a b"), 1) == nil
    assert Words.word_at(cells("a b"), 9) == nil
    assert Words.word_at(cells("x \"/a b/c\""), 5) == {3, 8}
  end

  test "herdr word bound cases" do
    cases = [
      {"see https://example.com/a-b_c?q=x@y.", "example.com", "https://example.com/a-b_c?q=x@y"},
      {"open \"https://example.com/a,b;c?q=x\";", "example.com", "https://example.com/a,b;c?q=x"},
      {"see https://en.wikipedia.org/wiki/Foo_(bar_(baz)),", "wikipedia",
       "https://en.wikipedia.org/wiki/Foo_(bar_(baz))"},
      {"see https://example.com/a(b[c{d}e]f),", "example.com",
       "https://example.com/a(b[c{d}e]f)"},
      {"see (https://example.com/a(b(c)d)))", "example.com", "https://example.com/a(b(c)d)"},
      {"open ./src/app/actions.rs:795", "actions", "./src/app/actions.rs:795"},
      {"edit src/app/actions.rs,then", "actions", "src/app/actions.rs"},
      {"cat \"/tmp/build output/log.txt\"", "output", "/tmp/build output/log.txt"},
      {"cat '/Users/me/Application Support/c.json'", "Support",
       "/Users/me/Application Support/c.json"},
      {"echo 你好-world done", "好", "你好-world"},
      {"export PATH=$HOME/.cargo/bin:$PATH", "$HOME", "PATH=$HOME/.cargo/bin:$PATH"},
      {"refs #123 and @owner/name", "owner", "@owner/name"},
      {"ERROR [worker-1] request_id=abc-123", "worker", "worker-1"},
      {"tmux|newhoo|fixhoo", "newhoo", "newhoo"},
      {"render_status_line(app, area)", "area", "area"},
      {"println!(\"hi\")", "println", "println"},
      {"( master)$", "master", "master"},
      {"regex foo$", "foo", "foo$"},
      {"left，right", "right", "right"}
    ]

    for {row, click, expected} <- cases do
      assert selected(row, click) == expected, "row=#{inspect(row)} click=#{inspect(click)}"
    end

    assert selected("echo 你好-world done", "好", 1) == "你好-world"
  end

  test "delimiters select nothing" do
    for {row, click} <- [
          {"alpha,beta;gamma", ","},
          {"if !enabled {", "!"},
          {"(done).", "("},
          {"(done).", "."}
        ] do
      assert selected(row, click) == nil, "row=#{inspect(row)} click=#{inspect(click)}"
    end

    assert selected("left，right", "，", 1) == nil
  end
end
