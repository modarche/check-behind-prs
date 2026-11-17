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
AUTOFIX_RUNS_FILE="$STATE_DIR/autofix-runs.json"
AUTOFIX_SKIPS_FILE="$STATE_DIR/autofix-skips.json"
AUTOFIX_RUNS_DIR="$STATE_DIR/runs"
AUTOFIX_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/check-behind-prs"
UPDATE_ATTEMPT_FILE="$STATE_DIR/update-branch-attempts.json"
UPDATE_REFUSED_FILE="$STATE_DIR/update-branch-refused.json"
APPROVED_STATE_FILE="$STATE_DIR/approved.json"
APPROVE_LOG_FILE="$STATE_DIR/auto-approve.log"
LOCK_FILE="$STATE_DIR/check-behind-prs.lock"
APPROVE_LOCK_FILE="$STATE_DIR/auto-approve.lock"
STAGE_LOCK_FILE="$STATE_DIR/stage-pr-autofix.lock"

[[ -f "$AUTOFIX_RUNS_FILE" ]] || printf '{}\n' > "$AUTOFIX_RUNS_FILE"
[[ -f "$AUTOFIX_SKIPS_FILE" ]] || printf '{}\n' > "$AUTOFIX_SKIPS_FILE"
[[ -f "$UPDATE_ATTEMPT_FILE" ]] || printf '{}\n' > "$UPDATE_ATTEMPT_FILE"
[[ -f "$UPDATE_REFUSED_FILE" ]] || printf '{}\n' > "$UPDATE_REFUSED_FILE"
[[ -f "$APPROVED_STATE_FILE" ]] || printf '{}\n' > "$APPROVED_STATE_FILE"

DEV_DIR="${DEV_DIR:-$HOME/dev}"
TMUX_SESSION="pr-autofix"

AUTOFIX_WORKTREE_ROOT="${AUTOFIX_WORKTREE_ROOT:-$DEV_DIR/.pr-autofix}"
AUTOFIX_MAX_RUNS="${AUTOFIX_MAX_RUNS:-3}"
AUTOFIX_SIDECARS="${AUTOFIX_SIDECARS:-mysql mysql-test localredis}"
AUTOFIX_STALE_MINUTES="${AUTOFIX_STALE_MINUTES:-180}"

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
