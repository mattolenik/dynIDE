defmodule HerdrServer.App.Keybinds do
  @moduledoc """
  Keybind tables, mirroring herdr's defaults (`src/config/model.rs`). Values are
  `{module, fun, args}` (`App.Actions`, or the modal openers `Modal.Prompt` / `Modal.Confirm`
  for new tab, renames and closes) called as `apply(m, f, [app | args])`; never funs.
  Mode changes are per-client: they target `{HerdrServer.Client.Keys, :enter_mode, [mode]}`
  and are applied to the client's input state by `Client.Keys`, never to the app.

  `to_config/1` and `rebind/3` speak herdr's `[keys]` names (`Keybinds.Catalog`) and key
  syntax (`Config.Keys`).

  Keys are `{key, mods}`. Shift-letter normalization: a shifted printable key is stored as
  its uppercase text with `:shift` removed (`normalize/2`); the terminal input parser emits
  the same form.
  """

  alias HerdrServer.App.Actions
  alias HerdrServer.App.Keybinds.Catalog
  alias HerdrServer.App.Modal.{Confirm, Prompt, Settings}
  alias HerdrServer.App.Modal.Keybinds, as: KeybindsModal
  alias HerdrServer.Client.Keys
  alias HerdrServer.Config.Keys, as: Spec

  defstruct prefix: [], prefix_binds: %{}, direct: %{}, resize: %{}

  @type key :: {binary() | atom(), [atom()]}
  @type mfa_t :: {module(), atom(), list()}
  @type t :: %__MODULE__{
          prefix: [key()],
          prefix_binds: %{key() => mfa_t()},
          direct: %{key() => mfa_t()},
          resize: %{key() => mfa_t()}
        }

  @spec default() :: t()
  def default do
    nav = [{"h", :left}, {"j", :down}, {"k", :up}, {"l", :right}]

    prefix_binds =
      %{
        {"c", []} => {Prompt, :new_tab, []},
        {"n", []} => a(:next_tab),
        {"p", []} => a(:previous_tab),
        {"X", []} => {Confirm, :close_tab, []},
        {"T", []} => {Prompt, :rename_tab, []},
        {"W", []} => {Prompt, :rename_workspace, []},
        {"P", []} => {Prompt, :rename_pane, []},
        {"D", []} => {Confirm, :close_workspace, []},
        {:tab, []} => a(:cycle, [:next]),
        {:tab, [:shift]} => a(:cycle, [:previous]),
        {"v", []} => a(:split, [:horizontal]),
        {"-", []} => a(:split, [:vertical]),
        {"x", []} => {Confirm, :close_pane, []},
        {"r", []} => {Keys, :enter_mode, [:resize]},
        {"q", []} => a(:detach),
        {"b", []} => a(:toggle_sidebar),
        {"N", []} => a(:new_workspace),
        {"?", []} => {KeybindsModal, :open, []},
        {"s", []} => {Settings, :open, []}
      }
      |> Map.merge(Map.new(1..9, &{{Integer.to_string(&1), []}, a(:switch_tab, [&1])}))
      |> Map.merge(Map.new(nav, fn {k, d} -> {{k, []}, a(:focus_dir, [d])} end))
      |> Map.merge(Map.new(nav, fn {k, d} -> {{String.upcase(k), []}, a(:swap_dir, [d])} end))

    resize =
      Map.new(nav, fn {k, d} -> {{k, []}, a(:resize_dir, [d, 0.05])} end)
      |> Map.merge(%{
        {:escape, []} => {Keys, :enter_mode, [:terminal]},
        {:enter, []} => {Keys, :enter_mode, [:terminal]}
      })

    %__MODULE__{
      prefix: [{"b", [:ctrl]}],
      prefix_binds: prefix_binds,
      direct: %{},
      resize: resize
    }
  end

  defp a(fun, args \\ []), do: {Actions, fun, args}

  @doc "Normalizes a key/mods pair to the stored form (see moduledoc)."
  @spec normalize(binary() | atom(), [atom()]) :: key()
  def normalize(key, mods) when is_binary(key) do
    up = String.upcase(key)

    if :shift in mods and up != String.downcase(key),
      do: {up, mods -- [:shift]},
      else: {key, mods}
  end

  def normalize(key, mods), do: {key, mods}

  @spec lookup(t(), :terminal | :prefix | :resize, key()) :: mfa_t() | nil
  def lookup(kb, :prefix, k), do: Map.get(kb.prefix_binds, k)
  def lookup(kb, :terminal, k), do: Map.get(kb.direct, k)
  def lookup(kb, :resize, k), do: Map.get(kb.resize, k)

  @spec prefix?(t(), key()) :: boolean()
  def prefix?(kb, k), do: k in kb.prefix

  @doc "Keys the client must send on the slow path: prefix keys and direct binds."
  @spec intercept_set(t()) :: MapSet.t(key())
  def intercept_set(kb), do: MapSet.new(kb.prefix ++ Map.keys(kb.direct))

  @doc "herdr `[keys]` view: each catalog action's specs (prefix ones first, `[]` unbound) and `prefix`."
  @spec to_config(t()) :: %{binary() => [binary()]}
  def to_config(kb) do
    Catalog.entries()
    |> Map.new(&{&1.action, specs(kb, &1.mfa)})
    |> Map.put("prefix", Enum.map(kb.prefix, &spec(false, &1)))
  end

  @doc """
  Binds `action` (a `Keybinds.Catalog` name) to `key_spec` alone: its other bindings go,
  and whatever held that key before loses it. A spec without `prefix+` is a direct bind;
  the prefix key itself cannot be one.
  """
  @spec rebind(t(), binary(), binary()) :: {:ok, t()} | {:error, binary()}
  def rebind(kb, action, key_spec) do
    with %{mfa: mfa} <- Catalog.find(action) || {:error, "unknown action #{inspect(action)}"},
         {:ok, %{prefix: p, key: k, mods: m}} <- Spec.parse(key_spec),
         :ok <- direct_ok(kb, p, {k, m}, key_spec) do
      kb = %{kb | prefix_binds: unbind(kb.prefix_binds, mfa), direct: unbind(kb.direct, mfa)}
      field = if p, do: :prefix_binds, else: :direct
      {:ok, Map.update!(kb, field, &Map.put(&1, {k, m}, mfa))}
    end
  end

  defp direct_ok(kb, false, key, spec),
    do: if(prefix?(kb, key), do: {:error, "#{spec} is the prefix"}, else: :ok)

  defp direct_ok(_kb, true, _key, _spec), do: :ok

  defp unbind(table, mfa), do: Map.reject(table, fn {_, v} -> v == mfa end)

  defp specs(kb, mfa) do
    for({k, ^mfa} <- kb.prefix_binds, do: spec(true, k)) ++
      for({k, ^mfa} <- kb.direct, do: spec(false, k))
  end

  defp spec(prefix, {key, mods}), do: Spec.format(%{prefix: prefix, key: key, mods: mods})
end
