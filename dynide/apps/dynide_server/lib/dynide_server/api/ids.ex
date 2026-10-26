defmodule DynideServer.Api.Ids do
  @moduledoc """
  Public API ids: workspace `"w<N>"`, tab `"w<N>:t<M>"`, pane `"p<K>"`.

  Numbers are positive integers without leading zeros or signs. Only this exact
  form is accepted; there is no lenient parsing.
  """

  @n "([1-9][0-9]*)"
  @workspace Regex.compile!("\\Aw" <> @n <> "\\z")
  @tab Regex.compile!("\\Aw" <> @n <> ":t" <> @n <> "\\z")
  @pane Regex.compile!("\\Ap" <> @n <> "\\z")

  @spec workspace(pos_integer()) :: String.t()
  def workspace(n) when is_integer(n) and n > 0, do: "w#{n}"

  @spec tab(pos_integer(), pos_integer()) :: String.t()
  def tab(ws, tab) when is_integer(ws) and ws > 0 and is_integer(tab) and tab > 0,
    do: "w#{ws}:t#{tab}"

  @spec pane(pos_integer()) :: String.t()
  def pane(n) when is_integer(n) and n > 0, do: "p#{n}"

  @spec parse_workspace(term()) :: {:ok, pos_integer()} | :error
  def parse_workspace(s) when is_binary(s) do
    case Regex.run(@workspace, s) do
      [_, a] -> {:ok, String.to_integer(a)}
      _ -> :error
    end
  end

  def parse_workspace(_), do: :error

  @spec parse_tab(term()) :: {:ok, {pos_integer(), pos_integer()}} | :error
  def parse_tab(s) when is_binary(s) do
    case Regex.run(@tab, s) do
      [_, a, b] -> {:ok, {String.to_integer(a), String.to_integer(b)}}
      _ -> :error
    end
  end

  def parse_tab(_), do: :error

  @spec parse_pane(term()) :: {:ok, pos_integer()} | :error
  def parse_pane(s) when is_binary(s) do
    case Regex.run(@pane, s) do
      [_, a] -> {:ok, String.to_integer(a)}
      _ -> :error
    end
  end

  def parse_pane(_), do: :error
end
