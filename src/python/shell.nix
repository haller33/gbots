{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  buildInputs = with pkgs; [
    gcc
    python3
    python3Packages.pandas
    python3Packages.matplotlib
  ];
  # Ensure the library path includes gcc's libstdc++
  shellHook = ''
    export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.gcc-unwrapped ]}:$LD_LIBRARY_PATH
  '';
}
