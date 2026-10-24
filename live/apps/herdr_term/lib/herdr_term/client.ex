defmodule HerdrTerm.Client do
  @moduledoc """
  One terminal client: `Tty.Owner`, `Client.Term.Render`, `Client.Term.Input`
  under `:rest_for_one`. Startable many times; each instance has an `id`
  (default `make_ref()`) and its children register as
  `{:via, Registry, {HerdrTerm.Registry, {id, role}}}` so restarted children
  find their siblings again.

  Options: `tty_opts` (map merged into the tty kernel's `open` options),
  `endpoint` (default `HerdrScene.Protocol.endpoint/0`), `id`, `name`, `local`
  (true only for `HerdrTerm.LocalClient`: see `local_exit/1`).
  """

  use Supervisor

  require Logger

  alias HerdrTerm.Client.Term.{Input, Render}
  alias HerdrTerm.Tty.Owner

  @type role :: :tty_owner | :render | :input

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Registered name of the `role` child of client `id`."
  @spec via(term, role) :: {:via, Registry, {HerdrTerm.Registry, {term, role}}}
  def via(id, role), do: {:via, Registry, {HerdrTerm.Registry, {id, role}}}

  @doc "Pid of the `role` child of client `id`, or nil."
  @spec whereis(term, role) :: pid | nil
  def whereis(id, role), do: GenServer.whereis(via(id, role))

  @impl true
  def init(opts) do
    opts = opts |> Keyword.delete(:name) |> Keyword.put_new_lazy(:id, &make_ref/0)
    children = [{Owner, opts}, {Render, opts}, {Input, opts}]
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  The local client is done (`{:detached, reason}` from the server, or
  `{:tty, reason}` when the host terminal hung up). Applies
  `config :herdr_term, :on_local_exit` (an MFA, default `{System, :stop, [0]}`):
  until M5's broker exists, detaching the local client quits herdr-live.
  """
  @spec local_exit(term) :: term
  def local_exit(why) do
    Logger.info("local terminal client done (#{inspect(why)}), stopping herdr-live")
    {m, f, a} = Application.get_env(:herdr_term, :on_local_exit, {System, :stop, [0]})
    apply(m, f, a)
  end

  @doc "The tty resource held by this client's `Tty.Owner`."
  def tty(sup), do: sup |> owner() |> Owner.tty()

  def owner(sup), do: child(sup, Owner)
  def render(sup), do: child(sup, Render)
  def input(sup), do: child(sup, Input)

  defp child(sup, mod) do
    Enum.find_value(Supervisor.which_children(sup), fn
      {^mod, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end
end
