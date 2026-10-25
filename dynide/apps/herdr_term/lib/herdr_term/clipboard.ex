defmodule HerdrTerm.Clipboard do
  @moduledoc """
  Puts text on the user's clipboard, as herdr does: over SSH or a VS Code remote
  terminal (`SSH_CONNECTION`, `SSH_TTY`, `VSCODE_IPC_HOOK_CLI` set) OSC 52 to the host
  terminal only; otherwise the client machine's clipboard tool
  (`HerdrTerm.Kernel.desktop/0`), falling back to OSC 52 when it is unavailable.
  OSC 52 is `ESC ] 52 ; c ; <base64> BEL`, for text up to 196_608 bytes (herdr's cap);
  larger text is `{:error, :too_large}`, a write the tty refuses `{:error, :backpressure}`.
  """

  alias HerdrTerm.Kernel

  @remote ~w(SSH_CONNECTION SSH_TTY VSCODE_IPC_HOOK_CLI)
  @osc52_max 196_608

  @spec write(term, binary) :: :ok | {:error, :too_large | :backpressure}
  def write(tty, text) when is_binary(text) do
    if not remote?() and Kernel.desktop().clipboard_write(text) == :ok,
      do: :ok,
      else: osc52(tty, text)
  end

  defp osc52(_tty, text) when byte_size(text) > @osc52_max, do: {:error, :too_large}
  defp osc52(tty, text), do: Kernel.tty().write(tty, ["\e]52;c;", Base.encode64(text), "\a"])

  defp remote?, do: Enum.any?(@remote, &(System.get_env(&1) not in [nil, ""]))
end
