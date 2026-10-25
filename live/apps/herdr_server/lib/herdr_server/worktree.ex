defmodule HerdrServer.Worktree do
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
      {:ok, %{root: root, common: Path.expand(common, cwd), name: Path.basename(root)}}
    else
      {:error, _} = err -> err
      _ -> {:error, "unexpected git rev-parse output"}
    end
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
    case System.cmd(
           "git",
           ["-C", root, "show-ref", "--verify", "--quiet", "refs/heads/" <> branch],
           stderr_to_stdout: true,
           env: env()
         ) do
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
  Runs git with `args`. `opts[:path]` overrides the PATH searched for git.
  Output is trimmed; stderr is merged into it.
  """
  @spec run([binary], keyword) :: {:ok, binary} | {:error, binary}
  def run(args, opts \\ []) do
    case find_git(opts[:path]) do
      nil ->
        {:error, "git not found"}

      git ->
        case System.cmd(git, args, stderr_to_stdout: true, env: env()) do
          {out, 0} -> {:ok, String.trim(out)}
          {out, code} -> {:error, error_message(out, code)}
        end
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
