defmodule HerdrServer.ReloadNotices do
  @moduledoc """
  Bridges `HerdrReload.Notices` to the attached clients: every reload event becomes
  `{:notice, %{level, text, source: :reload}}` sent to each `Client.Session` (which
  renders it in the status line and forwards it to its client).

  Always started. Subscribes when the `HerdrReload.Notices` registry runs (reload is
  enabled), else retries every 500 ms; a registry restart is followed the same way
  (exits are trapped: the registry links its subscribers).
  Texts are one line of at most 80 characters.
  """
  use GenServer

  alias HerdrReload.Guard

  @retry_ms 500
  @max 80

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    # Registry.register links us to the registry: its exit must not take us down
    Process.flag(:trap_exit, true)
    {:ok, subscribe(nil)}
  end

  @impl true
  # state: the monitor of the registry we are subscribed to, or nil
  def handle_info(:subscribe, ref), do: {:noreply, subscribe(ref)}

  def handle_info({:DOWN, ref, :process, _, _}, ref), do: {:noreply, subscribe(nil)}

  def handle_info({:herdr_reload, event}, ref) do
    {level, text} = format(event)
    n = %{level: level, text: text, source: :reload}

    Registry.dispatch(
      HerdrServer.Client.Registry,
      :clients,
      &for({pid, _} <- &1, do: send(pid, {:notice, n}))
    )

    {:noreply, ref}
  end

  def handle_info(_, ref), do: {:noreply, ref}

  defp subscribe(ref) when is_reference(ref), do: ref

  defp subscribe(nil) do
    case Process.whereis(HerdrReload.Notices) do
      nil ->
        Process.send_after(self(), :subscribe, @retry_ms)
        nil

      pid ->
        :ok = HerdrReload.Notices.subscribe()
        Process.monitor(pid)
    end
  end

  @doc "The notice level and text for a reload event."
  @spec format(term) :: {:error | :warning | :info, String.t()}
  def format(event) do
    {level, text} = raw(event)
    {level, text |> String.replace(~r/\s+/, " ") |> String.slice(0, @max)}
  end

  defp raw({:compile_error, [d | _]}), do: {:error, "#{where(d)}: #{d.message}"}
  defp raw({:compile_error, []}), do: {:error, "compile error"}
  defp raw({:loaded, _id, mods}), do: {:info, "reloaded #{length(mods)} modules"}

  defp raw({:rolled_back, id, mods, reason}),
    do: {:warning, "rolled back batch #{id} (#{length(mods)} modules): #{summary(reason)}"}

  defp raw({:rejected, mod, path}),
    do: {:warning, "rejected: local fun from #{inspect(mod)} at #{inspect(path)}"}

  defp raw({:purge_blocked, mod, holders}),
    do: {:warning, "purge blocked: #{inspect(mod)} still running in #{length(holders)} processes"}

  defp raw(other), do: {:warning, "reload: #{inspect(other)}"}

  defp where(%{file: file, position: pos}) when is_binary(file),
    do: "#{Path.relative_to_cwd(file)}:#{line(pos)}"

  defp where(_), do: "compile error"

  defp line({l, _col}), do: l
  defp line(l), do: l

  defp summary(:manual), do: "manual"
  defp summary({reason, errs}) when is_list(errs), do: summary(reason) <> " (load errors)"

  defp summary({k, _, _} = reason) when k in [:raise, :throw, :exit, :timeout, :local_fun],
    do: Guard.message(reason)

  defp summary(reason), do: inspect(reason)
end
