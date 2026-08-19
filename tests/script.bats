start_mock() {
    [ -z "${MOCK_PID:-}" ] || kill "$MOCK_PID" 2>/dev/null || true
    : >"$MOCK_READY"

    python3 "$BATS_TEST_DIRNAME/mock-api.py" 0 &
    MOCK_PID=$!

    local waited=0
    while [ ! -s "$MOCK_READY" ]; do
        sleep 0.05
        waited=$((waited + 1))
        [ "$waited" -lt 200 ] || {
            echo "mock api did not start" >&2
            return 1
        }
    done
    ENDPOINT="http://127.0.0.1:$(cat "$MOCK_READY")"
}

setup() {
    TEST_DIR=$(mktemp -d)
    export MOCK_LOG="$TEST_DIR/calls.log"
    export MOCK_READY="$TEST_DIR/ready"
    : >"$MOCK_LOG"

    start_mock

    TOKENS="$TEST_DIR/tokens"
    printf '111:aaa\n222:bbb\n' >"$TOKENS"
    chmod 600 "$TOKENS"
}

teardown() {
    [ -z "${MOCK_PID:-}" ] || kill "$MOCK_PID" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

write_config() {
    CONFIG="$TEST_DIR/config.json"
    jq -n --arg t "$TOKENS" --arg e "$ENDPOINT" --argjson bots "$1" \
        '{tokensFile: $t, apiEndpoint: $e, bots: $bots}' >"$CONFIG"
}

bot() {
    jq -n --argjson extra "${1:-{\}}" \
        '{key: "main", id: 111, apiEndpoint: null, name: {}, description: {},
          shortDescription: {}, commands: [], menuButton: [],
          administratorRights: {groups: null, channels: null}} + $extra'
}

calls() {
    jq -r 'select(.method | startswith("set")) | .method' "$MOCK_LOG"
}

sent() {
    jq -c --arg m "$1" 'select(.method == $m) | .payload' "$MOCK_LOG"
}

@test "rejects a missing config file" {
    run nix-bot-config "$TEST_DIR/absent.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not readable"* ]]
}

@test "rejects a missing argument" {
    run nix-bot-config
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage:"* ]]
}

@test "rejects an unreadable tokens file" {
    write_config "[$(bot)]"
    jq '.tokensFile = "/nonexistent/tokens"' "$CONFIG" >"$CONFIG.tmp"
    mv "$CONFIG.tmp" "$CONFIG"
    run nix-bot-config "$CONFIG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"tokens file"* ]]
}

@test "fails when a bot id has no token" {
    write_config "[$(bot '{"id": 999}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no token for bot id 999"* ]]
    [ ! -s "$MOCK_LOG" ]
}

@test "does not confuse a bot id with a longer id sharing its prefix" {
    printf '1110:wrong\n111:right\n' >"$TOKENS"
    write_config "[$(bot '{"name": {"": "Bot"}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.token' "$MOCK_LOG" | sort -u)" = "111:right" ]
}

@test "sets name, description and short description" {
    write_config "[$(bot '{"name": {"": "Bot"}, "description": {"": "Long"}, "shortDescription": {"": "Short"}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(calls)" = "setMyName
setMyDescription
setMyShortDescription" ]
    [ "$(sent setMyName)" = '{"name":"Bot","language_code":""}' ]
}

@test "is idempotent across runs" {
    write_config "[$(bot '{"name": {"": "Bot", "ru": "Бот"},
                            "description": {"": "Long"},
                            "shortDescription": {"": "Short"},
                            "commands": [{"scope": {"type": "default"}, "language_code": "", "commands": [{"command": "start", "description": "Start"}]}],
                            "administratorRights": {"groups": {"can_manage_chat": true, "is_anonymous": false}, "channels": null},
                            "menuButton": [{"chat_id": null, "button": {"type": "commands"}}]}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ -n "$(calls)" ]

    : >"$MOCK_LOG"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ -z "$(calls)" ]
}

@test "updates only the fields that drift" {
    write_config "[$(bot '{"name": {"": "Bot"}, "description": {"": "Long"}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]

    : >"$MOCK_LOG"
    write_config "[$(bot '{"name": {"": "Bot"}, "description": {"": "Longer"}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(calls)" = "setMyDescription" ]
}

@test "sets per-language values independently" {
    write_config "[$(bot '{"name": {"": "Bot", "ru": "Бот"}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(sent setMyName | jq -r '.language_code' | sort | tr '\n' ' ')" = " ru " ]
}

@test "sets commands per scope and language" {
    write_config "[$(bot '{"commands": [
        {"scope": {"type": "default"}, "language_code": "", "commands": [{"command": "start", "description": "Start"}]},
        {"scope": {"type": "chat", "chat_id": -100}, "language_code": "ru", "commands": [{"command": "help", "description": "Помощь"}]}]}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(sent setMyCommands | wc -l)" -eq 2 ]
    [ "$(sent setMyCommands | jq -c 'select(.language_code == "ru") | .scope')" = '{"type":"chat","chat_id":-100}' ]
}

@test "preserves command order" {
    write_config "[$(bot '{"commands": [{"scope": {"type": "default"}, "language_code": "", "commands": [
        {"command": "b", "description": "B"}, {"command": "a", "description": "A"}]}]}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(sent setMyCommands | jq -c '[.commands[].command]')" = '["b","a"]' ]

    : >"$MOCK_LOG"
    write_config "[$(bot '{"commands": [{"scope": {"type": "default"}, "language_code": "", "commands": [
        {"command": "a", "description": "A"}, {"command": "b", "description": "B"}]}]}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(calls)" = "setMyCommands" ]
}

@test "clears commands when the desired list is empty" {
    write_config "[$(bot '{"commands": [{"scope": {"type": "default"}, "language_code": "", "commands": [{"command": "a", "description": "A"}]}]}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]

    : >"$MOCK_LOG"
    write_config "[$(bot '{"commands": [{"scope": {"type": "default"}, "language_code": "", "commands": []}]}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(sent setMyCommands | jq -c '.commands')" = '[]' ]
}

@test "sets default administrator rights for both sides" {
    write_config "[$(bot '{"administratorRights": {
        "groups": {"can_manage_chat": true, "is_anonymous": false},
        "channels": {"can_post_messages": true, "is_anonymous": true}}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(sent setMyDefaultAdministratorRights | jq -c '.for_channels' | tr '\n' ' ')" = "false true " ]
}

@test "leaves administrator rights untouched when unset" {
    write_config "[$(bot '{"administratorRights": {"groups": null, "channels": null}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ -z "$(calls)" ]
}

@test "sets the global and per chat menu buttons" {
    write_config "[$(bot '{"menuButton": [
        {"chat_id": null, "button": {"type": "commands"}},
        {"chat_id": 42, "button": {"type": "web_app", "text": "Open", "web_app": {"url": "https://example.com"}}}]}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(sent setChatMenuButton | jq -c 'select(.chat_id == null) | .menu_button')" = '{"type":"commands"}' ]
    [ "$(sent getChatMenuButton | jq -c 'select(has("chat_id") | not)')" = '{}' ]
    [ "$(sent setChatMenuButton | jq -c 'select(.chat_id == 42) | .menu_button.web_app.url')" = '"https://example.com"' ]
}

@test "supports string chat ids" {
    write_config "[$(bot '{"menuButton": [{"chat_id": "@channel", "button": {"type": "commands"}}]}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(sent setChatMenuButton | jq -c '.chat_id')" = '"@channel"' ]
}

@test "configures several bots with their own tokens" {
    write_config "[$(bot '{"key": "one", "id": 111, "name": {"": "One"}}'), $(bot '{"key": "two", "id": 222, "name": {"": "Two"}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(sent setMyName | jq -r '.name' | sort | tr '\n' ' ')" = "One Two " ]
    [ "$(jq -r 'select(.method == "setMyName") | .token' "$MOCK_LOG" | sort | tr '\n' ' ')" = "111:aaa 222:bbb " ]
}

@test "honours a per bot api endpoint override" {
    write_config "[$(bot "{\"apiEndpoint\": \"$ENDPOINT\", \"name\": {\"\": \"Bot\"}}")]"
    jq '.apiEndpoint = "http://127.0.0.1:1"' "$CONFIG" >"$CONFIG.tmp"
    mv "$CONFIG.tmp" "$CONFIG"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(calls)" = "setMyName" ]
}

@test "fails loudly when the api rejects the token" {
    export MOCK_REJECT="111:aaa"
    start_mock

    write_config "[$(bot '{"name": {"": "Bot"}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"401"* ]]
    [[ "$output" == *"Unauthorized"* ]]
}

@test "fails when the endpoint is unreachable" {
    write_config "[$(bot '{"apiEndpoint": "http://127.0.0.1:1", "name": {"": "Bot"}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed"* ]]
}

@test "stops before touching the api when one bot is missing a token" {
    write_config "[$(bot '{"key": "one", "id": 111, "name": {"": "One"}}'), $(bot '{"key": "two", "id": 999, "name": {"": "Two"}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -ne 0 ]
    [ -z "$(calls)" ]
}

@test "fails on a config that is not valid json" {
    CONFIG="$TEST_DIR/config.json"
    printf 'not json at all\n' >"$CONFIG"
    run nix-bot-config "$CONFIG"
    [ "$status" -ne 0 ]
}

@test "fails on a config without a bots list" {
    CONFIG="$TEST_DIR/config.json"
    jq -n --arg t "$TOKENS" --arg e "$ENDPOINT" '{tokensFile: $t, apiEndpoint: $e}' >"$CONFIG"
    run nix-bot-config "$CONFIG"
    [ "$status" -ne 0 ]
}

@test "accepts an empty bots list" {
    write_config "[]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ ! -s "$MOCK_LOG" ]
}

@test "gives up instead of hanging when the api never answers" {
    export MOCK_HANG="getMyName"
    start_mock

    write_config "[$(bot '{"name": {"": "Bot"}}')]"
    run timeout 120 nix-bot-config "$CONFIG"
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
}

@test "reads a tokens file with carriage returns" {
    printf '111:aaa\r\n222:bbb\r\n' >"$TOKENS"
    write_config "[$(bot '{"name": {"": "Bot"}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.token' "$MOCK_LOG" | sort -u)" = "111:aaa" ]
}

@test "keeps multi line values intact" {
    write_config "[$(bot '{"description": {"": "first\nsecond"}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(sent setMyDescription | jq -r '.description')" = "first
second" ]
}

@test "keeps values containing shell and json metacharacters intact" {
    write_config "[$(bot '{"description": {"": "a\"b $(x) `y` \\ z"}}')]"
    run nix-bot-config "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$(sent setMyDescription | jq -r '.description')" = 'a"b $(x) `y` \ z' ]
}
