defmodule HerdrServer.Api.Handlers.Worktrees do
  @moduledoc """
  The `worktree.*` handlers (herdr's `worktree list|create|open|remove`). Git runs here,
  in the API connection process, never in the Store; the workspace changes go through
  `App.Store.request/1` on `App.Worktrees`. A source is `workspace_id` (its root pane's
  cwd), `cwd`, or by default the focused workspace. A git failure (no git, not a repo,
  a rejected branch) answers `failed` with git's message; removing a dirty worktree
  without `force` answers `failed` with `data.reason: "dirty"`.
  """

  alias HerdrServer.Api.{Ids, View}
  alias HerdrServer.App.{Commands, Store, Worktrees}
  alias HerdrServer.App.Workspaces.Label
  alias HerdrServer.Worktree

  @type reply :: {:ok, map()} | {:error, atom(), String.t()} | {:error, atom(), String.t(), map()}

  @spec handle(String.t(), map()) :: reply()
  def handle("worktree.list", p) do
    app = app!()

    with {:ok, repo, entries} <- discover(app, p) do
      ctx = ctx(app, repo, entries)

      {:ok,
       %{
         type: "worktree_list",
         source: %{
           repo_name: repo.name,
           repo_root: Worktree.main_root(repo),
           source_checkout_path: repo.root
         },
         worktrees: Enum.map(entries, &info(&1, ctx))
       }}
    end
  end

  def handle("worktree.create", p) do
    app = app!()

    with {:ok, src} <- source(app, p),
         {:ok, path} <- absolute(p[:path]),
         {:ok, root} <- git(Worktree.create(src, p.branch, p[:base], path, nil)),
         {:ok, repo} <- git(Worktree.repo(root)) do
      entry = %{path: root, branch: p.branch, bare?: false, detached?: false, prunable?: false}
      open_new("worktree_created", entry, p, Worktree.main_root(repo))
    end
  end

  def handle("worktree.open", p) do
    app = app!()

    with :ok <- one_target(p),
         {:ok, repo, entries} <- discover(app, p),
         {:ok, entry} <- find_entry(entries, p) do
      {cwds, paths, main} = ctx(app, repo, entries)
      open_entry(app, Worktrees.owner(cwds, paths, entry.path), entry, p, main)
    end
  end

  def handle("worktree.remove", %{workspace_id: w} = p) do
    force? = Map.get(p, :force, false)

    with {:ok, ws} <- find_ws(app!(), w),
         {:ok, cwd} <- known(Worktrees.root_cwd(ws)),
         {:ok, path} <- removed(Worktree.remove_at(cwd, force?)),
         ids = for({id, c} <- Worktrees.open_ids(app!()), Worktrees.under?(c, path), do: id),
         {:ok, _aft} <- request({Worktrees, :close, [ids]}) do
      {:ok,
       %{type: "worktree_removed", workspace_id: Ids.workspace(w), path: path, forced: force?}}
    end
  end

  # --- sources and entries ---

  defp discover(app, p) do
    with {:ok, src} <- source(app, p),
         {:ok, repo} <- git(Worktree.repo(src)),
         {:ok, entries} <- git(Worktree.list(repo.root)),
         do: {:ok, repo, entries}
  end

  defp source(_app, %{workspace_id: _, cwd: _}),
    do: {:error, :invalid_params, "give at most one of workspace_id and cwd"}

  defp source(_app, %{cwd: cwd}), do: absolute(cwd)

  defp source(app, p) do
    with {:ok, ws} <- find_ws(app, p[:workspace_id] || app.session.active_workspace),
         do: known(Worktrees.root_cwd(ws))
  end

  defp one_target(p) do
    if Map.has_key?(p, :path) != Map.has_key?(p, :branch),
      do: :ok,
      else: {:error, :invalid_params, "give exactly one of path and branch"}
  end

  defp find_entry(entries, %{branch: b}),
    do: entry(Enum.find(entries, &(&1.branch == b)), "no worktree has branch #{b}")

  defp find_entry(entries, %{path: path}) do
    with {:ok, path} <- absolute(path) do
      # git reports resolved paths; the repo lookup resolves the caller's the same way
      path =
        case Worktree.repo(path) do
          {:ok, %{root: root}} -> root
          _ -> Path.expand(path)
        end

      entry(Enum.find(entries, &(&1.path == path)), "no worktree at #{path}")
    end
  end

  defp entry(nil, msg), do: {:error, :not_found, msg}

  defp entry(%{bare?: b, prunable?: p} = e, _msg) when b or p,
    do: {:error, :failed, "worktree #{e.path} cannot be opened"}

  defp entry(e, _msg), do: {:ok, e}

  defp ctx(app, repo, entries),
    do: {Worktrees.open_ids(app), Enum.map(entries, & &1.path), Worktree.main_root(repo)}

  defp info(e, {cwds, paths, main}),
    do: info(e, main, Worktrees.owner(cwds, paths, e.path))

  defp info(e, main, ws_id) do
    %{
      path: e.path,
      branch: e.branch,
      is_bare: e.bare?,
      is_detached: e.detached?,
      is_prunable: e.prunable?,
      is_linked_worktree: e.path != main,
      open_workspace_id: ws_id && Ids.workspace(ws_id),
      label: Label.auto(e.path) || e.path
    }
  end

  # --- workspaces ---

  defp open_new(type, entry, p, main) do
    label = p[:label] || Label.auto(entry.path)
    mfa = {Worktrees, :open, [entry.path, label, Map.get(p, :focus, false), p[:label] == nil]}
    before = app!()

    with {:ok, aft} <- request(mfa) do
      case Enum.reject(aft.session.workspaces, &View.find_workspace(before, &1.id)) do
        [ws | _] ->
          {:ok, Map.merge(described(aft, ws), %{type: type, worktree: info(entry, main, ws.id)})}

        [] ->
          {:error, :internal, "no workspace was created"}
      end
    end
  end

  defp open_entry(_app, nil, entry, p, main) do
    with {:ok, r} <- open_new("worktree_opened", entry, p, main),
         do: {:ok, Map.put(r, :already_open, false)}
  end

  defp open_entry(app, id, entry, p, main) do
    focused =
      if Map.get(p, :focus, false),
        do: request({Commands, :focus_workspace, [id]}),
        else: {:ok, app}

    with {:ok, app} <- focused do
      extra = %{type: "worktree_opened", worktree: info(entry, main, id), already_open: true}
      {:ok, Map.merge(described(app, View.find_workspace(app, id)), extra)}
    end
  end

  defp described(app, ws) do
    tab = Enum.find(ws.tabs, &(&1.id == ws.active_tab))

    %{
      workspace: View.workspace(app, ws),
      tab: View.tab(app, ws, tab),
      root_pane: View.pane(app, tab.layout.focus)
    }
  end

  defp find_ws(app, w) do
    case View.find_workspace(app, w) do
      nil -> {:error, :not_found, "#{Ids.workspace(w)} not found"}
      ws -> {:ok, ws}
    end
  end

  # --- git results ---

  defp git({:error, msg}) when is_binary(msg), do: {:error, :failed, msg}
  defp git(ok), do: ok

  defp removed({:error, :dirty}),
    do:
      {:error, :failed, "the worktree has uncommitted changes (dirty); pass force to remove it",
       %{reason: "dirty"}}

  defp removed(result), do: git(result)

  defp known(nil), do: {:error, :failed, "the workspace's directory is not known"}
  defp known(cwd), do: {:ok, cwd}

  defp absolute(nil), do: {:ok, nil}

  defp absolute(path) do
    if Path.type(path) == :absolute,
      do: {:ok, path},
      else: {:error, :invalid_params, "#{path} is not an absolute path"}
  end

  # --- store ---

  defp app! do
    case Store.snapshot() do
      nil -> with {:ok, _, aft} <- Store.request({Commands, :noop, []}), do: aft
      app -> app
    end
  end

  # the app after `mfa`; a crashed command (error notice) is `internal`, a warning `failed`
  defp request(mfa) do
    {:ok, _before, aft} = Store.request(mfa)

    notices = drain()
    error = Enum.find(notices, &(&1.level == :error))
    warning = Enum.find(notices, &(&1.level == :warning))

    cond do
      error -> {:error, :internal, error.text}
      warning -> {:error, :failed, warning.text}
      true -> {:ok, aft}
    end
  end

  defp drain do
    receive do
      {:notice, n} -> [n | drain()]
    after
      0 -> []
    end
  end
end
