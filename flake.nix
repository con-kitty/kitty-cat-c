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
                # test is broken with DBool.
                "generic-accessors" =
                  haskellLib.dontCheck super.generic-accessors;
              });
          });
        };

        haskellLib = (import nixpkgs { inherit system; }).haskell.lib;
        parseCabalProject = import (categorifier + "/parse-cabal-project.nix");
        categorifierCPackages =
          # found this corner case
          [{
            name = "categorifier-c";
            path = ".";
          }] ++ parseCabalProject ./cabal.project;
        categorifierCPackageNames =
          builtins.map ({ name, ... }: name) categorifierCPackages;

        haskellOverlay = self: super:
          builtins.listToAttrs (builtins.map ({ name, path }: {
            inherit name;
            value = self.callCabal2nix name (./. + "/${path}") { };
          }) categorifierCPackages);

        # see these issues and discussions:
        # - https://github.com/NixOS/nixpkgs/issues/16394
        # - https://github.com/NixOS/nixpkgs/issues/25887
        # - https://github.com/NixOS/nixpkgs/issues/26561
        # - https://discourse.nixos.org/t/nix-haskell-development-2020/6170
        fullOverlays = [
          overlay_connection
          (final: prev: {
            haskellPackages = prev.haskellPackages.override (old: {
              overrides =
                final.lib.composeExtensions (old.overrides or (_: _: { }))
                haskellOverlay;
            });
          })
        ];

      in {
        packages = let
          packagesOnGHC = ghcVer:
            let
              overlayGHC = final: prev: {
                haskellPackages = prev.haskell.packages.${ghcVer};
              };

              newPkgs = import nixpkgs {
                overlays = [ overlayGHC (concat.overlay.${system}) ]
                  ++ (categorifier.overlays.${system}) ++ fullOverlays;
                inherit system;
                config.allowBroken = true;
              };

              individualPackages = builtins.listToAttrs (builtins.map (p: {
                name = ghcVer + "_" + p;
                value = builtins.getAttr p newPkgs.haskellPackages;
              }) categorifierCPackageNames);

              allEnv = let
                hsenv = newPkgs.haskellPackages.ghcWithPackages (p:
                  let
                    deps = builtins.map ({ name, ... }: p.${name})
                      categorifierCPackages;
                  in deps);
              in newPkgs.buildEnv {
                name = "all-packages";
                paths = [ hsenv ];
              };
            in individualPackages // { "${ghcVer}_all" = allEnv; };

        in packagesOnGHC "ghc8107" // packagesOnGHC "ghc884"
        // packagesOnGHC "ghc901" // packagesOnGHC "ghc921"
        // packagesOnGHC "ghcHEAD";

        overlays = fullOverlays;

        devShells = let
          mkDevShell = ghcVer:
            let
              overlayGHC = final: prev: {
                haskellPackages = prev.haskell.packages.${ghcVer};
              };
              pkgs = import nixpkgs {
                overlays = [ overlayGHC (concat.overlay.${system}) ]
                  ++ (categorifier.overlays.${system}) ++ fullOverlays;
                inherit system;
                config.allowBroken = true;
              };
            in pkgs.haskellPackages.shellFor {
              packages = ps:
                builtins.map (name: ps.${name}) categorifierCPackageNames;
              buildInputs = [
                pkgs.haskellPackages.cabal-install
                pkgs.haskell-language-server
              ];
              withHoogle = false;
            };

        in {
          # nix develop .#ghc8107
          # (or .#ghc921)
          # This is used for building categorifier-c
          "ghc8107" = mkDevShell "ghc8107";
          "ghc921" = mkDevShell "ghc921";
          # The shell with all batteries included!
          # user-shell = let
          #   hsenv = pkgs.haskellPackages.ghcWithPackages (p: [
          #     p.cabal-install
          #     p.categorifier-c
          #     p.categorifier-c-examples
          #     p.categorifier-c-hk-classes
          #     p.categorifier-c-maker-map
          #     p.categorifier-c-recursion
          #     p.categorifier-c-unconcat
          #     p.categorifier-c-test-lib
          #   ]);
          # in pkgs.mkShell {
          #   buildInputs = [ hsenv pkgs.haskell-language-server ];
          # };
        };
      });
}
