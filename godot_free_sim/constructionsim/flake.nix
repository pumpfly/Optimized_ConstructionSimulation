{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {

          buildInputs = with pkgs; [
            go
            delve
            gdlv
            libGL
            xorg.libXi
            xorg.libXcursor
            xorg.libXrandr
            xorg.libXinerama
            wayland
            libxkbcommon
          ];
          # this is needed for delve to work with cgo
          # see: https://wiki.nixos.org/wiki/Go#Using_cgo_on_NixOS
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            echo "opening Golang dev shell";
          '';
        };
      }
    );
}
