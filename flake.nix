{
  description = "AI function-generation plugin for Neovim, packaged as a Nix flake";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        plugin = pkgs.vimUtils.buildVimPlugin {
          pname = "vim-module";
          version = "0.1.0";
          src = self;   # git-tracked files only; .planning is gitignored -> never in the store
        };
      in {
        packages.default = plugin;
        checks.default = plugin;   # so `nix flake check` also builds -> runs the require-check
      }
    )
    // {
      homeManagerModules.default = import ./home-manager.nix { inherit self; };
    };
}
