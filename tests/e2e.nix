{ package }:

{ lib, pkgs, ... }:

{
  name = "nix-bot-config";

  nodes.machine = {
    imports = [ ../module.nix ];

    systemd.services.mock-api = {
      description = "Fake Telegram Bot API";
      wantedBy = [ "multi-user.target" ];
      before = [ "nix-bot-config.service" ];
      environment = {
        MOCK_LOG = "/var/lib/mock-api/calls.log";
        MOCK_READY = "/run/mock-api.ready";
      };
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.python3} ${./mock-api.py} 8080";
        StateDirectory = "mock-api";
        Restart = "on-failure";
      };
    };

    systemd.services.nix-bot-config = {
      after = [ "mock-api.service" ];
      requires = [ "mock-api.service" ];
    };

    environment.etc."bot-tokens".text = ''
      111:secret-token-aaa
      222:secret-token-bbb
    '';

    services.nix-bot-config = {
      enable = true;
      inherit package;
      tokensFile = "/etc/bot-tokens";
      apiEndpoint = "http://127.0.0.1:8080";
      bots = {
        first = {
          id = 111;
          name.default = "First";
          description.default = "First bot";
          shortDescription.ru = "Первый";
          commands = [
            {
              commands = [
                {
                  command = "start";
                  description = "Start";
                }
              ];
            }
          ];
          defaultAdministratorRights.groups.canManageChat = true;
          menuButton = [ { type = "commands"; } ];
        };
        second = {
          id = 222;
          name.default = "Second";
        };
      };
    };
  };

  testScript = ''
    machine.wait_for_unit("mock-api.service")
    machine.wait_for_open_port(8080)
    machine.wait_for_unit("nix-bot-config.service")

    calls = machine.succeed("cat /var/lib/mock-api/calls.log")
    for method in [
        "setMyName",
        "setMyDescription",
        "setMyShortDescription",
        "setMyCommands",
        "setMyDefaultAdministratorRights",
        "setChatMenuButton",
    ]:
        assert method in calls, f"{method} was never called: {calls}"
    assert '"First"' in calls and '"Second"' in calls

    machine.succeed("truncate -s 0 /var/lib/mock-api/calls.log")
    machine.succeed("systemctl restart nix-bot-config.service")
    machine.wait_for_unit("nix-bot-config.service")
    again = machine.succeed("cat /var/lib/mock-api/calls.log")
    assert '"method": "set' not in again, f"second run was not idempotent: {again}"

    journal = machine.succeed("journalctl -u nix-bot-config.service --no-pager")
    assert "secret-token" not in journal, "the bot token leaked into the journal"
  '';
}
