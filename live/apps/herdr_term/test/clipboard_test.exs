defmodule HerdrTerm.ClipboardTest do
  # env vars and the fake desktop are VM-global
  use ExUnit.Case, async: false

  alias HerdrTerm.Clipboard
  alias HerdrTerm.Kernel.Fake.{Desktop, Tty}

  @remote ~w(SSH_CONNECTION SSH_TTY VSCODE_IPC_HOOK_CLI)

  setup do
    saved = Map.new(@remote, &{&1, System.get_env(&1)})
    Enum.each(@remote, &System.delete_env/1)

    on_exit(fn ->
      Desktop.reset()
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end)

    {:ok, tty} = Tty.open()
    %{tty: tty}
  end

  test "over ssh: OSC 52 only", %{tty: tty} do
    System.put_env("SSH_TTY", "/dev/pts/1")
    Desktop.listen(self())
    assert Clipboard.write(tty, "héllo") == :ok
    assert Tty.written(tty) == "\e]52;c;" <> Base.encode64("héllo") <> "\a"
    refute_received {:desktop, _, _}
  end

  test "locally the desktop tool takes it, nothing on the tty", %{tty: tty} do
    Desktop.listen(self())
    assert Clipboard.write(tty, "abc") == :ok
    assert_received {:desktop, :clipboard_write, "abc"}
    assert Tty.written(tty) == ""
  end

  test "a failing desktop tool falls back to OSC 52", %{tty: tty} do
    Desktop.listen(self(), {:error, :unavailable})
    assert Clipboard.write(tty, "abc") == :ok
    assert_received {:desktop, :clipboard_write, "abc"}
    assert Tty.written(tty) == "\e]52;c;YWJj\a"
  end
end
