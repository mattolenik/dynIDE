defmodule HerdrReload.ReloadCase do
  @moduledoc "Test helpers that build throwaway Mix projects for reload tests."
  use ExUnit.CaseTemplate

  @doc """
  Writes a toy Mix project for `app` with `files` (relative path => source);
  returns its dir. `extra` is appended to the project keyword list.
  """
  @spec toy_project!(atom(), %{String.t() => String.t()}, String.t()) :: Path.t()
  def toy_project!(app, files, extra \\ "") do
    dir = Path.join(System.tmp_dir!(), "toy_#{app}_#{System.unique_integer([:positive])}")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    mod = "Toy#{Macro.camelize(Atom.to_string(app))}.MixProject"

    write_source!(dir, "mix.exs", """
    defmodule #{mod} do
      use Mix.Project

      def project do
        [app: :#{app}, version: "0.1.0", elixir: "~> 1.20", consolidate_protocols: false, deps: []#{extra}]
      end
    end
    """)

    for {rel, src} <- files, do: write_source!(dir, rel, src)
    dir
  end

  @doc "Writes `src` to `rel` under `dir`, creating directories."
  @spec write_source!(Path.t(), String.t(), String.t()) :: :ok
  def write_source!(dir, rel, src) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, src)
  end
end
