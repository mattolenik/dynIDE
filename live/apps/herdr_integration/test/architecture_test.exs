defmodule HerdrIntegration.ArchitectureTest do
  @moduledoc """
  Contract decision 10: no compiled module references another app's modules
  across the server/terminal boundary. Cross-app calls go through MFA tuples
  and registered names carried by the protocol.
  """
  use ExUnit.Case, async: true

  alias HerdrScene.{Cell, Event}
  alias HerdrScene.Scene.Pane, as: ScenePane
  alias HerdrServer.App.{Actions, Modal}
  alias HerdrServer.Client.{Keys, PaneScene, State}
  alias HerdrServer.{RuntimeStatus, View}

  # Atoms in `app`'s compiled beams that start with any of `prefixes`, as {module, atom}.
  defp refs(app, prefixes) do
    {:ok, mods} = :application.get_key(app, :modules)

    for mod <- mods,
        {:ok, {^mod, [atoms: atoms]}} = :beam_lib.chunks(:code.which(mod), [:atoms]),
        {_, atom} <- atoms,
        name = Atom.to_string(atom),
        String.starts_with?(name, prefixes),
        do: {mod, atom}
  end

  test "the scan reads atoms (negative control)" do
    assert {HerdrServer.App.Store, HerdrScene.Protocol} in refs(:herdr_server, [
             "Elixir.HerdrScene"
           ])
  end

  test "herdr_server references no HerdrTerm module" do
    assert refs(:herdr_server, ["Elixir.HerdrTerm"]) == []
  end

  test "herdr_term references no HerdrServer module" do
    assert refs(:herdr_term, ["Elixir.HerdrServer"]) == []
  end

  test "herdr_reload references neither HerdrServer nor HerdrTerm" do
    assert refs(:herdr_reload, ["Elixir.HerdrServer", "Elixir.HerdrTerm"]) == []
  end

  test "herdr_scene references neither" do
    assert refs(:herdr_scene, ["Elixir.HerdrServer", "Elixir.HerdrTerm"]) == []
  end

  # M16 R7: a remote client decodes server frames with [:safe], so every atom the server
  # puts in a frame must exist in the client VM. A fresh VM that preloads the client's apps
  # the way `HerdrTerm.Remote.main/1` does decodes each atom with [:safe]; the ones it
  # rejects are leaks.
  test "every atom a socket client receives exists on the client" do
    leaks = leaks(server_messages())
    assert leaks == [], "atoms unknown to the remote client:\n" <> Enum.join(leaks, "\n")
  end

  test "the leak check reports a server-only atom (negative control)" do
    fresh = String.to_atom("server_only_#{System.unique_integer([:positive])}")

    leaks = leaks([{"module", {:x, HerdrServer.View}}, {"fresh", %{k: [{:ok, fresh}]}}])
    assert leaks == [~s(HerdrServer.View in module), "#{inspect(fresh)} in fresh"]
    assert leaks([{"ok", {:notice, %{level: :info, text: "t"}}}]) == []
  end

  test "the walk finds map keys and struct names" do
    found = walk({:a, %{k: [%HerdrScene.Scene.Node{role: :r}]}}, [])
    assert [:a, :k, HerdrScene.Scene.Node, :role, :r, :children] -- found == []
  end

  test "every {:detached, reason} the server sends is in Protocol.detach_reasons/0" do
    lib = Path.expand("../../herdr_server/lib", __DIR__)

    sent =
      for file <- Path.wildcard(Path.join(lib, "**/*.ex")),
          [_, reason] <- Regex.scan(~r/\{:detached,\s*:(\w+)\}/, File.read!(file)),
          uniq: true,
          do: String.to_atom(reason)

    assert sent != []
    assert sent -- HerdrScene.Protocol.detach_reasons() == []
  end

  defp leaks(messages) do
    atoms =
      for {name, msg} <- messages,
          atom <- msg |> walk([]) |> Enum.uniq(),
          do: {atom, name}

    missing = missing_on_client(atoms |> Enum.map(&elem(&1, 0)) |> Enum.uniq())
    for {atom, name} <- atoms, atom in missing, do: "#{inspect(atom)} in #{name}"
  end

  @child ~S"""
  [file] = System.argv()
  HerdrTerm.Remote.preload()
  {:ok, _} = Application.ensure_all_started(:logger)

  missing =
    for hex <- File.read!(file) |> String.split(),
        name = Base.decode16!(hex),
        byte_size(name) < 256,
        not (try do
               :erlang.binary_to_term(<<131, 119, byte_size(name)>> <> name, [:safe])
               true
             rescue
               ArgumentError -> false
             end),
        do: hex

  IO.puts("MISSING " <> Enum.join(missing, ","))
  """

  defp missing_on_client(atoms) do
    dir = Path.join(System.tmp_dir!(), "r7_#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "atoms")
    File.write!(file, Enum.map_join(atoms, "\n", &Base.encode16(Atom.to_string(&1))))
    pa = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])
    {out, 0} = System.cmd("elixir", pa ++ ["-e", @child, file], stderr_to_stdout: true)
    File.rm_rf!(dir)
    [_, hexes] = Regex.run(~r/MISSING (.*)/, out) || flunk("client VM check failed:\n" <> out)
    names = hexes |> String.split(",", trim: true) |> MapSet.new(&Base.decode16!/1)
    Enum.filter(atoms, &MapSet.member?(names, Atom.to_string(&1)))
  end

  # prefix + key, as a client would
  defp pfx(app, key) do
    input = %{mode: :prefix, swallow: MapSet.new()}

    {_, {:run, {m, f, a}}} =
      Keys.resolve(input, app.ui.keybinds, Event.key(key))

    elem(Kernel.apply(m, f, [app | a]), 0)
  end

  defp handoff_phases do
    {:ok, types} = Code.Typespec.fetch_types(HerdrServer.Handoff.Notice)
    [ast] = for {:type, {:event, ast, []}} <- types, do: ast
    {_, phases} = Macro.prewalk(Code.Typespec.type_to_quoted({:event, ast, []}), [], &atoms/2)
    true = :adopted in phases
    phases
  end

  defp walk(t, acc) when is_atom(t) and t not in [nil, true, false], do: [t | acc]

  defp walk(%name{} = s, acc), do: s |> Map.from_struct() |> walk([name | acc])
  defp walk(%{} = m, acc), do: Enum.reduce(m, acc, fn {k, v}, a -> walk(v, walk(k, a)) end)
  defp walk(t, acc) when is_tuple(t), do: t |> Tuple.to_list() |> walk(acc)
  defp walk([h | t], acc), do: walk(t, walk(h, acc))
  defp walk(_, acc), do: acc

  defp server_messages do
    {app, _} = Actions.init(%{cols: 100, rows: 30})
    split = app |> pfx("v") |> pfx("-") |> pfx("c")

    state = fn mode, extra ->
      struct(State, [size: %{cols: 100, rows: 30}, transport: :inline, mode: mode] ++ extra)
    end

    rt =
      Enum.reduce(
        [
          {:herdr_reload, {:loaded, 3, [A, B]}},
          {:herdr_reload, {:tests, :failed, %{files: 2, failures: 1, ms: 40}}},
          {:handoff, %{phase: :adopted, gen: 2, panes: [1], kind: :graceful}}
        ],
        RuntimeStatus.new(),
        &RuntimeStatus.apply(&2, &1, 0)
      )

    notice = %{level: :warning, text: "n", ref: nil}

    scenes =
      for mode <- [:terminal, :prefix, :resize],
          {label, a} <- [single: app, split: split],
          {extra_label, extra} <- [plain: [], full: [runtime: rt, notice: notice]] do
        {"scene #{label}/#{mode}/#{extra_label}", {:scene, View.compute(a, state.(mode, extra))}}
      end

    # one status state per reload/handoff outcome
    statuses =
      for {n, ev} <- [
            rolled_back: {:herdr_reload, {:rolled_back, 4, [A], :manual}},
            compile_error: {:herdr_reload, {:compile_error, [%{message: "x"}]}},
            synced: {:herdr_reload, {:synced, [A]}},
            rejected: {:herdr_reload, {:rejected, A, "p"}},
            purge_blocked: {:herdr_reload, {:purge_blocked, A, []}},
            tests_running: {:herdr_reload, {:tests, :running, %{}}},
            tests_passed: {:herdr_reload, {:tests, :passed, %{files: 1}}},
            tests_error: {:herdr_reload, {:tests, :error, %{}}},
            handoff_begin: {:handoff, %{phase: :begin, gen: 1, panes: [1]}},
            handoff_aborted: {:handoff, %{phase: :aborted, gen: 1, panes: [1]}},
            handoff_released: {:handoff, %{phase: :released, gen: 1, panes: [1]}},
            handoff_adopted: {:handoff, %{phase: :adopted, gen: 1, panes: [1], kind: :crash}}
          ] do
        st = RuntimeStatus.apply(RuntimeStatus.new(), ev, 0)
        {"scene status #{n}", {:scene, View.compute(app, state.(:terminal, runtime: st))}}
      end

    row = Cell.blank_row(10)
    cursor = %{x: 1, y: 0, shape: :block, visible: true}
    size = %{cols: 20, rows: 5}

    pane_scenes =
      for {n, c} <- [
            block: cursor,
            bar: %{cursor | shape: :bar},
            underline: %{cursor | shape: :underline},
            hidden: %{cursor | visible: false},
            none: nil
          ] do
        {"pane scene #{n}", {:scene, PaneScene.build(1, {0, {row, row}, c}, size)}}
      end ++ [{"pane scene empty", {:scene, PaneScene.build(1, nil, size)}}]

    # every pane layer (the popup scene itself lands with App.Modal.Popup)
    base = View.compute(app, state.(:terminal, []))

    layers =
      for l <- ScenePane.layers() do
        {"pane layer #{l}", {:scene, %{base | panes: Enum.map(base.panes, &%{&1 | layer: l})}}}
      end

    handoffs =
      for phase <- handoff_phases() do
        {"handoff #{phase}", {:handoff, %{phase: phase, gen: 2, panes: [1, 2]}}}
      end

    scenes ++
      statuses ++
      modal_scenes(split, state.(:terminal, [])) ++
      pane_scenes ++ layers ++ handoffs ++ simple_messages(row)
  end

  # every M13 modal kind open over the split app (menus, prompts, confirms, settings, ...)
  defp modal_scenes(app, st) do
    at = %{x: 1, y: 1}
    ws = app.session.active_workspace

    opens = [
      onboarding: &Modal.Onboarding.at_start(%{&1 | ui: %{&1.ui | onboarding: true}}),
      keybinds: &elem(Modal.Keybinds.open(&1), 0),
      settings: &elem(Modal.Settings.open(&1), 0),
      settings_indicators: &settings(&1, 1),
      settings_sound: &settings(&1, 2),
      settings_toasts: &settings(&1, 3),
      new_tab: &elem(Modal.Prompt.new_tab(&1), 0),
      rename_pane: &elem(Modal.Prompt.rename_pane(&1), 0),
      close_pane: &elem(Modal.Confirm.close_pane(&1), 0),
      close_workspace: &elem(Modal.Confirm.close_workspace(&1), 0),
      menu_tab: &elem(Modal.Menu.open(&1, :tab, 1, at), 0),
      menu_workspace: &elem(Modal.Menu.open(&1, :workspace, ws, at), 0),
      menu_pane: &elem(Modal.Menu.open(&1, :pane, &1.focus.pane, at), 0),
      menu_global: &elem(Modal.Menu.open(&1, :global, nil, at), 0)
    ]

    for {n, open} <- opens, do: {"scene modal #{n}", {:scene, View.compute(open.(app), st)}}
  end

  defp settings(app, tabs) do
    {app, _} = Modal.Settings.open(app)
    Enum.reduce(1..tabs, app, fn _, a -> elem(Modal.key(a, Event.key(:tab)), 0) end)
  end

  defp simple_messages(row) do
    [
      {"damage", {:damage, 1, 0}},
      {"rows", {:rows, 1, 0, [{0, row}]}},
      {"ack", {:ack, 1}},
      {"bell", {:bell, 1}},
      {"open_url", {:open_url, "https://x"}},
      {"attached true", {:attached, %{resumed: true, session: "s"}}},
      {"attached false", {:attached, %{resumed: false, session: "s"}}},
      {"attached handoff", {:attached, %{resumed: :handoff, session: "s"}}},
      {"refused", {:refused, "bad token"}}
    ] ++
      for(
        l <- [:info, :warning, :error],
        do: {"notice #{l}", {:notice, %{level: l, text: "t"}}}
      ) ++
      [{"reload notice", {:notice, %{level: :error, text: "t", source: :reload}}}] ++
      for(
        l <- [:info, :attention, :done],
        s <- [:done, :request, nil],
        do:
          {"alert #{l}/#{s}",
           {:alert, %{kind: :notification, level: l, title: "t", body: nil, pane: 1, sound: s}}}
      ) ++
      for(
        s <- [:selection, :pane],
        do: {"clipboard #{s}", {:clipboard, %{text: "t", source: s}}}
      ) ++
      for(m <- [:terminal, :prefix, :resize, :copy], do: {"input_mode #{m}", {:input_mode, m}}) ++
      for(
        r <- HerdrScene.Protocol.detach_reasons(),
        do: {"detached #{r}", {:detached, r}}
      )
  end

  defp atoms(a, acc) when is_atom(a) and a not in [nil, true, false], do: {a, [a | acc]}
  defp atoms(node, acc), do: {node, acc}
end
