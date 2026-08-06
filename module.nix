{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nix-bot-config;

  rightsFields = [
    "isAnonymous"
    "canManageChat"
    "canDeleteMessages"
    "canManageVideoChats"
    "canRestrictMembers"
    "canPromoteMembers"
    "canChangeInfo"
    "canInviteUsers"
    "canPostStories"
    "canEditStories"
    "canDeleteStories"
    "canPostMessages"
    "canEditMessages"
    "canPinMessages"
    "canManageTopics"
  ];

  snake =
    name:
    lib.concatStrings (
      map (c: if c == lib.toUpper c && c != lib.toLower c then "_" + lib.toLower c else c) (
        lib.stringToCharacters name
      )
    );

  rightsType = lib.types.submodule {
    options = lib.listToAttrs (
      map (
        f:
        lib.nameValuePair f (
          lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Telegram administrator right ${snake f}.";
          }
        )
      ) rightsFields
    );
  };

  renderRights = r: lib.listToAttrs (map (f: lib.nameValuePair (snake f) r.${f}) rightsFields);

  localizedType = lib.types.attrsOf lib.types.str;

  renderLocalized = v: lib.mapAttrs' (l: s: lib.nameValuePair (if l == "default" then "" else l) s) v;

  scopeType = lib.types.submodule {
    options = {
      type = lib.mkOption {
        type = lib.types.enum [
          "default"
          "all_private_chats"
          "all_group_chats"
          "all_chat_administrators"
          "chat"
          "chat_administrators"
          "chat_member"
        ];
        default = "default";
        description = "Scope type as defined by the Telegram Bot API.";
      };
      chatId = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.int lib.types.str);
        default = null;
        description = "Chat the scope applies to, for chat scopes.";
      };
      userId = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "User the scope applies to, for the chat_member scope.";
      };
    };
  };

  renderScope =
    s:
    {
      type = s.type;
    }
    // lib.optionalAttrs (s.chatId != null) { chat_id = s.chatId; }
    // lib.optionalAttrs (s.userId != null) { user_id = s.userId; };

  commandType = lib.types.submodule {
    options = {
      command = lib.mkOption {
        type = lib.types.str;
        description = "Command name without the leading slash.";
      };
      description = lib.mkOption {
        type = lib.types.str;
        description = "Command description shown to users.";
      };
    };
  };

  commandGroupType = lib.types.submodule {
    options = {
      scope = lib.mkOption {
        type = scopeType;
        default = { };
        description = "Scope these commands apply to.";
      };
      languageCode = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Two-letter language code, or null for the default list.";
      };
      commands = lib.mkOption {
        type = lib.types.listOf commandType;
        description = "Ordered list of commands for this scope and language.";
      };
    };
  };

  menuButtonType = lib.types.submodule {
    options = {
      chatId = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.int lib.types.str);
        default = null;
        description = "Chat the button applies to, or null for the global default.";
      };
      type = lib.mkOption {
        type = lib.types.enum [
          "default"
          "commands"
          "web_app"
        ];
        description = "Menu button type as defined by the Telegram Bot API.";
      };
      text = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Button label, required for web_app buttons.";
      };
      webAppUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Web app URL, required for web_app buttons.";
      };
    };
  };

  renderMenuButton = b: {
    chat_id = b.chatId;
    button = {
      type = b.type;
    }
    // lib.optionalAttrs (b.type == "web_app") {
      text = b.text;
      web_app.url = b.webAppUrl;
    };
  };

  botType = lib.types.submodule (
    { ... }: {
      options = {
        id = lib.mkOption {
          type = lib.types.int;
          description = "Numeric bot id used to look up its token in the tokens file.";
        };
        apiEndpoint = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Bot API endpoint overriding the global one.";
        };
        name = lib.mkOption {
          type = localizedType;
          default = { };
          description = "Bot name per language code, using default for the fallback.";
        };
        description = lib.mkOption {
          type = localizedType;
          default = { };
          description = "Bot description per language code.";
        };
        shortDescription = lib.mkOption {
          type = localizedType;
          default = { };
          description = "Bot short description per language code.";
        };
        commands = lib.mkOption {
          type = lib.types.listOf commandGroupType;
          default = [ ];
          description = "Command lists per scope and language.";
        };
        defaultAdministratorRights = {
          groups = lib.mkOption {
            type = lib.types.nullOr rightsType;
            default = null;
            description = "Default administrator rights in groups and supergroups.";
          };
          channels = lib.mkOption {
            type = lib.types.nullOr rightsType;
            default = null;
            description = "Default administrator rights in channels.";
          };
        };
        menuButton = lib.mkOption {
          type = lib.types.listOf menuButtonType;
          default = [ ];
          description = "Chat menu buttons, globally and per chat.";
        };
      };
    }
  );

  renderBot = key: bot: {
    inherit key;
    inherit (bot) id;
    apiEndpoint = bot.apiEndpoint;
    name = renderLocalized bot.name;
    description = renderLocalized bot.description;
    shortDescription = renderLocalized bot.shortDescription;
    commands = map (g: {
      scope = renderScope g.scope;
      language_code = if g.languageCode == null then "" else g.languageCode;
      commands = map (c: { inherit (c) command description; }) g.commands;
    }) bot.commands;
    administratorRights = {
      groups =
        if bot.defaultAdministratorRights.groups == null then
          null
        else
          renderRights bot.defaultAdministratorRights.groups;
      channels =
        if bot.defaultAdministratorRights.channels == null then
          null
        else
          renderRights bot.defaultAdministratorRights.channels;
    };
    menuButton = map renderMenuButton bot.menuButton;
  };

  configFile = pkgs.writeText "nix-bot-config.json" (
    builtins.toJSON {
      inherit (cfg) tokensFile apiEndpoint;
      bots = lib.mapAttrsToList renderBot cfg.bots;
    }
  );
in
{
  options.services.nix-bot-config = {
    enable = lib.mkEnableOption "declarative Telegram bot configuration";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Package providing the nix-bot-config executable.";
    };

    tokensFile = lib.mkOption {
      type = lib.types.path;
      description = "File holding one full bot token per line, provisioned out of band.";
    };

    apiEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://api.telegram.org";
      description = "Bot API endpoint used for bots that do not override it.";
    };

    bots = lib.mkOption {
      type = lib.types.attrsOf botType;
      default = { };
      description = "Bots to configure, keyed by an arbitrary name.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.flatten (
      lib.mapAttrsToList (
        key: bot:
        map (b: {
          assertion = b.type != "web_app" || (b.text != null && b.webAppUrl != null);
          message = "services.nix-bot-config.bots.${key}: web_app menu buttons require text and webAppUrl";
        }) bot.menuButton
        ++ map (g: {
          assertion =
            (lib.elem g.scope.type [
              "chat"
              "chat_administrators"
              "chat_member"
            ]) == (g.scope.chatId != null);
          message = "services.nix-bot-config.bots.${key}: scope ${g.scope.type} and chatId must be used together";
        }) bot.commands
        ++ map (g: {
          assertion = g.scope.userId == null || g.scope.type == "chat_member";
          message = "services.nix-bot-config.bots.${key}: userId is only valid for the chat_member scope";
        }) bot.commands
      ) cfg.bots
    );

    systemd.services.nix-bot-config = {
      description = "Apply declarative Telegram bot configuration";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ configFile ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe cfg.package} ${configFile}";
      };
    };
  };
}
