{
  description = "Declarative Telegram bot configuration for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        nix-bot-config = pkgs.writeShellApplication {
          name = "nix-bot-config";
          runtimeInputs = [
            pkgs.curl
            pkgs.jq
          ];
          text = builtins.readFile ./nix-bot-config.sh;
        };
        default = nix-bot-config;
      });

      nixosModules = rec {
        nix-bot-config = { lib, pkgs, ... }: {
          imports = [ ./module.nix ];
          services.nix-bot-config.package =
            lib.mkDefault
              self.packages.${pkgs.stdenv.hostPlatform.system}.nix-bot-config;
        };
        default = nix-bot-config;
      };

      checks = forAllSystems (
        pkgs:
        import ./tests {
          inherit pkgs;
          package = self.packages.${pkgs.stdenv.hostPlatform.system}.nix-bot-config;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
