#!/usr/bin/env bash
# Claude Code status line — shows container mode, context usage, and working directory.

input=$(cat)

# Current working directory
cwd=$(echo "$input" | jq -r '.workspace.current_dir')

# Context window info
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // empty')
output_tokens=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // empty')

# Container indicator
if [ "${CLAUDE_MODE}" = "persistent" ]; then
  container_label=" [persistent: $(hostname)]"
elif [ "${CLAUDE_MODE}" = "temp" ]; then
  container_label=" [temp-container]"
elif [ "${DEVCONTAINER}" = "true" ]; then
  container_label=" [vs-container]"
else
  container_label=""
fi

# Build token usage string
if [ -n "$remaining" ] && [ -n "$input_tokens" ] && [ -n "$output_tokens" ]; then
  token_info=$(printf "%.0f%% ctx remaining | in: %s out: %s" "$remaining" "$input_tokens" "$output_tokens")
elif [ -n "$remaining" ]; then
  token_info=$(printf "%.0f%% ctx remaining" "$remaining")
else
  token_info=""
fi

# Compose status line
if [ -n "$token_info" ]; then
  printf "%s%s | %s" "$cwd" "$container_label" "$token_info"
else
  printf "%s%s" "$cwd" "$container_label"
fi
