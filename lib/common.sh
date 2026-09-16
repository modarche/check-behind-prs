#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT_DIR/lib"
LIBEXEC_DIR="$ROOT_DIR/libexec"
PROMPT_DIR="$ROOT_DIR/prompts"
AUTOFIX_PROMPT_FILE="$PROMPT_DIR/pr-autofix.txt"

for dir in "$HOME/.local/bin" "$HOME/go/bin" /usr/local/bin /opt/homebrew/bin; do
	[[ -d "$dir" && ":$PATH:" != *":$dir:"* ]] && PATH="$PATH:$dir"
done
unset dir

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/check-behind-prs"
mkdir -p "$STATE_DIR"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/check-behind-prs"

BEHIND_STATE_FILE="$STATE_DIR/behind.json"
AUTOFIX_STATE_FILE="$STATE_DIR/automation-state.json"
UPDATE_ATTEMPT_FILE="$STATE_DIR/update-branch-attempts.json"
APPROVED_STATE_FILE="$STATE_DIR/approved.json"
APPROVE_LOG_FILE="$STATE_DIR/auto-approve.log"
LOCK_FILE="$STATE_DIR/check-behind-prs.lock"
APPROVE_LOCK_FILE="$STATE_DIR/auto-approve.lock"
STAGE_LOCK_FILE="$STATE_DIR/stage-pr-autofix.lock"

[[ -f "$AUTOFIX_STATE_FILE" ]] || printf '{}\n' > "$AUTOFIX_STATE_FILE"
[[ -f "$UPDATE_ATTEMPT_FILE" ]] || printf '{}\n' > "$UPDATE_ATTEMPT_FILE"
[[ -f "$APPROVED_STATE_FILE" ]] || printf '{}\n' > "$APPROVED_STATE_FILE"

DEV_DIR="${DEV_DIR:-$HOME/dev}"
TMUX_SESSION="pr-autofix"

require_commands() {
	local cmd missing=()
	for cmd in "$@"; do
		command -v "$cmd" > /dev/null 2>&1 || missing+=("$cmd")
	done
	[[ ${#missing[@]} -eq 0 ]] && return 0
	echo "Missing required command(s): ${missing[*]}" >&2
	return 1
}

have_commands() {
	local cmd
	for cmd in "$@"; do
		command -v "$cmd" > /dev/null 2>&1 || return 1
	done
}

repo_dir_for() {
	printf '%s' "$DEV_DIR/${1#*/}"
}

json_update() {
	local file="$1" tmp
	shift
	tmp="$(mktemp "$file.XXXXXX")" || return 1
	if ! jq "$@" "$file" > "$tmp" 2> /dev/null; then
		jq "$@" <<< '{}' > "$tmp" 2> /dev/null || {
			rm -f "$tmp"
			return 1
		}
	fi
	mv "$tmp" "$file"
}
