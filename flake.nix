{
  description = "UPort - File Upload Portal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/48652e9d5aea46e555b3df87354280d4f29cd3a3";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      overlay = final: prev: {
        uport = final.haskellPackages.callCabal2nix "uport" self {};
      };
    in
    (flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };
        hPkgs = pkgs.haskellPackages;
        uPortPkg = pkgs.uport;
      in
      {
        packages = {
          default = uPortPkg;
          uport = uPortPkg;
        };

        devShells.default = hPkgs.shellFor {
          packages = p: [ uPortPkg ];
          withHoogle = true;
          buildInputs = with pkgs; [
            hPkgs.cabal-install
            hPkgs.haskell-language-server
            hPkgs.implicit-hie
            zlib
          ];
        };
      }
    )) // {
      overlays.default = overlay;
      nixosModules.default = import ./nix/modules/default.nix self;
    };
}
