# Signed update channel manifest (M18 R5, docs/herdr-live/site/update-manifest.md).
# Usage: elixir make_manifest.exs --url-base URL --key KEY [--out DIR] [--channel C]
#          [--released ISO8601] [--notes-url URL] TARBALL...
# Every TARBALL is dynide-<V>-<os>-<arch>.tar.gz of one version V; its artifact url is
# URL/<basename> (URL percent-encoded as given). KEY is a keygen.sh private key file.
# Writes DIR/manifest.json and DIR/manifest.json.sig (base64 ed25519 signature over the
# exact manifest bytes); DIR defaults to the first tarball's dir. Prints the manifest path.
{opts, tarballs} =
  OptionParser.parse!(System.argv(),
    strict: [
      url_base: :string,
      key: :string,
      out: :string,
      channel: :string,
      released: :string,
      notes_url: :string
    ]
  )

usage = fn msg ->
  IO.puts(:stderr, "make_manifest.exs: #{msg}")
  System.halt(2)
end

(opts[:url_base] && opts[:key] && tarballs != []) || usage.("need --url-base, --key and tarballs")

artifacts =
  for t <- tarballs do
    case Regex.run(
           ~r/^dynide-(.+)-(macos|linux)-(aarch64|x86_64)\.tar\.gz$/,
           Path.basename(t)
         ) do
      [_, v, os, arch] ->
        data = File.read!(t)

        {v,
         %{
           "os" => os,
           "arch" => arch,
           "url" =>
             String.trim_trailing(opts[:url_base], "/") <> "/" <> URI.encode(Path.basename(t)),
           "sha256" => Base.encode16(:crypto.hash(:sha256, data), case: :lower),
           "size" => byte_size(data)
         }}

      _ ->
        usage.("#{t}: not dynide-<V>-<os>-<arch>.tar.gz")
    end
  end

v =
  case artifacts |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
    [v] -> v
    _ -> usage.("tarballs of more than one version")
  end

manifest =
  %{
    "schema" => 1,
    "channel" => opts[:channel] || "stable",
    "version" => v,
    "released" =>
      opts[:released] || DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
    "artifacts" => Enum.map(artifacts, &elem(&1, 1))
  }
  |> then(&if(opts[:notes_url], do: Map.put(&1, "notes_url", opts[:notes_url]), else: &1))

{:ok, <<_::binary-size(32)>> = priv} =
  opts[:key] |> File.read!() |> String.trim() |> Base.decode64()

bytes = JSON.encode!(manifest)
out = opts[:out] || Path.dirname(hd(tarballs))
File.mkdir_p!(out)
path = Path.join(out, "manifest.json")
File.write!(path, bytes)

File.write!(
  path <> ".sig",
  Base.encode64(:crypto.sign(:eddsa, :none, bytes, [priv, :ed25519])) <> "\n"
)

IO.puts(path)
