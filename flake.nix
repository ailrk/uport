{
  description = "UPort - File Upload Portal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/48652e9d5aea46e555b3df87354280d4f29cd3a3";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        hPkgs = pkgs.haskellPackages;
        packageName = "uport";
        uPortPkg = hPkgs.callCabal2nix packageName self {};

      in
      {
        # Packages/Derivations: `nix build .#upload-portal-server`, etc.
        packages = {
          default = uPortPkg;
          server = pkgs.lib.getExe' uPortPkg "uport-server";
          cli = pkgs.lib.getExe' uPortPkg "uport-cli";
        };

        nixosModules.default = import ./nix/modules/server.nix;

        # Development Environment: `nix develop`
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
    );
}
