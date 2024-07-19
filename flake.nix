{
  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    emacs-builtins.url = "github:emacs-twist/emacs-builtins";
  };

  outputs = {flake-parts, ...} @ inputs:
    flake-parts.lib.mkFlake {inherit inputs;} ({flake-parts-lib, ...}: let
      inherit (flake-parts-lib) importApply;
      flakeModules.default = importApply ./flake-module.nix {
        inherit (inputs) emacs-builtins;
      };
    in {
      systems = [];
      flake = {
        inherit flakeModules;

        lib = {
          /*
          Generate `elisp-rice` flake output from inputs.

          Example:
            elisp-rice = inputs.elisp-rice.lib.configFromInputs {
              inherit (inputs) rice-src rice-lock registries systems;
            };
          */
          configFromInputs = {
            rice-src,
            rice-lock,
            registries,
            systems,
          }: let
            cfg = rice-src.elisp-rice;
          in {
            localPackages = cfg.packages;
            extraPackages = cfg.extraPackages or [];
            tests = cfg.tests or {};
            src = rice-src.outPath;
            lockDir = rice-lock.outPath;
            github = {
              systems = import systems;
            };
            registries = registries.lib.registries;
          };
        };
      };
    });
}
