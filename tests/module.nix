{ pkgs }:

let
  inherit (pkgs) lib;

  stub =
    { lib, ... }:
    {
      options.assertions = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [ ];
      };
      options.systemd.services = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.unspecified);
        default = { };
      };
    };

  evalConfig =
    module:
    (lib.evalModules {
      modules = [
        ../module.nix
        stub
        module
      ];
      specialArgs = { inherit pkgs; };
    }).config;

  base = {
    services.nix-bot-config = {
      enable = true;
      package = pkgs.hello;
      tokensFile = "/run/secrets/bot-tokens";
    };
  };

  configPath =
    module:
    lib.last (
      lib.splitString " " (evalConfig module).systemd.services.nix-bot-config.serviceConfig.ExecStart
    );

  failures =
    module: map (a: a.message) (builtins.filter (a: !a.assertion) (evalConfig module).assertions);

  renders =
    name: module: expected:
    pkgs.runCommand "render-${name}"
      {
        nativeBuildInputs = [ pkgs.jq ];
        actual = configPath module;
        expected = builtins.toFile "expected-${name}.json" (builtins.toJSON expected);
      }
      ''
        diff <(jq -S . "$actual") <(jq -S . "$expected")
        touch "$out"
      '';

  asserts =
    name: module: expected:
    pkgs.runCommand "assert-${name}"
      {
        actual = builtins.toJSON (failures module);
        expected = builtins.toJSON expected;
      }
      ''
        [ "$actual" = "$expected" ] || {
          printf 'actual:   %s\nexpected: %s\n' "$actual" "$expected" >&2
          exit 1
        }
        touch "$out"
      '';

  minimalBot = lib.recursiveUpdate base {
    services.nix-bot-config.bots.main.id = 111;
  };

  fullBot = lib.recursiveUpdate base {
    services.nix-bot-config.apiEndpoint = "https://global.example";
    services.nix-bot-config.bots.main = {
      id = 111;
      apiEndpoint = "https://bot.example";
      name = {
        default = "Bot";
        ru = "Бот";
      };
      description.default = "Long";
      shortDescription.ru = "Кратко";
      commands = [
        {
          commands = [
            {
              command = "start";
              description = "Start";
            }
          ];
        }
        {
          scope = {
            type = "chat_member";
            chatId = -100;
            userId = 7;
          };
          languageCode = "ru";
          commands = [
            {
              command = "help";
              description = "Помощь";
            }
          ];
        }
      ];
      defaultAdministratorRights.groups = {
        canManageChat = true;
        isAnonymous = true;
      };
      menuButton = [
        { type = "commands"; }
        {
          chatId = "@channel";
          type = "web_app";
          text = "Open";
          webAppUrl = "https://example.com";
        }
      ];
    };
  };

  allRights =
    enabled:
    {
      is_anonymous = false;
      can_manage_chat = false;
      can_delete_messages = false;
      can_manage_video_chats = false;
      can_restrict_members = false;
      can_promote_members = false;
      can_change_info = false;
      can_invite_users = false;
      can_post_stories = false;
      can_edit_stories = false;
      can_delete_stories = false;
      can_post_messages = false;
      can_edit_messages = false;
      can_pin_messages = false;
      can_manage_topics = false;
    }
    // enabled;
in
{
  render-minimal = renders "minimal" minimalBot {
    tokensFile = "/run/secrets/bot-tokens";
    apiEndpoint = "https://api.telegram.org";
    bots = [
      {
        key = "main";
        id = 111;
        apiEndpoint = null;
        name = { };
        description = { };
        shortDescription = { };
        commands = [ ];
        administratorRights = {
          groups = null;
          channels = null;
        };
        menuButton = [ ];
      }
    ];
  };

  render-full = renders "full" fullBot {
    tokensFile = "/run/secrets/bot-tokens";
    apiEndpoint = "https://global.example";
    bots = [
      {
        key = "main";
        id = 111;
        apiEndpoint = "https://bot.example";
        name = {
          "" = "Bot";
          ru = "Бот";
        };
        description."" = "Long";
        shortDescription.ru = "Кратко";
        commands = [
          {
            scope.type = "default";
            language_code = "";
            commands = [
              {
                command = "start";
                description = "Start";
              }
            ];
          }
          {
            scope = {
              type = "chat_member";
              chat_id = -100;
              user_id = 7;
            };
            language_code = "ru";
            commands = [
              {
                command = "help";
                description = "Помощь";
              }
            ];
          }
        ];
        administratorRights = {
          groups = allRights {
            can_manage_chat = true;
            is_anonymous = true;
          };
          channels = null;
        };
        menuButton = [
          {
            chat_id = null;
            button.type = "commands";
          }
          {
            chat_id = "@channel";
            button = {
              type = "web_app";
              text = "Open";
              web_app.url = "https://example.com";
            };
          }
        ];
      }
    ];
  };

  assert-clean = asserts "clean" fullBot [ ];

  assert-web-app-needs-text = asserts "web-app-needs-text" (lib.recursiveUpdate base {
    services.nix-bot-config.bots.main = {
      id = 111;
      menuButton = [
        {
          type = "web_app";
          webAppUrl = "https://example.com";
        }
      ];
    };
  }) [ "services.nix-bot-config.bots.main: web_app menu buttons require text and webAppUrl" ];

  assert-chat-scope-needs-chat-id = asserts "chat-scope-needs-chat-id" (lib.recursiveUpdate base {
    services.nix-bot-config.bots.main = {
      id = 111;
      commands = [
        {
          scope.type = "chat";
          commands = [ ];
        }
      ];
    };
  }) [ "services.nix-bot-config.bots.main: scope chat and chatId must be used together" ];

  assert-chat-id-needs-chat-scope = asserts "chat-id-needs-chat-scope" (lib.recursiveUpdate base {
    services.nix-bot-config.bots.main = {
      id = 111;
      commands = [
        {
          scope = {
            type = "default";
            chatId = 5;
          };
          commands = [ ];
        }
      ];
    };
  }) [ "services.nix-bot-config.bots.main: scope default and chatId must be used together" ];

  assert-user-id-needs-chat-member = asserts "user-id-needs-chat-member" (lib.recursiveUpdate base {
    services.nix-bot-config.bots.main = {
      id = 111;
      commands = [
        {
          scope = {
            type = "chat";
            chatId = 5;
            userId = 7;
          };
          commands = [ ];
        }
      ];
    };
  }) [ "services.nix-bot-config.bots.main: userId is only valid for the chat_member scope" ];

  assert-disabled-is-inert = asserts "disabled-is-inert" {
    services.nix-bot-config = {
      package = pkgs.hello;
      tokensFile = "/run/secrets/bot-tokens";
      bots.main = {
        id = 111;
        menuButton = [ { type = "web_app"; } ];
      };
    };
  } [ ];
}
