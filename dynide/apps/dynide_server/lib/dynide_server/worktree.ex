defmodule DynideServer.Worktree do
  @moduledoc """
  Git worktree commands: argv building, porcelain parsing and running git.
  Pure of server state; every function takes the directory it works in.
  """

  @default_dir "~/.herdr-live/worktrees"

  @doc "Branch name as a path-safe slug (herdr `branch_to_path_slug`)."
  @spec slug(binary) :: binary
  def slug(branch) do
    s =
      for <<c::utf8 <- branch>>, into: "" do
        cond do
          c in ?A..?Z -> <<c + 32>>
          c in ?a..?z or c in ?0..?9 -> <<c>>
          true -> "-"
        end
      end

    case s |> String.replace(~r/-+/, "-") |> String.trim("-") do
      "" -> "worktree"
      slug -> slug
    end
  end

  @doc "Default checkout path: `dir/repo_name/slug(branch)`; `dir` defaults to `~/.herdr-live/worktrees`."
  @spec default_path(binary | nil, binary, binary) :: Path.t()
  def default_path(dir, repo_name, branch) do
    Path.join([expand(dir || @default_dir), repo_name, slug(branch)])
  end

  defp expand("~"), do: System.user_home!()
  defp expand("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand(dir), do: dir

  @doc "Repository root, common git dir and name for the repo containing `cwd`."
  @spec repo(Path.t()) ::
          {:ok, %{root: Path.t(), common: Path.t(), name: binary}} | {:error, binary}
  def repo(cwd) do
    with {:ok, out} <- run(["-C", cwd, "rev-parse", "--show-toplevel", "--git-common-dir"]),
         [root, common] <- String.split(out, "\n", trim: true) do
      common = Path.expand(common, cwd)
      {:ok, %{root: root, common: common, name: repo_name(common)}}
    else
      {:error, _} = err -> err
      _ -> {:error, "unexpected git rev-parse output"}
    end
  end

  # herdr names a repo from its common dir, so linked worktrees share the main repo's name.
  defp repo_name(common) do
    if Path.basename(common) == ".git",
      do: common |> Path.dirname() |> Path.basename(),
      else: common |> Path.basename() |> String.replace_suffix(".git", "")
  end

  @doc "Worktrees of the repo at `root`."
  @spec list(Path.t()) :: {:ok, [map]} | {:error, binary}
  def list(root) do
    with {:ok, out} <- run(["-C", root, "worktree", "list", "--porcelain"]) do
      {:ok, parse(out)}
    end
  end

  @doc "Parses `git worktree list --porcelain` output."
  @spec parse(binary) :: [map]
  def parse(out) do
    out
    |> String.split(~r/\r?\n\s*\r?\n/, trim: true)
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(&is_nil(&1.path))
  end

  defp parse_entry(block) do
    base = %{path: nil, branch: nil, head: nil, bare?: false, detached?: false, prunable?: false}

    block
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reduce(base, fn
      "worktree " <> p, e -> %{e | path: p}
      "HEAD " <> h, e -> %{e | head: h}
      "branch " <> b, e -> %{e | branch: String.replace_prefix(b, "refs/heads/", "")}
      "detached", e -> %{e | detached?: true}
      "bare", e -> %{e | bare?: true}
      "prunable" <> _, e -> %{e | prunable?: true}
      _, e -> e
    end)
  end

  @doc "Adds a worktree at `path`: checks out `branch` if it exists, else creates it from `base` (default HEAD)."
  @spec add(Path.t(), Path.t(), binary, binary | nil) :: :ok | {:error, binary}
  def add(_root, _path, "-" <> _, _base), do: {:error, "invalid branch name"}
  def add(_root, _path, _branch, "-" <> _), do: {:error, "invalid branch name"}

  def add(root, path, branch, base) do
    with {:ok, exists?} <- branch_exists?(root, branch) do
      args =
        if exists?,
          do: ["worktree", "add", path, branch],
          else: ["worktree", "add", "-b", branch, path, base || "HEAD"]

      ok(run(["-C", root | args]))
    end
  end

  defp branch_exists?(root, branch) do
    case cmd(["-C", root, "show-ref", "--verify", "--quiet", "refs/heads/" <> branch], nil) do
      {:error, _} = err -> err
      {_, 0} -> {:ok, true}
      {_, 1} -> {:ok, false}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  @doc "Removes the worktree at `path`; refuses a dirty one unless `force?`. Never deletes the branch."
  @spec remove(Path.t(), Path.t(), boolean) :: :ok | {:error, :dirty | binary}
  def remove(root, path, force?) do
    with :ok <- if(force?, do: :ok, else: check_clean(path)) do
      args = ["-C", root, "worktree", "remove"] ++ if(force?, do: ["--force"], else: []) ++ [path]

      args |> run() |> remove_result()
    end
  end

  defp remove_result({:ok, _}), do: :ok

  defp remove_result({:error, msg}),
    do: if(dirty_error?(msg), do: {:error, :dirty}, else: {:error, msg})

  defp check_clean(path) do
    case run(["-C", path, "status", "--porcelain", "--untracked-files=all"]) do
      {:ok, ""} -> :ok
      {:ok, _} -> {:error, :dirty}
      {:error, _} = err -> err
    end
  end

  defp dirty_error?(msg) do
    m = String.downcase(msg)

    (m =~ "contains modified or untracked files" and m =~ "use --force") or
      m =~ "working trees containing submodules cannot be moved or removed"
  end

  @doc """
  Adds a worktree for `branch` to the repo containing `cwd`, at `path` (nil: `default_path/3`
  under `dir`), and returns its checkout path as git reports it.
  """
  @spec create(Path.t(), binary, binary | nil, Path.t() | nil, binary | nil) ::
          {:ok, Path.t()} | {:error, :linked_worktree_source | binary}
  def create(cwd, branch, base, path, dir) do
    with {:ok, repo} <- parent_repo(cwd),
         path = path || default_path(dir, repo.name, branch),
         :ok <- add(repo.root, path, branch, base),
         {:ok, %{root: root}} <- repo(path) do
      {:ok, root}
    end
  end

  @doc "Removes the linked worktree containing `cwd` (see `remove/3`) and returns its path."
  @spec remove_at(Path.t(), boolean) :: {:ok, Path.t()} | {:error, :dirty | binary}
  def remove_at(cwd, force?) do
    with {:ok, %{root: root}} <- repo(cwd),
         :ok <- linked(root),
         :ok <- remove(root, root, force?) do
      {:ok, root}
    end
  end

  @doc """
  `repo/1` for a source of new and open worktree actions: like herdr, a linked worktree is
  refused (`{:error, :linked_worktree_source}`); they start from the main checkout.
  """
  @spec parent_repo(Path.t()) :: {:ok, map} | {:error, :linked_worktree_source | binary}
  def parent_repo(cwd) do
    with {:ok, repo} <- repo(cwd) do
      if linked?(repo.root), do: {:error, :linked_worktree_source}, else: {:ok, repo}
    end
  end

  @doc "herdr's message for a linked-worktree source."
  @spec linked_source_message() :: binary
  def linked_source_message,
    do: "New and open worktree actions start from the repo parent workspace."

  defp linked(root),
    do: if(linked?(root), do: :ok, else: {:error, "#{root} is not a linked worktree"})

  # a linked worktree's checkout has a `.git` file; the main checkout a `.git` directory
  defp linked?(root), do: File.regular?(Path.join(root, ".git"))

  @doc "The main checkout of a `repo/1` result (a bare repo: its git dir)."
  @spec main_root(%{:common => Path.t(), optional(atom) => term}) :: Path.t()
  def main_root(%{common: common}),
    do: if(Path.basename(common) == ".git", do: Path.dirname(common), else: common)

  @doc """
  Runs git with `args`. `opts[:path]` overrides the PATH searched for git.
  Output is trimmed; stderr is merged into it.
  """
  @spec run([binary], keyword) :: {:ok, binary} | {:error, binary}
  def run(args, opts \\ []) do
    case cmd(args, opts[:path]) do
      {:error, _} = err -> err
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, error_message(out, code)}
    end
  end

  # the one System.cmd site: {output, status}, or {:error, "git not found"}
  defp cmd(args, path) do
    case find_git(path) do
      nil -> {:error, "git not found"}
      git -> System.cmd(git, args, stderr_to_stdout: true, env: env())
    end
  end

  defp find_git(nil), do: System.find_executable("git")

  defp find_git(path) do
    case :os.find_executable(~c"git", String.to_charlist(path)) do
      false -> nil
      found -> List.to_string(found)
    end
  end

  # LC_ALL=C: remove errors are classified by git's English diagnostics.
  defp env, do: [{"GIT_TERMINAL_PROMPT", "0"}, {"LC_ALL", "C"}]

  defp error_message("", code), do: "git failed with status #{code}"
  defp error_message(out, _), do: String.trim(out)

  defp ok({:ok, _}), do: :ok
  defp ok(err), do: err
end
