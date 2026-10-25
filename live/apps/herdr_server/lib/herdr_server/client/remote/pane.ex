defmodule HerdrServer.Client.Remote.Pane do
  @moduledoc """
  Pane mode (R17) of a `Client.Remote` conn: the one-pane scene, the Store follow and the
  input rule. `:control` writes keys, mouse and paste straight to `Pane.Input` (whatever
  has focus), `:observe` drops input. The conn keeps the socket, outbox and acks.
  """

  alias HerdrServer.App.Store
  alias HerdrServer.Client.PaneScene
  alias HerdrServer.Pane.{Input, Rows}

  @store_wait_ms 10
  @store_tries 100

  @type size :: %{cols: pos_integer, rows: pos_integer}

  @doc """
  Registers the caller for pane damage (`Client.Registry :clients`) and Store changes;
  the first scene and the Store monitor, or `:ignore` when the pane has no rows.
  """
  @spec attach(pos_integer, size) :: {:ok, {:scene, HerdrScene.Scene.t()}, reference} | :ignore
  def attach(id, size) do
    case scene(id, size) do
      nil ->
        :ignore

      msg ->
        {:ok, _} = Registry.register(HerdrServer.Client.Registry, :clients, nil)
        :ok = Store.subscribe(self())
        {:ok, msg, Process.monitor(Store)}
    end
  end

  @doc "The scene of the pane's current rows, nil once they are gone."
  @spec scene(pos_integer, size) :: {:scene, HerdrScene.Scene.t()} | nil
  def scene(id, size) do
    case Rows.fetch(id) do
      nil -> nil
      fetched -> {:scene, PaneScene.build(id, fetched, size)}
    end
  end

  @spec open?(term, pos_integer) :: boolean
  def open?(app, id), do: match?(%{session: %{panes: %{^id => _}}}, app)

  @doc "After a Store restart: follows the new Store (its monitor), or `:error` when it or the pane is gone."
  @spec follow_store(pos_integer) :: {:ok, reference} | :error
  def follow_store(id) do
    with pid when is_pid(pid) <- await_store(@store_tries),
         {:ok, app} <- subscribe(),
         true <- open?(app, id) do
      {:ok, Process.monitor(pid)}
    else
      _ -> :error
    end
  end

  @doc "Applies one input event for `target`: `:ok`, or a notice for the client."
  @spec input(term, tuple) :: :ok | {:notice, map}
  def input({:pane, id, :control}, ev), do: control(ev, id)
  def input(_observe, _ev), do: :ok

  defp control({:key, _} = ev, id), do: ok(Input.key(ev, id))
  defp control({:mouse, _} = ev, id), do: ok(Input.mouse(ev, id))

  defp control({:paste, bin}, id) do
    case Input.paste(bin, id, self()) do
      {:error, {:too_large, n, max}} ->
        {:notice, %{level: :warning, text: "paste rejected: #{n} bytes (max #{max})"}}

      # queued: a later truncation notifies this conn (the origin); :closed is an exited pane, a
      # handoff freeze never gets here (client_frame holds input while the phase is :begin)
      _ok_or_closed ->
        :ok
    end
  end

  defp control(_ev, _id), do: :ok

  # Pane.Input logs a failed write
  defp ok(_result), do: :ok

  # the new Store may die too while we call it
  defp subscribe do
    :ok = Store.subscribe(self())
    {:ok, Store.snapshot()}
  catch
    :exit, _ -> :error
  end

  defp await_store(0), do: nil

  defp await_store(n) do
    with nil <- Process.whereis(Store) do
      receive do
      after
        @store_wait_ms -> await_store(n - 1)
      end
    end
  end
end
