defmodule HerdrIntegration.ArchitectureTest do
  @moduledoc """
  Contract decision 10: no compiled module references another app's modules
  across the server/terminal boundary. Cross-app calls go through MFA tuples
  and registered names carried by the protocol.
  """
  use ExUnit.Case, async: true

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

  defp atoms(a, acc) when is_atom(a) and a not in [nil, true, false], do: {a, [a | acc]}
  defp atoms(node, acc), do: {node, acc}
end
