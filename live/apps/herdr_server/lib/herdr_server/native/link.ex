defmodule HerdrServer.Native.Link do
  @moduledoc """
  The VM side of the broker socket: length-prefixed frames with SCM_RIGHTS fds
  (wire protocol in `docs/herdr-live/plans/m5.md`). A kernel thread reads frames and
  sends the owner, in order:

      {:herdr_link, link, kind, body, fds}   fds :: [Pty.fd()], CLOEXEC, single-use
      {:herdr_link_closed, link, reason}     once, last; reason :: :eof | binary

  The owner is monitored: its exit closes the link.

  Senders queue on one mutex per link, so a send waits behind any frame in flight.
  The 5 s timeout applies per `sendmsg` call, not per frame. A send that fails
  after writing may have left a partial frame, so it closes the link (the reader
  then reports `:herdr_link_closed`); only `:too_large`, rejected before any write,
  leaves it open.
  """

  alias HerdrServer.Native
  alias HerdrServer.Native.Pty

  @opaque link :: reference
  @type kind_name ::
          :hello
          | :hold
          | :update
          | :drop
          | :restored
          | :prepared
          | :reply
          | :fresh
          | :adopt
          | :adopt_end
          | :prepare
          | :release
          | :thaw
          | :request

  @hello 0x01
  @hold 0x02
  @update 0x03
  @drop 0x04
  @restored 0x05
  @prepared 0x06
  @reply 0x07
  @fresh 0x41
  @adopt 0x42
  @adopt_end 0x43
  @prepare 0x44
  @release 0x45
  @thaw 0x46
  @request 0x47

  @doc """
  Connects to the broker socket at `path` and starts the reader for `owner`. Sends
  time out after 5 s; reads never do. Errors: `:enoent`, `:eacces`, `:econnrefused`,
  `:einval` (path too long), `:noproc` (owner dead), else `:connect_failed`.
  """
  @spec connect(binary, pid) :: {:ok, link} | {:error, atom}
  def connect(path, owner), do: Native.link_connect(path, owner)

  @doc """
  Sends one frame. Each of `fds` goes as a fresh dup: a pty's master, or an fd
  resource (left unconsumed; a consumed one is `{:error, :consumed}`). Concurrent
  senders never interleave. Errors: `:closed`, `:timeout`, `:too_large`, else a message.
  """
  @spec send(link, byte, iodata, [Pty.fd() | Pty.pty()]) :: :ok | {:error, atom | binary}
  def send(link, kind, body, fds), do: Native.link_send(link, kind, body, fds)

  @doc "CLOEXEC dup of a raw fd (the caller keeps its own) into an fd resource."
  @spec fd_dup(non_neg_integer) :: {:ok, Pty.fd()} | {:error, atom | binary}
  def fd_dup(raw), do: Native.fd_dup_raw(raw)

  @doc "Takes the fd out of the resource; the caller owns the raw fd and must close or `fdopen` it."
  @spec fd_take(Pty.fd()) :: {:ok, non_neg_integer} | {:error, :consumed}
  def fd_take(fd), do: Native.fd_into_raw(fd)

  @doc """
  The fd number, still owned by the resource (closed by `fd_close/1` or when the resource
  is collected). For `:gen_tcp.fdopen/2`: its port never closes an fd it did not open.
  """
  @spec fd_raw(Pty.fd()) :: {:ok, non_neg_integer} | {:error, :consumed}
  def fd_raw(fd), do: Native.fd_raw(fd)

  @doc "Closes the fd now. A consumed resource is `{:error, :consumed}`."
  @spec fd_close(Pty.fd()) :: :ok | {:error, :consumed}
  def fd_close(fd), do: Native.fd_close(fd)

  @doc "Shuts the socket down; the reader then reports `:eof`. Idempotent."
  @spec close(link) :: :ok
  def close(link), do: Native.link_close(link)

  @doc "`klen: u16 | key | blob`; a key over 65535 bytes raises `ArgumentError`."
  @spec frame_key(binary, iodata) :: iodata
  def frame_key(key, blob) when byte_size(key) <= 65_535, do: [<<byte_size(key)::16>>, key, blob]

  def frame_key(key, _blob),
    do: raise(ArgumentError, "link key of #{byte_size(key)} bytes: at most 65535")

  @doc "Inverse of `frame_key/2`; `:error` for a body too short for its key."
  @spec parse_key(binary) :: {binary, binary} | :error
  def parse_key(<<n::16, key::binary-size(n), rest::binary>>), do: {key, rest}
  def parse_key(_), do: :error

  @doc "The wire byte for a VM link frame kind."
  @spec kind(kind_name) :: byte
  def kind(:hello), do: @hello
  def kind(:hold), do: @hold
  def kind(:update), do: @update
  def kind(:drop), do: @drop
  def kind(:restored), do: @restored
  def kind(:prepared), do: @prepared
  def kind(:reply), do: @reply
  def kind(:fresh), do: @fresh
  def kind(:adopt), do: @adopt
  def kind(:adopt_end), do: @adopt_end
  def kind(:prepare), do: @prepare
  def kind(:release), do: @release
  def kind(:thaw), do: @thaw
  def kind(:request), do: @request
end
