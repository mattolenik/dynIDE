defmodule HerdrServer.Persist.SchemaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias HerdrServer.App.{Actions, Keybinds}
  alias HerdrServer.Persist.Schema

  defp fresh, do: elem(Actions.init(%{cols: 80, rows: 24}), 0)

  defp step(app, fun, args \\ []), do: elem(apply(Actions, fun, [app | args]), 0)

  # two tabs, the first split once: panes 1, 2 (tab 1) and 3 (tab 2)
  defp three do
    fresh() |> step(:split, [:horizontal]) |> step(:new_tab)
  end

  defp put_ws(s, fun), do: update_in(s, [:session, :workspaces], fn [ws] -> [fun.(ws)] end)

  defp put_tab(s, i, fun) do
    put_ws(s, fn ws -> %{ws | tabs: List.update_at(ws.tabs, i, fun)} end)
  end

  describe "capture/2" do
    test "an initial app has exactly the v1 shape" do
      assert Schema.version() == 1

      assert Schema.capture(fresh(), %{1 => %{cwd: "/tmp", command: ["/bin/zsh"], hidden: true}}) ==
               %{
                 v: 1,
                 session: %{
                   workspaces: [
                     %{
                       id: 1,
                       name: "1",
                       active_tab: 1,
                       tabs: [
                         %{
                           id: 1,
                           name: "1",
                           layout: %{root: {:pane, 1}, focus: 1, prev_focus: nil}
                         }
                       ]
                     }
                   ],
                   active_workspace: 1,
                   next_id: 2,
                   area: %{x: 0, y: 0, w: 80, h: 23}
                 },
                 focus: %{pane: 1},
                 ui: %{status: %{show_hints: true}, theme: :default},
                 panes: %{1 => %{title: nil, cwd: "/tmp", command: ["/bin/zsh"], hidden: true}}
               }
    end

    test "missing facts are nil, nil, false" do
      assert Schema.capture(fresh(), %{}).panes == %{
               1 => %{title: nil, cwd: nil, command: nil, hidden: false}
             }
    end

    test "split ratios and titles are kept" do
      app = three() |> step(:switch_tab, [1]) |> step(:resize_dir, [:right, 0.1])
      app = elem(Actions.apply(app, {:pane_title, 2, "vim"}), 0)
      s = Schema.capture(app, %{})
      [ws] = s.session.workspaces
      assert {:split, :horizontal, r, {:pane, 1}, {:pane, 2}} = hd(ws.tabs).layout.root
      assert is_float(r) and r != 0.5
      assert s.panes[2].title == "vim"
    end
  end

  describe "restore/1" do
    test "gives back session and focus, pane metas at layout_gen 0, modal []" do
      app = three()
      app = put_in(app.session.panes[2].layout_gen, 7)
      app = put_in(app.focus.modal, [:something])
      facts = %{2 => %{cwd: "/home", command: nil, hidden: false}}

      assert {:ok, a2, f2} = Schema.restore(Schema.capture(app, facts))
      assert a2.session == put_in(app.session.panes[2].layout_gen, 0).session
      assert a2.focus == %{app.focus | modal: []}
      assert a2.ui.keybinds == Keybinds.default()
      assert a2.ui == app.ui

      assert f2 == %{
               1 => %{cwd: nil, command: nil, hidden: false},
               2 => %{cwd: "/home", command: nil, hidden: false},
               3 => %{cwd: nil, command: nil, hidden: false}
             }
    end

    test "an unknown ui key is dropped and a missing one defaulted" do
      s = Schema.capture(fresh(), %{})
      s = %{s | ui: %{foo: 1, status: %{show_hints: false}}}
      assert {:ok, a2, _} = Schema.restore(s)
      assert a2.ui.status == %{show_hints: false}
      assert a2.ui.theme == :default
      refute Map.has_key?(a2.ui, :foo)
    end

    test "next_id at or below the max pane id is repaired, not an error" do
      s = three() |> Schema.capture(%{}) |> put_in([:session, :next_id], 2)
      assert {:ok, a2, _} = Schema.restore(s)
      assert a2.session.next_id == 4
    end

    test "a layout pane missing from panes is invalid" do
      s = three() |> Schema.capture(%{}) |> update_in([:panes], &Map.delete(&1, 2))
      assert {:error, {:invalid, _}} = Schema.restore(s)
    end

    test "a pane in panes but in no layout is invalid" do
      s =
        put_in(Schema.capture(fresh(), %{}), [:panes, 9], %{
          title: nil,
          cwd: nil,
          command: nil,
          hidden: false
        })

      assert {:error, {:invalid, _}} = Schema.restore(s)
    end

    test "a pane in two layouts is invalid" do
      s = three() |> Schema.capture(%{})
      s = put_tab(s, 1, &put_in(&1.layout.root, {:split, :vertical, 0.5, {:pane, 3}, {:pane, 1}}))
      assert {:error, {:invalid, _}} = Schema.restore(s)
    end

    test "a workspace without tabs is invalid" do
      s = fresh() |> Schema.capture(%{}) |> put_ws(&%{&1 | tabs: []})
      assert {:error, {:invalid, _}} = Schema.restore(s)
    end

    test "an active_tab that does not exist is invalid" do
      s = fresh() |> Schema.capture(%{}) |> put_ws(&%{&1 | active_tab: 5})
      assert {:error, {:invalid, _}} = Schema.restore(s)
    end

    test "an active_workspace that does not exist is invalid" do
      s = fresh() |> Schema.capture(%{}) |> put_in([:session, :active_workspace], 3)
      assert {:error, {:invalid, _}} = Schema.restore(s)
    end

    test "a layout focus that does not exist is invalid" do
      s = fresh() |> Schema.capture(%{}) |> put_tab(0, &put_in(&1.layout.focus, 2))
      assert {:error, {:invalid, _}} = Schema.restore(s)
    end

    test "non-plain terms are invalid" do
      s = Schema.capture(fresh(), %{})
      assert {:error, {:invalid, _}} = Schema.restore(put_in(s, [:ui, :status], fn -> 1 end))
      assert {:error, {:invalid, _}} = Schema.restore(put_in(s, [:panes, 1, :cwd], self()))
    end

    test "a malformed snapshot is an error, not a crash" do
      s = Schema.capture(fresh(), %{})
      assert {:error, {:invalid, _}} = Schema.restore(put_in(s, [:session, :workspaces], :nope))

      assert {:error, {:invalid, _}} =
               Schema.restore(put_tab(s, 0, &put_in(&1.layout.root, {:pane, "x"})))

      assert {:error, {:invalid, _}} = Schema.restore(%{v: 1})
      assert {:error, _} = Schema.restore(:garbage)
    end

    test "a newer snapshot is refused" do
      assert {:error, {:newer, 2}} = Schema.restore(%{Schema.capture(fresh(), %{}) | v: 2})
    end
  end

  describe "plain?/1" do
    test "data is plain, funs, pids and refs are not" do
      assert Schema.plain?(%{a: [1, 2.5, "x", nil, true, {:pane, 1}], b: %{}})
      refute Schema.plain?(fn -> 1 end)
      refute Schema.plain?(&IO.puts/1)
      refute Schema.plain?([self()])
      refute Schema.plain?(%{a: make_ref()})
      refute Schema.plain?({:ok, [1 | 2]})
    end
  end

  describe "migrate/2" do
    def up(%{v: 0} = m), do: m |> Map.delete(:old) |> Map.put(:v, 1)

    test "a newer version is refused" do
      assert Schema.migrate(%{v: 2}) == {:error, {:newer, 2}}
    end

    test "a non-integer or missing version is unknown" do
      assert Schema.migrate(%{v: "1"}) == {:error, {:unknown_version, "1"}}
      assert Schema.migrate(%{}) == {:error, {:unknown_version, nil}}
    end

    test "an older version with no migration is unknown" do
      assert Schema.migrate(%{v: 0}) == {:error, {:unknown_version, 0}}
    end

    test "the current version is unchanged" do
      assert Schema.migrate(%{v: 1, x: 2}) == {:ok, %{v: 1, x: 2}}
    end

    test "a synthetic chain is applied in order" do
      chain = %{0 => {__MODULE__, :up}}
      assert Schema.migrate(%{v: 0, old: true, x: 1}, chain) == {:ok, %{v: 1, x: 1}}
    end
  end

  # --- fixed-point property ---

  @steps [
    {:split, [:horizontal]},
    {:split, [:vertical]},
    {:new_tab, []},
    {:next_tab, []},
    {:close_pane, []},
    {:close_tab, []},
    {:cycle, [:next]},
    {:switch_tab, [1]},
    {:switch_tab, [2]},
    {:switch_tab, [3]},
    {:switch_tab, [4]},
    {:resize_dir, [:left, 0.1]},
    {:resize_dir, [:right, 0.1]},
    {:resize_dir, [:up, 0.1]},
    {:resize_dir, [:down, 0.1]}
  ]

  defp app_gen do
    gen all(
          cols <- integer(40..250),
          rows <- integer(10..80),
          steps <- list_of(member_of(@steps), max_length: 30)
        ) do
      app = elem(Actions.init(%{cols: cols, rows: rows}), 0)
      Enum.reduce(steps, app, fn {f, a}, acc -> step(acc, f, a) end)
    end
  end

  defp title_gen, do: one_of([constant(nil), string(:utf8, max_length: 40)])

  defp fact_gen do
    gen all(
          cwd <- one_of([constant(nil), map(string(:printable), &("/" <> &1))]),
          command <- member_of([nil, ["/bin/zsh"]]),
          hidden <- boolean()
        ) do
      %{cwd: cwd, command: command, hidden: hidden}
    end
  end

  defp world_gen do
    gen all(
          app <- app_gen(),
          ids = Map.keys(app.session.panes),
          titles <- fixed_list(Enum.map(ids, fn _ -> title_gen() end)),
          facts <- fixed_list(Enum.map(ids, fn _ -> fact_gen() end))
        ) do
      app =
        ids
        |> Enum.zip(titles)
        |> Enum.reduce(app, fn {id, t}, acc ->
          elem(Actions.apply(acc, {:pane_title, id, t}), 0)
        end)

      {app, ids |> Enum.zip(facts) |> Map.new()}
    end
  end

  property "snapshot -> restore -> snapshot is a fixed point" do
    check all({app, facts} <- world_gen(), max_runs: 300) do
      s = Schema.capture(app, facts)
      assert {:ok, a2, f2} = Schema.restore(s)
      assert Schema.capture(a2, f2) == s
      assert Schema.plain?(s)
      assert :erlang.binary_to_term(:erlang.term_to_binary(s), [:safe]) == s
    end
  end
end
