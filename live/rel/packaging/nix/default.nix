# Installs a herdr-live release tarball. Usage (see flake.nix):
#   pkgs.callPackage ./default.nix { src = /abs/herdr-live-0.1.0-linux-aarch64.tar.gz; version = "0.1.0"; }
# Or give url + sha256 instead of src. Untested: nix was not installed when this was written.
{ lib, stdenv, fetchurl, autoPatchelfHook, makeWrapper, openssl_3, ncurses, glibc
, version ? "0.1.0"
, src ? null
, url ? null
, sha256 ? null
}:

stdenv.mkDerivation {
  pname = "herdr-live";
  inherit version;
  src = if src != null then src else fetchurl { inherit url sha256; };

  nativeBuildInputs = lib.optionals stdenv.isLinux [ autoPatchelfHook ];
  # libcrypto.so.3 (OpenSSL 3), libtinfo.so.6 (ncurses), glibc >= 2.39 come from nixpkgs
  buildInputs = lib.optionals stdenv.isLinux [ openssl_3 ncurses stdenv.cc.cc.lib ];

  dontConfigure = true;
  dontBuild = true;
  # erts and the NIFs are stripped/patched by the build already; fixing them again breaks beams
  dontStrip = true;

  # the tarball unpacks to herdr-live-<V>/ (unpackPhase enters it)
  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec $out/bin
    cp -a . $out/libexec/herdr-live
    echo nix > $out/libexec/herdr-live/releases/managed-by
    ln -s $out/libexec/herdr-live/bin/herdr-live $out/bin/herdr-live
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/herdr-live --version | grep -F "herdr-live ${version}"
  '';

  meta = {
    description = "Terminal multiplexer for AI agents that you can edit while it runs";
    platforms = [ "aarch64-darwin" "aarch64-linux" ];
    mainProgram = "herdr-live";
  };
}
