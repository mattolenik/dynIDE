defmodule HerdrServer.Reload.LocalFuns do
  @moduledoc """
  Finds local (non-external) funs inside a term. A local fun pins the code
  generation of its defining module, so it would break on purge.
  """

  @type path :: [term()]

  @doc "Returns `:ok` or the module and key path of the first local fun found."
  @spec find(term()) :: :ok | {:local_fun, module(), path()}
  def find(term) do
    case walk(term, []) do
      nil -> :ok
      {mod, path} -> {:local_fun, mod, Enum.reverse(path)}
    end
  end

  defp walk(f, path) when is_function(f) do
    if :erlang.fun_info(f, :type) == {:type, :local} do
      {:module, mod} = :erlang.fun_info(f, :module)
      {mod, path}
    end
  end

  defp walk(%_{} = struct, path), do: walk_pairs(Map.from_struct(struct), path)
  defp walk(map, path) when is_map(map), do: walk_pairs(map, path)
  defp walk(tuple, path) when is_tuple(tuple), do: walk_list(Tuple.to_list(tuple), 0, path)
  defp walk(list, path) when is_list(list), do: walk_list(list, 0, path)
  defp walk(_, _), do: nil

  defp walk_pairs(map, path) do
    Enum.find_value(map, fn {k, v} -> walk(v, [k | path]) end)
  end

  defp walk_list([h | t], i, path), do: walk(h, [i | path]) || walk_list(t, i + 1, path)
  defp walk_list([], _, _), do: nil
  defp walk_list(improper, i, path), do: walk(improper, [i | path])
end
