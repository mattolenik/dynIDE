# Untested: nix was not installed when this was written.
# nix build --impure --expr '(builtins.getFlake (toString ./.)).lib.mkDynide { system = "aarch64-linux"; tarball = /abs/dynide-0.1.0-linux-aarch64.tar.gz; }'
{
  description = "dynIDE from a release tarball";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: {
    lib.mkDynide = { system, tarball, version ? "0.1.0" }:
      nixpkgs.legacyPackages.${system}.callPackage ./default.nix { src = tarball; inherit version; };
  };
}
