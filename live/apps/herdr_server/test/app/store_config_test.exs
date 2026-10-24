defmodule HerdrServer.App.StoreConfigTest do
  # the Store reads :config_path; the app env is global
  use ExUnit.Case, async: false
  @moduletag :capture_log
  @moduletag :tmp_dir

  alias HerdrServer.App.{Actions, Keybinds, Store}
  alias HerdrServer.App.Modal.Prompt

  @size %{cols: 80, rows: 24}

  setup %{tmp_dir: dir} do
    saved = Application.get_env(:herdr_server, :config_path)
    path = Path.join(dir, "config.toml")
    Application.put_env(:herdr_server, :config_path, path)
    Store.reset()

    on_exit(fn ->
      Application.put_env(:herdr_server, :config_path, saved)
      Store.reset()
    end)

    %{path: path}
  end

  test "the first init uses the config; reload swaps keybinds", %{path: path} do
    File.write!(path, "onboarding = false\n[keys]\nnew_tab = \"prefix+t\"\n")
    Store.subscribe(self())
    :ok = Store.event({:resize, @size}, @size)
    kb = Store.snapshot().ui.keybinds
    assert Keybinds.lookup(kb, :prefix, {"t", []}) == {Prompt, :new_tab, []}

    File.write!(path, "onboarding = false\n[keys]\nnew_tab = \"prefix+y\"\n")
    assert_receive {:app_changed, _}, 500
    :ok = Store.run({Actions, :reload_config, []}, @size)
    assert_receive {:notice, %{level: :info, text: "reloaded config"}}, 500
    assert_receive {:app_changed, app}, 500
    assert Keybinds.lookup(app.ui.keybinds, :prefix, {"y", []}) == {Prompt, :new_tab, []}
    assert Keybinds.lookup(app.ui.keybinds, :prefix, {"t", []}) == nil
  end

  test "a missing file opens onboarding; dismissing it writes onboarding = false",
       %{path: path} do
    :ok = Store.event({:resize, @size}, @size)
    assert [%{kind: :onboarding}] = Store.snapshot().focus.modal
    :ok = Store.event(HerdrScene.Event.key(:enter), @size)
    assert Store.snapshot().focus.modal == []
    assert File.read!(path) == "onboarding = false\n"
  end

  test "diagnostics are one warning notice to every subscriber", %{path: path} do
    File.write!(path, "onboarding = false\n[keys]\nnope = \"prefix+t\"\nnew_tab = \"hyper+x\"\n")
    Store.subscribe(self())
    :ok = Store.event({:resize, @size}, @size)
    assert_receive {:notice, %{level: :warning, text: text}}, 500
    assert text =~ "nope"
    assert text =~ "hyper+x"
    refute_receive {:notice, %{level: :warning}}, 100

    # a later subscriber sees the standing diagnostics
    me = self()
    pid = spawn(fn -> receive(do: (m -> send(me, {:late, m}))) end)
    Store.subscribe(pid)
    assert_receive {:late, {:notice, %{level: :warning}}}, 500
  end

  test "a failed write warns the origin", %{path: path} do
    # the atomic write's temp file cannot be created (even as root)
    File.mkdir_p!(path <> ".tmp")
    Store.subscribe(self())
    :ok = Store.event({:resize, @size}, @size)
    :ok = Store.event(HerdrScene.Event.key(:enter), @size)
    assert_receive {:notice, %{level: :warning, text: "config write failed" <> _}}, 500
  end
end
