defmodule HerdrServer.Plugins.Manifest do
  @moduledoc """
  Reads and validates `herdr-plugin.toml` (herdr's manifest rules; reason strings verbatim).
  Result maps use string keys, matching the API `plugin` object's manifest fields.
  """

  @compat "0.9.4"
  @id_max 120
  @platforms ~w(linux macos windows)
  @placements ~w(overlay popup split tab zoomed)
  @contexts ~w(global workspace tab pane selection)
  @hook_events ~w(workspace.created workspace.updated workspace.closed workspace.renamed
                  workspace.moved workspace.reordered workspace.focused worktree.created
                  worktree.opened worktree.removed tab.created tab.closed tab.renamed tab.moved
                  tab.focused pane.created pane.closed pane.focused pane.moved pane.exited
                  pane.agent_detected pane.agent_status_changed)
  @not_emitted ~w(worktree.created worktree.opened worktree.removed pane.moved pane.exited
                  workspace.updated workspace.moved workspace.reordered tab.moved)

  @type manifest :: %{optional(String.t()) => term()}

  @spec compat_version() :: String.t()
  def compat_version, do: @compat

  @spec load(Path.t()) :: {:ok, manifest()} | {:error, String.t(), String.t()}
  def load(path) do
    file = if File.dir?(path), do: Path.join(path, "herdr-plugin.toml"), else: path
    file = Path.expand(file)

    with {:ok, text} <- read(file),
         {:ok, raw} <- decode(text) do
      {:ok, build(raw, file)}
    end
  catch
    {:manifest, reason, message} -> {:error, reason, message}
  end

  @doc "Item platforms win over the plugin's; undeclared means supported."
  @spec platform_ok?([String.t()] | nil, [String.t()] | nil) :: boolean()
  def platform_ok?(item, top) do
    case item || top do
      nil -> true
      list -> current_platform() in list
    end
  end

  defp current_platform do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {:unix, :linux} -> "linux"
      _ -> "windows"
    end
  end

  defp read(file) do
    case File.read(file) do
      {:ok, text} -> {:ok, text}
      {:error, e} -> {:error, "plugin_manifest_not_found", "#{file}: #{:file.format_error(e)}"}
    end
  end

  defp decode(text) do
    case Toml.decode(text) do
      {:ok, raw} -> {:ok, raw}
      # the decoder's first line, as the config does: a one-line toast and log record
      {:error, {:invalid_toml, why}} -> {:error, "plugin_manifest_parse_failed", first_line(why)}
      {:error, e} -> {:error, "plugin_manifest_parse_failed", first_line(e)}
    end
  end

  # Toml.reason() is `{:invalid_toml, binary} | binary`: no other shape to inspect
  # (dialyzer rejects a catch-all clause here)
  defp first_line(text), do: text |> String.split("\n", trim: true) |> List.first("")

  defp build(raw, file) do
    id =
      ident(
        raw["id"],
        @id_max,
        ~r/\A[A-Za-z0-9.:_-]+\z/,
        "invalid_plugin_id",
        "invalid plugin id"
      )

    platforms = platforms(raw["platforms"])

    actions =
      raw
      |> list("actions")
      |> Enum.map(&action(&1, id))
      |> uniq("duplicate_plugin_action_id", "action")

    panes = raw |> list("panes") |> Enum.map(&pane/1) |> uniq("duplicate_plugin_pane_id", "pane")
    handlers = raw |> list("link_handlers") |> Enum.map(&handler/1)
    uniq(handlers, "duplicate_plugin_link_handler_id", "link handler")

    for h <- handlers, h["action"] not in Enum.map(actions, & &1["id"]) do
      fail(
        "invalid_plugin_link_handler_action",
        "link handler '#{h["id"]}' references unknown action '#{h["action"]}'"
      )
    end

    events =
      raw |> list("events") |> Enum.map(&event/1) |> Enum.sort_by(&{&1["on"], &1["command"]})

    %{
      "plugin_id" => id,
      "name" => text(raw["name"], "invalid_plugin_name", "plugin name is required"),
      "version" => text(raw["version"], "invalid_plugin_version", "plugin version is required"),
      "min_herdr_version" => min_version(raw["min_herdr_version"]),
      "description" => opt_text(raw["description"]),
      "platforms" => platforms,
      "build" => raw |> list("build") |> Enum.map(&cmd_item/1),
      "startup" => raw |> list("startup") |> Enum.map(&cmd_item/1),
      "actions" => Enum.sort_by(actions, & &1["id"]),
      "events" => events,
      "panes" => Enum.sort_by(panes, & &1["id"]),
      "link_handlers" => handlers,
      "warnings" => warnings(events, platforms),
      "manifest_path" => file,
      "plugin_root" => Path.dirname(file)
    }
  end

  defp action(a, plugin_id) do
    id = local_id(a["id"], "invalid_plugin_action_id", "invalid action id")
    contexts = a["contexts"] || []

    if not (is_list(contexts) and Enum.all?(contexts, &(&1 in @contexts))),
      do: fail("plugin_manifest_parse_failed", "invalid action contexts")

    %{
      "id" => id,
      "qualified_id" => "#{plugin_id}.#{id}",
      "title" => text(a["title"], "invalid_plugin_action_title", "action title is required"),
      "description" => opt_text(a["description"]),
      "contexts" => contexts,
      "platforms" => platforms(a["platforms"]),
      "command" => command(a["command"])
    }
  end

  defp pane(p) do
    placement = p["placement"] || "overlay"

    if placement not in @placements,
      do: fail("plugin_manifest_parse_failed", "unknown pane placement '#{show(placement)}'")

    if placement != "popup" and (p["width"] != nil or p["height"] != nil),
      do:
        fail(
          "invalid_plugin_pane_size",
          "pane width and height are only supported when placement is popup"
        )

    %{
      "id" => local_id(p["id"], "invalid_plugin_pane_id", "invalid pane id"),
      "title" => text(p["title"], "invalid_plugin_pane_title", "pane title is required"),
      "description" => opt_text(p["description"]),
      "platforms" => platforms(p["platforms"]),
      "placement" => placement,
      "width" => size(p["width"]),
      "height" => size(p["height"]),
      "command" => command(p["command"])
    }
  end

  defp event(e) do
    %{
      "on" => text(e["on"], "invalid_plugin_event", "event name is required"),
      "platforms" => platforms(e["platforms"]),
      "command" => command(e["command"])
    }
  end

  defp handler(h) do
    pattern =
      text(
        h["pattern"],
        "invalid_plugin_link_handler_pattern",
        "link handler pattern is required"
      )

    case Regex.compile(pattern) do
      {:ok, _} -> :ok
      {:error, {msg, _}} -> fail("invalid_plugin_link_handler_pattern", to_string(msg))
    end

    %{
      "id" => local_id(h["id"], "invalid_plugin_link_handler_id", "invalid link handler id"),
      "title" =>
        text(h["title"], "invalid_plugin_link_handler_title", "link handler title is required"),
      "pattern" => pattern,
      "action" =>
        local_id(h["action"], "invalid_plugin_link_handler_action", "invalid link handler action"),
      "platforms" => platforms(h["platforms"])
    }
  end

  defp cmd_item(i),
    do: %{"platforms" => platforms(i["platforms"]), "command" => command(i["command"])}

  defp warnings(events, platforms) do
    event_warnings =
      for %{"on" => on} <- events do
        cond do
          on not in @hook_events -> "unknown event '#{on}'"
          on in @not_emitted -> "event #{on} is not emitted by herdr-live yet"
          true -> nil
        end
      end

    Enum.reject(event_warnings, &is_nil/1) ++
      if(platforms == nil,
        do: ["manifest does not declare platforms; platform support unknown"],
        else: []
      )
  end

  defp list(raw, key) do
    case raw[key] do
      nil ->
        []

      l when is_list(l) ->
        if Enum.all?(l, &is_map/1),
          do: l,
          else: fail("plugin_manifest_parse_failed", "invalid #{key}")

      _ ->
        fail("plugin_manifest_parse_failed", "invalid #{key}")
    end
  end

  defp uniq(items, reason, what) do
    ids = Enum.map(items, & &1["id"])

    case ids -- Enum.uniq(ids) do
      [dup | _] -> fail(reason, "duplicate #{what} id '#{dup}'")
      [] -> items
    end
  end

  defp ident(v, max, re, reason, msg) do
    s = if is_binary(v), do: String.trim(v), else: ""
    if s != "" and String.length(s) <= max and s =~ re, do: s, else: fail(reason, msg)
  end

  defp local_id(v, reason, msg), do: ident(v, @id_max, ~r/\A[A-Za-z0-9:_-]+\z/, reason, msg)

  defp text(v, reason, msg) do
    s = if is_binary(v), do: String.trim(v), else: ""
    if s == "", do: fail(reason, msg), else: s
  end

  defp opt_text(v) when is_binary(v),
    do: v |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))

  defp opt_text(_), do: nil

  defp command(c) do
    if is_list(c) and c != [] and Enum.all?(c, &(is_binary(&1) and &1 != "")),
      do: c,
      else: fail("invalid_plugin_command", "command must contain non-empty argv strings")
  end

  defp platforms(nil), do: nil

  defp platforms([_ | _] = l) do
    case Enum.find(l, &(&1 not in @platforms)) do
      nil -> l
      bad -> fail("invalid_plugin_platform", "unknown platform '#{show(bad)}'")
    end
  end

  defp platforms(_),
    do:
      fail(
        "invalid_plugin_platform",
        "platforms must be a non-empty array; omit the field to leave platforms undeclared"
      )

  defp size(nil), do: nil
  defp size(n) when is_integer(n) and n in 0..65_535, do: n

  defp size(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, "%"} when n in 1..100 -> s
      _ -> fail("plugin_manifest_parse_failed", "string sizes must be percentages like 80%")
    end
  end

  defp size(_), do: fail("plugin_manifest_parse_failed", "invalid pane size")

  defp min_version(v) do
    s = text(v, "invalid_plugin_min_herdr_version", "plugin min_herdr_version is required")

    case Version.parse(s) do
      {:ok, req} ->
        if Version.compare(req, @compat) == :gt,
          do:
            fail(
              "plugin_requires_newer_herdr",
              "plugin requires herdr #{s} or newer; compatible herdr is #{@compat}"
            ),
          else: s

      :error ->
        fail(
          "invalid_plugin_min_herdr_version",
          "plugin min_herdr_version must be a semantic version like #{@compat}"
        )
    end
  end

  defp show(v) when is_binary(v), do: v
  defp show(v), do: inspect(v)

  defp fail(reason, message), do: throw({:manifest, reason, message})
end
