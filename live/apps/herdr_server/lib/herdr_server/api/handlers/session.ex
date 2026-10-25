defmodule HerdrServer.Api.Handlers.Session do
  @moduledoc """
  Handlers for `session.list`, `session.get`, `session.snapshot` and `client.list`.
  One session per instance (R16). `client.list` shows the socket clients of
  `Client.Remote.list/0` with the first 8 characters of their id; `session_info.clients`
  counts every registered client session except pane-mode socket conns.
  """

  alias HerdrServer.Api.Handlers.{Server, Topology}
  alias HerdrServer.Api.{Ids, SocketPath, View}
  alias HerdrServer.Client.{Remote, Socket}

  @spec handle(String.t(), map()) :: {:ok, map()} | {:error, atom(), String.t()}
  def handle("session.list", _p), do: {:ok, %{type: "session_list", sessions: [info()]}}

  def handle("session.get", p) do
    me = Socket.session_name()

    case p[:name] do
      name when name in [nil, me] -> {:ok, %{type: "session_info", session: info()}}
      name -> {:error, :not_found, "no session #{name} here (this server runs #{me})"}
    end
  end

  def handle("client.list", _p) do
    clients =
      for c <- Remote.list() do
        %{
          id: binary_part(c.id, 0, min(8, byte_size(c.id))),
          kind: to_string(c.kind),
          target: target(c.target),
          cols: c.size.cols,
          rows: c.size.rows,
          connected: c.connected
        }
      end

    {:ok, %{type: "client_list", clients: clients}}
  end

  @spec snapshot() :: {:ok, map()}
  def snapshot do
    app = Topology.app!()
    wss = app.session.workspaces
    tabs = for ws <- wss, tab <- ws.tabs, do: {ws, tab}
    ws = View.find_workspace(app, app.session.active_workspace)

    {:ok,
     %{
       type: "session_snapshot",
       version: Server.version(),
       session: info(),
       focused: %{
         workspace_id: Ids.workspace(app.session.active_workspace),
         tab_id: Ids.tab(ws.id, ws.active_tab),
         pane_id: Ids.pane(app.focus.pane)
       },
       workspaces: Enum.map(wss, &View.workspace(app, &1)),
       tabs: for({w, t} <- tabs, do: View.tab(app, w, t)),
       panes: for({w, t} <- tabs, p <- View.panes(app, w, t), do: p),
       layouts:
         for({w, t} <- tabs, do: %{tab_id: Ids.tab(w.id, t.id), layout: View.layout(app, w, t)})
     }}
  end

  defp info do
    pane_conns = Enum.count(Remote.list(), &match?({:pane, _, _}, &1.target))

    %{
      name: Socket.session_name(),
      os_pid: String.to_integer(System.pid()),
      gen: Server.gen(),
      api_socket: SocketPath.path(),
      client_socket: Socket.path(),
      clients: Registry.count_match(HerdrServer.Client.Registry, :clients, :_) - pane_conns
    }
  end

  defp target(:session), do: "session"
  defp target({:pane, id, mode}), do: "pane:#{Ids.pane(id)}:#{mode}"
end
