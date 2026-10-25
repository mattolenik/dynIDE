defmodule HerdrServer.App.Worktrees do
  @moduledoc """
  Git worktrees as workspaces. Git never runs in the Store: the API handler
  (`Api.Handlers.Worktrees`) runs it in its connection process, and the keybind and modal
  flow emits `{:worktree, op, args}`, which the Store runs in a task (`run/2`, through
  `HerdrReload.Guard`) that answers `{:worktree_done, result}` (`done/2`).

  In the Store (pure): `open/4,5` adds a workspace whose first pane starts in the checkout
  (`auto_name: true`, named by the caller's `Workspaces.Label.auto/1`, and `cwd` set
  right away), `close/2` closes workspaces, `done/2` applies a task's result, and
  `create/3`, `list/2`, `remove/3` emit the effects for a source workspace id. The
  effect carries its root pane, polled cwd and `ui.worktrees_dir` (config `[worktrees]
  directory`); `run/2` reads the live cwd off the Store.

  Off the Store: `run/2`, `root_cwd/1`, `open_ids/1`.
  """

  alias HerdrServer.App.{Modal, Workspaces}
  alias HerdrServer.App.Modal.{Confirm, Menu}
  alias HerdrServer.App.Workspaces.Label
  alias HerdrServer.{Layout, Worktree}
  alias HerdrServer.Persist.Facts

  @type app :: HerdrServer.App.Actions.app()
  @type result ::
          {:open, Path.t(), binary | nil}
          | {:list, [%{path: Path.t(), label: binary | nil, branch: binary | nil}]}
          | {:removed, Path.t()}
          | {:dirty, pos_integer}
          | {:error, binary}

  # --- in the Store ---

  @doc "Adds a workspace on `path` named `label`; it keeps auto-naming unless `auto?` is false."
  @spec open(app, Path.t(), binary | nil, boolean, boolean) :: {app, [tuple]}
  def open(app, path, label, focus?, auto? \\ true) do
    {app, [{:spawn, id, size}]} = Workspaces.new_workspace(app, label, focus?)

    app =
      update_in(app.session.workspaces, fn wss ->
        List.update_at(wss, -1, &Map.merge(&1, %{auto_name: auto? or label == nil, cwd: path}))
      end)

    {app, [{:spawn, id, size, %{cwd: path, replay: nil}}]}
  end

  @doc "Closes workspaces `ids` (the last one is replaced by a fresh one)."
  @spec close(app, [term]) :: {app, [tuple]}
  def close(app, ids) do
    Enum.reduce(ids, {app, []}, fn id, {app, fx} ->
      {app, more} = Workspaces.close_workspace(app, id)
      {app, fx ++ more}
    end)
  end

  @spec create(app, term, binary) :: {app, [tuple]}
  def create(app, ws_id, branch), do: effect(app, ws_id, :create, %{branch: branch})

  @spec list(app, term) :: {app, [tuple]}
  def list(app, ws_id), do: effect(app, ws_id, :list, %{})

  @spec remove(app, term, boolean) :: {app, [tuple]}
  def remove(app, ws_id, force?), do: effect(app, ws_id, :remove, %{force: force?})

  # args: the source workspace, its root pane and polled cwd (`run/2` prefers the live
  # one, as `root_cwd/1` does) and the configured checkout directory
  defp effect(app, ws_id, op, args) do
    case Enum.find(app.session.workspaces, &(&1.id == ws_id)) do
      nil ->
        {app, []}

      ws ->
        src = %{ws: ws_id, pane: root_pane(ws), cwd: ws[:cwd], dir: app.ui.worktrees_dir}
        {app, [{:worktree, op, Map.merge(src, args)}]}
    end
  end

  @doc "Applies a `run/2` result."
  @spec done(app, result) :: {app, [tuple]}
  def done(app, {:open, path, label}), do: open(app, path, label, true)

  def done(app, {:list, []}), do: notice(app, :info, "no worktrees to open")
  def done(app, {:list, entries}), do: Menu.worktrees(app, entries)

  # the Store side matches checkouts on the polled `ws.cwd`: the live cwd is a kernel read,
  # which `root_cwd/1` does only off the Store
  def done(app, {:removed, path}) do
    ids = for ws <- app.session.workspaces, under?(ws[:cwd], path), do: ws.id
    {app, fx} = close(app, ids)
    {app, fx ++ [{:notice, %{level: :info, text: "removed worktree #{path}"}}]}
  end

  def done(app, {:dirty, ws_id}) do
    modal =
      Confirm.new(
        "Worktree has changes",
        "remove it anyway? uncommitted changes are lost",
        :danger,
        {__MODULE__, :remove, [ws_id, true]}
      )

    {Modal.push(app, modal), []}
  end

  def done(app, {:error, msg}), do: notice(app, :warning, msg)

  @doc "The workspace whose cwd lies in checkout `path` (nested checkouts: the deepest wins)."
  @spec owner([{term, binary | nil}], [Path.t()], Path.t()) :: term | nil
  def owner(ws_cwds, paths, path) do
    Enum.find_value(ws_cwds, fn {id, cwd} -> if deepest(paths, cwd) == path, do: id end)
  end

  defp deepest(paths, cwd) do
    paths |> Enum.filter(&under?(cwd, &1)) |> Enum.max_by(&byte_size/1, fn -> nil end)
  end

  @spec under?(binary | nil, Path.t()) :: boolean
  def under?(nil, _path), do: false
  def under?(cwd, path), do: cwd == path or String.starts_with?(cwd, path <> "/")

  @spec root_pane(map) :: pos_integer
  def root_pane(ws), do: ws.tabs |> hd() |> Map.fetch!(:layout) |> Layout.pane_ids() |> hd()

  defp notice(app, level, text), do: {app, [{:notice, %{level: level, text: text}}]}

  # --- off the Store ---

  @doc "Runs git for an effect `{:worktree, op, args}`; the result goes to `done/2`."
  @spec run(:create | :list | :remove, map) :: result
  def run(:create, %{branch: branch} = src) do
    with {:ok, cwd} <- src_cwd(src),
         {:ok, path} <- Worktree.create(cwd, branch, nil, nil, src.dir) do
      {:open, path, Label.auto(path)}
    else
      {:error, :linked_worktree_source} -> {:error, Worktree.linked_source_message()}
      err -> err
    end
  end

  def run(:list, src) do
    with {:ok, cwd} <- src_cwd(src),
         {:ok, repo} <- Worktree.repo(cwd),
         {:ok, entries} <- Worktree.list(repo.root) do
      {:list,
       for(
         e <- entries,
         not e.bare? and not e.prunable?,
         do: %{path: e.path, branch: e.branch, label: Label.auto(e.path)}
       )}
    end
  end

  def run(:remove, %{force: force?} = src) do
    with {:ok, cwd} <- src_cwd(src) do
      case Worktree.remove_at(cwd, force?) do
        {:ok, path} -> {:removed, path}
        {:error, :dirty} -> {:dirty, src.ws}
        err -> err
      end
    end
  end

  @doc "A workspace's root pane cwd: the live one, else the last one `WorkspaceFacts` saw."
  @spec root_cwd(map) :: binary | nil
  def root_cwd(ws), do: Facts.cwd(root_pane(ws)) || ws[:cwd]

  defp src_cwd(%{pane: pane, cwd: cwd}) do
    case Facts.cwd(pane) || cwd do
      nil -> {:error, "the workspace's directory is not known"}
      cwd -> {:ok, cwd}
    end
  end

  @doc "`{workspace_id, root cwd}` for every workspace of `app`."
  @spec open_ids(app) :: [{term, binary | nil}]
  def open_ids(app), do: for(ws <- app.session.workspaces, do: {ws.id, root_cwd(ws)})
end
