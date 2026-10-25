defmodule HerdrIntegration.ArchitectureTest do
  @moduledoc """
  Contract decision 10: no compiled module references another app's modules
  across the server/terminal boundary. Cross-app calls go through MFA tuples
  and registered names carried by the protocol.
  """
  use ExUnit.Case, async: true

  alias HerdrScene.{Cell, Event}
  alias HerdrServer.App.Actions
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
  # puts in a frame must exist in the client VM: OTP's and Elixir's plus these apps' (it
  # preloads them); a module's atoms chunk stands for its atoms once loaded
  test "the remote client's apps know every handoff phase the server broadcasts" do
    {:ok, types} = Code.Typespec.fetch_types(HerdrServer.Handoff.Notice)
    [ast] = for {:type, {:event, ast, []}} <- types, do: ast
    {_, phases} = Macro.prewalk(Code.Typespec.type_to_quoted({:event, ast, []}), [], &atoms/2)

    client =
      for app <- [:kernel, :stdlib, :elixir, :logger, :herdr_scene, :herdr_reload, :herdr_term],
          {:ok, mods} = :application.get_key(app, :modules),
          mod <- mods,
          {:ok, {_, [atoms: atoms]}} <- [:beam_lib.chunks(:code.which(mod), [:atoms])],
          {_, a} <- atoms,
          into: MapSet.new(),
          do: a

    assert :adopted in phases
    assert Enum.reject(phases, &(&1 in client)) == []
  end

  # every atom of every server message a socket client can get must be in the client VM
  test "every atom a socket client receives exists on the client" do
    client = client_atoms()

    leaks =
      for {name, msg} <- server_messages(),
          atom <- msg |> walk([]) |> Enum.uniq(),
          not MapSet.member?(client, atom),
          do: "#{inspect(atom)} in #{name}"

    assert leaks == [], "atoms unknown to the remote client:\n" <> Enum.join(leaks, "\n")
  end

  test "the walk finds map keys and struct names (negative control)" do
    found = walk({:a, %{k: [%HerdrScene.Scene.Node{role: :r}]}}, [])
    assert [:a, :k, HerdrScene.Scene.Node, :role, :r, :children] -- found == []
  end

  # prefix + key, as a client would
  defp pfx(app, key) do
    input = %{mode: :prefix, swallow: MapSet.new()}

    {_, {:run, {m, f, a}}} =
      Keys.resolve(input, app.ui.keybinds, Event.key(key))

    elem(Kernel.apply(m, f, [app | a]), 0)
  end

  # the atoms chunk plus the atoms inside literals (constant lists and maps compile to the
  # literal table); loading a module creates both
  defp client_atoms do
    for app <- [:kernel, :stdlib, :elixir, :logger, :herdr_scene, :herdr_reload, :herdr_term],
        {:ok, mods} = :application.get_key(app, :modules),
        mod <- mods,
        {:ok, {_, [atoms: atoms, literals: lits]}} <-
          [:beam_lib.chunks(:code.which(mod), [:atoms, :literals])],
        a <- Enum.map(atoms, &elem(&1, 1)) ++ walk(lits, []),
        into: MapSet.new(),
        do: a
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

    handoffs =
      for phase <- [:begin, :aborted, :released, :adopted] do
        {"handoff #{phase}", {:handoff, %{phase: phase, gen: 2, panes: [1, 2]}}}
      end

    scenes ++ statuses ++ pane_scenes ++ handoffs ++ simple_messages(row)
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
        r <- [:requested, :store_restart, :replaced, :session_ended, :pane_closed],
        do: {"detached #{r}", {:detached, r}}
      )
  end

  defp atoms(a, acc) when is_atom(a) and a not in [nil, true, false], do: {a, [a | acc]}
  defp atoms(node, acc), do: {node, acc}
end
