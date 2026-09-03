#!/usr/bin/env bash
set -euo pipefail

for cmd in gh jq; do
	command -v "$cmd" > /dev/null 2>&1 || {
		echo "Missing required command: $cmd" >&2
		exit 1
	}
done

if [[ "$(uname -s)" == "Darwin" ]]; then
	OPEN_CMD="open"
	NOTIFY_CMD="osascript"
	STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/check-behind-prs"
else
	command -v notify-send > /dev/null 2>&1 || {
		echo "Missing required command: notify-send" >&2
		exit 1
	}
	command -v xdg-open > /dev/null 2>&1 || {
		echo "Missing required command: xdg-open" >&2
		exit 1
	}
	OPEN_CMD="xdg-open"
	NOTIFY_CMD="notify-send"
	STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/check-behind-prs"
fi

mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/behind.json"

setup_linux_notification_env() {
	[[ "$(uname -s)" == "Linux" ]] || return 0

	export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

	if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "$XDG_RUNTIME_DIR/bus" ]]; then
		export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
	fi

	if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
		WAYLAND_DISPLAY="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' 2> /dev/null | head -n1 || true)"
		[[ -n "$WAYLAND_DISPLAY" ]] && export WAYLAND_DISPLAY
	fi
}

notify_pr() {
	local repo="$1"
	local title="$2"
	local url="$3"
	local merge_state="$4"

	local notif_title="GitHub PR behind base"
	[[ "$merge_state" == "DIRTY" ]] && notif_title="GitHub PR behind base (conflicts)"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		"$NOTIFY_CMD" -e "display notification $(printf '%s' "$title - $repo" | jq -Rsa .) with title $(printf '%s' "$notif_title" | jq -Rsa .)" > /dev/null
		return 0
	fi

	(
		action="$(
			"$NOTIFY_CMD" \
				--urgency=normal \
				--expire-time=259200000 \
				--hint=boolean:resident:true \
				--hint=boolean:transient:false \
				--app-name="GitHub PR Watch" \
				--action="default=Open PR" \
				"$notif_title" \
				"$title
$repo" 2> /dev/null || true
		)"
		[[ "$action" == "default" ]] && "$OPEN_CMD" "$url" > /dev/null 2>&1
	) > /dev/null 2>&1 &
}

setup_linux_notification_env

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
        mergeStateStatus
      }
  ' <<< "$response" >> "$tmp_file"

	has_next="$(jq -r '.data.viewer.pullRequests.pageInfo.hasNextPage' <<< "$response")"
	[[ "$has_next" == "true" ]] || break

	end_cursor="$(jq -r '.data.viewer.pullRequests.pageInfo.endCursor' <<< "$response")"
	cursor="$end_cursor"
done

current_json="$(jq -s 'map(select(type == "object"))' "$tmp_file")"
current_keys="$(jq -r '.[].key' <<< "$current_json" | sort -u)"

if [[ -f "$STATE_FILE" ]]; then
	previous_keys="$(jq -r '.[]' "$STATE_FILE" 2> /dev/null | sort -u || true)"
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
		notify_pr "$repo" "$title" "$url" "$merge_state"
	done <<< "$new_keys"
fi

jq -r '.[].key' <<< "$current_json" | sort -u | jq -R . | jq -s . > "$STATE_FILE"
