defmodule HerdrServer.Config.WriteTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Config.Write

  @moduletag :tmp_dir

  @file_body """
  # herdr-live config
  onboarding = true   # first run

  [keys]
  # my binds
  new_tab = "prefix+t"
  detach = [
    "prefix+q",
  ]

  [ui]
  sidebar_width = 30

  [theme]
  name = "nord" # comment kept elsewhere
  """

  defp write(dir, body) do
    path = Path.join(dir, "config.toml")
    File.write!(path, body)
    path
  end

  test "replaces only the target line, keeping comments, blanks and other tables",
       %{tmp_dir: dir} do
    path = write(dir, @file_body)
    assert :ok = Write.upsert(path, ["ui"], %{"sidebar_width" => 40})

    assert File.read!(path) ==
             String.replace(@file_body, "sidebar_width = 30", "sidebar_width = 40")
  end

  test "top-level keys and multi-line arrays", %{tmp_dir: dir} do
    path = write(dir, @file_body)
    assert :ok = Write.upsert(path, [], %{"onboarding" => false})
    assert :ok = Write.upsert(path, ["keys"], %{"detach" => ["prefix+y", "alt+q"]})

    expected =
      @file_body
      |> String.replace("onboarding = true   # first run", "onboarding = false")
      |> String.replace("detach = [\n  \"prefix+q\",\n]", "detach = [\"prefix+y\", \"alt+q\"]")

    assert File.read!(path) == expected
  end

  test "a missing key is appended at the end of its table", %{tmp_dir: dir} do
    path = write(dir, @file_body)
    assert :ok = Write.upsert(path, ["ui"], %{"status_indicators" => "symbols"})

    assert File.read!(path) ==
             String.replace(
               @file_body,
               "sidebar_width = 30\n",
               "sidebar_width = 30\nstatus_indicators = \"symbols\"\n"
             )
  end

  test "a missing table is appended at the end of the file", %{tmp_dir: dir} do
    path = write(dir, @file_body)
    assert :ok = Write.upsert(path, ["ui", "sound"], %{"enabled" => false})
    assert File.read!(path) == @file_body <> "\n[ui.sound]\nenabled = false\n"
    assert {:ok, %{"ui" => %{"sound" => %{"enabled" => false}}}} = Toml.decode_file(path)
  end

  test "a missing top-level key goes before the first table", %{tmp_dir: dir} do
    path = write(dir, "[keys]\nnew_tab = \"prefix+t\"\n")
    assert :ok = Write.upsert(path, [], %{"onboarding" => false})
    assert File.read!(path) == "onboarding = false\n\n[keys]\nnew_tab = \"prefix+t\"\n"
  end

  test "creates the file and its directory; values decode back", %{tmp_dir: dir} do
    path = Path.join([dir, "a", "b", "config.toml"])
    kv = %{"s" => "q\"uo\\te\n\e", "n" => 3, "b" => true, "l" => ["x", "y"], "e" => []}
    assert :ok = Write.upsert(path, ["t"], kv)
    assert {:ok, %{"t" => ^kv}} = Toml.decode_file(path)
  end
end
