{
  description = "categorifier-c";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-21.11";
    flake-utils.url = "github:numtide/flake-utils";
    concat = {
      url = "github:con-kitty/concat/wavewave-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utlis.follows = "flake-utils";
    };
    categorifier = {
      url = "github:con-kitty/categorifier/wavewave-flakes-2";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.concat.follows = "concat";
    };
    connections = {
      url = "github:cmk/connections/master";
      flake = false;
    };
  };
  outputs = { self, nixpkgs, flake-utils, concat, categorifier, connections }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "x86_64-darwin" ] (system:
      let
        overlay_connection = final: prev: {
          haskellPackages = prev.haskellPackages.override (old: {
            overrides =
              final.lib.composeExtensions (old.overrides or (_: _: { }))
              (self: super: {
                "connections" =
                  self.callCabal2nix "connections" connections { };
              });
          });
        };

        pkgs = import nixpkgs {
          overlays = [
            overlay_connection
            (concat.overlay.${system})
            (categorifier.overlay.${system})
          ];
          inherit system;
          config.allowBroken = true;
        };
        #haskellOverlay_connection = self: super: {
        #  "connections" = self.callCabal2nix "connections" connections { };
        #};

        haskellOverlay = self: super: {
          "categorifier-c" = self.callCabal2nix "categorifier-c" ./. { };
          "categorifier-c-examples" =
            self.callCabal2nix "categorifier-c-examples" ./examples { };
          "categorifier-c-hk-classes" =
            self.callCabal2nix "categorifier-c-hk-classes" ./hk-classes { };
          "categorifier-c-maker-map" =
            self.callCabal2nix "categorifier-c-maker-map" ./maker-map { };
          "categorifier-c-recursion" =
            self.callCabal2nix "categorifier-c-recursion" ./recursion { };
          "categorifier-c-unconcat" =
            self.callCabal2nix "categorifier-c-unconcat" ./unconcat { };
          "categorifier-c-test-lib" =
            self.callCabal2nix "categorifier-c-test-lib" ./test-lib { };
          "categorifier-c-tests" =
            self.callCabal2nix "categorifier-c-tests" ./tests { };
          # test is broken with DBool.
          "generic-accessors" =
            pkgs.haskell.lib.dontCheck super.generic-accessors;
        };

        # NOTE: This would not be necessary if we can provide overlay from connections package.
        #newHaskellPackages = pkgs.haskellPackages.override (old: {
        #  overrides = pkgs.lib.composeExtensions (old.overrides or (_: _: { }))
        #    haskellOverlay_connection;
        #});

      in {
        packages = let
          newHaskellPackages2 = pkgs.haskellPackages.override (old: {
            overrides =
              pkgs.lib.composeExtensions (old.overrides or (_: _: { }))
              haskellOverlay;
          });

        in {
          inherit (newHaskellPackages2) categorifier-c categorifier-c-examples;
        };
        # see these issues and discussions:
        # - https://github.com/NixOS/nixpkgs/issues/16394
        # - https://github.com/NixOS/nixpkgs/issues/25887
        # - https://github.com/NixOS/nixpkgs/issues/26561
        # - https://discourse.nixos.org/t/nix-haskell-development-2020/6170
        overlays = [
          overlay_connection
          (final: prev: {
            haskellPackages = prev.haskellPackages.override (old: {
              overrides =
                final.lib.composeExtensions (old.overrides or (_: _: { }))
                haskellOverlay;
            });
          })
        ];

        devShells = {
          # Default shell invoked by nix develop .#
          # This is used for building categorifier-c
          default = let
            hsenv = pkgs.haskellPackages.ghcWithPackages (p: [
              p.cabal-install
              p.categorifier-category
              p.categorifier-client
              p.categorifier-common
              p.categorifier-concat-extensions-category
              p.categorifier-concat-extensions-integration
              p.categorifier-concat-integration
              p.categorifier-duoids
              p.categorifier-ghc
              p.categorifier-hedgehog
              p.categorifier-plugin
              p.categorifier-th
              p.categorifier-unconcat-category
              p.categorifier-unconcat-integration
              p.concat-classes
              p.connections
            ]);
          in pkgs.mkShell { buildInputs = [ hsenv ]; };
          # The shell with all batteries included!
          user-shell = let
            postBuildHaskellPackages = pkgs.haskellPackages.override (old: {
              overrides =
                pkgs.lib.composeExtensions (old.overrides or (_: _: { }))
                haskellOverlay;
            });
            hsenv = postBuildHaskellPackages.ghcWithPackages (p: [
              p.cabal-install
              p.categorifier-c
              p.categorifier-c-examples
              p.categorifier-c-hk-classes
              p.categorifier-c-maker-map
              p.categorifier-c-recursion
              p.categorifier-c-unconcat
              p.categorifier-c-test-lib
            ]);
          in pkgs.mkShell { buildInputs = [ hsenv ]; };
        };
      });
}
