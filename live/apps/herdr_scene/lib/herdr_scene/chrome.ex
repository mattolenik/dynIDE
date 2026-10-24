defmodule HerdrScene.Chrome do
  @moduledoc """
  The chrome vocabulary: required props per role, region roles, badge states
  and chrome action kinds. Pure; `HerdrScene.Scene.validate/1` calls
  `errors/2` on every chrome node.

  Region rule: a node with a `rect` is a region; children without rects are
  laid out by the client inside their nearest region. A node with a role in
  `region_roles/0` must carry a rect unless some ancestor carries one; then
  the client lays it out inside that ancestor region (e.g. `:tabs` inside
  `:status`). A region role with no rect-carrying ancestor (e.g. a top-level
  `:modal`) without a rect is rejected.

  Paths are lists of node ids from the root's children down; the root id is
  not part of a path (`[:tabs, {:tab, 2}]`).

  Chrome actions, sent by clients as `{:chrome, path, action}`, are
  `{kind, %{x, y}}` with scene-cell coordinates and `kind` in
  `action_kinds/0`.

  Required props (extra props are allowed):

    * `:tab` `[:index, :active]`
    * `:badge` `[:kind, :state]`; when `kind` is `:agent_state`, `state` is
      in `badge_states/0`
    * `:input` `[:cursor]`, `0 <= cursor <= String.length(text)` (nil text
      counts as `""`)
    * `:keycap` `[:key, :mods]`, `:button` `[:action]`
    * `:modal` `[:kind]`, `:menu` `[:kind]`, `:toast` `[:level]`
    * `:divider` `[:direction, :path]` (pane split) or
      `[:direction, :target]` (named chrome split)
    * every other role: none
  """

  alias HerdrScene.Scene.Node

  @regions [:status, :sidebar, :tabs, :divider, :modal, :menu, :toast]
  @badge_states [:idle, :working, :blocked, :done, :unknown]
  @action_kinds [:click, :double_click, :right_click, :middle_click, :drag, :drop] ++
                  [:scroll_up, :scroll_down]

  @required %{
    tab: [:index, :active],
    badge: [:kind, :state],
    input: [:cursor],
    keycap: [:key, :mods],
    button: [:action],
    modal: [:kind],
    menu: [:kind],
    toast: [:level],
    divider: [:direction, :path]
  }

  @spec region_roles() :: [atom]
  def region_roles, do: @regions

  @spec badge_states() :: [atom]
  def badge_states, do: @badge_states

  @spec action_kinds() :: [atom]
  def action_kinds, do: @action_kinds

  @doc "Props a node of `role` must carry. A divider may carry `:target` instead of `:path`."
  @spec required_props(atom) :: [atom]
  def required_props(role), do: Map.get(@required, role, [])

  @doc """
  Chrome-vocabulary errors for one node (not its children), named under `path`.
  Option `in_region: true` says an ancestor carries a rect (default false).
  """
  @spec errors(binary, term, keyword) :: [binary]
  def errors(path, node, opts \\ [])

  def errors(path, %Node{role: role, props: props} = n, opts) when is_map(props) do
    region_errors(path, n, Keyword.get(opts, :in_region, false)) ++
      props_errors(path, role, props, n)
  end

  def errors(_, _, _), do: []

  defp region_errors(path, %Node{role: role, rect: nil}, false) when role in @regions,
    do: ["#{path}.rect: #{inspect(role)} is a region and needs a rect"]

  defp region_errors(_, _, _), do: []

  defp props_errors(path, role, props, n) do
    case missing(role, props) do
      [] -> value_errors(path, role, props, n)
      missing -> ["#{path}.props: #{inspect(role)} needs #{inspect(missing)}"]
    end
  end

  defp missing(role, props) do
    need =
      if role == :divider and Map.has_key?(props, :target),
        do: [:direction, :target],
        else: required_props(role)

    Enum.reject(need, &Map.has_key?(props, &1))
  end

  defp value_errors(path, :badge, %{kind: :agent_state, state: s}, _) do
    if s in @badge_states,
      do: [],
      else: [
        "#{path}.props.state: unknown #{inspect(s)}, expected one of #{inspect(@badge_states)}"
      ]
  end

  defp value_errors(path, :input, %{cursor: c}, %Node{text: text}) do
    len = if is_binary(text), do: String.length(text), else: 0

    if is_integer(c) and c >= 0 and c <= len,
      do: [],
      else: ["#{path}.props.cursor: expected 0..#{len}, got #{inspect(c)}"]
  end

  defp value_errors(_, _, _, _), do: []
end
