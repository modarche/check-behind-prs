#!/usr/bin/env bash
set -euo pipefail

for cmd in gh jq; do
	command -v "$cmd" > /dev/null 2>&1 || {
		echo "Missing required command: $cmd" >&2
		exit 1
	}
done

if [[ "$(uname -s)" != "Darwin" ]]; then
	command -v notify-send > /dev/null 2>&1 || {
		echo "Missing required command: notify-send" >&2
		exit 1
	}
	command -v xdg-open > /dev/null 2>&1 || {
		echo "Missing required command: xdg-open" >&2
		exit 1
	}
fi

PATH="$PATH:$HOME/.local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/notify.sh"

if command -v flock > /dev/null 2>&1; then
	exec 200> "$LOCK_FILE"
	flock -n 200 || exit 0
fi

AUTOFIX_ENABLED=true
if [[ "${AUTOFIX_DISABLED:-}" == "1" ]]; then
	AUTOFIX_ENABLED=false
elif ! command -v tmux > /dev/null 2>&1 || ! command -v claude > /dev/null 2>&1; then
	AUTOFIX_ENABLED=false
fi

query='
  query($endCursor: String) {
    viewer {
      pullRequests(
        first: 100
        after: $endCursor
        states: OPEN
        orderBy: { field: CREATED_AT, direction: DESC }
      ) {
        nodes {
          title
          url
          mergeStateStatus
          mergeable
          baseRefName
          headRefName
          headRefOid
          isDraft
          isCrossRepository
          repository {
            nameWithOwner
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
'

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT
printf '[]\n' > "$tmp_file"

cursor="null"
while :; do
	response="$(
		gh api graphql \
			-f query="$query" \
			-F endCursor="$cursor"
	)"

	jq -c '
    .data.viewer.pullRequests.nodes[]
    | select(.mergeStateStatus == "BEHIND" or (.mergeStateStatus == "DIRTY" and .mergeable == "CONFLICTING"))
    | {
        key: (.repository.nameWithOwner + "|" + .url),
        repo: .repository.nameWithOwner,
        title,
        url,
        mergeStateStatus,
        baseRefName,
        headRefName,
        headRefOid,
        isDraft,
        isCrossRepository
      }
  ' <<< "$response" >> "$tmp_file"

	has_next="$(jq -r '.data.viewer.pullRequests.pageInfo.hasNextPage' <<< "$response")"
	[[ "$has_next" == "true" ]] || break

	end_cursor="$(jq -r '.data.viewer.pullRequests.pageInfo.endCursor' <<< "$response")"
	cursor="$end_cursor"
done

current_json="$(jq -s 'map(select(type == "object"))' "$tmp_file")"
current_keys="$(jq -r '.[].key' <<< "$current_json" | sort -u)"

if [[ -f "$BEHIND_STATE_FILE" ]]; then
	previous_keys="$(jq -r '.[]' "$BEHIND_STATE_FILE" 2> /dev/null | sort -u || true)"
else
	previous_keys=""
fi

new_keys="$(comm -13 <(printf '%s\n' "$previous_keys") <(printf '%s\n' "$current_keys"))"

if [[ -n "$new_keys" ]]; then
	while IFS= read -r key; do
		[[ -n "$key" ]] || continue
		pr="$(jq -r --arg key "$key" '.[] | select(.key == $key)' <<< "$current_json")"
		repo="$(jq -r '.repo' <<< "$pr")"
		title="$(jq -r '.title' <<< "$pr")"
		url="$(jq -r '.url' <<< "$pr")"
		merge_state="$(jq -r '.mergeStateStatus' <<< "$pr")"

		notif_title="GitHub PR behind base"
		[[ "$merge_state" == "DIRTY" ]] && notif_title="GitHub PR behind base (conflicts)"
		send_notification "$notif_title" "$title
$repo" "$url"
	done <<< "$new_keys"
fi

jq -r '.[].key' <<< "$current_json" | sort -u | jq -R . | jq -s . > "$BEHIND_STATE_FILE"

if [[ "$AUTOFIX_ENABLED" == "true" ]]; then
	autofix_repos="$(jq -r 'keys[]' "$AUTOFIX_STATE_FILE" 2> /dev/null || true)"
	if [[ -n "$autofix_repos" ]]; then
		while IFS= read -r repo; do
			[[ -n "$repo" ]] || continue
			entry="$(jq -c --arg repo "$repo" '.[$repo]' "$AUTOFIX_STATE_FILE")"
			window_name="$(jq -r '.windowName' <<< "$entry")"
			head_ref="$(jq -r '.headRef' <<< "$entry")"
			head_sha_before="$(jq -r '.headShaBefore' <<< "$entry")"
			repo_dir="$DEV_DIR/${repo#*/}"

			window_alive="false"
			tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2> /dev/null | grep -qxF "$window_name" && window_alive="true"

			current_sha="$(git -C "$repo_dir" ls-remote origin "refs/heads/$head_ref" 2> /dev/null | cut -f1 || true)"

			if [[ "$window_alive" == "false" ]]; then
				jq --arg repo "$repo" 'del(.[$repo])' "$AUTOFIX_STATE_FILE" > "$AUTOFIX_STATE_FILE.tmp" && mv "$AUTOFIX_STATE_FILE.tmp" "$AUTOFIX_STATE_FILE"
			elif [[ -n "$current_sha" && "$current_sha" != "$head_sha_before" ]]; then
				pushed_by_claude="false"
				if git -C "$repo_dir" fetch origin "refs/heads/$head_ref" > /dev/null 2>&1; then
					commit_msg="$(git -C "$repo_dir" log -1 --format=%B "$current_sha" 2> /dev/null || true)"
					grep -qF 'Co-Authored-By: Claude <noreply@anthropic.com>' <<< "$commit_msg" && pushed_by_claude="true"
				fi

				if [[ "$pushed_by_claude" == "true" ]]; then
					(sleep 5 && tmux kill-window -t "$TMUX_SESSION:$window_name" > /dev/null 2>&1) &
					disown 2> /dev/null || true
					jq --arg repo "$repo" 'del(.[$repo])' "$AUTOFIX_STATE_FILE" > "$AUTOFIX_STATE_FILE.tmp" && mv "$AUTOFIX_STATE_FILE.tmp" "$AUTOFIX_STATE_FILE"
				else
					jq --arg repo "$repo" --arg sha "$current_sha" '.[$repo].headShaBefore = $sha' "$AUTOFIX_STATE_FILE" > "$AUTOFIX_STATE_FILE.tmp" && mv "$AUTOFIX_STATE_FILE.tmp" "$AUTOFIX_STATE_FILE"
				fi
			fi
		done <<< "$autofix_repos"
	fi

	eligible_json="$(jq -c '[.[] | select(.isDraft == false and .isCrossRepository == false and .mergeStateStatus == "DIRTY")] | group_by(.repo) | map(.[0])' <<< "$current_json")"

	while IFS= read -r pr; do
		[[ -n "$pr" && "$pr" != "null" ]] || continue
		repo="$(jq -r '.repo' <<< "$pr")"

		jq -e --arg repo "$repo" 'has($repo)' "$AUTOFIX_STATE_FILE" > /dev/null 2>&1 && continue

		owner="${repo%%/*}"
		short_repo="${repo#*/}"
		url="$(jq -r '.url' <<< "$pr")"
		pr_number="${url##*/}"
		base_ref="$(jq -r '.baseRefName' <<< "$pr")"
		head_ref="$(jq -r '.headRefName' <<< "$pr")"
		title="$(jq -r '.title' <<< "$pr")"

		"$SCRIPT_DIR/pr-autofix-worker.sh" "$owner" "$short_repo" "$pr_number" "$base_ref" "$head_ref" "$url" "$title" < /dev/null || true
	done < <(jq -c '.[]' <<< "$eligible_json")
fi

if [[ "${AUTOUPDATE_DISABLED:-}" != "1" ]]; then
	behind_json="$(jq -c '[.[] | select(.isDraft == false and .isCrossRepository == false and .mergeStateStatus == "BEHIND")]' <<< "$current_json")"

	while IFS= read -r pr; do
		[[ -n "$pr" && "$pr" != "null" ]] || continue
		repo="$(jq -r '.repo' <<< "$pr")"
		url="$(jq -r '.url' <<< "$pr")"
		head_oid="$(jq -r '.headRefOid' <<< "$pr")"
		pr_number="${url##*/}"
		attempt_key="$repo#$pr_number"

		last_attempt="$(jq -r --arg key "$attempt_key" '.[$key] // ""' "$UPDATE_ATTEMPT_FILE" 2> /dev/null || true)"
		[[ "$last_attempt" == "$head_oid" ]] && continue

		jq --arg key "$attempt_key" --arg sha "$head_oid" '.[$key] = $sha' "$UPDATE_ATTEMPT_FILE" > "$UPDATE_ATTEMPT_FILE.tmp" \
			&& mv "$UPDATE_ATTEMPT_FILE.tmp" "$UPDATE_ATTEMPT_FILE"

		gh api --method PUT "repos/$repo/pulls/$pr_number/update-branch" \
			-f expected_head_sha="$head_oid" > /dev/null 2>&1 || true
	done < <(jq -c '.[]' <<< "$behind_json")
fi
