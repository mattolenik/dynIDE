defmodule HerdrCli.Argv do
  @moduledoc """
  Pure argv parsing for `herdr-live <verb>`: argv and env in, an API request out.

  Each command is a row of data: words, method, positionals, options, output mode
  and its usage line (the Spec's `cli` string, minus `herdr-live `, checked by the
  integration conformance test). Ids are passed through as given (the server
  validates them); enums are checked here so a typo is a usage error (exit 2).

  Positional kinds: `{:req, name}`; `{:opt, name}` (a string, may be omitted); `{:pane, name, :required | :optional}` (when
  omitted, `HERDR_PANE_ID` from env, else usage / left out); `{:keys, name}` (one or
  more); `{:int, name}`; `{:opt_int, name}`; `{:opt_enum, name, values}`. Option kinds: `:string`,
  `:int`, `:number`, `:flag`, `{:const, value}` (a flag that sets `value`), `{:enum, values}`,
  `{:many, values}` (repeatable), `:file` (a path; becomes `{:file, path}` for the caller to read into the param), `{:kv_many}` (repeatable `KEY=VALUE`, collected into a map).
  An atom key is consumed by `finish/3` (`:json` is accepted and dropped). A row with
  `alias: true` is another spelling of a command and has no Spec `cli` string of its own.
  `--opt value` and `--opt=value` are both accepted; `--` ends options.
  """

  @type out :: :json | :text | :path | :lines | :rollback | :gate
  @type result ::
          {:call, String.t(), map(), out()}
          | {:subscribe, map()}
          | {:usage, String.t()}
          | {:help, String.t()}
          | {:print, binary()}

  @sources ~w(visible recent)
  @agent_states ~w(idle working blocked done unknown)
  @event_types ~w(workspace.created workspace.closed workspace.focused workspace.renamed
                  tab.created tab.closed tab.focused tab.renamed
                  pane.created pane.closed pane.focused pane.updated
                  pane.agent_detected pane.agent_status_changed layout.updated
                  notification.shown)

  @source {:enum, @sources}
  @read_opts %{"source" => {"source", @source}, "lines" => {"lines", :int}}

  defp cmd(words, method, pos, opts, out, usage),
    do: %{words: words, method: method, pos: pos, opts: opts, out: out, usage: usage}

  @doc "Every command row; `usage` is the CLI form without the `herdr-live ` prefix."
  @spec commands() :: [map()]
  def commands do
    server() ++
      session() ++
      workspace() ++
      tab() ++
      pane() ++
      notification() ++
      title() ++
      agent() ++
      events() ++
      plugin() ++
      worktree()
  end

  defp worktree do
    src = %{"workspace" => {"workspace_id", :string}, "cwd" => {"cwd", :string}}
    src_usage = "[--workspace <workspace_id> | --cwd <path>]"
    open = Map.merge(src, %{"label" => {"label", :string}, "focus" => {"focus", :flag}})

    create =
      Map.merge(open, %{
        "branch" => {"branch", :string},
        "base" => {"base", :string},
        "path" => {"path", :string}
      })

    [
      cmd(~w(worktree list), "worktree.list", [], src, :json, "worktree list #{src_usage}"),
      cmd(
        ~w(worktree create),
        "worktree.create",
        [],
        create,
        :json,
        "worktree create --branch B #{src_usage} [--base REF] [--path P] [--label L] [--focus]"
      ),
      cmd(
        ~w(worktree open),
        "worktree.open",
        [],
        Map.merge(open, %{"branch" => {"branch", :string}, "path" => {"path", :string}}),
        :json,
        "worktree open (--path P | --branch B) #{src_usage} [--label L] [--focus]"
      ),
      cmd(
        ~w(worktree remove),
        "worktree.remove",
        [{:req, "workspace_id"}],
        %{"force" => {"force", :flag}},
        :json,
        "worktree remove <workspace_id> [--force]"
      )
    ]
  end

  defp session do
    [
      cmd(["session", "list"], "session.list", [], %{}, :json, "session list"),
      cmd(
        ["session", "get"],
        "session.get",
        [{:opt, "name"}],
        %{},
        :json,
        "session get [<name>]"
      ),
      cmd(["api", "snapshot"], "session.snapshot", [], %{}, :json, "api snapshot"),
      cmd(["client", "list"], "client.list", [], %{}, :json, "client list")
    ]
  end

  defp server do
    [
      cmd(["ping"], "ping", [], %{}, :json, "ping"),
      cmd(["api", "schema"], "api.schema", [], %{}, :json, "api schema"),
      cmd(["api", "call"], :raw, [], %{}, :json, "api call <method> [<params json>]"),
      cmd(
        ["server", "status"],
        "server.status",
        [],
        %{"kv" => {:kv, :flag}},
        :json,
        "server status [--kv]"
      ),
      cmd(
        ["server", "agent-manifests"],
        "server.agent_manifests",
        [],
        %{},
        :json,
        "server agent-manifests"
      ),
      cmd(
        ["server", "reload-agent-manifests"],
        "server.reload_agent_manifests",
        [],
        %{},
        :json,
        "server reload-agent-manifests"
      ),
      cmd(["rollback"], "reload.rollback", [{:opt_int, "n"}], %{}, :rollback, "rollback [<n>]"),
      cmd(
        ["test-on-save"],
        "reload.test_on_save",
        [{:opt_enum, "mode", ["on", "off"]}],
        %{},
        :gate,
        "test-on-save [on|off]"
      ),
      # CLI-local (no API method): answered by `parse/2` itself
      cmd(["--default-config"], :print, [], %{}, :text, "--default-config"),
      cmd(["completion"], :print, [], %{}, :text, "completion bash|zsh|fish")
    ]
  end

  defp workspace do
    id = {:req, "workspace_id"}
    label = %{"label" => {"label", :string}, "focus" => {"focus", :flag}}

    [
      cmd(~w(workspace list), "workspace.list", [], %{}, :json, "workspace list"),
      cmd(~w(workspace get), "workspace.get", [id], %{}, :json, "workspace get <workspace_id>"),
      cmd(
        ~w(workspace create),
        "workspace.create",
        [],
        label,
        :json,
        "workspace create [--label L] [--focus]"
      ),
      cmd(
        ~w(workspace focus),
        "workspace.focus",
        [id],
        %{},
        :json,
        "workspace focus <workspace_id>"
      ),
      cmd(
        ~w(workspace rename),
        "workspace.rename",
        [id, {:req, "label"}],
        %{},
        :json,
        "workspace rename <workspace_id> <label>"
      ),
      cmd(
        ~w(workspace move),
        "workspace.move",
        [id, {:int, "index"}],
        %{},
        :json,
        "workspace move <workspace_id> <index>"
      ),
      cmd(
        ~w(workspace close),
        "workspace.close",
        [id],
        %{},
        :json,
        "workspace close <workspace_id>"
      )
    ]
  end

  defp tab do
    id = {:req, "tab_id"}
    ws = %{"workspace" => {"workspace_id", :string}}

    create =
      Map.merge(ws, %{"label" => {"label", :string}, "focus" => {"focus", :flag}})

    [
      cmd(~w(tab list), "tab.list", [], ws, :json, "tab list [--workspace <workspace_id>]"),
      cmd(~w(tab get), "tab.get", [id], %{}, :json, "tab get <tab_id>"),
      cmd(
        ~w(tab create),
        "tab.create",
        [],
        create,
        :json,
        "tab create [--workspace <workspace_id>] [--label L] [--focus]"
      ),
      cmd(~w(tab focus), "tab.focus", [id], %{}, :json, "tab focus <tab_id>"),
      cmd(
        ~w(tab rename),
        "tab.rename",
        [id, {:req, "label"}],
        %{},
        :json,
        "tab rename <tab_id> <label>"
      ),
      cmd(
        ~w(tab move),
        "tab.move",
        [id, {:int, "index"}],
        %{},
        :json,
        "tab move <tab_id> <index>"
      ),
      cmd(~w(tab close), "tab.close", [id], %{}, :json, "tab close <tab_id>")
    ]
  end

  defp pane do
    id = {:req, "pane_id"}
    env_id = {:pane, "pane_id", :required}
    opt_id = {:pane, "pane_id", :optional}

    list = %{"workspace" => {"workspace_id", :string}, "tab" => {"tab_id", :string}}

    split = %{
      "direction" => {"direction", {:enum, ["right", "down"]}},
      "ratio" => {"ratio", :number},
      "focus" => {"focus", :flag},
      "no-focus" => {"focus", {:const, false}}
    }

    link = %{
      "col" => {"col", :int},
      "row" => {"viewport_row", :int},
      "modifier" => {"modifiers", {:many, ~w(shift alt ctrl)}}
    }

    wait =
      Map.merge(@read_opts, %{
        "match" => {"match", :string},
        "regex" => {"regex", :string},
        "timeout" => {"timeout_ms", :int}
      })

    [
      cmd(
        ~w(pane list),
        "pane.list",
        [],
        list,
        :json,
        "pane list [--workspace <workspace_id>] [--tab <tab_id>]"
      ),
      cmd(~w(pane get), "pane.get", [id], %{}, :json, "pane get <pane_id>"),
      cmd(~w(pane current), "pane.current", [], %{}, :json, "pane current"),
      cmd(
        ~w(pane split),
        "pane.split",
        [opt_id],
        split,
        :json,
        "pane split [<pane_id>] --direction right|down [--ratio R] [--focus|--no-focus]"
      ),
      cmd(
        ~w(pane rename),
        "pane.rename",
        [id, {:opt, "label"}],
        %{},
        :json,
        "pane rename <pane_id> [<label>]"
      ),
      cmd(
        ~w(pane link activate),
        "pane.link.activate",
        [id],
        link,
        :json,
        "pane link activate <pane_id> --col N --row N [--modifier M]..."
      ),
      cmd(~w(pane close), "pane.close", [id], %{}, :json, "pane close <pane_id>"),
      cmd(~w(pane focus), "pane.focus", [id], %{}, :json, "pane focus <pane_id>"),
      cmd(
        ~w(pane zoom),
        "pane.zoom",
        [opt_id],
        %{"on" => {"zoom", :flag}, "off" => {"off", :flag}},
        :json,
        "pane zoom [<pane_id>] [--on|--off]"
      ),
      cmd(~w(pane layout), "pane.layout", [opt_id], %{}, :json, "pane layout [<pane_id>]"),
      cmd(
        ~w(pane process-info),
        "pane.process_info",
        [env_id],
        %{},
        :json,
        "pane process-info [<pane_id>]"
      ),
      cmd(
        ~w(pane send-text),
        "pane.send_text",
        [id, {:req, "text"}],
        %{},
        :json,
        "pane send-text <pane_id> <text>"
      ),
      cmd(
        ~w(pane send-keys),
        "pane.send_keys",
        [id, {:keys, "keys"}],
        %{},
        :json,
        "pane send-keys <pane_id> <key>..."
      ),
      cmd(
        ~w(pane run),
        "pane.run",
        [id, {:req, "command"}],
        %{},
        :json,
        "pane run <pane_id> <command>"
      ),
      cmd(
        ~w(pane report-agent),
        "pane.report_agent",
        [id],
        %{
          "source" => {"source", :string},
          "agent" => {"agent", :string},
          "state" => {"state", {:enum, ~w(idle working blocked unknown)}},
          "message" => {"message", :string},
          "seq" => {"seq", :int}
        },
        :json,
        "pane report-agent <pane_id> --source S --agent A --state S [--message T] [--seq N]"
      ),
      cmd(
        ~w(pane release-agent),
        "pane.release_agent",
        [id],
        %{
          "source" => {"source", :string},
          "agent" => {"agent", :string},
          "seq" => {"seq", :int}
        },
        :json,
        "pane release-agent <pane_id> --source S --agent A [--seq N]"
      ),
      cmd(
        ~w(pane read),
        "pane.read",
        [env_id],
        @read_opts,
        :text,
        "pane read [<pane_id>] [--source visible|recent] [--lines N]"
      ),
      cmd(
        ~w(pane wait-output),
        "pane.wait_for_output",
        [env_id],
        wait,
        :json,
        "pane wait-output [<pane_id>] (--match S | --regex R) [--source visible|recent] " <>
          "[--lines N] [--timeout MS]"
      )
    ]
  end

  defp notification do
    [
      cmd(
        ~w(notification show),
        "notification.show",
        [{:req, "title"}],
        %{"body" => {"body", :string}, "pane" => {"pane_id", :string}},
        :json,
        "notification show <title> [--body <text>] [--pane <pane_id>]"
      )
    ]
  end

  defp title do
    [
      cmd(
        ~w(title set),
        "client.window_title.set",
        [{:req, "title"}],
        %{},
        :json,
        "title set <title>"
      ),
      cmd(~w(title clear), "client.window_title.clear", [], %{}, :json, "title clear")
    ]
  end

  defp agent do
    t = {:req, "target"}

    [
      cmd(~w(agent list), "agent.list", [], %{}, :json, "agent list"),
      cmd(~w(agent get), "agent.get", [t], %{}, :json, "agent get <target>"),
      cmd(
        ~w(agent read),
        "agent.read",
        [t],
        @read_opts,
        :text,
        "agent read <target> [--source visible|recent] [--lines N]"
      ),
      cmd(
        ~w(agent explain),
        "agent.explain",
        [{:opt, "target"}],
        %{
          "json" => {:json, :flag},
          "verbose" => {"verbose", :flag},
          "agent" => {"agent", :string},
          "file" => {"text", :file}
        },
        :json,
        "agent explain <target> [--json] [--verbose] | " <>
          "herdr-live agent explain --file PATH --agent LABEL [--json]"
      ),
      cmd(
        ~w(agent wait),
        "agent.wait",
        [t],
        %{"until" => {"until", {:many, @agent_states}}, "timeout" => {"timeout_ms", :int}},
        :json,
        "agent wait <target> [--until S]... [--timeout MS]"
      ),
      cmd(
        ~w(agent prompt),
        "agent.prompt",
        [t, {:req, "text"}],
        %{},
        :json,
        "agent prompt <target> <text>"
      ),
      cmd(
        ~w(agent send-keys),
        "agent.send_keys",
        [t, {:keys, "keys"}],
        %{},
        :json,
        "agent send-keys <target> <key>..."
      )
    ]
  end

  defp events do
    [
      cmd(
        ~w(events subscribe),
        "events.subscribe",
        [{:keys, "types"}],
        %{
          "pane" => {"pane_id", :string},
          "tab" => {"tab_id", :string},
          "workspace" => {"workspace_id", :string}
        },
        :events,
        "events subscribe <type>... [--pane <pane_id>] [--tab <tab_id>] " <>
          "[--workspace <workspace_id>]"
      )
    ]
  end

  defp plugin do
    pid = {:req, "plugin_id"}
    filter = %{"plugin" => {"plugin_id", :string}}
    target = {:req, "target"}

    open = %{
      "plugin" => {"plugin_id", :string},
      "entrypoint" => {"entrypoint", :string},
      "placement" => {"placement", {:enum, ~w(overlay popup split tab zoomed)}},
      "width" => {"width", :string},
      "height" => {"height", :string},
      "workspace" => {"workspace_id", :string},
      "target-pane" => {"target_pane_id", :string},
      "direction" => {"direction", {:enum, ["right", "down"]}},
      "cwd" => {"cwd", :string},
      "env" => {"env", {:kv_many}},
      "focus" => {"focus", :flag},
      "no-focus" => {"focus", {:const, false}}
    }

    [
      cmd(
        ~w(plugin list),
        "plugin.list",
        [],
        Map.put(filter, "json", {:json, :flag}),
        :json,
        "plugin list [--plugin ID] [--json]"
      ),
      cmd(
        ~w(plugin install),
        "plugin.install",
        [{:req, "source"}],
        %{"ref" => {"ref", :string}, "yes" => {"yes", :flag}},
        :json,
        "plugin install <source> [--ref REF] [--yes]"
      ),
      cmd(
        ~w(plugin link),
        "plugin.link",
        [{:req, "path"}],
        %{"disabled" => {"enabled", {:const, false}}},
        :json,
        "plugin link <path> [--disabled]"
      ),
      cmd(
        ~w(plugin uninstall),
        "plugin.uninstall",
        [target],
        %{},
        :json,
        "plugin uninstall <target>"
      ),
      cmd(~w(plugin remove), "plugin.uninstall", [target], %{}, :json, "plugin remove <target>")
      |> Map.put(:alias, true),
      cmd(~w(plugin unlink), "plugin.uninstall", [target], %{}, :json, "plugin unlink <target>")
      |> Map.put(:alias, true),
      cmd(~w(plugin enable), "plugin.enable", [pid], %{}, :json, "plugin enable <plugin_id>"),
      cmd(~w(plugin disable), "plugin.disable", [pid], %{}, :json, "plugin disable <plugin_id>"),
      cmd(
        ~w(plugin config-dir),
        "plugin.config_dir",
        [pid],
        %{},
        :path,
        "plugin config-dir <plugin_id>"
      ),
      cmd(
        ~w(plugin action list),
        "plugin.action.list",
        [],
        filter,
        :json,
        "plugin action list [--plugin ID]"
      ),
      cmd(
        ~w(plugin action invoke),
        "plugin.action.invoke",
        [{:req, "action_id"}],
        filter,
        :json,
        "plugin action invoke <action_id> [--plugin ID]"
      ),
      cmd(
        ~w(plugin log list),
        "plugin.log.list",
        [],
        Map.put(filter, "limit", {"limit", :int}),
        :json,
        "plugin log list [--plugin ID] [--limit N]"
      ),
      cmd(
        ~w(plugin pane open),
        "plugin.pane.open",
        [],
        open,
        :json,
        "plugin pane open --plugin ID --entrypoint ID [--placement P] [--width S] " <>
          "[--height S] [--workspace ID] [--target-pane PANE] [--direction right|down] " <>
          "[--cwd PATH] [--env KEY=VALUE]... [--focus|--no-focus]"
      ),
      cmd(
        ~w(plugin pane focus),
        "plugin.pane.focus",
        [{:req, "pane_id"}],
        %{},
        :json,
        "plugin pane focus <pane_id>"
      ),
      cmd(
        ~w(plugin pane close),
        "plugin.pane.close",
        [{:req, "pane_id"}],
        %{},
        :json,
        "plugin pane close <pane_id>"
      )
    ]
  end

  @doc "The event types `events subscribe` accepts."
  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  @doc "The top-level verbs the parser accepts."
  @spec verbs() :: [String.t()]
  def verbs, do: commands() |> Enum.map(&hd(&1.words)) |> Enum.uniq()

  @doc "The full usage text."
  @spec usage() :: String.t()
  def usage do
    lines = Enum.map_join(commands(), "\n", &("  herdr-live " <> &1.usage))
    "usage: herdr-live <verb> ...\n" <> lines <> "\n"
  end

  @doc "Parses argv (without the program name) against `env` into a request."
  @spec parse([String.t()], %{optional(String.t()) => String.t()}) :: result()
  def parse([help | _], _env) when help in ["help", "--help", "-h"], do: {:help, usage()}

  def parse(argv, env) do
    case find(argv) do
      {%{method: :raw} = c, rest} -> raw(c, rest)
      {%{method: :print} = c, rest} -> print(c, rest)
      {c, rest} -> with_usage(c, build(c, rest, env))
      nil -> {:usage, unknown(argv) <> usage()}
    end
  end

  defp unknown([]), do: ""
  defp unknown(["" | _]), do: "herdr-live: empty command\n"
  defp unknown(argv), do: "herdr-live: unknown command #{Enum.join(Enum.take(argv, 2), " ")}\n"

  # longest match first: two-word commands before one-word ones
  defp find(argv) do
    commands()
    |> Enum.sort_by(&(-length(&1.words)))
    |> Enum.find_value(fn c ->
      n = length(c.words)
      if Enum.take(argv, n) == c.words, do: {c, Enum.drop(argv, n)}
    end)
  end

  defp with_usage(_c, {:ok, req}), do: req

  defp with_usage(c, {:error, msg}),
    do: {:usage, "herdr-live: #{msg}\nusage: herdr-live #{c.usage}\n"}

  defp print(%{words: ["--default-config"]} = c, [_ | _]),
    do: with_usage(c, {:error, "takes no arguments"})

  defp print(%{words: ["--default-config"]}, []) do
    case File.read(default_config_path()) do
      {:ok, text} ->
        {:print, text}

      {:error, r} ->
        {:usage, "herdr-live: cannot read default config: #{:file.format_error(r)}\n"}
    end
  end

  defp print(%{words: ["completion"]}, [shell]) when shell in ~w(bash zsh fish),
    do:
      {:print,
       HerdrCli.Completion.script(
         Map.fetch!(%{"bash" => :bash, "zsh" => :zsh, "fish" => :fish}, shell),
         commands()
       )}

  defp print(c, _), do: with_usage(c, {:error, "expected one of bash, zsh, fish"})

  # ebin/../priv; works under `erl -pa ebin` where there is no application to ask
  defp default_config_path do
    :code.which(__MODULE__) |> Path.dirname() |> Path.join("../priv/default_config.toml")
  end

  defp raw(_c, [method]), do: {:call, method, %{}, :json}

  defp raw(c, [method, json]) do
    case JSON.decode(json) do
      {:ok, params} when is_map(params) -> {:call, method, params, :json}
      _ -> with_usage(c, {:error, "params must be a JSON object"})
    end
  end

  defp raw(c, _), do: with_usage(c, {:error, "expected a method and optional params"})

  defp build(c, rest, env) do
    with {:ok, pos, opts} <- split_opts(rest, c.opts, [], %{}),
         {:ok, params} <- positionals(c.pos, pos, env, opts),
         :ok <- check(c.method, params) do
      {:ok, finish(c, params, env)}
    end
  end

  defp finish(%{method: "pane.current"} = c, params, env) do
    case Map.get(env, "HERDR_PANE_ID", "") do
      "" -> {:call, c.method, params, c.out}
      id -> {:call, c.method, Map.put(params, "caller_pane_id", id), c.out}
    end
  end

  defp finish(%{method: "events.subscribe"}, params, _env) do
    {types, filters} = Map.pop(params, "types")
    {:subscribe, %{"subscriptions" => Enum.map(types, &Map.put(filters, "type", &1))}}
  end

  defp finish(%{method: "server.status"} = c, params, _env) do
    {kv, params} = Map.pop(params, :kv)
    {:call, c.method, params, if(kv, do: :lines, else: :json)}
  end

  # herdr's normalize_plugin_path_arg: local paths go absolute against the caller's cwd
  defp finish(%{method: "plugin.link"} = c, params, env),
    do: plain(c, Map.update!(params, "path", &abs_path(&1, env)))

  defp finish(%{method: "plugin.install"} = c, %{"source" => s} = params, env),
    do: plain(c, if(local?(s), do: %{params | "source" => abs_path(s, env)}, else: params))

  defp finish(%{method: "pane.zoom"} = c, params, _env) do
    {off, params} = Map.pop(params, "off")
    params = Map.delete(params, :json)
    {:call, c.method, if(off, do: Map.put(params, "zoom", false), else: params), c.out}
  end

  # the server takes absolute paths: relative ones are the caller's
  defp finish(%{method: "worktree." <> _} = c, params, env) do
    plain(
      c,
      Enum.reduce(~w(cwd path), params, &Map.replace_lazy(&2, &1, fn v -> abs_path(v, env) end))
    )
  end

  defp finish(c, params, _env), do: plain(c, params)

  defp plain(c, params), do: {:call, c.method, Map.delete(params, :json), c.out}

  defp local?(s), do: s in [".", "..", "~"] or String.starts_with?(s, ["./", "../", "~/"])

  defp abs_path("~", env), do: Map.get(env, "HOME", "~")
  defp abs_path("~/" <> rest, %{"HOME" => home}), do: Path.join(home, rest)

  defp abs_path(p, %{"PWD" => cwd}) do
    if Path.type(p) == :relative, do: Path.expand(p, cwd), else: p
  end

  defp abs_path(p, _env), do: p

  # --- options ---------------------------------------------------------------

  defp split_opts([], _spec, pos, acc), do: {:ok, Enum.reverse(pos), acc}
  defp split_opts(["--" | rest], _spec, pos, acc), do: {:ok, Enum.reverse(pos, rest), acc}

  defp split_opts(["--" <> opt | rest], spec, pos, acc) do
    {name, inline} =
      case String.split(opt, "=", parts: 2) do
        [n, v] -> {n, {:inline, v}}
        [n] -> {n, :none}
      end

    case Map.fetch(spec, name) do
      {:ok, {key, kind}} ->
        with {:ok, value, rest} <- take_value(name, kind, inline, rest),
             {:ok, v} <- convert(name, kind, value) do
          split_opts(rest, spec, pos, put_opt(acc, key, kind, v))
        end

      :error ->
        {:error, "unknown option --#{name}"}
    end
  end

  defp split_opts([arg | rest], spec, pos, acc), do: split_opts(rest, spec, [arg | pos], acc)

  defp take_value(_name, :flag, :none, rest), do: {:ok, true, rest}
  defp take_value(_name, {:const, v}, :none, rest), do: {:ok, v, rest}

  defp take_value(name, :flag, {:inline, _}, _), do: {:error, "--#{name} takes no value"}
  defp take_value(name, {:const, _}, {:inline, _}, _), do: {:error, "--#{name} takes no value"}
  defp take_value(_name, _kind, {:inline, v}, rest), do: {:ok, v, rest}

  defp take_value(name, _kind, :none, [v | rest]) do
    if String.starts_with?(v, "--"),
      do: {:error, "--#{name} needs a value (use --#{name}=#{v} for a value starting with --)"},
      else: {:ok, v, rest}
  end

  defp take_value(name, _kind, :none, []), do: {:error, "--#{name} needs a value"}

  defp put_opt(acc, key, {:many, _}, v), do: Map.update(acc, key, [v], &(&1 ++ [v]))

  defp put_opt(acc, key, {:kv_many}, {k, v}),
    do: Map.update(acc, key, %{k => v}, &Map.put(&1, k, v))

  defp put_opt(acc, key, _kind, v), do: Map.put(acc, key, v)

  defp convert(_name, :flag, v), do: {:ok, v}
  defp convert(_name, {:const, _}, v), do: {:ok, v}

  defp convert(name, {:kv_many}, v) do
    case String.split(v, "=", parts: 2) do
      [k, val] when k != "" -> {:ok, {k, val}}
      _ -> {:error, "--#{name} must be KEY=VALUE, got #{inspect(v)}"}
    end
  end

  defp convert(_name, :string, v), do: {:ok, v}
  defp convert(_name, :file, v), do: {:ok, {:file, v}}
  defp convert(name, :int, v), do: int(v, "--#{name}")
  defp convert(name, {:enum, values}, v), do: enum(v, values, "--#{name}")
  defp convert(name, {:many, values}, v), do: enum(v, values, "--#{name}")

  defp convert(name, :number, v) do
    case Float.parse(v) do
      {f, ""} -> {:ok, f}
      _ -> {:error, "--#{name} must be a number, got #{inspect(v)}"}
    end
  end

  defp int(v, what) do
    case Integer.parse(v) do
      {i, ""} -> {:ok, i}
      _ -> {:error, "#{what} must be an integer, got #{inspect(v)}"}
    end
  end

  defp enum(v, values, what) do
    if v in values,
      do: {:ok, v},
      else: {:error, "#{what} must be one of #{Enum.join(values, ", ")}, got #{inspect(v)}"}
  end

  # --- positionals -----------------------------------------------------------

  defp positionals([], [], _env, acc), do: {:ok, acc}

  defp positionals([], [extra | _], _env, _acc),
    do: {:error, "unexpected argument #{inspect(extra)}"}

  defp positionals([{:req, name} | spec], [v | rest], env, acc),
    do: positionals(spec, rest, env, Map.put(acc, name, v))

  defp positionals([{:req, name} | _], [], _env, _acc), do: {:error, "missing <#{name}>"}

  defp positionals([{:pane, name, _} | spec], [v | rest], env, acc),
    do: positionals(spec, rest, env, Map.put(acc, name, v))

  defp positionals([{:pane, name, need} | spec], [], env, acc) do
    case {Map.get(env, "HERDR_PANE_ID", ""), need} do
      {"", :required} -> {:error, "missing <#{name}> (and HERDR_PANE_ID is not set)"}
      {"", :optional} -> positionals(spec, [], env, acc)
      {id, _} -> positionals(spec, [], env, Map.put(acc, name, id))
    end
  end

  defp positionals([{:keys, name}], [_ | _] = vs, _env, acc), do: {:ok, Map.put(acc, name, vs)}
  defp positionals([{:keys, name}], [], _env, _acc), do: {:error, "missing <#{name}>"}

  defp positionals([{:opt, _} | spec], [], env, acc), do: positionals(spec, [], env, acc)

  defp positionals([{:opt, name} | spec], [v | rest], env, acc),
    do: positionals(spec, rest, env, Map.put(acc, name, v))

  defp positionals([{:int, name} | _], [], _env, _acc), do: {:error, "missing <#{name}>"}

  defp positionals([{:int, name} | spec], [v | rest], env, acc) do
    with {:ok, i} <- int(v, "<#{name}>"), do: positionals(spec, rest, env, Map.put(acc, name, i))
  end

  defp positionals([{:opt_int, _} | spec], [], env, acc), do: positionals(spec, [], env, acc)

  defp positionals([{:opt_int, name} | spec], [v | rest], env, acc) do
    with {:ok, i} <- int(v, "<#{name}>"), do: positionals(spec, rest, env, Map.put(acc, name, i))
  end

  defp positionals([{:opt_enum, _, _} | spec], [], env, acc), do: positionals(spec, [], env, acc)

  defp positionals([{:opt_enum, name, values} | spec], [v | rest], env, acc) do
    with {:ok, v} <- enum(v, values, "<#{name}>"),
         do: positionals(spec, rest, env, Map.put(acc, name, v))
  end

  # --- cross-field checks ----------------------------------------------------

  defp check("pane.split", %{"direction" => _}), do: :ok
  defp check("pane.split", _), do: {:error, "--direction is required"}

  # a pane target, or a label and a file of screen text; never both
  defp check("agent.explain", params) do
    case {Map.has_key?(params, "target"), Map.has_key?(params, "agent"),
          Map.has_key?(params, "text")} do
      {true, false, false} -> :ok
      {false, true, true} -> :ok
      _ -> {:error, "give either <target> or both --file and --agent"}
    end
  end

  defp check("pane.report_agent", params), do: require_opts(params, ~w(source agent state))
  defp check("pane.release_agent", params), do: require_opts(params, ~w(source agent))

  defp check("pane.zoom", %{"zoom" => true, "off" => true}),
    do: {:error, "give at most one of --on and --off"}

  defp check("pane.wait_for_output", params) do
    case {Map.has_key?(params, "match"), Map.has_key?(params, "regex")} do
      {true, false} -> :ok
      {false, true} -> :ok
      _ -> {:error, "give exactly one of --match and --regex"}
    end
  end

  defp check("events.subscribe", %{"types" => types}) do
    Enum.find_value(types, :ok, fn t ->
      if t not in @event_types,
        do: {:error, "unknown event type #{inspect(t)}; one of #{Enum.join(@event_types, ", ")}"}
    end)
  end

  defp check("worktree.create", %{"branch" => _}), do: :ok
  defp check("worktree.create", _), do: {:error, "--branch is required"}

  defp check("worktree.open", params) do
    if Map.has_key?(params, "path") != Map.has_key?(params, "branch"),
      do: :ok,
      else: {:error, "give exactly one of --path and --branch"}
  end

  defp check(_method, _params), do: :ok

  defp require_opts(params, names) do
    case Enum.reject(names, &Map.has_key?(params, &1)) do
      [] -> :ok
      [n | _] -> {:error, "--#{n} is required"}
    end
  end
end
