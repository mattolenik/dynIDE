defmodule HerdrTerm.Clipboard do
  @moduledoc """
  Puts text on the user's clipboard, as herdr does: over SSH or a VS Code remote
  terminal (`SSH_CONNECTION`, `SSH_TTY`, `VSCODE_IPC_HOOK_CLI` set) OSC 52 to the host
  terminal only; otherwise the client machine's clipboard tool
  (`HerdrTerm.Kernel.desktop/0`), falling back to OSC 52 when it is unavailable.
  OSC 52 is `ESC ] 52 ; c ; <base64> BEL`, no size cap (a write over the tty's 1 MiB
  queue is refused by the kernel).
  """

  alias HerdrTerm.Kernel

  @remote ~w(SSH_CONNECTION SSH_TTY VSCODE_IPC_HOOK_CLI)

  @spec write(term, binary) :: :ok
  def write(tty, text) when is_binary(text) do
    if remote?() or Kernel.desktop().clipboard_write(text) != :ok,
      do: Kernel.tty().write(tty, ["\e]52;c;", Base.encode64(text), "\a"])

    :ok
  end

  defp remote?, do: Enum.any?(@remote, &(System.get_env(&1) not in [nil, ""]))
end
