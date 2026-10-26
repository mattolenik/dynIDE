defmodule DynideTerm.Client.Term.Notify do
  @moduledoc """
  Pure: terminal notification bytes for this client's host terminal (herdr
  `terminal_notify.rs`).

    * `backend/1` from the environment: `TERM_PROGRAM` `ghostty`, `iTerm.app`, `WezTerm`
      are OSC 9; `KITTY_WINDOW_ID` is OSC 99; then `TERM` `xterm-ghostty` (OSC 9),
      `xterm-kitty` (OSC 99), anything containing `wezterm` (OSC 9). Unknown terminals
      get OSC 9 (dynIDE's M13 behaviour; terminals ignore OSCs they do not know).
    * `sequence/4`: OSC 9 `title: body`, or OSC 99 title then body (kitty, `i=1`),
      ST-terminated; under `TMUX` wrapped in a `tmux;` DCS passthrough with every ESC
      doubled. Title and body arrive sanitized (`Alert`).
  """

  @type backend :: :osc9 | :osc99

  @spec backend(%{optional(binary) => binary}) :: backend
  def backend(env) do
    term_program = env["TERM_PROGRAM"]
    term = env["TERM"] || ""

    cond do
      term_program in ["ghostty", "iTerm.app", "WezTerm"] -> :osc9
      env["KITTY_WINDOW_ID"] not in [nil, ""] -> :osc99
      term == "xterm-kitty" -> :osc99
      true -> :osc9
    end
  end

  @doc "Whether the client runs inside tmux (`TMUX` set)."
  @spec tmux?(%{optional(binary) => binary}) :: boolean
  def tmux?(env), do: env["TMUX"] not in [nil, ""]

  @spec sequence(backend, binary, binary | nil, boolean) :: binary
  def sequence(backend, title, body, tmux) do
    seq = build(backend, title, body)
    if tmux, do: wrap_tmux(seq), else: seq
  end

  defp build(:osc9, title, body) when body in [nil, ""], do: "\e]9;" <> title <> "\e\\"
  defp build(:osc9, title, body), do: "\e]9;" <> title <> ": " <> body <> "\e\\"
  defp build(:osc99, title, body) when body in [nil, ""], do: "\e]99;;" <> title <> "\e\\"

  defp build(:osc99, title, body),
    do: "\e]99;i=1:d=0;" <> title <> "\e\\\e]99;i=1:p=body;" <> body <> "\e\\"

  @doc "tmux DCS passthrough: `ESC P tmux;` + the sequence with ESC doubled + ST."
  @spec wrap_tmux(binary) :: binary
  def wrap_tmux(seq), do: "\ePtmux;" <> String.replace(seq, "\e", "\e\e") <> "\e\\"
end
