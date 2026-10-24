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

  test "herdr_scene references neither" do
    assert refs(:herdr_scene, ["Elixir.HerdrServer", "Elixir.HerdrTerm"]) == []
  end
end
