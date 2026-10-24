defmodule HerdrServer.Api.Spec do
  @moduledoc """
  The socket API as plain data: methods, params, result shapes, error codes.

  One source for the validator, the schema endpoint, the CLI and the generated
  `docs/herdr-live/api.md`. Pure: no processes, no I/O.

  Param types: `:string | :boolean | {:integer, min, max} | {:number, min, max} |
  {:enum, [String.t()]} | :pane_id | :tab_id | :workspace_id | {:list, type} |
  {:map, :string} | {:object, [param]}`. A list param may carry `min_items: n`.
  Result field types add `:integer`, `:object` (opaque JSON object),
  `:null_or_string`, `{:ref, object_name}`.
  """

  alias HerdrServer.Api.Ids

  @error_codes ~w(parse_error invalid_request unknown_method invalid_params not_found
                  not_available failed timeout backpressure events_lost internal)a

  @event_types ~w(workspace.created workspace.closed workspace.focused workspace.renamed
                  tab.created tab.closed tab.focused tab.renamed
                  pane.created pane.closed pane.focused pane.updated layout.updated)

  @sources ~w(visible recent)
  @agent_states ~w(idle working blocked done unknown)

  @spec error_codes() :: [atom()]
  def error_codes, do: @error_codes

  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  # --- param builders --------------------------------------------------------

  defp req(name, type, doc), do: %{name: name, type: type, required: true, doc: doc}
  defp opt(name, type, doc), do: %{name: name, type: type, required: false, doc: doc}

  defp opt_pane(doc), do: opt("pane_id", :pane_id, doc)
  defp tab_id, do: req("tab_id", :tab_id, "Target tab.")
  defp ws_id, do: req("workspace_id", :workspace_id, "Target workspace.")
  defp label, do: req("label", :string, "New label.")
  defp focus(doc), do: opt("focus", :boolean, doc)
  defp source, do: opt("source", {:enum, @sources}, "Text source; default `visible`.")
  defp lines, do: opt("lines", {:integer, 1, 10_000}, "Maximum number of lines.")
  defp target, do: req("target", :string, "Agent target (pane id or agent name).")

  defp timeout_ms,
    do: opt("timeout_ms", {:integer, 1, 3_600_000}, "Give up after this many milliseconds.")

  defp method(name, group, summary, params, result, errors, cli) do
    errors = if params == [], do: errors, else: [:invalid_params | errors]

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

  defp agent(name, summary, params, result, cli),
    do: method("agent." <> name, "agent", summary, params, result, [:not_available], cli)

  # --- methods ---------------------------------------------------------------

  @spec methods() :: [map()]
  def methods do
    server() ++ reload() ++ workspace() ++ tab() ++ pane() ++ events() ++ agents()
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
        [:failed],
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
        [:not_found, :failed],
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
    send_errors = [:not_found, :backpressure]

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
          focus("Focus the new pane.")
        ],
        "pane_split",
        [:not_found, :failed],
        "herdr-live pane split [<pane_id>] --direction right|down [--ratio R] [--focus]"
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
        send_errors,
        "herdr-live pane run <pane_id> <command>"
      ),
      method(
        "pane.read",
        g,
        "Read terminal text.",
        [pid, source(), lines()],
        "pane_read",
        send_errors,
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

  defp events do
    sub = [
      req("type", {:enum, @event_types}, "Event type."),
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
        [:not_found, :events_lost],
        "herdr-live events subscribe <type>... [--pane <pane_id>] [--tab <tab_id>] [--workspace <workspace_id>]"
      )
    ]
  end

  defp agents do
    until =
      opt("until", {:list, {:enum, @agent_states}}, "Agent states to wait for; default `idle`.")

    [
      agent("list", "List detected agents.", [], "agent_list", "herdr-live agent list"),
      agent(
        "get",
        "Describe an agent.",
        [target()],
        "agent_info",
        "herdr-live agent get <target>"
      ),
      agent(
        "read",
        "Read an agent's terminal text.",
        [target(), source(), lines()],
        "agent_read",
        "herdr-live agent read <target> [--source visible|recent] [--lines N]"
      ),
      agent(
        "explain",
        "Explain why detection reports the agent's state.",
        [target()],
        "agent_explain",
        "herdr-live agent explain <target>"
      ),
      agent(
        "wait",
        "Wait until an agent reaches one of the given states.",
        [target(), until, timeout_ms()],
        "agent_wait",
        "herdr-live agent wait <target> [--until S]... [--timeout MS]"
      ),
      agent(
        "prompt",
        "Send a prompt to an agent.",
        [target(), req("text", :string, "Prompt text.")],
        "ok",
        "herdr-live agent prompt <target> <text>"
      ),
      agent(
        "send_keys",
        "Send named keys to an agent.",
        [target(), Map.put(req("keys", {:list, :string}, "Key names."), :min_items, 1)],
        "ok",
        "herdr-live agent send-keys <target> <key>..."
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
        f("active_tab_id", :tab_id)
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
        f("focused", :boolean),
        f("cols", :integer),
        f("rows", :integer)
      ],
      "layout" => [
        f("tab_id", :tab_id),
        f("workspace_id", :workspace_id),
        f("focused_pane_id", :pane_id),
        f("root", :object)
      ]
    }
  end

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
      "agent_list" => [f("agents", {:list, :object})],
      "agent_info" => [f("agent", :object)],
      "agent_read" => [f("target", :string), f("text", :string)],
      "agent_explain" => [f("agent", :object), f("explanation", :string)],
      "agent_wait" => [f("agent", :object)]
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
  defp check({:object, params}, v, full, _), do: check_object(params, v, full)

  defp id({:ok, v}, _, _), do: {:ok, v}
  defp id(:error, full, what), do: bad(full, what)

  # --- result validation (tests) ---------------------------------------------

  @spec validate_result(String.t(), map()) :: :ok | {:error, String.t()}
  def validate_result(name, result) do
    with {:ok, m} <- fetch(name),
         {:ok, fields} <- Map.fetch(results(), m.result) |> or_error("no result type #{m.result}"),
         :ok <- check_type_name(m.result, result) do
      check_fields_result(fields, result, "")
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

  defp check_fields_result(fields, map, prefix) do
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
    do: check_fields_result(Map.fetch!(objects(), obj), v, full <> ".")

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
