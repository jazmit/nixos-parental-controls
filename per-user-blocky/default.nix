# A DNS proxy that updates configuration based on the logged in users
# Implemented as a python script that listens to logind events on dbus
# and starts instances of blocky as appropriate
{ pkgs ? (import <nixpkgs> {}) }:
with pkgs;

stdenv.mkDerivation {
  name = "per-user-blocky";
  buildInputs = [
    (python39.withPackages (pp: [
      pp.pygobject3
      pp.dbus-python
    ]))
  ];
  unpackPhase = "true";
  # The following is purely to make blocky available in $PATH for the proxy
  installPhase = ''
    mkdir -p $out/bin
    cp ${./per-user-blocky.py} $out/per-user-blocky.py
    echo "#!/usr/bin/env bash" > $out/bin/per-user-blocky
    echo PATH="PATH:${blocky}/bin" $out/per-user-blocky.py '"$@"' >> $out/bin/per-user-blocky
    chmod +x $out/per-user-blocky.py
    chmod +x $out/bin/per-user-blocky
  '';
}
