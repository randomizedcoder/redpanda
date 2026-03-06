{
  description = "Redpanda: a Kafka-compatible streaming data platform";

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
    flake-utils.lib.eachSystem
      [
        "x86_64-linux"
        "aarch64-linux"
      ]
      (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

          redpanda = pkgs.callPackage ./nix/redpanda.nix { };

          rpk = pkgs.callPackage ./nix/rpk.nix { };

          bench = import ./nix/bench.nix {
            inherit pkgs flake-utils;
            redpandaDrv = redpanda;
          };
        in
        {
          packages = {
            inherit redpanda rpk;
            default = redpanda;
          };

          apps = bench;

          devShells.default = pkgs.callPackage ./nix/shell.nix { };

          checks = {
            rpk-version = pkgs.runCommand "rpk-version-check" { } ''
              ${rpk}/bin/rpk version
              touch $out
            '';
          };
        }
      );
}
