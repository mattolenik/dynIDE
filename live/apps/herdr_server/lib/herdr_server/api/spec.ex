defmodule HerdrServer.Api.Spec do
  @moduledoc """
  The socket API as plain data: methods, params, result shapes, error codes.

  One source for the validator, the schema endpoint, the CLI and the generated
  `docs/herdr-live/api.md`. Pure: no processes, no I/O.

  Param types: `:string | :boolean | {:integer, min, max} | {:number, min, max} |
  {:enum, [String.t()]} | :pane_id | :tab_id | :workspace_id | {:list, type} |
  {:map, :string | :null_or_string} | :object | {:object, [param]} | :popup_size` (`:object` is
  any JSON object; `:popup_size` is herdr's popup size: an integer cell count 0..65535 or a
  percentage string `"1%"`..`"100%"`). A list
  param may carry `min_items: n`.
  Result field types add `:integer`, `:object` (opaque JSON object),
  `:null_or_string`, `{:ref, object_name}`.
  """

  alias HerdrServer.Api.Ids

  @error_codes ~w(parse_error invalid_request unknown_method invalid_params not_found
                  not_available failed timeout backpressure events_lost ui_busy internal)a

  @sources ~w(visible recent)
  @agent_states ~w(idle working blocked done unknown)

  @spec error_codes() :: [atom()]
  def error_codes, do: @error_codes

  @doc "The CLI verbs that do not call the JSON API: they speak the client socket."
  @spec client_verbs() :: [%{cli: String.t(), summary: String.t()}]
  def client_verbs do
    [
      %{
        cli: "herdr-live attach [<host>] [<session>]",
        summary:
          "Attach a terminal client to the session: the local client socket, or over ssh to <host> (needs key or agent auth)."
      },
      %{
        cli: "herdr-live terminal attach <pane_id> [--host <host>]",
        summary: "Attach to one pane with input (control)."
      },
      %{
        cli: "herdr-live terminal observe <pane_id> [--host <host>]",
        summary: "Watch one pane; input is dropped."
      },
      %{
        cli: "herdr-live attach-relay [<session>]",
        summary:
          "Run on the server host over ssh: relays stdio to the client socket and sends the auth frame with the host's token."
      }
    ]
  end

  @spec event_types() :: [String.t()]
  def event_types, do: Enum.map(events(), & &1.type)

  # --- param builders --------------------------------------------------------

  defp req(name, type, doc), do: %{name: name, type: type, required: true, doc: doc}
  defp opt(name, type, doc), do: %{name: name, type: type, required: false, doc: doc}

  defp opt_pane(doc), do: opt("pane_id", :pane_id, doc)
  defp dir, do: req("direction", {:enum, ~w(left right up down)}, "Which way.")
  defp tab_id, do: req("tab_id", :tab_id, "Target tab.")
  defp ws_id, do: req("workspace_id", :workspace_id, "Target workspace.")
  defp label, do: req("label", :string, "New label.")

  defp insert_index,
    do:
      req("insert_index", {:integer, 0, 65_535}, "Gap to insert at, 0-based; past the end fails.")

  defp focus(doc), do: opt("focus", :boolean, doc)
  defp source, do: opt("source", {:enum, @sources}, "Text source; default `visible`.")
  defp lines, do: opt("lines", {:integer, 1, 10_000}, "Maximum number of lines.")
  defp target, do: req("target", :string, "Agent target (pane id or agent name).")

  # herdr's report_metadata params after the target
  defp metadata_params do
    [
      req("source", :string, "Reporting integration: ASCII letters, digits, `:._-`, 1-80."),
      req(
        "tokens",
        {:map, :null_or_string},
        "1-16 keys `[A-Za-z0-9_-]{1,32}` (not `__`-prefixed); a value is trimmed, " <>
          "stripped of control characters and cut to 80; null or empty clears the key."
      ),
      opt(
        "seq",
        {:integer, 0, 9_007_199_254_740_991},
        "Report sequence number; at most the source's last is dropped."
      ),
      opt("ttl_ms", {:integer, 1, 86_400_000}, "The set keys expire after this many ms.")
    ]
  end

  defp timeout_ms,
    do: opt("timeout_ms", {:integer, 1, 3_600_000}, "Give up after this many milliseconds.")

  # every method rejects unknown params, so every method can answer invalid_params;
  # `internal` (a handler crashed) is implicit and never listed
  defp method(name, group, summary, params, result, errors, cli) do
    errors = [:invalid_params | errors]

    %{
      name: name,
      group: group,
      summary: summary,
      params: params,
      result: result,
      errors: errors,
      cli: cli
    }
  end

  defp agent(name, summary, params, result, errors, cli),
    do: method("agent." <> name, "agent", summary, params, result, errors, cli)

  # --- methods ---------------------------------------------------------------

  @spec methods() :: [map()]
  def methods do
    server() ++
      session() ++
      reload() ++
      workspace() ++
      tab() ++
      pane() ++
      notification() ++
      window_title() ++
      event_methods() ++
      agents() ++
      plugins() ++
      worktrees()
  end

  defp worktrees do
    g = "worktree"
    ws = opt("workspace_id", :workspace_id, "Source workspace; default the focused one.")
    cwd = opt("cwd", :string, "Absolute path inside the source repo, instead of a workspace.")
    label = opt("label", :string, "Workspace label; default the checkout's name.")
    focus = focus("Focus the workspace; default false.")
    errors = [:not_found, :failed]

    [
      method(
        "worktree.list",
        g,
        "List the git worktrees of a workspace's repo.",
        [ws, cwd],
        "worktree_list",
        errors,
        "herdr-live worktree list [--workspace <workspace_id> | --cwd <path>]"
      ),
      method(
        "worktree.create",
        g,
        "Add a git worktree and open a workspace in it.",
        [
          ws,
          cwd,
          req("branch", :string, "Branch to check out; created from `base` when missing."),
          opt("base", :string, "Start point of a new branch; default HEAD."),
          opt(
            "path",
            :string,
            "Absolute checkout path; default `~/.herdr-live/worktrees/<repo>/<branch>`."
          ),
          label,
          focus
        ],
        "worktree_created",
        errors,
        "herdr-live worktree create --branch B [--workspace <workspace_id> | --cwd <path>] " <>
          "[--base REF] [--path P] [--label L] [--focus]"
      ),
      method(
        "worktree.open",
        g,
        "Open a workspace in an existing worktree (or focus the one open there).",
        [
          ws,
          cwd,
          opt("path", :string, "Checkout path of the worktree."),
          opt("branch", :string, "Branch checked out in the worktree."),
          label,
          focus
        ],
        "worktree_opened",
        errors,
        "herdr-live worktree open (--path P | --branch B) [--workspace <workspace_id> | --cwd <path>] " <>
          "[--label L] [--focus]"
      ),
      method(
        "worktree.remove",
        g,
        "Remove a workspace's linked worktree and close the workspaces in it; the branch is kept.",
        [
          ws_id(),
          opt("force", :boolean, "Remove even with uncommitted changes; default false.")
        ],
        "worktree_removed",
        errors,
        "herdr-live worktree remove <workspace_id> [--force]"
      )
    ]
  end

  defp server do
    [
      method("ping", "server", "Liveness check.", [], "pong", [], "herdr-live ping"),
      method(
        "api.schema",
        "server",
        "Return the method catalogue this server speaks.",
        [],
        "api_schema",
        [],
        "herdr-live api schema"
      ),
      method(
        "server.status",
        "server",
        "Server generation, process and reload facts.",
        [],
        "server_status",
        [],
        "herdr-live server status [--kv]"
      ),
      method(
        "server.agent_manifests",
        "server",
        "The loaded agent detection manifests.",
        [],
        "agent_manifests",
        [],
        "herdr-live server agent-manifests"
      ),
      method(
        "server.reload_agent_manifests",
        "server",
        "Reload the agent detection manifests from disk.",
        [],
        "agent_manifests",
        [],
        "herdr-live server reload-agent-manifests"
      )
    ]
  end

  defp session do
    [
      method(
        "session.list",
        "session",
        "The sessions on this socket: one per instance.",
        [],
        "session_list",
        [],
        "herdr-live session list"
      ),
      method(
        "session.get",
        "session",
        "One session; default this instance's.",
        [opt("name", :string, "Session name; default this instance's.")],
        "session_info",
        [:not_found],
        "herdr-live session get [<name>]"
      ),
      method(
        "session.snapshot",
        "session",
        "The whole topology in one answer: focus, workspaces, tabs, panes and layouts.",
        [],
        "session_snapshot",
        [],
        "herdr-live api snapshot"
      ),
      method(
        "client.list",
        "session",
        "Socket clients (remote attach, terminal verbs) with their current size.",
        [],
        "client_list",
        [],
        "herdr-live client list"
      )
    ]
  end

  defp reload do
    [
      method(
        "reload.rollback",
        "reload",
        "Roll back the last n reload batches.",
        [opt("n", {:integer, 1, 100}, "Number of batches to roll back; default 1.")],
        "reload_rollback",
        [:not_available, :failed, :timeout],
        "herdr-live rollback [<n>]"
      ),
      method(
        "reload.test_on_save",
        "reload",
        "Read or set the test-on-save gate.",
        [opt("mode", {:enum, ["on", "off"]}, "Set the gate; omit to read it.")],
        "test_on_save",
        [:not_available],
        "herdr-live test-on-save [on|off]"
      )
    ]
  end

  defp workspace do
    g = "workspace"

    [
      method(
        "workspace.list",
        g,
        "List workspaces.",
        [],
        "workspace_list",
        [],
        "herdr-live workspace list"
      ),
      method(
        "workspace.get",
        g,
        "Describe a workspace.",
        [ws_id()],
        "workspace_info",
        [:not_found],
        "herdr-live workspace get <workspace_id>"
      ),
      method(
        "workspace.create",
        g,
        "Create a workspace with one tab and one pane.",
        [
          opt("label", :string, "Workspace label."),
          focus("Focus the new workspace; default false.")
        ],
        "workspace_created",
        [],
        "herdr-live workspace create [--label L] [--focus]"
      ),
      method(
        "workspace.focus",
        g,
        "Focus a workspace.",
        [ws_id()],
        "workspace_info",
        [:not_found],
        "herdr-live workspace focus <workspace_id>"
      ),
      method(
        "workspace.rename",
        g,
        "Rename a workspace.",
        [ws_id(), label()],
        "workspace_info",
        [:not_found],
        "herdr-live workspace rename <workspace_id> <label>"
      ),
      method(
        "workspace.move",
        g,
        "Move a workspace before the one at `insert_index` (its count appends); the " <>
          "focused one stays focused. Answers the new order.",
        [ws_id(), insert_index()],
        "workspace_list",
        [:not_found, :failed],
        "herdr-live workspace move <workspace_id> <insert_index>"
      ),
      method(
        "workspace.report_metadata",
        g,
        "Set or clear a workspace's metadata tokens (at most 32), shown after its branch.",
        [ws_id() | metadata_params()],
        "ok",
        [:not_found, :failed],
        "herdr-live workspace report-metadata <workspace_id> --source S --token K=V... " <>
          "[--clear-token K]... [--seq N] [--ttl-ms N]"
      ),
      method(
        "workspace.close",
        g,
        "Close a workspace and its panes.",
        [ws_id()],
        "workspace_closed",
        [:not_found, :failed],
        "herdr-live workspace close <workspace_id>"
      )
    ]
  end

  defp tab do
    g = "tab"

    [
      method(
        "tab.list",
        g,
        "List tabs, optionally of one workspace.",
        [opt("workspace_id", :workspace_id, "Only tabs of this workspace.")],
        "tab_list",
        [:not_found],
        "herdr-live tab list [--workspace <workspace_id>]"
      ),
      method(
        "tab.get",
        g,
        "Describe a tab.",
        [tab_id()],
        "tab_info",
        [:not_found],
        "herdr-live tab get <tab_id>"
      ),
      method(
        "tab.create",
        g,
        "Create a tab with one pane.",
        [
          opt("workspace_id", :workspace_id, "Workspace to add to; default the focused one."),
          opt("label", :string, "Tab label."),
          focus("Focus the new tab.")
        ],
        "tab_created",
        [:not_found],
        "herdr-live tab create [--workspace <workspace_id>] [--label L] [--focus]"
      ),
      method(
        "tab.focus",
        g,
        "Focus a tab.",
        [tab_id()],
        "tab_info",
        [:not_found],
        "herdr-live tab focus <tab_id>"
      ),
      method(
        "tab.rename",
        g,
        "Rename a tab.",
        [tab_id(), label()],
        "tab_info",
        [:not_found],
        "herdr-live tab rename <tab_id> <label>"
      ),
      method(
        "tab.move",
        g,
        "Move a tab before the one at `insert_index` in its workspace (its count appends); " <>
          "the active one stays active. Answers the workspace's new tab order.",
        [tab_id(), insert_index()],
        "tab_list",
        [:not_found, :failed],
        "herdr-live tab move <tab_id> <insert_index>"
      ),
      method(
        "tab.close",
        g,
        "Close a tab and its panes.",
        [tab_id()],
        "tab_closed",
        [:not_found],
        "herdr-live tab close <tab_id>"
      )
    ]
  end

  defp pane do
    g = "pane"
    pid = req("pane_id", :pane_id, "Target pane.")
    send_errors = [:not_found, :backpressure, :failed]

    [
      method(
        "pane.list",
        g,
        "List panes, optionally of one workspace or tab.",
        [
          opt("workspace_id", :workspace_id, "Only panes of this workspace."),
          opt("tab_id", :tab_id, "Only panes of this tab.")
        ],
        "pane_list",
        [:not_found],
        "herdr-live pane list [--workspace <workspace_id>] [--tab <tab_id>]"
      ),
      method(
        "pane.get",
        g,
        "Describe a pane.",
        [pid],
        "pane_info",
        [:not_found],
        "herdr-live pane get <pane_id>"
      ),
      method(
        "pane.current",
        g,
        "The pane the caller runs in, else the focused pane.",
        [opt("caller_pane_id", :pane_id, "Pane the caller reports itself running in.")],
        "pane_info",
        [:not_found],
        "herdr-live pane current"
      ),
      method(
        "pane.split",
        g,
        "Split a pane; the new pane is created beside it.",
        [
          opt_pane("Pane to split; default the focused pane."),
          req("direction", {:enum, ["right", "down"]}, "Where the new pane goes."),
          opt("ratio", {:number, 0.1, 0.9}, "Share of the space kept by the first pane."),
          opt(
            "cwd",
            :string,
            "Absolute working directory of the new pane; must be an existing directory."
          ),
          opt("env", {:map, :string}, "Extra environment; herdr's own variables win."),
          focus("Focus the new pane.")
        ],
        "pane_split",
        [:not_found, :failed],
        "herdr-live pane split [<pane_id>] --direction right|down [--ratio R] [--cwd PATH] " <>
          "[--env KEY=VALUE]... [--focus|--no-focus]"
      ),
      method(
        "pane.focus_direction",
        g,
        "Focus the neighbour of a pane in a direction; clears the tab's zoom.",
        [opt_pane("Pane to start from; default the focused pane."), dir()],
        "pane_focus_direction",
        [:not_found],
        "herdr-live pane focus-direction [<pane_id>] --direction left|right|up|down"
      ),
      method(
        "pane.swap",
        g,
        "Swap a pane with its neighbour in a direction; clears the tab's zoom.",
        [opt_pane("Pane to swap; default the focused pane."), dir()],
        "pane_swap",
        [:not_found],
        "herdr-live pane swap [<pane_id>] --direction left|right|up|down"
      ),
      method(
        "pane.resize",
        g,
        "Move the pane's edge in a direction by a percentage of the tab; clears the tab's zoom.",
        [
          opt_pane("Pane to resize; default the focused pane."),
          dir(),
          opt(
            "amount",
            {:number, -1.0e6, 1.0e6},
            "Fraction of the tab; magnitude capped at 0.5; default 0.05."
          )
        ],
        "pane_resize",
        [:not_found],
        "herdr-live pane resize [<pane_id>] --direction left|right|up|down [--amount F]"
      ),
      method(
        "pane.report_agent",
        g,
        "Report an agent's state for a pane from an integration (hook).",
        [
          pid,
          req("source", :string, "Reporting integration."),
          req("agent", :string, "Agent label."),
          req("state", {:enum, ~w(idle working blocked unknown)}, "Reported state."),
          opt("message", :string, "Status message."),
          opt("seq", {:integer, 0, 9_007_199_254_740_991}, "Report sequence number."),
          opt("agent_session_id", :string, "Accepted and ignored (M17)."),
          opt("agent_session_path", :string, "Accepted and ignored (M17)."),
          opt("resume_argv", {:list, :string}, "Accepted and ignored (M17).")
        ],
        "ok",
        [:not_found],
        "herdr-live pane report-agent <pane_id> --source S --agent A --state S [--message T] [--seq N]"
      ),
      method(
        "pane.report_agent_session",
        g,
        "Report the agent session a pane holds, so a restore with " <>
          "`session.resume_agents_on_restore` can resume it.",
        [
          pid,
          req(
            "source",
            :string,
            "Reporting integration; an id or path counts only from `herdr:<agent>`."
          ),
          req("agent", :string, "Agent label."),
          opt(
            "seq",
            {:integer, 0, 9_007_199_254_740_991},
            "Report sequence number; ignored until M11 detection."
          ),
          opt("agent_session_id", :string, "Agent session id, at most 512 bytes."),
          opt(
            "agent_session_path",
            :string,
            "Absolute session path (pi, omp), at most 4096 bytes."
          ),
          opt("session_start_source", :string, "How the session started; ignored until M11."),
          opt(
            "resume_argv",
            {:list, :string},
            "Command that resumes the session; refused (`invalid_params`) until the reporter can " <>
              "hold the pane with `pane.report_agent` (M11)."
          )
        ],
        "ok",
        [:not_found],
        "herdr-live pane report-agent-session <pane_id> --source S --agent A [--seq N] " <>
          "[--agent-session-id ID] [--agent-session-path PATH] [--session-start-source S] " <>
          "[-- <resume_arg>...]"
      ),
      method(
        "pane.report_metadata",
        g,
        "Set or clear a pane's metadata tokens (at most 32), shown under its agent line.",
        [pid | metadata_params()],
        "ok",
        [:not_found, :failed],
        "herdr-live pane report-metadata <pane_id> --source S --token K=V... " <>
          "[--clear-token K]... [--seq N] [--ttl-ms N]"
      ),
      method(
        "pane.release_agent",
        g,
        "Release an integration's agent report for a pane.",
        [
          pid,
          req("source", :string, "Reporting integration."),
          req("agent", :string, "Agent label."),
          opt("seq", {:integer, 0, 9_007_199_254_740_991}, "Report sequence number.")
        ],
        "ok",
        [:not_found],
        "herdr-live pane release-agent <pane_id> --source S --agent A [--seq N]"
      ),
      method(
        "pane.rename",
        g,
        "Name a pane; an absent or empty label clears the name.",
        [pid, opt("label", :string, "New name; absent or empty clears it.")],
        "pane_info",
        [:not_found],
        "herdr-live pane rename <pane_id> [<label>]"
      ),
      method(
        "pane.link.activate",
        g,
        "Activate the link under a cell of a pane's viewport, as a click would.",
        [
          pid,
          req("col", {:integer, 0, 65_535}, "Viewport column."),
          req("viewport_row", {:integer, 0, 65_535}, "Viewport row."),
          opt("modifiers", {:list, {:enum, ~w(shift alt ctrl)}}, "Modifiers held.")
        ],
        "pane_link_activated",
        [:not_found, :failed],
        "herdr-live pane link activate <pane_id> --col N --row N [--modifier M]..."
      ),
      method(
        "pane.close",
        g,
        "Close a pane.",
        [pid],
        "pane_closed",
        [:not_found],
        "herdr-live pane close <pane_id>"
      ),
      method(
        "pane.focus",
        g,
        "Focus a pane.",
        [pid],
        "pane_info",
        [:not_found],
        "herdr-live pane focus <pane_id>"
      ),
      method(
        "pane.zoom",
        g,
        "Focus a pane and zoom it to the whole pane area, or unzoom.",
        [
          opt_pane("Pane to zoom; default the focused pane."),
          opt("zoom", :boolean, "true zooms, false unzooms; default toggle.")
        ],
        "pane_info",
        [:not_found],
        "herdr-live pane zoom [<pane_id>] [--on|--off]"
      ),
      method(
        "pane.layout",
        g,
        "The split tree of the tab holding a pane.",
        [opt_pane("Pane in the tab; default the focused pane.")],
        "pane_layout",
        [:not_found],
        "herdr-live pane layout [<pane_id>]"
      ),
      method(
        "pane.process_info",
        g,
        "OS process facts of a pane.",
        [pid],
        "process_info",
        [:not_found],
        "herdr-live pane process-info [<pane_id>]"
      ),
      method(
        "pane.send_text",
        g,
        "Write text to a pane as typed input, without a trailing newline.",
        [pid, req("text", :string, "Text to write.")],
        "ok",
        send_errors,
        "herdr-live pane send-text <pane_id> <text>"
      )
      |> Map.put(
        :notes,
        "Text is written in 64 KiB chunks. On `backpressure` or `failed` the error's " <>
          "`data.written` is the number of bytes already written: resend only the text " <>
          "from that byte offset, or the pane gets the start twice."
      ),
      method(
        "pane.send_keys",
        g,
        "Send named keys (for example `Enter`, `C-c`) to a pane.",
        [pid, Map.put(req("keys", {:list, :string}, "Key names."), :min_items, 1)],
        "ok",
        send_errors,
        "herdr-live pane send-keys <pane_id> <key>..."
      ),
      method(
        "pane.run",
        g,
        "Write a command line to a pane and press Enter.",
        [pid, req("command", :string, "Command line.")],
        "ok",
        [:not_found],
        "herdr-live pane run <pane_id> <command>"
      )
      |> Map.put(
        :notes,
        "The command and its Enter join the pane's input queue, which retries until the " <>
          "pane takes them: `ok` means queued, not yet read by the program."
      ),
      method(
        "pane.read",
        g,
        "Read terminal text.",
        [pid, source(), lines()],
        "pane_read",
        [:not_found],
        "herdr-live pane read [<pane_id>] [--source visible|recent] [--lines N]"
      ),
      method(
        "pane.wait_for_output",
        g,
        "Wait until a pane's output matches a substring or a regex.",
        [
          pid,
          opt("match", :string, "Substring to wait for (use this or `regex`)."),
          opt("regex", :string, "Regular expression to wait for (use this or `match`)."),
          source(),
          lines(),
          timeout_ms()
        ],
        "output_matched",
        [:not_found, :timeout],
        "herdr-live pane wait-output [<pane_id>] (--match S | --regex R) [--source visible|recent] [--lines N] [--timeout MS]"
      )
    ]
  end

  defp notification do
    [
      method(
        "notification.show",
        "notification",
        "Raise a toast on every attached client.",
        [
          req("title", :string, "Toast title."),
          opt("body", :string, "Toast body; default empty."),
          opt_pane("Pane the toast is about; default none.")
        ],
        "ok",
        [],
        "herdr-live notification show <title> [--body <text>] [--pane <pane_id>]"
      )
    ]
  end

  defp window_title do
    [
      method(
        "client.window_title.set",
        "client",
        "Override the window title on every attached client.",
        [req("title", :string, "Window title; control characters are stripped.")],
        "ok",
        [],
        "herdr-live title set <title>"
      ),
      method(
        "client.window_title.clear",
        "client",
        "Drop the window title override on every attached client.",
        [],
        "ok",
        [],
        "herdr-live title clear"
      ),
      method(
        "popup.close",
        "popup",
        "Close the open popup pane (its process is ended).",
        [],
        "ok",
        [:not_found],
        "herdr-live popup close"
      )
    ]
  end

  defp event_methods do
    sub = [
      req("type", {:enum, event_types()}, "Event type."),
      opt("pane_id", :pane_id, "Only events of this pane."),
      opt("tab_id", :tab_id, "Only events of this tab."),
      opt("workspace_id", :workspace_id, "Only events of this workspace.")
    ]

    [
      method(
        "events.subscribe",
        "events",
        "Turn the connection into an event stream.",
        [
          Map.put(
            req("subscriptions", {:list, {:object, sub}}, "Subscriptions."),
            :min_items,
            1
          )
        ],
        "subscription_started",
        [:not_found, :not_available, :events_lost],
        "herdr-live events subscribe <type>... [--pane <pane_id>] [--tab <tab_id>] [--workspace <workspace_id>]"
      )
    ]
  end

  defp agents do
    until =
      opt("until", {:list, {:enum, @agent_states}}, "Agent states to wait for; default `idle`.")

    [
      agent("list", "List detected agents.", [], "agent_list", [], "herdr-live agent list"),
      agent(
        "get",
        "Describe an agent.",
        [target()],
        "agent_info",
        [:not_found],
        "herdr-live agent get <target>"
      ),
      agent(
        "read",
        "Read an agent's terminal text.",
        [target(), source(), lines()],
        "agent_read",
        [:not_found],
        "herdr-live agent read <target> [--source visible|recent] [--lines N]"
      ),
      agent(
        "explain",
        "Explain why detection reports the agent's state: for a pane (`target`), or for " <>
          "supplied screen `text` under the `agent` manifest. Give exactly one of the two.",
        [
          opt("target", :string, "Agent target (pane id or agent name)."),
          opt("agent", :string, "Agent label whose manifest evaluates `text`."),
          opt("text", :string, "Screen text to evaluate (at most 1 MiB)."),
          opt("verbose", :boolean, "Verbose explanation text.")
        ],
        "agent_explain",
        [:not_found, :failed],
        "herdr-live agent explain <target> [--json] [--verbose] | " <>
          "herdr-live agent explain --file PATH --agent LABEL [--json]"
      ),
      agent(
        "wait",
        "Wait until an agent reaches one of the given states.",
        [target(), until, timeout_ms()],
        "agent_wait",
        [:not_found, :timeout],
        "herdr-live agent wait <target> [--until S]... [--timeout MS]"
      ),
      agent(
        "prompt",
        "Send a prompt to an agent.",
        [target(), req("text", :string, "Prompt text.")],
        "ok",
        [:not_found],
        "herdr-live agent prompt <target> <text>"
      ),
      agent(
        "send_keys",
        "Send named keys to an agent.",
        [target(), Map.put(req("keys", {:list, :string}, "Key names."), :min_items, 1)],
        "ok",
        [:not_found],
        "herdr-live agent send-keys <target> <key>..."
      )
    ]
  end

  defp plugin(name, summary, params, result, cli, errors),
    do: method("plugin." <> name, "plugin", summary, params, result, errors, cli)

  defp plugins do
    filter = opt("plugin_id", :string, "Only this plugin.")
    plugin_id = req("plugin_id", :string, "Target plugin.")
    pid = req("pane_id", :pane_id, "Target plugin pane.")

    [
      plugin(
        "list",
        "List installed and linked plugins.",
        [filter],
        "plugin_list",
        "herdr-live plugin list [--plugin ID] [--json]",
        []
      ),
      plugin(
        "install",
        "Install a plugin from GitHub; without `yes` answers a preview to confirm.",
        [
          req("source", :string, "`owner/repo[/subdir]` or a GitHub URL."),
          opt("ref", :string, "Git ref to check out."),
          opt("yes", :boolean, "Confirm the install.")
        ],
        "plugin_info",
        "herdr-live plugin install <source> [--ref REF] [--yes]",
        [:failed]
      )
      |> Map.put(
        :notes,
        "`source` may also be a local directory (absolute, `./`, `../` or `~`), copied without `.git`. " <>
          "Without `yes` the answer is `failed` with `data.reason` `confirmation_required` " <>
          "and `data.preview` describing what would be installed. Every error carries herdr's code in `data.reason`."
      ),
      plugin(
        "link",
        "Link a local plugin directory.",
        [
          req("path", :string, "Plugin directory."),
          opt("enabled", :boolean, "Enable it; default true.")
        ],
        "plugin_info",
        "herdr-live plugin link <path> [--disabled]",
        [:failed]
      ),
      plugin(
        "uninstall",
        "Remove a plugin by id or by `owner/repo[/subdir]`.",
        [req("target", :string, "Plugin id or `owner/repo[/subdir]`.")],
        "plugin_removed",
        "herdr-live plugin uninstall <target>",
        [:not_found, :failed]
      ),
      plugin(
        "enable",
        "Enable a plugin.",
        [plugin_id],
        "plugin_info",
        "herdr-live plugin enable <plugin_id>",
        [:not_found, :failed]
      ),
      plugin(
        "disable",
        "Disable a plugin.",
        [plugin_id],
        "plugin_info",
        "herdr-live plugin disable <plugin_id>",
        [:not_found, :failed]
      ),
      plugin(
        "config_dir",
        "The plugin's config directory.",
        [plugin_id],
        "plugin_dir",
        "herdr-live plugin config-dir <plugin_id>",
        [:failed]
      ),
      plugin(
        "action.list",
        "List plugin actions.",
        [filter],
        "plugin_action_list",
        "herdr-live plugin action list [--plugin ID]",
        []
      ),
      plugin(
        "action.invoke",
        "Run a plugin action.",
        [
          req("action_id", :string, "Action id."),
          opt("plugin_id", :string, "Plugin owning the action, when the id is ambiguous."),
          opt("context", :object, "Extra context passed to the command.")
        ],
        "plugin_action_invoked",
        "herdr-live plugin action invoke <action_id> [--plugin ID]",
        [:not_found, :failed, :not_available]
      )
      |> Map.put(
        :notes,
        "Starts the action's command and answers at once with the `running` log record; " <>
          "`plugin.log.list` shows how it ended. `data.reason` carries herdr's code " <>
          "(`plugin_action_not_found`, `ambiguous_plugin_action`, `plugin_disabled`, " <>
          "`plugin_command_limit_reached`, ...); `not_available` when the plugin runtime is not running."
      ),
      plugin(
        "log.list",
        "Recent plugin command records.",
        [filter, opt("limit", {:integer, 1, 200}, "Maximum number of records.")],
        "plugin_log_list",
        "herdr-live plugin log list [--plugin ID] [--limit N]",
        [:not_available]
      ),
      plugin(
        "pane.open",
        "Open a plugin pane entrypoint.",
        [
          req("plugin_id", :string, "Plugin."),
          req("entrypoint", :string, "Pane entrypoint id."),
          opt("placement", {:enum, ~w(overlay popup split tab zoomed)}, "Where it opens."),
          opt("width", :popup_size, "Popup outer width; default the entry's, else half."),
          opt("height", :popup_size, "Popup outer height; default the entry's, else half."),
          opt("workspace_id", :workspace_id, "Workspace; default the focused one."),
          opt("target_pane_id", :pane_id, "Pane to split; default the focused pane."),
          opt("direction", {:enum, ["right", "down"]}, "Split direction."),
          opt("cwd", :string, "Working directory."),
          opt("env", {:map, :string}, "Extra environment; herdr's own variables win."),
          focus("Focus the new pane; default true.")
        ],
        "pane_info",
        "herdr-live plugin pane open --plugin ID --entrypoint ID [--placement P] [--width S] " <>
          "[--height S] [--workspace ID] [--target-pane PANE] [--direction right|down] " <>
          "[--cwd PATH] [--env KEY=VALUE]... [--focus|--no-focus]",
        [:not_found, :failed, :ui_busy]
      )
      |> Map.put(
        :notes,
        "Runs the entry's command (argv, no shell) as the pane's program, in the plugin root " <>
          "unless `cwd` is given. `split` splits the target pane (`direction` default `right`); " <>
          "`tab`, `overlay` and `zoomed` open a new tab in the workspace (herdr-live has no " <>
          "overlay or zoom). `popup` opens the session popup over the active tab (one at a " <>
          "time: another is `ui_busy`, `data.reason` too; it closes when its program " <>
          "exits or on `popup.close`), sized by `width` / `height`, else the entry's, else " <>
          "half the pane area; its pane is not in any tab and the result's `tab_id` / " <>
          "`workspace_id` are the active tab's. The pane is named " <>
          "after the entry's title. `data.reason` carries herdr's code (`plugin_not_found`, " <>
          "`plugin_pane_not_found`, `plugin_disabled`, `invalid_env`, `ui_busy`, ...)."
      ),
      plugin(
        "pane.focus",
        "Focus a plugin pane.",
        [pid],
        "ok",
        "herdr-live plugin pane focus <pane_id>",
        [:not_found]
      ),
      plugin(
        "pane.close",
        "Close a plugin pane.",
        [pid],
        "ok",
        "herdr-live plugin pane close <pane_id>",
        [:not_found]
      )
    ]
  end

  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(name) do
    case Enum.find(methods(), &(&1.name == name)) do
      nil -> :error
      m -> {:ok, m}
    end
  end

  # --- results and objects ---------------------------------------------------

  defp f(name, type, required \\ true), do: %{name: name, type: type, required: required}

  @spec objects() :: %{String.t() => [map()]}
  def objects do
    %{
      "workspace" => [
        f("workspace_id", :workspace_id),
        f("label", :string),
        f("focused", :boolean),
        f("tabs", :integer),
        f("active_tab_id", :tab_id),
        f("tokens", :object, false)
      ],
      "tab" => [
        f("tab_id", :tab_id),
        f("workspace_id", :workspace_id),
        f("label", :string),
        f("focused", :boolean),
        f("panes", :integer),
        f("focused_pane_id", :pane_id)
      ],
      "pane" => [
        f("pane_id", :pane_id),
        f("tab_id", :tab_id),
        f("workspace_id", :workspace_id),
        f("title", :null_or_string),
        f("label", :null_or_string),
        f("focused", :boolean),
        f("cols", :integer),
        f("rows", :integer),
        f("tokens", :object, false)
      ],
      "agent" => [
        f("pane_id", :pane_id),
        f("workspace_id", :workspace_id),
        f("tab_id", :tab_id),
        f("agent", :null_or_string),
        f("agent_status", {:enum, @agent_states}),
        f("title", :null_or_string),
        f("terminal_title", :null_or_string),
        f("terminal_title_stripped", :null_or_string),
        f("focused", :boolean),
        f("cwd", :null_or_string),
        f("screen_detection_skipped", :boolean),
        f("hook_source", :null_or_string)
      ],
      "plugin" => [
        f("plugin_id", :string),
        f("name", :string),
        f("version", :string),
        f("min_herdr_version", :string),
        f("description", :null_or_string),
        f("plugin_root", :string),
        f("manifest_path", :string),
        f("enabled", :boolean),
        f("source", :object),
        f("warnings", {:list, :string}),
        f("error", :null_or_string),
        f("actions", {:list, :object}),
        f("panes", {:list, :object}),
        f("link_handlers", {:list, :object}),
        f("events", {:list, :object}),
        f("startup", {:list, :object})
      ],
      "session" => [
        f("name", :string),
        f("os_pid", :integer),
        f("gen", :integer),
        f("api_socket", :string),
        f("client_socket", :null_or_string),
        f("clients", :integer)
      ],
      "client" => [
        f("id", :string),
        f("kind", :string),
        f("target", :string),
        f("cols", :integer),
        f("rows", :integer),
        f("connected", :boolean)
      ],
      "focus" => [
        f("workspace_id", :workspace_id, false),
        f("tab_id", :tab_id, false),
        f("pane_id", :pane_id, false)
      ],
      "worktree" => [
        f("path", :string),
        f("branch", :null_or_string),
        f("is_bare", :boolean),
        f("is_detached", :boolean),
        f("is_prunable", :boolean),
        f("is_linked_worktree", :boolean),
        f("open_workspace_id", :null_or_string),
        f("label", :string)
      ],
      "layout" => [
        f("tab_id", :tab_id),
        f("workspace_id", :workspace_id),
        f("focused_pane_id", :pane_id),
        f("root", :object)
      ]
    }
  end

  @doc """
  The event stream's line types, in order. Each line is `{"event": type, "data": data}`;
  `data` holds exactly `fields` (`Api.EventDiff` builds them).
  """
  @spec events() :: [%{type: String.t(), summary: String.t(), fields: [map()]}]
  def events do
    ws = [f("workspace_id", :workspace_id)]
    tab = [f("tab_id", :tab_id) | ws]
    pane = [f("pane_id", :pane_id) | tab]
    ws_obj = ws ++ [f("workspace", {:ref, "workspace"})]
    tab_obj = tab ++ [f("tab", {:ref, "tab"})]
    pane_obj = pane ++ [f("pane", {:ref, "pane"})]

    [
      ev("workspace.created", "A workspace was created.", ws_obj),
      ev("workspace.closed", "A workspace was closed.", ws),
      ev("workspace.focused", "The focused workspace changed.", ws_obj),
      ev("workspace.renamed", "A workspace's label changed.", ws_obj),
      ev("workspace.metadata_updated", "A workspace's metadata tokens changed.", ws_obj),
      ev(
        "workspace.moved",
        "A workspace was moved: its id, the requested insert_index and the new order.",
        ws ++ [f("insert_index", :integer), f("workspaces", {:list, {:ref, "workspace"}})]
      ),
      ev("tab.created", "A tab was created.", tab_obj),
      ev("tab.closed", "A tab was closed.", tab),
      ev("tab.focused", "The focused tab changed.", tab_obj),
      ev("tab.renamed", "A tab's label changed.", tab_obj),
      ev(
        "tab.moved",
        "A tab was moved: its id, the requested insert_index and its workspace's new order.",
        tab ++ [f("insert_index", :integer), f("tabs", {:list, {:ref, "tab"}})]
      ),
      ev("pane.created", "A pane was created.", pane_obj),
      ev("pane.closed", "A pane was closed.", pane),
      ev("pane.focused", "The focused pane changed.", pane_obj),
      ev("pane.updated", "A pane's title, size or metadata tokens changed.", pane_obj),
      ev(
        "pane.agent_detected",
        "A pane's detected agent changed.",
        pane ++ [f("agent", :null_or_string)]
      ),
      ev(
        "pane.agent_status_changed",
        "A pane's agent status changed.",
        pane ++ [f("agent", :null_or_string), f("agent_status", {:enum, @agent_states})]
      ),
      ev("layout.updated", "A tab's split tree changed.", tab ++ [f("layout", {:ref, "layout"})]),
      ev(
        "notification.shown",
        "An agent needs attention or finished.",
        pane ++
          [
            f("level", {:enum, ["attention", "done"]}),
            f("title", :string),
            f("body", :string),
            f("sound", {:enum, ["request", "done"]})
          ]
      )
    ]
  end

  defp ev(type, summary, fields), do: %{type: type, summary: summary, fields: fields}

  @doc "Checks one decoded event line against `events/0` (tests)."
  @spec validate_event(map()) :: :ok | {:error, String.t()}
  def validate_event(%{"event" => type, "data" => data} = line)
      when map_size(line) == 2 and is_map(data) do
    case Enum.find(events(), &(&1.type == type)) do
      nil -> {:error, "unknown event #{inspect(type)}"}
      e -> check_fields_result(e.fields, data, "data.", [])
    end
  end

  def validate_event(line), do: {:error, "an event line is {event, data}: #{inspect(line)}"}

  @spec results() :: %{String.t() => [map()]}
  def results do
    ws = {:ref, "workspace"}
    tab = {:ref, "tab"}
    pane = {:ref, "pane"}

    %{
      "pong" => [f("version", :string), f("gen", :integer)],
      "api_schema" => [f("methods", {:list, :object})],
      "server_status" => [
        f("gen", :integer),
        f("os_pid", :integer),
        f("reload_enabled", :boolean),
        f("test_on_save", :null_or_string),
        f("handoff", :null_or_string),
        f("workspaces", :integer),
        f("panes", :integer),
        f("api_conns", :integer)
      ],
      "session_list" => [f("sessions", {:list, {:ref, "session"}})],
      "session_info" => [f("session", {:ref, "session"})],
      "session_snapshot" => [
        f("version", :string),
        f("session", {:ref, "session"}),
        f("focused", {:ref, "focus"}),
        f("workspaces", {:list, ws}),
        f("tabs", {:list, tab}),
        f("panes", {:list, pane}),
        f("layouts", {:list, :object})
      ],
      "client_list" => [f("clients", {:list, {:ref, "client"}})],
      "reload_rollback" => [f("batches", {:list, :integer})],
      "test_on_save" => [f("mode", {:enum, ["gate", "off"]})],
      "workspace_list" => [f("workspaces", {:list, ws})],
      "workspace_info" => [f("workspace", ws)],
      "workspace_created" => [f("workspace", ws), f("tab", tab), f("root_pane", pane)],
      "workspace_closed" => [f("workspace_id", :workspace_id)],
      "tab_list" => [f("tabs", {:list, tab})],
      "tab_info" => [f("tab", tab)],
      "tab_created" => [f("tab", tab), f("root_pane", pane)],
      "tab_closed" => [f("tab_id", :tab_id)],
      "pane_list" => [f("panes", {:list, pane})],
      "pane_info" => [f("pane", pane)],
      "pane_split" => [f("pane", pane)],
      "pane_closed" => [f("pane_id", :pane_id)],
      "pane_focus_direction" => [
        f("changed", :boolean),
        f("reason", {:enum, ["no_neighbor"]}, false),
        f("source_pane_id", :pane_id),
        f("focused_pane_id", :pane_id),
        f("layout", {:ref, "layout"})
      ],
      "pane_swap" => [
        f("changed", :boolean),
        f("reason", {:enum, ["no_neighbor"]}, false),
        f("source_pane_id", :pane_id),
        f("focused_pane_id", :pane_id),
        f("layout", {:ref, "layout"})
      ],
      "pane_resize" => [
        f("changed", :boolean),
        f("reason", {:enum, ["unchanged"]}, false),
        f("pane_id", :pane_id),
        f("focused_pane_id", :pane_id),
        f("layout", {:ref, "layout"})
      ],
      "pane_layout" => [f("layout", {:ref, "layout"})],
      "process_info" => [
        f("pane_id", :pane_id),
        f("os_pid", :integer),
        f("cwd", :null_or_string),
        f("exited", :boolean)
      ],
      "ok" => [],
      "pane_read" => [
        f("pane_id", :pane_id),
        f("source", {:enum, @sources}),
        f("text", :string)
      ],
      "output_matched" => [f("pane_id", :pane_id), f("line", :string)],
      "subscription_started" => [f("subscriptions", :integer)],
      "agent_list" => [f("agents", {:list, {:ref, "agent"}})],
      "agent_info" => [f("agent", {:ref, "agent"})],
      "agent_read" => [f("target", :string), f("text", :string)],
      "agent_explain" => [f("agent", :object), f("explanation", :string)],
      "agent_wait" => [f("agent", {:ref, "agent"})],
      "agent_manifests" => [f("manifests", {:list, :object})],
      "pane_link_activated" => [f("url", :null_or_string), f("handled", :boolean)],
      "plugin_list" => [f("plugins", {:list, {:ref, "plugin"}})],
      "plugin_info" => [f("plugin", {:ref, "plugin"})],
      "plugin_removed" => [f("plugin_id", :string)],
      "plugin_dir" => [f("path", :string)],
      "plugin_action_list" => [f("actions", {:list, :object})],
      "plugin_action_invoked" => [
        f("action", :object),
        f("context", :object),
        f("log", :object)
      ],
      "plugin_log_list" => [f("logs", {:list, :object})],
      "worktree_list" => [f("source", :object), f("worktrees", {:list, {:ref, "worktree"}})],
      "worktree_created" => [
        f("workspace", ws),
        f("tab", tab),
        f("root_pane", pane),
        f("worktree", {:ref, "worktree"})
      ],
      "worktree_opened" => [
        f("workspace", ws),
        f("tab", tab),
        f("root_pane", pane),
        f("worktree", {:ref, "worktree"}),
        f("already_open", :boolean)
      ],
      "worktree_removed" => [
        f("workspace_id", :workspace_id),
        f("path", :string),
        f("forced", :boolean)
      ]
    }
  end

  # --- param validation ------------------------------------------------------

  @spec validate_params(String.t(), term()) :: {:ok, %{atom() => term()}} | {:error, String.t()}
  def validate_params(name, params) do
    case fetch(name) do
      {:ok, m} -> check_object(m.params, params, nil)
      :error -> {:error, "unknown method #{inspect(name)}"}
    end
  end

  defp check_object(params, input, path) when is_map(input) do
    known = Map.new(params, &{&1.name, &1})

    case Enum.find(Map.keys(input), &(not is_map_key(known, &1))) do
      nil -> check_fields(params, input, path)
      key -> {:error, "unknown param #{path_name(path, to_string_key(key))}"}
    end
  end

  defp check_object(_params, _input, path), do: {:error, "#{path || "params"} must be an object"}

  defp check_items(type, items, full) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, i}, {:ok, acc} ->
      case check(type, item, "#{full}[#{i}]", nil) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      e -> e
    end
  end

  defp to_string_key(k) when is_binary(k), do: k
  defp to_string_key(k), do: inspect(k)

  defp check_fields(params, input, path) do
    Enum.reduce_while(params, {:ok, %{}}, fn p, {:ok, acc} ->
      full = path_name(path, p.name)

      case Map.fetch(input, p.name) do
        :error when p.required -> {:halt, {:error, "missing required param #{full}"}}
        :error -> {:cont, {:ok, acc}}
        {:ok, v} -> put_checked(acc, p, v, full)
      end
    end)
  end

  defp put_checked(acc, p, v, full) do
    case check(p.type, v, full, Map.get(p, :min_items)) do
      {:ok, parsed} ->
        # Atoms come from the spec's own names, never from user input.
        {:cont, {:ok, Map.put(acc, String.to_atom(p.name), parsed)}}

      {:error, _} = e ->
        {:halt, e}
    end
  end

  defp path_name(nil, name), do: name
  defp path_name(path, name), do: path <> "." <> name

  defp bad(full, what), do: {:error, "param #{full} must be #{what}"}

  defp check(:string, v, _, _) when is_binary(v), do: {:ok, v}
  defp check(:string, _, full, _), do: bad(full, "a string")
  defp check(:boolean, v, _, _) when is_boolean(v), do: {:ok, v}
  defp check(:boolean, _, full, _), do: bad(full, "a boolean")

  defp check(:popup_size, v, _, _) when is_integer(v) and v in 0..65_535, do: {:ok, v}

  defp check(:popup_size, v, full, _) when is_binary(v) do
    case Integer.parse(v) do
      {n, "%"} when n in 1..100 -> {:ok, v}
      _ -> bad(full, "a number of cells or a percentage like 80%")
    end
  end

  defp check(:popup_size, _, full, _), do: bad(full, "a number of cells or a percentage like 80%")

  defp check({:integer, min, max}, v, _, _) when is_integer(v) and v >= min and v <= max,
    do: {:ok, v}

  defp check({:integer, min, max}, _, full, _), do: bad(full, "an integer in #{min}..#{max}")

  defp check({:number, min, max}, v, _, _) when is_number(v) and v >= min and v <= max,
    do: {:ok, v}

  defp check({:number, min, max}, _, full, _), do: bad(full, "a number in #{min}..#{max}")

  defp check({:enum, values}, v, full, _) do
    if v in values, do: {:ok, v}, else: bad(full, "one of #{Enum.join(values, ", ")}")
  end

  defp check(:pane_id, v, full, _), do: id(Ids.parse_pane(v), full, "a pane id like \"p1\"")
  defp check(:tab_id, v, full, _), do: id(Ids.parse_tab(v), full, "a tab id like \"w1:t1\"")

  defp check(:workspace_id, v, full, _),
    do: id(Ids.parse_workspace(v), full, "a workspace id like \"w1\"")

  defp check({:list, type}, v, full, min) when is_list(v) do
    if length(v) < (min || 0) do
      bad(full, "a list of at least #{min}")
    else
      check_items(type, v, full)
    end
  end

  defp check({:list, _}, _, full, _), do: bad(full, "a list")

  defp check({:map, :string}, v, full, _) when is_map(v) do
    if Enum.all?(v, fn {k, x} -> is_binary(k) and is_binary(x) end),
      do: {:ok, v},
      else: bad(full, "an object of strings")
  end

  defp check({:map, :string}, _, full, _), do: bad(full, "an object of strings")

  defp check({:map, :null_or_string}, v, full, _) when is_map(v) do
    if Enum.all?(v, fn {k, x} -> is_binary(k) and (is_binary(x) or is_nil(x)) end),
      do: {:ok, v},
      else: bad(full, "an object of strings or nulls")
  end

  defp check({:map, :null_or_string}, _, full, _), do: bad(full, "an object of strings or nulls")
  defp check({:object, params}, v, full, _), do: check_object(params, v, full)
  defp check(:object, v, _, _) when is_map(v), do: {:ok, v}
  defp check(:object, _, full, _), do: bad(full, "an object")

  defp id({:ok, v}, _, _), do: {:ok, v}
  defp id(:error, full, what), do: bad(full, what)

  # --- result validation (tests) ---------------------------------------------

  @spec validate_result(String.t(), map()) :: :ok | {:error, String.t()}
  def validate_result(name, result) do
    with {:ok, m} <- fetch(name),
         {:ok, fields} <- Map.fetch(results(), m.result) |> or_error("no result type #{m.result}"),
         :ok <- check_type_name(m.result, result) do
      check_fields_result(fields, result, "", ["type"])
    else
      :error -> {:error, "unknown method #{inspect(name)}"}
      {:error, _} = e -> e
    end
  end

  defp or_error({:ok, _} = ok, _), do: ok
  defp or_error(:error, msg), do: {:error, msg}

  defp check_type_name(expected, %{"type" => expected}), do: :ok

  defp check_type_name(expected, other),
    do: {:error, "type must be #{expected}, got #{inspect(Map.get(other, "type"))}"}

  # every declared field checked, and no field the spec does not declare
  defp check_fields_result(fields, map, prefix, extra) do
    declared = extra ++ Enum.map(fields, & &1.name)

    case Enum.find(Map.keys(map), &(&1 not in declared)) do
      nil -> check_declared(fields, map, prefix)
      key -> {:error, "undeclared field #{prefix}#{key}"}
    end
  end

  defp check_declared(fields, map, prefix) do
    Enum.reduce_while(fields, :ok, fn fl, :ok ->
      case check_field(fl, Map.fetch(map, fl.name), prefix <> fl.name) do
        :ok -> {:cont, :ok}
        e -> {:halt, e}
      end
    end)
  end

  defp check_field(%{required: true}, :error, full), do: {:error, "missing field #{full}"}
  defp check_field(_, :error, _), do: :ok
  defp check_field(fl, {:ok, v}, full), do: rtype(fl.type, v, full)

  defp rtype(:string, v, _) when is_binary(v), do: :ok
  defp rtype(:boolean, v, _) when is_boolean(v), do: :ok
  defp rtype(:integer, v, _) when is_integer(v), do: :ok
  defp rtype(:object, v, _) when is_map(v), do: :ok
  defp rtype(:null_or_string, v, _) when is_nil(v) or is_binary(v), do: :ok

  defp rtype({:enum, values}, v, full),
    do: if(v in values, do: :ok, else: rbad(full, "an enum value"))

  defp rtype(:pane_id, v, full), do: rid(Ids.parse_pane(v), full)
  defp rtype(:tab_id, v, full), do: rid(Ids.parse_tab(v), full)
  defp rtype(:workspace_id, v, full), do: rid(Ids.parse_workspace(v), full)

  defp rtype({:ref, obj}, v, full) when is_map(v),
    do: check_fields_result(Map.fetch!(objects(), obj), v, full <> ".", [])

  defp rtype({:list, t}, v, full) when is_list(v) do
    v
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {x, i} ->
      case rtype(t, x, "#{full}[#{i}]") do
        :ok -> nil
        e -> e
      end
    end)
  end

  defp rtype(_, _, full), do: rbad(full, "of the declared type")

  defp rid({:ok, _}, _), do: :ok
  defp rid(:error, full), do: rbad(full, "a valid public id")

  defp rbad(full, what), do: {:error, "field #{full} must be #{what}"}
end
