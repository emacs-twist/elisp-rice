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
      };
    });
}
