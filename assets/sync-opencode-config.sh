#!/bin/bash
# 从 cc-switch 的 Claude 配置生成 OpenCode 配置。
set -u

if [ "${1:-}" = "--install-wrappers" ]; then
    bash_profile=/etc/profile.d/07-opencode-config.sh
    fish_config="$HOME/.config/fish/config.fish"
    if [ -f "$bash_profile" ]; then
        sudo sed -i '/^opencode() {$/,/^}$/c\opencode() {\n    "$HOME/.local/bin/cc-sync-opencode-config"\n    command opencode "$@"\n}' "$bash_profile" || exit 1
    fi
    if [ -f "$fish_config" ]; then
        sed -i '/^function opencode$/,/^end$/c\function opencode\n    "$HOME/.local/bin/cc-sync-opencode-config"\n    command opencode $argv\nend' "$fish_config" || exit 1
    fi
    exit 0
fi

settings="$HOME/.claude-host/settings.json"
[ -f "$settings" ] || exit 0

base_url=$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$settings" 2>/dev/null)
api_key=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // .env.ANTHROPIC_API_KEY // empty' "$settings" 2>/dev/null)
[ -n "$base_url" ] && [ -n "$api_key" ] || exit 0

# @ai-sdk/anthropic 会追加 /messages，而 Claude Code 会追加 /v1/messages。
case "$base_url" in
    */v1) ;;
    */) base_url="${base_url}v1" ;;
    *) base_url="${base_url}/v1" ;;
esac

mkdir -p "$HOME/.config/opencode"
jq -n --arg b "$base_url" --arg k "$api_key" --rawfile cfg "$settings" '
    ($cfg | fromjson) as $c
    | ($c.env // {}) as $e
    | def actual($name; $route):
        if ($name // "") != "" then $name else ($route // "") end;
    (if $c.model == "opus" then actual($e.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME; $e.ANTHROPIC_DEFAULT_OPUS_MODEL)
       elif $c.model == "haiku" then actual($e.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME; $e.ANTHROPIC_DEFAULT_HAIKU_MODEL)
       elif $c.model == "fable" then actual($e.ANTHROPIC_DEFAULT_FABLE_MODEL_NAME; $e.ANTHROPIC_DEFAULT_FABLE_MODEL)
       else actual($e.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME; $e.ANTHROPIC_DEFAULT_SONNET_MODEL)
       end) as $selected
    | (if $selected == "" then actual($e.ANTHROPIC_MODEL_NAME; $e.ANTHROPIC_MODEL) else $selected end) as $configured
    | (if $configured == "" then "claude-sonnet-4-5" else $configured end) as $dflt
    | [ actual($e.ANTHROPIC_MODEL_NAME; $e.ANTHROPIC_MODEL),
        actual($e.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME; $e.ANTHROPIC_DEFAULT_OPUS_MODEL),
        actual($e.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME; $e.ANTHROPIC_DEFAULT_SONNET_MODEL),
        actual($e.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME; $e.ANTHROPIC_DEFAULT_HAIKU_MODEL),
        actual($e.ANTHROPIC_DEFAULT_FABLE_MODEL_NAME; $e.ANTHROPIC_DEFAULT_FABLE_MODEL),
        $dflt ]
      | map(select(. != "")) | unique
      | map({ key: ., value: { name: . } }) | from_entries
      | {
          "$schema": "https://opencode.ai/config.json",
          "permission": { "*": "allow" },
          "provider": {
              "cc-switch": {
                  "npm": "@ai-sdk/anthropic",
                  "options": { "baseURL": $b, "apiKey": $k },
                  "models": .
              }
          },
          "model": ("cc-switch/" + $dflt)
        }
' > "$HOME/.config/opencode/opencode.json.tmp" || exit 1
mv "$HOME/.config/opencode/opencode.json.tmp" "$HOME/.config/opencode/opencode.json"
