{ pkgs, package }:

let
  inherit (pkgs) lib;

  script =
    pkgs.runCommand "script-tests"
      {
        nativeBuildInputs = [
          pkgs.bats
          pkgs.jq
          pkgs.python3
          pkgs.curl
          package
        ];
      }
      ''
        cp -r ${./.} suite
        chmod -R u+w suite
        bats --print-output-on-failure suite/script.bats
        touch "$out"
      '';

  e2e = pkgs.testers.runNixOSTest (import ./e2e.nix { inherit package; });
in
lib.mapAttrs' (name: value: lib.nameValuePair "module-${name}" value) (
  import ./module.nix { inherit pkgs; }
)
// {
  inherit script;
}
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux { inherit e2e; }
