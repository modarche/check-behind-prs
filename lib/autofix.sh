#!/usr/bin/env bash

CLAUDE_TRAILER='Co-Authored-By: Claude <noreply@anthropic.com>'

AUTOFIX_DENY_TOOLS=(
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

autofix_claude_cmd() {
	local IFS=,
	printf "claude --model %s --disallowedTools '%s'" "${AUTOFIX_MODEL:-sonnet}" "${AUTOFIX_DENY_TOOLS[*]}"
}

autofix_available() {
	[[ "${AUTOFIX_DISABLED:-}" != "1" ]] && have_commands tmux claude
}

autofix_window_exists() {
	tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2> /dev/null | grep -qxF "$1"
}

autofix_reap_windows() {
	local repo entry window_name head_ref head_sha_before repo_dir current_sha commit_msg

	while IFS= read -r repo; do
		[[ -n "$repo" ]] || continue
		entry="$(jq -c --arg repo "$repo" '.[$repo]' "$AUTOFIX_STATE_FILE")"
		window_name="$(jq -r '.windowName' <<< "$entry")"
		head_ref="$(jq -r '.headRef' <<< "$entry")"
		head_sha_before="$(jq -r '.headShaBefore' <<< "$entry")"
		repo_dir="$(repo_dir_for "$repo")"

		if ! autofix_window_exists "$window_name"; then
			json_update "$AUTOFIX_STATE_FILE" --arg repo "$repo" 'del(.[$repo])'
			continue
		fi

		current_sha="$(git -C "$repo_dir" ls-remote origin "refs/heads/$head_ref" 2> /dev/null | cut -f1 || true)"
		[[ -n "$current_sha" && "$current_sha" != "$head_sha_before" ]] || continue

		commit_msg=""
		if git -C "$repo_dir" fetch origin "refs/heads/$head_ref" > /dev/null 2>&1; then
			commit_msg="$(git -C "$repo_dir" log -1 --format=%B "$current_sha" 2> /dev/null || true)"
		fi

		if grep -qF "$CLAUDE_TRAILER" <<< "$commit_msg"; then
			(sleep 5 && tmux kill-window -t "$TMUX_SESSION:$window_name" > /dev/null 2>&1) &
			disown 2> /dev/null || true
			json_update "$AUTOFIX_STATE_FILE" --arg repo "$repo" 'del(.[$repo])'
		else
			json_update "$AUTOFIX_STATE_FILE" --arg repo "$repo" --arg sha "$current_sha" '.[$repo].headShaBefore = $sha'
		fi
	done < <(jq -r 'keys[]' "$AUTOFIX_STATE_FILE" 2> /dev/null || true)
}

autofix_stage_conflicted() {
	local stuck_json="$1"
	local eligible_json pr repo owner short_repo url pr_number base_ref head_ref title

	eligible_json="$(jq -c '[.[] | select(.isDraft == false and .isCrossRepository == false and .mergeStateStatus == "DIRTY")] | group_by(.repo) | map(.[0])' <<< "$stuck_json")"

	while IFS= read -r pr; do
		[[ -n "$pr" && "$pr" != "null" ]] || continue
		repo="$(jq -r '.repo' <<< "$pr")"

		jq -e --arg repo "$repo" 'has($repo)' "$AUTOFIX_STATE_FILE" > /dev/null 2>&1 && continue

		owner="${repo%%/*}"
		short_repo="${repo#*/}"
		url="$(jq -r '.url' <<< "$pr")"
		pr_number="$(pr_number_from_url "$url")"
		base_ref="$(jq -r '.baseRefName' <<< "$pr")"
		head_ref="$(jq -r '.headRefName' <<< "$pr")"
		title="$(jq -r '.title' <<< "$pr")"

		"$LIBEXEC_DIR/stage-pr-autofix" \
			"$owner" "$short_repo" "$pr_number" "$base_ref" "$head_ref" "$url" "$title" < /dev/null || true
	done < <(jq -c '.[]' <<< "$eligible_json")
}
