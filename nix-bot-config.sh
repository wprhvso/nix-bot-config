# shellcheck shell=bash
config="${1:?usage: nix-bot-config CONFIG_JSON}"

die() {
    printf 'nix-bot-config: %s\n' "$1" >&2
    exit 1
}
log() { printf 'nix-bot-config: %s\n' "$1"; }

[ -r "$config" ] || die "config $config is not readable"

jq -e 'type == "object" and (.tokensFile | type == "string") and (.apiEndpoint | type == "string") and (.bots | type == "array")' "$config" >/dev/null 2>&1 ||
    die "config $config is not a valid nix-bot-config document"

bots=$(jq -c '.bots[]' "$config") || die "config $config could not be read"
tokens_file=$(jq -r '.tokensFile' "$config")
default_endpoint=$(jq -r '.apiEndpoint' "$config")

[ -r "$tokens_file" ] || die "tokens file $tokens_file is not readable"

token_for() {
    local id="$1" line
    line=$(tr -d '\r' <"$tokens_file" | grep -m1 -E "^${id}:" || true)
    [ -n "$line" ] || die "no token for bot id $id in $tokens_file"
    printf '%s' "$line"
}

call() {
    local endpoint="$1" token="$2" method="$3" payload="$4" response ok
    response=$(curl -sS --fail-with-body --connect-timeout 10 --max-time 30 \
        -X POST -H 'Content-Type: application/json' -d "$payload" "$endpoint/bot$token/$method") ||
        die "$key: request to $method failed: $(jq -c '{error_code, description}' <<<"$response" 2>/dev/null || printf '%s' "$response")"
    ok=$(jq -r '.ok // false' <<<"$response")
    [ "$ok" = "true" ] || die "$key: $method returned $(jq -c '{error_code, description}' <<<"$response")"
    jq -c '.result' <<<"$response"
}

same() { [ "$(jq -Sc . <<<"$1")" = "$(jq -Sc . <<<"$2")" ]; }

sync_text_field() {
    local getter="$1" setter="$2" field="$3" label="$4" values="$5" lang desired current
    while IFS= read -r lang; do
        desired=$(jq -r --arg l "$lang" '.[$l]' <<<"$values")
        current=$(call "$endpoint" "$token" "$getter" "$(jq -nc --arg l "$lang" '{language_code: $l}')" |
            jq -r --arg f "$field" '.[$f] // ""')
        [ "$current" = "$desired" ] && continue
        call "$endpoint" "$token" "$setter" \
            "$(jq -nc --arg f "$field" --arg v "$desired" --arg l "$lang" '{($f): $v, language_code: $l}')" >/dev/null
        log "$key: $label updated${lang:+ (${lang})}"
    done < <(jq -r 'keys_unsorted[]' <<<"$values")
}

sync_commands() {
    local entries="$1" entry scope lang desired current
    while IFS= read -r entry; do
        scope=$(jq -c '.scope' <<<"$entry")
        lang=$(jq -r '.language_code' <<<"$entry")
        desired=$(jq -c '.commands' <<<"$entry")
        current=$(call "$endpoint" "$token" getMyCommands \
            "$(jq -nc --argjson s "$scope" --arg l "$lang" '{scope: $s, language_code: $l}')")
        same "$current" "$desired" && continue
        call "$endpoint" "$token" setMyCommands \
            "$(jq -nc --argjson s "$scope" --arg l "$lang" --argjson c "$desired" '{scope: $s, language_code: $l, commands: $c}')" >/dev/null
        log "$key: commands updated for scope $(jq -r '.type' <<<"$scope")${lang:+ (${lang})}"
    done < <(jq -c '.[]' <<<"$entries")
}

sync_rights() {
    local rights="$1" side for_channels desired current
    for side in groups channels; do
        desired=$(jq -c --arg s "$side" '.[$s]' <<<"$rights")
        [ "$desired" = "null" ] && continue
        [ "$side" = channels ] && for_channels=true || for_channels=false
        current=$(call "$endpoint" "$token" getMyDefaultAdministratorRights \
            "$(jq -nc --argjson c "$for_channels" '{for_channels: $c}')")
        same "$current" "$desired" && continue
        call "$endpoint" "$token" setMyDefaultAdministratorRights \
            "$(jq -nc --argjson c "$for_channels" --argjson r "$desired" '{for_channels: $c, rights: $r}')" >/dev/null
        log "$key: default administrator rights updated for $side"
    done
}

sync_menu_button() {
    local entries="$1" entry chat_id desired current where
    while IFS= read -r entry; do
        chat_id=$(jq -c '.chat_id' <<<"$entry")
        desired=$(jq -c '.button' <<<"$entry")
        current=$(call "$endpoint" "$token" getChatMenuButton \
            "$(jq -nc --argjson i "$chat_id" 'if $i == null then {} else {chat_id: $i} end')")
        same "$current" "$desired" && continue
        call "$endpoint" "$token" setChatMenuButton \
            "$(jq -nc --argjson i "$chat_id" --argjson b "$desired" '{menu_button: $b} + (if $i == null then {} else {chat_id: $i} end)')" >/dev/null
        [ "$chat_id" = "null" ] && where="" || where=" for chat $chat_id"
        log "$key: menu button updated$where"
    done < <(jq -c '.[]' <<<"$entries")
}

[ -n "$bots" ] || {
    log "no bots configured"
    exit 0
}

declare -A tokens
while IFS= read -r bot; do
    key=$(jq -r '.key' <<<"$bot")
    tokens["$key"]=$(token_for "$(jq -r '.id' <<<"$bot")")
done <<<"$bots"

while IFS= read -r bot; do
    key=$(jq -r '.key' <<<"$bot")
    endpoint=$(jq -r --arg d "$default_endpoint" '.apiEndpoint // $d' <<<"$bot")
    token="${tokens[$key]}"

    sync_text_field getMyName setMyName name name "$(jq -c '.name // {}' <<<"$bot")"
    sync_text_field getMyDescription setMyDescription description description "$(jq -c '.description // {}' <<<"$bot")"
    sync_text_field getMyShortDescription setMyShortDescription short_description "short description" "$(jq -c '.shortDescription // {}' <<<"$bot")"
    sync_commands "$(jq -c '.commands // []' <<<"$bot")"
    sync_rights "$(jq -c '.administratorRights // {}' <<<"$bot")"
    sync_menu_button "$(jq -c '.menuButton // []' <<<"$bot")"
done <<<"$bots"
