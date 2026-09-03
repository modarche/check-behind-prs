#!/usr/bin/env bash

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

setup_linux_notification_env

send_notification() {
	local title="$1"
	local body="$2"
	local open_url="${3:-}"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		osascript -e "display notification $(printf '%s' "$body" | jq -Rsa .) with title $(printf '%s' "$title" | jq -Rsa .)" > /dev/null 2>&1
		return 0
	fi

	command -v notify-send > /dev/null 2>&1 || return 0

	(
		exec 200>&- 2> /dev/null || true

		if [[ -n "$open_url" ]] && command -v xdg-open > /dev/null 2>&1; then
			action="$(
				notify-send \
					--urgency=normal \
					--expire-time=259200000 \
					--hint=boolean:resident:true \
					--hint=boolean:transient:false \
					--app-name="GitHub PR Watch" \
					--action="default=Open PR" \
					"$title" \
					"$body" 2> /dev/null || true
			)"
			[[ "$action" == "default" ]] && xdg-open "$open_url" > /dev/null 2>&1
		else
			notify-send \
				--urgency=normal \
				--expire-time=259200000 \
				--app-name="GitHub PR Watch" \
				"$title" \
				"$body" > /dev/null 2>&1 || true
		fi
	) > /dev/null 2>&1 &
}
