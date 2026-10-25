defmodule HerdrCli.Update.ManifestTest do
  use ExUnit.Case, async: true

  alias HerdrCli.Update.Manifest

  setup do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, pub: pub, priv: priv}
  end

  defp manifest(over \\ %{}) do
    Map.merge(
      %{
        "schema" => 1,
        "channel" => "stable",
        "version" => "0.1.1",
        "released" => "2026-10-25T00:00:00Z",
        "notes_url" => "https://example.invalid/notes",
        "artifacts" => [
          %{
            "os" => "macos",
            "arch" => "aarch64",
            "url" => "file:///m.tar.gz",
            "sha256" => String.duplicate("a", 64),
            "size" => 1
          },
          %{
            "os" => "linux",
            "arch" => "aarch64",
            "url" => "file:///l.tar.gz",
            "sha256" => String.duplicate("b", 64),
            "size" => 2
          }
        ]
      },
      over
    )
  end

  defp sign(bytes, priv), do: Base.encode64(:crypto.sign(:eddsa, :none, bytes, [priv, :ed25519]))

  test "a valid signature is accepted", %{pub: pub, priv: priv} do
    bytes = JSON.encode!(manifest())
    assert {:ok, %{"version" => "0.1.1"}} = Manifest.verify(bytes, sign(bytes, priv), [pub])
    # trailing newline in the .sig file is fine
    assert {:ok, _} = Manifest.verify(bytes, sign(bytes, priv) <> "\n", [pub])
  end

  test "one flipped byte of the manifest is a bad signature", %{pub: pub, priv: priv} do
    bytes = JSON.encode!(manifest())
    sig = sign(bytes, priv)
    <<a, rest::binary>> = bytes

    assert Manifest.verify(<<Bitwise.bxor(a, 1), rest::binary>>, sig, [pub]) ==
             {:error, :bad_signature}
  end

  test "a signature by a key not in the list is a bad signature", %{pub: pub} do
    {_other_pub, other_priv} = :crypto.generate_key(:eddsa, :ed25519)
    bytes = JSON.encode!(manifest())
    assert Manifest.verify(bytes, sign(bytes, other_priv), [pub]) == {:error, :bad_signature}
    assert Manifest.verify(bytes, "not base64!", [pub]) == {:error, :bad_signature}
    assert Manifest.verify(bytes, sign(bytes, other_priv), []) == {:error, :bad_signature}
  end

  test "schema 2 is unsupported", %{pub: pub, priv: priv} do
    bytes = JSON.encode!(manifest(%{"schema" => 2}))
    assert Manifest.verify(bytes, sign(bytes, priv), [pub]) == {:error, {:unsupported_schema, 2}}
  end

  test "missing artifacts, a bad version or bad sha is a bad schema", %{pub: pub, priv: priv} do
    for bytes <- [
          JSON.encode!(Map.delete(manifest(), "artifacts")),
          JSON.encode!(manifest(%{"version" => "../x"})),
          JSON.encode!(
            manifest(%{
              "artifacts" => [
                %{
                  "os" => "macos",
                  "arch" => "aarch64",
                  "url" => "u",
                  "sha256" => "x",
                  "size" => 1
                }
              ]
            })
          ),
          "[1]",
          "not json"
        ] do
      assert Manifest.verify(bytes, sign(bytes, priv), [pub]) == {:error, :bad_schema}
    end
  end

  test "pick by os and arch" do
    assert {:ok, %{"url" => "file:///l.tar.gz"}} = Manifest.pick(manifest(), "linux", "aarch64")
    assert {:ok, %{"url" => "file:///m.tar.gz"}} = Manifest.pick(manifest(), "macos", "aarch64")
    assert Manifest.pick(manifest(), "linux", "x86_64") == {:error, :no_artifact}
  end

  test "newer? compares versions" do
    assert Manifest.newer?("0.1.1", "0.1.0")
    refute Manifest.newer?("0.1.0", "0.1.0")
    refute Manifest.newer?("0.1.0", "0.1.1")
    refute Manifest.newer?("0.1.1", "not-semver")
  end
end
