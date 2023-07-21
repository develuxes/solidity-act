{
  description = "act";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs";
    hevmUpstream = {
      url = "github:ethereum/hevm/308cf16788c29a3e98542d87125d3ffb237615e1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, hevmUpstream, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        gitignore = pkgs.nix-gitignore.gitignoreSourcePure [ ./.gitignore ];
	myHaskellPackages = pkgs.haskellPackages.override {
          overrides = self: super: rec {
	    hevm = hevmUpstream.packages.${system}.noTests;
          };
	};
        act = (myHaskellPackages.callCabal2nixWithOptions "act" (gitignore ./src) "-fci" {})
          .overrideAttrs (attrs : {
            buildInputs = attrs.buildInputs ++ [ pkgs.z3 pkgs.cvc5 ];
          });
      in rec {
        packages.act = act;
        packages.default = packages.act;

        apps.act = flake-utils.lib.mkApp { drv = packages.act; };
        apps.default = apps.act;

        devShell = with pkgs;
          let libraryPath = "${lib.makeLibraryPath [ libff secp256k1 gmp ]}";
          in myHaskellPackages.shellFor {
          packages = _: [ act ];
          buildInputs = with pkgs.haskellPackages; [
            cabal-install
            haskell-language-server
            pkgs.jq
            pkgs.z3
            pkgs.cvc5
            pkgs.coq
            pkgs.solc
            pkgs.mdbook
            pkgs.mdbook-mermaid
            pkgs.mdbook-katex
          ];
          withHoogle = true;
          shellHook = ''
            export PATH=$(pwd)/bin:$PATH
	    export DYLD_LIBRARY_PATH="${libraryPath}"
          '';
        };
      }
  );
}
