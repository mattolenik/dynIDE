defmodule HerdrCli.Update.Manifest do
  @moduledoc """
  The update channel manifest (schema 1, docs/herdr-live/site/update-manifest.md), pure.

  `verify/3` checks the detached ed25519 signature over the exact manifest bytes before it
  parses anything, then the schema. Keys and signatures are raw bytes: a key is 32, a
  signature 64 (the `.sig` file and `update-keys/*.pub` hold them base64).
  """

  @type artifact :: %{String.t() => term()}
  @type t :: %{String.t() => term()}

  @version ~r/\A[0-9A-Za-z._+-]+\z/

  @doc "Verifies `bytes` against `sig_b64` with any of `keys`, then parses schema 1."
  @spec verify(binary(), binary(), [binary()]) ::
          {:ok, t()} | {:error, :bad_signature | :bad_schema | {:unsupported_schema, term()}}
  def verify(bytes, sig_b64, keys) do
    with {:ok, sig} <- decode_sig(sig_b64),
         true <- Enum.any?(keys, &signed?(bytes, sig, &1)) || {:error, :bad_signature},
         {:ok, map} when is_map(map) <- JSON.decode(bytes) do
      check(map)
    else
      {:error, :bad_signature} = e -> e
      _ -> {:error, :bad_schema}
    end
  end

  defp decode_sig(b64) do
    case Base.decode64(String.trim(b64)) do
      {:ok, <<_::binary-size(64)>> = sig} -> {:ok, sig}
      _ -> {:error, :bad_signature}
    end
  end

  defp signed?(bytes, sig, <<_::binary-size(32)>> = key),
    do: :crypto.verify(:eddsa, :none, bytes, sig, [key, :ed25519])

  defp signed?(_bytes, _sig, _key), do: false

  defp check(%{"schema" => 1} = m) do
    if version?(m["version"]) and is_binary(m["channel"]) and optional_strings?(m) and
         artifacts?(m["artifacts"]),
       do: {:ok, m},
       else: {:error, :bad_schema}
  end

  defp check(%{"schema" => n}), do: {:error, {:unsupported_schema, n}}
  defp check(_), do: {:error, :bad_schema}

  # the version names a directory: no path separators, never "." or ".."
  defp version?(v),
    do:
      is_binary(v) and v not in [".", ".."] and v =~ @version and
        match?({:ok, _}, Version.parse(v))

  defp optional_strings?(m),
    do: Enum.all?(~w(released notes_url), &(m[&1] == nil or is_binary(m[&1])))

  defp artifacts?([_ | _] = list), do: Enum.all?(list, &artifact?/1)
  defp artifacts?(_), do: false

  defp artifact?(%{"os" => os, "arch" => arch, "url" => url, "sha256" => sha, "size" => size})
       when is_binary(os) and is_binary(arch) and is_binary(url) and is_binary(sha) and
              is_integer(size) and size > 0,
       do: sha =~ ~r/\A[0-9a-f]{64}\z/

  defp artifact?(_), do: false

  @doc "The artifact for `os` (`macos`, `linux`) and `arch` (`aarch64`, `x86_64`)."
  @spec pick(t(), String.t(), String.t()) :: {:ok, artifact()} | {:error, :no_artifact}
  def pick(%{"artifacts" => list}, os, arch) do
    case Enum.find(list, &(&1["os"] == os and &1["arch"] == arch)) do
      nil -> {:error, :no_artifact}
      a -> {:ok, a}
    end
  end

  @doc "Whether `candidate` is a newer version than `current`; false when either is not semver."
  @spec newer?(String.t(), String.t()) :: boolean()
  def newer?(candidate, current) do
    with {:ok, a} <- Version.parse(candidate),
         {:ok, b} <- Version.parse(current),
         do: Version.compare(a, b) == :gt,
         else: (_ -> false)
  end
end
