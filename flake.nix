{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-25.05";
    flake-parts.url = "github:hercules-ci/flake-parts";
    haskell-flake.url = "github:srid/haskell-flake";
    system.url = "github:nix-systems/default";
    services-flake.url = "github:juspay/services-flake";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
  };
  outputs = inputs@{ self, nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.system;
      imports = [
        inputs.haskell-flake.flakeModule
        inputs.process-compose-flake.flakeModule
      ];
      perSystem = { self', pkgs, config, ... }: {

        formatter = pkgs.nixpkgs-fmt;
        process-compose.redis-service = { config, ... }: {
          imports = [
            inputs.services-flake.processComposeModules.default
          ];
          services.redis-cluster."cluster1".enable = true;
          services.redis."redis".enable = true;
        };
        haskellProjects.default = {
          basePackages = pkgs.haskell.packages.ghc984;
          autoWire = [ "packages" ];
        };
        packages.default = self'.packages.hedis;
        devShells.default = pkgs.mkShell {
          name = "hedis";
          inputsFrom = [
            config.haskellProjects.default.outputs.devShell
          ];
        };
      };
    };
}

