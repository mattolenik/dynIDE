defmodule HerdrServer.Config do
  @moduledoc """
  herdr's TOML config file (inventory §8), read at start and on `reload_config`.

    * `path/0`: `config :herdr_server, :config_path`, else `$HERDR_LIVE_CONFIG`, else
      `${XDG_CONFIG_HOME:-$HOME/.config}/herdr-live/config.toml`.
    * `load/1` reads and decodes the file into its raw `keys`, `ui`, `theme`, `worktrees` and `session` tables
      plus `onboarding` (true unless the file sets `onboarding = false`). A missing file
      is the defaults with onboarding and no diagnostics; a file that does not decode or
      cannot be read is the defaults, no onboarding, one `"config: <reason>"` diagnostic
      and `failed: true` (not a config: a running app keeps its keybinds and ui).
    * `apply/4` (pure) puts the tables over a keybind table and a `%Ui{}`: every key the
      file sets wins, keys it does not set keep the given value. An entry that is invalid
      (unknown action, bad key spec, wrong type or range) keeps its value with one
      diagnostic. `sidebar_start_collapsed` applies only with `start: true`. Unknown
      `[ui]`/`[theme]` keys and other tables (herdr has many) are ignored.

  Keys: `[keys]` `prefix` and the `Keybinds.Catalog` action names (a spec string or an
  array, `[]` unbinds); `[ui]` `sidebar_width`, `sidebar_min_width`, `sidebar_max_width`,
  `sidebar_start_collapsed`, `confirm_close`, `status_indicators` (`"dots"` |
  `"symbols"`), `prompt_new_tab_name`, `window_title` (template of `{hostname}`,
  `{workspace}`, `{tab}`, `{pane}`, `{terminal_title}`); `[ui.sound]` `enabled`,
  `command` (run by an in-VM terminal client with the sound name as its last argument;
  never sent to a socket client, which runs its own `HERDR_LIVE_SOUND_COMMAND`),
  `done_path`, `request_path` (sound files played instead of the built-in ones, same
  rule: socket clients use `HERDR_LIVE_SOUND_DONE_PATH` / `_REQUEST_PATH`; relative to
  the config file's directory, `~` expanded; a missing or non-`.mp3` file is kept with a
  diagnostic; unset keys are absent from `ui.sound`, also after a reload drops them);
  `[ui.toast]` `delivery`
  (`off | herdr | terminal | system`), `delay_seconds` (0..3600); `[theme]` `name`,
  `auto_switch`, `light_name`, `dark_name`; `[worktrees]` `directory` (new checkouts go
  under it, default `~/.herdr-live/worktrees`); `[session]` `resume_agents_on_restore`
  (default false) and `startup_per_agent_delay_ms` (0..60000, default 500), read by a
  disk restore (`Persist.RestorePlan.resumes/2`); top-level `onboarding`.

  `[[keys.command]]` (herdr's custom commands): `key` (a spec), `command`, `type`
  (`shell`, the default, | `pane` | `popup` | `plugin_action`), optional `description`,
  and `width` / `height` for popups. Each valid entry lands in `ui.custom_commands` (plain
  maps, replaced on every apply) and binds its key to `{App.CustomCommands, :run, [index]}`.
  An empty command, an unknown type, a bad key, the prefix key or a key an earlier command
  holds drops the entry with one diagnostic; a key that takes over a `[keys]` action's
  bind, and width or height on another type, keep it with one.
  """

  alias HerdrServer.App.{CustomCommands, Keybinds, Ui}
  alias HerdrServer.App.Keybinds.Catalog
  alias HerdrServer.Config.Keys, as: Spec
  alias HerdrServer.Plugins.Keybind

  @type t :: %{
          keys: map,
          ui: map,
          theme: map,
          worktrees: map,
          session: map,
          onboarding: boolean,
          diagnostics: [binary],
          failed: boolean
        }

  # {table, key path in the table, kind, Ui path}
  @fields [
    {:ui, ["sidebar_width"], :pos_int, [:sidebar, :width]},
    {:ui, ["sidebar_min_width"], :pos_int, [:sidebar, :min]},
    {:ui, ["sidebar_max_width"], :pos_int, [:sidebar, :max]},
    {:ui, ["confirm_close"], :bool, [:confirm_close]},
    {:ui, ["status_indicators"], {:enum, ~w(dots symbols)}, [:indicators]},
    {:ui, ["prompt_new_tab_name"], :bool, [:prompt_new_tab_name]},
    {:ui, ["hide_tab_bar_when_single_tab"], :bool, [:tab_bar, :hide_single]},
    {:ui, ["tab_bar_position"], {:enum, ~w(top bottom)}, [:tab_bar, :position]},
    {:ui, ["pane_borders"], {:enum, ~w(auto always off)}, [:pane_borders]},
    {:ui, ["window_title"], :string, [:window_title]},
    {:ui, ["sound", "enabled"], :bool, [:sound, :enabled]},
    {:ui, ["sound", "command"], :string, [:sound, :command]},
    {:ui, ["sound", "done_path"], :string, [:sound, :done_path]},
    {:ui, ["sound", "request_path"], :string, [:sound, :request_path]},
    {:ui, ["toast", "delivery"], {:enum, ~w(off herdr terminal system)}, [:toast, :delivery]},
    {:ui, ["toast", "delay_seconds"], :delay, [:toast, :delay_ms]},
    {:theme, ["name"], :string, [:theme, :name]},
    {:theme, ["auto_switch"], :bool, [:theme, :auto_switch]},
    {:theme, ["light_name"], :string, [:theme, :light]},
    {:theme, ["dark_name"], :string, [:theme, :dark]},
    {:worktrees, ["directory"], :string, [:worktrees_dir]},
    {:session, ["resume_agents_on_restore"], :bool, [:session, :resume_agents_on_restore]},
    {:session, ["startup_per_agent_delay_ms"], :delay_ms, [:session, :startup_per_agent_delay_ms]}
  ]

  @spec path() :: Path.t()
  def path do
    Application.get_env(:herdr_server, :config_path) || env("HERDR_LIVE_CONFIG") ||
      Path.join(
        env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config"),
        "herdr-live/config.toml"
      )
  end

  defp env(name), do: if(System.get_env(name) in [nil, ""], do: nil, else: System.get_env(name))

  @spec load(Path.t()) :: t
  def load(path \\ path()) do
    case File.read(path) do
      {:ok, bin} -> bin |> decode() |> sound_paths(Path.dirname(path))
      {:error, :enoent} -> %{defaults(true, []) | failed: false}
      {:error, r} -> defaults(false, ["config: #{path}: #{:file.format_error(r)}"])
    end
  end

  defp decode(bin) do
    case Toml.decode(bin) do
      {:ok, t} ->
        {[keys, ui, theme, worktrees, session], diags} =
          Enum.map_reduce(~w(keys ui theme worktrees session), [], &table(t, &1, &2))

        {onboarding, diags} = onboarding(Map.get(t, "onboarding", true), diags)

        %{
          keys: keys,
          ui: ui,
          theme: theme,
          worktrees: worktrees,
          session: session,
          onboarding: onboarding,
          diagnostics: diags,
          failed: false
        }

      {:error, {:invalid_toml, reason}} ->
        defaults(false, ["config: " <> (reason |> String.split("\n") |> hd())])

      {:error, reason} ->
        defaults(false, ["config: #{inspect(reason)}"])
    end
  end

  @sound_paths ~w(done_path request_path)

  # herdr: sound paths are relative to the config file's directory; a missing or non-mp3
  # file is kept (the client falls back to the built-in sound) with a diagnostic
  defp sound_paths(%{ui: %{"sound" => %{} = snd}} = cfg, dir) do
    Enum.reduce(@sound_paths, cfg, fn key, cfg ->
      case snd do
        %{^key => p} when is_binary(p) and p != "" -> sound_path(cfg, key, Path.expand(p, dir))
        _ -> cfg
      end
    end)
  end

  defp sound_paths(cfg, _dir), do: cfg

  defp sound_path(cfg, key, full) do
    cfg = put_in(cfg, [:ui, "sound", key], full)

    why =
      cond do
        not File.regular?(full) -> "no file #{full}"
        Path.extname(full) != ".mp3" -> "not an .mp3: #{full}"
        true -> nil
      end

    if why,
      do: %{cfg | diagnostics: cfg.diagnostics ++ ["config: ui.sound.#{key}: #{why}"]},
      else: cfg
  end

  defp table(t, name, diags) do
    case Map.get(t, name, %{}) do
      m when is_map(m) -> {m, diags}
      _ -> {%{}, diags ++ ["config: #{name} must be a table"]}
    end
  end

  defp onboarding(b, diags) when is_boolean(b), do: {b, diags}
  defp onboarding(_, diags), do: {true, diags ++ ["config: onboarding must be true or false"]}

  defp defaults(onboarding, diags),
    do: %{
      keys: %{},
      ui: %{},
      theme: %{},
      worktrees: %{},
      session: %{},
      onboarding: onboarding,
      diagnostics: diags,
      failed: true
    }

  @doc "Puts `cfg` over `kb` and `ui`: `{kb, ui, load diagnostics ++ apply diagnostics}`."
  @spec apply(t, Keybinds.t(), Ui.t(), keyword) :: {Keybinds.t(), Ui.t(), [binary]}
  def apply(cfg, kb, ui, opts \\ []) do
    # file-only keys: a reload without them goes back to the built-in sounds
    ui = %{ui | sound: Map.drop(ui.sound, [:done_path, :request_path])}
    {kb, kd} = keys(Map.delete(cfg.keys, "command"), kb)
    {kb, cmds, cd} = commands(Map.get(cfg.keys, "command", []), kb)
    kd = kd ++ cd

    {new, ud} =
      Enum.reduce(@fields, {ui, []}, fn {table, keys, kind, at}, {ui, d} ->
        case field(Map.get(cfg, table, %{}), keys) do
          :error -> {ui, d}
          {:ok, v} -> put(ui, at, cast(kind, v), d, "#{table}.#{Enum.join(keys, ".")}", v)
        end
      end)

    {new, ud} = bounds(new, ui, ud)

    {new, ud} =
      case field(cfg.ui, ["sidebar_start_collapsed"]) do
        {:ok, b} when is_boolean(b) ->
          {if(opts[:start], do: put_in(new.sidebar.collapsed, b), else: new), ud}

        {:ok, v} ->
          {new, ud ++ [bad("ui.sidebar_start_collapsed", v)]}

        :error ->
          {new, ud}
      end

    {kb, %{new | onboarding: cfg.onboarding, custom_commands: cmds}, cfg.diagnostics ++ kd ++ ud}
  end

  @types ~w(shell pane popup plugin_action)

  defp commands(list, kb) when is_list(list) do
    {kb, cmds, d} =
      list
      |> Enum.with_index()
      |> Enum.reduce({kb, [], []}, fn {t, i}, acc -> command(t, "keys.command[#{i}]", acc) end)

    {kb, Enum.reverse(cmds), d}
  end

  defp commands(_other, kb), do: {kb, [], ["config: keys.command must be an array of tables"]}

  defp command(%{} = t, name, {kb, cmds, d}) do
    type = Map.get(t, "type", "shell")
    cmd = t["command"]
    key = t["key"]

    with {:cmd, true} <- {:cmd, is_binary(cmd) and String.trim(cmd) != ""},
         {:type, true} <- {:type, type in @types},
         {:ok, %{prefix: p, key: k, mods: m}} <- Spec.parse(key),
         {:prefix, false} <- {:prefix, Keybinds.prefix?(kb, {k, m})},
         held = Keybinds.lookup(kb, if(p, do: :prefix, else: :terminal), {k, m}),
         {:dup, false} <- {:dup, match?({CustomCommands, :run, _}, held)},
         {:ok, kb} <- Keybinds.bind_mfa(kb, {CustomCommands, :run, [length(cmds)]}, [key]) do
      {kb, [entry(t, key, cmd, type) | cmds], d ++ warnings(t, name, key, type, held)}
    else
      {:cmd, _} -> {kb, cmds, d ++ ["config: #{name}: empty command"]}
      {:type, _} -> {kb, cmds, d ++ ["config: #{name}: unknown type #{inspect(type)}"]}
      {:prefix, _} -> {kb, cmds, d ++ ["config: #{name}.key: #{key} is the prefix"]}
      {:dup, _} -> {kb, cmds, d ++ ["config: #{name}.key: #{key} is another command's key"]}
      {:error, why} -> {kb, cmds, d ++ ["config: #{name}.key: #{why}"]}
    end
  end

  defp command(_other, name, {kb, cmds, d}),
    do: {kb, cmds, d ++ ["config: #{name}: expected a table"]}

  defp entry(t, key, cmd, type) do
    popup = type == "popup"
    desc = t["description"]

    %{
      key: key,
      command: cmd,
      type: type,
      description: if(is_binary(desc) and desc != "", do: desc),
      width: if(popup, do: t["width"]),
      height: if(popup, do: t["height"])
    }
  end

  defp warnings(t, name, key, type, held) do
    sized = type != "popup" and (Map.has_key?(t, "width") or Map.has_key?(t, "height"))

    if(sized,
      do: ["config: #{name}: width and height apply only to popup commands; ignored"],
      else: []
    ) ++ if(held, do: ["config: #{name}.key: #{key} replaces #{action(held)}"], else: [])
  end

  defp action(mfa) do
    case Enum.find(Catalog.entries(), &(&1.mfa == mfa)) do
      %{action: a} -> "keys.#{a}"
      nil -> inspect(mfa)
    end
  end

  # prefix first: direct binds are checked against it
  defp keys(table, kb) do
    table
    |> Enum.sort_by(fn {k, _} -> {k != "prefix", k} end)
    |> Enum.reduce({kb, []}, fn
      # M14 stopgap: M17's [[keys.command]] parser replaces this clause
      {"command", v}, {kb, d} ->
        commands(v, kb, d)

      {action, v}, {kb, d} ->
        with {:ok, specs} <- specs(v),
             {:ok, kb} <- Keybinds.bind(kb, action, specs) do
          {kb, d}
        else
          {:error, why} -> {kb, d ++ ["config: keys.#{action}: #{why}"]}
        end
    end)
  end

  # M14 stopgap: M17's [[keys.command]] parser replaces this clause. Only
  # `type = "plugin_action"` binds (to `Plugins.Keybind.mfa(command)`, each command once
  # with all its keys); other types (herdr's default is "shell") get one diagnostic each.
  defp commands(entries, kb, d) when is_list(entries) do
    {binds, d} =
      Enum.reduce(entries, {[], d}, fn e, {binds, d} ->
        case command(e) do
          {:ok, cmd, specs} -> {[{cmd, specs} | binds], d}
          {:error, why} -> {binds, d ++ ["config: keys.command#{why}"]}
        end
      end)

    binds
    |> Enum.reverse()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce({kb, d}, fn {cmd, specs}, {kb, d} ->
      case Keybinds.bind_mfa(kb, Keybind.mfa(cmd), Enum.concat(specs)) do
        {:ok, kb} -> {kb, d}
        {:error, why} -> {kb, d ++ ["config: keys.command #{cmd}: #{why}"]}
      end
    end)
  end

  defp commands(v, kb, d),
    do: {kb, d ++ ["config: keys.command: expected an array of tables, got #{inspect(v)}"]}

  defp command(%{} = e) do
    case Map.get(e, "type", "shell") do
      "plugin_action" ->
        with {:ok, specs} <- specs(e["key"]),
             cmd when is_binary(cmd) and cmd != "" <- e["command"] do
          {:ok, cmd, specs}
        else
          {:error, why} -> {:error, ": #{why}"}
          _ -> {:error, ": a plugin_action needs a command"}
        end

      t ->
        {:error, " type #{inspect_type(t)} is not supported yet"}
    end
  end

  defp command(e), do: {:error, ": invalid entry #{inspect(e)}"}

  defp inspect_type(t) when is_binary(t), do: t
  defp inspect_type(t), do: inspect(t)

  defp specs(v) when is_binary(v), do: {:ok, [v]}

  defp specs(v) when is_list(v),
    do: if(Enum.all?(v, &is_binary/1), do: {:ok, v}, else: {:error, "expected key strings"})

  defp specs(v), do: {:error, "expected a key string or an array, got #{inspect(v)}"}

  defp field(table, [k]), do: Map.fetch(table, k)

  defp field(table, [k | rest]) do
    case Map.get(table, k) do
      %{} = sub -> field(sub, rest)
      _ -> :error
    end
  end

  defp cast(:bool, v) when is_boolean(v), do: {:ok, v}
  defp cast(:pos_int, v) when is_integer(v) and v > 0, do: {:ok, v}
  defp cast(:string, v) when is_binary(v), do: {:ok, v}
  defp cast(:delay, v) when is_integer(v) and v in 0..3600, do: {:ok, v * 1000}
  defp cast(:delay_ms, v) when is_integer(v) and v in 0..60_000, do: {:ok, v}

  # to_atom, not to_existing_atom: a value may name an atom no loaded module holds yet
  # (`always`), and `vals` is a fixed whitelist, so config cannot grow the atom table
  defp cast({:enum, vals}, v) when is_binary(v),
    do: if(v in vals, do: {:ok, String.to_atom(v)}, else: :error)

  defp cast(_kind, _v), do: :error

  defp put(ui, at, {:ok, v}, d, _name, _raw),
    do: {put_in(ui, Enum.map(at, &Access.key/1), v), d}

  defp put(ui, _at, :error, d, name, raw), do: {ui, d ++ [bad(name, raw)]}

  defp bad(name, v), do: "config: #{name}: invalid value #{inspect(v)}"

  # min > max keeps both bounds as they were
  defp bounds(%{sidebar: %{min: min, max: max}} = new, old, d) when min > max,
    do:
      {%{new | sidebar: %{new.sidebar | min: old.sidebar.min, max: old.sidebar.max}},
       d ++ ["config: ui.sidebar_min_width #{min} exceeds sidebar_max_width #{max}"]}

  defp bounds(new, _old, d), do: {new, d}
end
