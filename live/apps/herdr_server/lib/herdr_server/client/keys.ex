defmodule HerdrServer.Client.Keys do
  @moduledoc """
  Pure per-client key resolution (tmux per-client key tables): `resolve/3` takes the
  client's input state `%{mode, swallow}`, the app's keybinds and a key event, and
  returns the new input state and what to do with the key:

    * `:consumed`: nothing reaches the app or a pane;
    * `{:forward, key_event}`: the key goes to the focused pane (through `App.Store`);
    * `{:run, {m, f, a}}`: an app action, applied by the Store as `apply(m, f, [app | a])`.

  Modes are `:terminal`, `:prefix`, `:resize` and `:copy` (every key consumed here; the
  session hands presses to `Client.CopyMode`). A binding whose module is this module
  (`enter_mode/2`) is a per-client effect: it is applied here, to the input state, and
  never reaches the app. Presses that are not forwarded are remembered in `swallow`
  (keyed by the key alone, case-insensitive) so their later release is consumed too;
  a forwarded press clears a stale entry. Releases in non-terminal modes are dropped.
  """

  alias HerdrServer.App.Keybinds

  @type mode :: :terminal | :prefix | :resize | :copy
  @type input :: %{mode: mode(), swallow: MapSet.t()}
  @type result :: :consumed | {:forward, tuple()} | {:run, Keybinds.mfa_t()}

  @spec resolve(input(), Keybinds.t(), tuple()) :: {input(), result()}
  def resolve(st, kb, {:key, %{key: k, mods: m, event: :release}} = event) do
    key = Keybinds.normalize(k, m)
    sk = swallow_key(key)

    cond do
      MapSet.member?(st.swallow, sk) ->
        {%{st | swallow: MapSet.delete(st.swallow, sk)}, :consumed}

      st.mode != :terminal ->
        {st, :consumed}

      true ->
        dispatch(st, kb, event, key)
    end
  end

  def resolve(st, kb, {:key, %{key: k, mods: m}} = event) do
    key = Keybinds.normalize(k, m)
    sk = swallow_key(key)

    case dispatch(st, kb, event, key) do
      {st, {:forward, _} = r} -> {%{st | swallow: MapSet.delete(st.swallow, sk)}, r}
      {st, r} -> {%{st | swallow: MapSet.put(st.swallow, sk)}, r}
    end
  end

  @doc "Keybind target for mode changes: `{HerdrServer.Client.Keys, :enter_mode, [mode]}`."
  @spec enter_mode(input(), mode()) :: input()
  def enter_mode(st, mode), do: %{st | mode: mode}

  defp swallow_key({k, _mods}) when is_binary(k), do: String.downcase(k)
  defp swallow_key({k, _mods}), do: k

  defp dispatch(%{mode: :copy} = st, _kb, _event, _key), do: {st, :consumed}

  defp dispatch(st, kb, event, key) do
    key_in(st.mode, st, event, Keybinds.lookup(kb, st.mode, key), Keybinds.prefix?(kb, key))
  end

  # key_in(mode, st, event, bound_mfa | nil, prefix_key?)
  defp key_in(:terminal, st, {:key, %{event: :release}}, bound, prefix?)
       when bound != nil or prefix?,
       do: {st, :consumed}

  defp key_in(:terminal, st, _, _, true), do: {enter_mode(st, :prefix), :consumed}
  defp key_in(:terminal, st, _, bound, _) when bound != nil, do: call(st, bound)
  defp key_in(:terminal, st, event, _, _), do: {st, {:forward, event}}

  defp key_in(:prefix, st, _, bound, _) when bound != nil,
    do: call(enter_mode(st, :terminal), bound)

  defp key_in(:prefix, st, event, _, true), do: {enter_mode(st, :terminal), {:forward, event}}
  defp key_in(:prefix, st, _, _, _), do: {enter_mode(st, :terminal), :consumed}
  defp key_in(:resize, st, _, bound, _) when bound != nil, do: call(st, bound)
  defp key_in(:resize, st, _, _, _), do: {st, :consumed}

  defp call(st, {__MODULE__, f, a}), do: {Kernel.apply(__MODULE__, f, [st | a]), :consumed}
  defp call(st, mfa), do: {st, {:run, mfa}}
end
