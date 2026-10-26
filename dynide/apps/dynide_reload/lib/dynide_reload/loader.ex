defmodule DynideReload.Loader do
  @moduledoc """
  Loads and purges module code without killing processes unless allowlisted.
  """

  alias DynideReload.Notices

  @type pid_info :: %{
          pid: pid(),
          name: atom() | nil,
          initial_call: mfa() | nil,
          current_function: mfa() | nil
        }

  @doc "Processes whose stack still references old code of `module`."
  @spec holders(module()) :: [pid_info()]
  def holders(module) do
    for pid <- Process.list(), :erlang.check_process_code(pid, module), do: info(pid)
  end

  @doc "Purges old code of `module`; blocked (and broadcast) when processes still run it."
  @spec purge_old(module(), keyword()) :: :ok | {:blocked, [pid_info()]}
  def purge_old(module, opts) do
    if :code.soft_purge(module) do
      :ok
    else
      retry(module, opts, Keyword.get(opts, :retries, 3))
    end
  end

  defp retry(module, opts, left) when left > 1 do
    Process.sleep(Keyword.get(opts, :retry_ms, 10))
    if :code.soft_purge(module), do: :ok, else: retry(module, opts, left - 1)
  end

  defp retry(module, opts, _) do
    if module in Keyword.get(opts, :allowlist, []) do
      :code.purge(module)
      :ok
    else
      holders = holders(module)
      Notices.broadcast({:purge_blocked, module, holders})
      {:blocked, holders}
    end
  end

  @doc "Loads `binary` as `module`, or removes the module when `binary` is nil."
  @spec load(module(), binary() | nil, keyword()) :: :ok | {:error, term()}
  def load(module, nil, opts) do
    with :ok <- purge_old(module, opts) do
      :code.delete(module)
      purge_old(module, opts)
    end
    |> normalize()
  end

  # Mix often already deleted the current code, leaving the old slot free:
  # purge only when the load says the old slot is taken.
  def load(module, binary, opts) do
    path = path(module, opts)

    result =
      with {:error, :not_purged} <- :code.load_binary(module, path, binary),
           :ok <- purge_old(module, opts),
           do: :code.load_binary(module, path, binary)

    case result do
      {:module, ^module} ->
        :code.soft_purge(module)
        :ok

      other ->
        normalize(other)
    end
  end

  defp normalize(:ok), do: :ok
  defp normalize({:blocked, holders}), do: {:error, {:purge_blocked, holders}}
  defp normalize({:error, _} = e), do: e

  defp path(module, opts) do
    case opts[:path] || :code.which(module) do
      p when is_list(p) -> p
      p when is_binary(p) -> String.to_charlist(p)
      _ -> String.to_charlist("#{module}.beam")
    end
  end

  defp info(pid) do
    p = Process.info(pid, [:registered_name, :initial_call, :current_function]) || []

    name =
      case p[:registered_name] do
        n when is_atom(n) -> n
        _ -> nil
      end

    %{
      pid: pid,
      name: name,
      initial_call: proc_lib_call(pid) || p[:initial_call],
      current_function: p[:current_function]
    }
  end

  defp proc_lib_call(pid) do
    case :proc_lib.initial_call(pid) do
      {_, _, _} = mfa -> mfa
      _ -> nil
    end
  end
end
