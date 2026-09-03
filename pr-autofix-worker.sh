#!/usr/bin/env bash
set -euo pipefail

owner="$1"
repo="$2"
pr_number="$3"
base_ref="$4"
head_ref="$5"
pr_url="$6"
pr_title="$7"

exec 200>&- 2> /dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

for cmd in git jq tmux claude; do
	command -v "$cmd" > /dev/null 2>&1 || exit 0
done

[[ -f "$SCRIPT_DIR/pr-autofix-prompt.txt" ]] || exit 0

repo_dir="$DEV_DIR/$repo"
window_name="${repo}-pr${pr_number}"
state_key="$owner/$repo"

git -C "$repo_dir" rev-parse --git-dir > /dev/null 2>&1 || exit 0

origin_url="$(git -C "$repo_dir" remote get-url origin 2> /dev/null || true)"
case "$origin_url" in
	*"$owner/$repo" | *"$owner/$repo.git") ;;
	*) exit 0 ;;
esac

head_sha_before="$(git -C "$repo_dir" ls-remote origin "refs/heads/$head_ref" 2> /dev/null | cut -f1 || true)"
[[ -n "$head_sha_before" ]] || exit 0

if jq -e --arg repo "$state_key" 'has($repo)' "$AUTOFIX_STATE_FILE" > /dev/null 2>&1; then
	exit 0
fi

existing_windows="$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2> /dev/null || true)"
while IFS= read -r existing; do
	[[ -n "$existing" ]] || continue
	[[ "$existing" == "${repo}-pr"* ]] && exit 0
done <<< "$existing_windows"

build_prompt() {
	local tmpl
	tmpl="$(cat "$SCRIPT_DIR/pr-autofix-prompt.txt")"
	tmpl="${tmpl//\{\{OWNER\}\}/$owner}"
	tmpl="${tmpl//\{\{REPO\}\}/$repo}"
	tmpl="${tmpl//\{\{PR_NUMBER\}\}/$pr_number}"
	tmpl="${tmpl//\{\{PR_TITLE\}\}/$pr_title}"
	tmpl="${tmpl//\{\{PR_URL\}\}/$pr_url}"
	tmpl="${tmpl//\{\{BASE_REF\}\}/$base_ref}"
	tmpl="${tmpl//\{\{HEAD_REF\}\}/$head_ref}"
	tmpl="${tmpl//\{\{REPO_DIR\}\}/$repo_dir}"
	printf '%s' "$tmpl"
}

write_state() {
	jq --arg repo "$state_key" \
		--argjson prNumber "$pr_number" \
		--arg headRef "$head_ref" \
		--arg baseRef "$base_ref" \
		--arg windowName "$window_name" \
		--arg headShaBefore "$head_sha_before" \
		--arg startedAt "$(date -u +%FT%TZ)" \
		'.[$repo] = {prNumber: $prNumber, headRef: $headRef, baseRef: $baseRef, windowName: $windowName, headShaBefore: $headShaBefore, startedAt: $startedAt}' \
		"$AUTOFIX_STATE_FILE" > "$AUTOFIX_STATE_FILE.tmp" && mv "$AUTOFIX_STATE_FILE.tmp" "$AUTOFIX_STATE_FILE"
}

clear_state() {
	jq --arg repo "$state_key" 'del(.[$repo])' "$AUTOFIX_STATE_FILE" > "$AUTOFIX_STATE_FILE.tmp" \
		&& mv "$AUTOFIX_STATE_FILE.tmp" "$AUTOFIX_STATE_FILE"
}

deny_force_push=(
	'Bash(git push --force)'
	'Bash(git push --force *)'
	'Bash(git push -f)'
	'Bash(git push -f *)'
	'Bash(git push --force-with-lease)'
	'Bash(git push --force-with-lease *)'
	'Bash(git push --force-with-lease=*)'
	'Bash(git push --force-if-includes)'
	'Bash(git push --force-if-includes *)'
)
deny_list="$(
	IFS=,
	printf '%s' "${deny_force_push[*]}"
)"

claude_cmd="claude --model sonnet --disallowedTools '$deny_list'"

if tmux has-session -t "$TMUX_SESSION" 2> /dev/null; then
	tmux new-window -t "$TMUX_SESSION" -n "$window_name" -c "$repo_dir" "$claude_cmd"
else
	tmux new-session -d -s "$TMUX_SESSION" -n "$window_name" -c "$repo_dir" "$claude_cmd"
fi

write_state

claude_ready=false
for _ in $(seq 1 60); do
	pane="$(tmux capture-pane -p -t "$TMUX_SESSION:$window_name" 2> /dev/null || true)"
	if grep -qF 'Claude Code v' <<< "$pane"; then
		claude_ready=true
		break
	fi
	sleep 1
done

if [[ "$claude_ready" != "true" ]]; then
	clear_state
	tmux kill-window -t "$TMUX_SESSION:$window_name" > /dev/null 2>&1 || true
	exit 0
fi

prompt_buffer="pr-autofix-prompt-$window_name"
tmux set-buffer -b "$prompt_buffer" -- "$(build_prompt)"
tmux paste-buffer -b "$prompt_buffer" -t "$TMUX_SESSION:$window_name"
tmux delete-buffer -b "$prompt_buffer" > /dev/null 2>&1 || true
