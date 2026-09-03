#!/usr/bin/env bash

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

[[ -f "$AUTOFIX_STATE_FILE" ]] || printf '{}\n' > "$AUTOFIX_STATE_FILE"
[[ -f "$UPDATE_ATTEMPT_FILE" ]] || printf '{}\n' > "$UPDATE_ATTEMPT_FILE"
[[ -f "$APPROVED_STATE_FILE" ]] || printf '{}\n' > "$APPROVED_STATE_FILE"

DEV_DIR="${DEV_DIR:-$HOME/dev}"
TMUX_SESSION="pr-autofix"
