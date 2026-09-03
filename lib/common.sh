#!/usr/bin/env bash

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/check-behind-prs"
mkdir -p "$STATE_DIR"

BEHIND_STATE_FILE="$STATE_DIR/behind.json"
AUTOFIX_STATE_FILE="$STATE_DIR/automation-state.json"
UPDATE_ATTEMPT_FILE="$STATE_DIR/update-branch-attempts.json"
LOCK_FILE="$STATE_DIR/check-behind-prs.lock"

[[ -f "$AUTOFIX_STATE_FILE" ]] || printf '{}\n' > "$AUTOFIX_STATE_FILE"
[[ -f "$UPDATE_ATTEMPT_FILE" ]] || printf '{}\n' > "$UPDATE_ATTEMPT_FILE"

DEV_DIR="${DEV_DIR:-$HOME/dev}"
TMUX_SESSION="pr-autofix"
