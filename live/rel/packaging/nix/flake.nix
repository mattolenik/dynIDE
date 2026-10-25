# Untested: nix was not installed when this was written.
# nix build --impure --expr '(builtins.getFlake (toString ./.)).lib.mkHerdrLive { system = "aarch64-linux"; tarball = /abs/herdr-live-0.1.0-linux-aarch64.tar.gz; }'
{
  description = "herdr-live from a release tarball";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: {
    lib.mkHerdrLive = { system, tarball, version ? "0.1.0" }:
      nixpkgs.legacyPackages.${system}.callPackage ./default.nix { src = tarball; inherit version; };
  };
}
