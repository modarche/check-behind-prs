#!/usr/bin/env bash

AUTOFIX_DENY_RULES=(
	'Bash(git push --force)'
	'Bash(git push --force *)'
	'Bash(git push -f)'
	'Bash(git push -f *)'
	'Bash(git push --force-with-lease)'
	'Bash(git push --force-with-lease *)'
	'Bash(git push --force-with-lease=*)'
	'Bash(git push --force-if-includes)'
	'Bash(git push --force-if-includes *)'
	'Bash(git push *--force*)'
	'Bash(git push * -f)'
	'Bash(git push * -f *)'
	'Bash(git push *+*)'
	'Bash(git push *--mirror*)'
	'Bash(git push *--delete*)'
	'Bash(git push * -d *)'
	'Bash(docker *)'
	'Bash(docker-compose *)'
	'Bash(sudo *)'
	'Bash(dphp *)'
	'Bash(dtest*)'
	'Bash(dptest*)'
	'Bash(migrtest*)'
	'Bash(gh pr comment*)'
	'Bash(gh pr review*)'
	'Bash(gh pr merge*)'
	'Bash(gh pr close*)'
	'Bash(gh pr edit*)'
	'Bash(gh pr ready*)'
	'Bash(gh issue comment*)'
)

autofix_available() {
	[[ "${AUTOFIX_DISABLED:-}" != "1" ]] && have_commands tmux claude git jq
}

autofix_window_exists() {
	tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2> /dev/null | grep -qxF "$1"
}

autofix_window_alive() {
	[[ -n "$1" ]] && tmux list-windows -t "$TMUX_SESSION" -F '#{window_id}' 2> /dev/null | grep -qxF "$1"
}

autofix_lock() {
	command -v flock > /dev/null 2>&1 || return 0
	exec 201> "$STAGE_LOCK_FILE"
	flock -w "${1:-30}" 201
}

autofix_unlock() {
	exec 201>&- || true
}

autofix_notify() {
	local args=("$1" "$2" "${3:-}")
	[[ -n "${4:-}" ]] && args+=("$4")
	if command -v setsid > /dev/null 2>&1; then
		setsid -f bash -c 'source "$1"; shift; send_notification "$@"; wait' _ "$LIB_DIR/notify.sh" "${args[@]}" \
			< /dev/null > /dev/null 2>&1 200>&- 201>&-
	else
		(
			source "$LIB_DIR/notify.sh"
			send_notification "${args[@]}"
		) < /dev/null > /dev/null 2>&1 200>&- 201>&-
	fi
}

autofix_notify_skip() {
	local key="$1" reason="$2" url="${3:-}" previous
	previous="$(jq -r --arg k "$key" '.[$k] // empty' "$AUTOFIX_SKIPS_FILE" 2> /dev/null || true)"
	[[ "$previous" == "$reason" ]] && return 0
	json_update "$AUTOFIX_SKIPS_FILE" --arg k "$key" --arg r "$reason" '.[$k] = $r'
	autofix_notify "No conflict session for ${key#*/}" "$reason" "$url"
}

autofix_clear_skip() {
	json_update "$AUTOFIX_SKIPS_FILE" --arg k "$1" 'del(.[$k])'
}

autofix_run_json() {
	jq -c --arg k "$1" '.[$k] // empty' "$AUTOFIX_RUNS_FILE" 2> /dev/null || true
}

autofix_drop_run() {
	json_update "$AUTOFIX_RUNS_FILE" --arg k "$1" 'del(.[$k])'
}

autofix_flag_run() {
	json_update "$AUTOFIX_RUNS_FILE" --arg k "$1" --arg f "$2" '.[$k].notified[$f] = true'
}

autofix_status_state() {
	jq -r '.state // empty' "$1/status.json" 2> /dev/null || true
}

autofix_write_status() {
	local run_dir="$1" state="$2" message="$3" url="${4:-}" tmp
	tmp="$(mktemp "$run_dir/status.json.XXXXXX")"
	jq -n --arg state "$state" --arg message "$message" --arg url "$url" --arg at "$(date -u +%FT%TZ)" \
		'{state: $state, message: $message, url: $url, updatedAt: $at}' > "$tmp"
	mv "$tmp" "$run_dir/status.json"
}

autofix_clone_trusted() {
	jq -e --arg p "$1" '.projects[$p].hasTrustDialogAccepted == true' "$HOME/.claude.json" > /dev/null 2>&1
}

autofix_fetch_refs() {
	local repo_dir="$1" ref refspecs=()
	shift
	for ref in "$@"; do
		refspecs+=("+refs/heads/$ref:refs/remotes/origin/$ref")
	done
	git -C "$repo_dir" fetch --quiet origin "${refspecs[@]}" > /dev/null 2>&1
}

autofix_network_name() {
	printf 'pr-autofix-%s' "$1"
}

autofix_copy_ignored_files() {
	local repo_dir="$1" worktree="$2" file
	while IFS= read -r file; do
		[[ -n "$file" && "$file" != */* && -f "$repo_dir/$file" && ! -e "$worktree/$file" ]] || continue
		cp -p "$repo_dir/$file" "$worktree/$file"
	done < <(git -C "$repo_dir" ls-files --others --ignored --exclude-standard -- '.env*' 'phpunit.xml' 2> /dev/null || true)
}

autofix_runtime_none() {
	jq -nc --arg reason "$1" '{kind: "none", reason: $reason}'
}

autofix_sidecar_spec() {
	local host="$1" run_id="$2" info
	info="$(docker inspect --type container "$host" 2> /dev/null | jq -c '.[0] // empty')" || return 1
	[[ -n "$info" ]] || return 1
	jq -c --arg host "$host" --arg name "pr-autofix-$run_id-$host" '{
		host: $host,
		aliases: ([$host] + [.NetworkSettings.Networks[]? | (.Aliases // []) + (.DNSNames // []) | .[]]
			| map(select(test("^[0-9a-f]{12,64}$") | not)) | unique),
		container: $name,
		image: .Config.Image,
		kind: (.Config.Image | if test("mysql|mariadb|percona") then "mysql" elif test("postgres") then "postgres" elif test("redis|valkey|keydb") then "redis" else "other" end),
		cmd: (.Config.Cmd // []),
		tmpfs: ((.Config.Volumes // {}) | keys)
	}' <<< "$info"
}

autofix_compose_store_specs() {
	local config="$1" worktree="$2" run_id="$3"
	jq -c --arg run "$run_id" --arg wt "$worktree/" '
		[ .services // {} | to_entries[]
		  | select(.key != "php" and .value.image != null and .value.entrypoint == null)
		  | .value.image as $image
		  | ($image | if test("mysql|mariadb|percona") then "mysql"
		              elif test("postgres") then "postgres"
		              elif test("redis|valkey|keydb") then "redis"
		              elif test("mongo") then "mongo"
		              else empty end) as $kind
		  | {
		      host: .key,
		      aliases: ([.key, (.value.container_name // empty)] + [(.value.networks // {})[] | (.aliases // [])[]] | unique),
		      container: "pr-autofix-\($run)-\(.key)",
		      image: $image,
		      kind: $kind,
		      env: [(.value.environment // {}) | to_entries[] | select(.value != null) | "\(.key)=\(.value)"],
		      cmd: (.value.command // [] | if type == "string" then split(" ") else . end),
		      tmpfs: ([{mysql: "/var/lib/mysql", postgres: "/var/lib/postgresql/data", redis: "/data", mongo: "/data/db"}[$kind]]
		              + [.value.volumes[]? | select(.type == "volume") | .target]
		              + (.value.tmpfs // []) | unique),
		      mounts: [.value.volumes[]? | select(.type == "bind" and (.source | startswith($wt))) | "\(.source):\(.target):ro"]
		    }
		]' <<< "$config"
}

autofix_referenced() {
	local env_text="$1" alias pattern
	while IFS= read -r alias; do
		pattern="(^|[^A-Za-z0-9_.-])${alias//./\\.}([^A-Za-z0-9_.-]|\$)"
		grep -qE "$pattern" <<< "$env_text" && return 0
	done
	return 1
}

autofix_detect_runtime() {
	local worktree="$1" run_dir="$2" run_id="$3"
	local config php image app_dir work_dir wt_real env_text host spec sidecars='[]'

	[[ -f "$worktree/docker-compose.dev.yml" ]] || {
		autofix_runtime_none "the repo has no docker-compose.dev.yml"
		return
	}
	have_commands docker || {
		autofix_runtime_none "docker is not installed"
		return
	}
	config="$(cd "$worktree" && COMPOSE_PROJECT_NAME="pr-autofix-$run_id" docker compose -f docker-compose.dev.yml config --format json 2> /dev/null)" || {
		autofix_runtime_none "docker compose could not read docker-compose.dev.yml"
		return
	}
	php="$(jq -c '.services.php // empty' <<< "$config")"
	[[ -n "$php" ]] || {
		autofix_runtime_none "docker-compose.dev.yml has no php service"
		return
	}
	image="$(jq -r '.image // empty' <<< "$php")"
	[[ -n "$image" ]] || {
		autofix_runtime_none "the php service names no image"
		return
	}
	docker image inspect "$image" > /dev/null 2>&1 || {
		autofix_runtime_none "the dev image $image is not on this machine (run make build in the clone)"
		return
	}
	wt_real="$(cd "$worktree" && pwd -P)"
	app_dir="$(jq -r --arg wt "$worktree" --arg real "$wt_real" \
		'[.volumes[]? | select(.type == "bind" and (.source == $wt or .source == $real)) | .target][0] // empty' <<< "$php")"
	[[ -n "$app_dir" ]] || {
		autofix_runtime_none "the php service does not mount the repository"
		return
	}
	work_dir="$(jq -r --arg d "$app_dir" '.working_dir // $d' <<< "$php")"

	jq -r '
		(.environment // {}) | to_entries[]
		| select(.value != null)
		| select(.key | IN("XDEBUG_MODE", "HOME", "COMPOSER_HOME", "COMPOSER_CACHE_DIR") | not)
		| (.value | tostring) as $v
		| select($v | test("\n") | not)
		| "\(.key)=\($v)"
	' <<< "$php" > "$run_dir/container.env"

	env_text="$(cat "$run_dir/container.env" "$worktree/.env" "$worktree/.env.test" 2> /dev/null || true)"
	while IFS= read -r spec; do
		[[ -n "$spec" ]] || continue
		autofix_referenced "$env_text" < <(jq -r '.aliases[]' <<< "$spec") || continue
		docker image inspect "$(jq -r '.image' <<< "$spec")" > /dev/null 2>&1 || continue
		sidecars="$(jq -c --argjson s "$spec" '. + [$s]' <<< "$sidecars")"
	done < <(autofix_compose_store_specs "$config" "$worktree" "$run_id" | jq -c '.[]')

	for host in $AUTOFIX_SIDECARS; do
		jq -e --arg h "$host" 'any(.[]; .aliases | index($h))' <<< "$sidecars" > /dev/null && continue
		spec="$(autofix_sidecar_spec "$host" "$run_id")" || continue
		autofix_referenced "$env_text" < <(jq -r '.aliases[]' <<< "$spec") || continue
		sidecars="$(jq -c --argjson s "$spec" '. + [$s]' <<< "$sidecars")"
	done

	jq -nc \
		--arg image "$image" \
		--arg appDir "$app_dir" \
		--arg workDir "$work_dir" \
		--arg network "$(autofix_network_name "$run_id")" \
		--argjson sidecars "$sidecars" \
		'{kind: "container", image: $image, appDir: $appDir, workDir: $workDir, network: $network, sidecars: $sidecars}'
}

autofix_start_sidecar() {
	local spec="$1" network="$2" run_id="$3" host container image line args=()
	host="$(jq -r '.host' <<< "$spec")"
	container="$(jq -r '.container' <<< "$spec")"
	image="$(jq -r '.image' <<< "$spec")"

	if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2> /dev/null || true)" == "true" ]]; then
		return 0
	fi
	docker rm -f "$container" > /dev/null 2>&1 || true

	args=(run -d --rm --pull never --name "$container" --label "pr-autofix=$run_id" --network "$network")
	while IFS= read -r line; do
		args+=(--network-alias "$line")
	done < <(jq -r --arg host "$host" '(.aliases // [$host])[]' <<< "$spec")
	if jq -e 'has("env")' <<< "$spec" > /dev/null; then
		while IFS= read -r line; do
			[[ -n "$line" ]] && args+=(-e "$line")
		done < <(jq -r '.env[]' <<< "$spec")
	else
		while IFS= read -r line; do
			[[ -n "$line" && "$line" != PATH=* ]] && args+=(-e "$line")
		done < <(docker inspect --type container "$host" --format '{{range .Config.Env}}{{println .}}{{end}}' 2> /dev/null || true)
	fi
	while IFS= read -r line; do
		[[ -n "$line" ]] && args+=(--tmpfs "$line")
	done < <(jq -r '.tmpfs[]' <<< "$spec")
	while IFS= read -r line; do
		[[ -n "$line" ]] && args+=(-v "$line")
	done < <(jq -r '.mounts[]?' <<< "$spec")
	args+=("$image")
	while IFS= read -r line; do
		args+=("$line")
	done < <(jq -r '.cmd[]' <<< "$spec")

	docker "${args[@]}" > /dev/null
}

autofix_sidecar_ready() {
	local kind="$1" container="$2"
	case "$kind" in
		mysql) docker exec "$container" mysqladmin ping -h 127.0.0.1 --silent > /dev/null 2>&1 ;;
		postgres) docker exec "$container" pg_isready -h 127.0.0.1 > /dev/null 2>&1 ;;
		redis) docker exec "$container" sh -c 'valkey-cli ping 2>/dev/null || redis-cli ping' 2> /dev/null | grep -q PONG ;;
		*) [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2> /dev/null || true)" == "true" ]] ;;
	esac
}

autofix_start_sidecars() {
	local run_dir="$1" run_id network spec
	run_id="$(jq -r '.runId' "$run_dir/run.json")"
	network="$(jq -r '.runtime.network' "$run_dir/run.json")"

	docker network inspect "$network" > /dev/null 2>&1 \
		|| docker network create --label "pr-autofix=$run_id" "$network" > /dev/null \
		|| return 1
	while IFS= read -r spec; do
		[[ -n "$spec" ]] || continue
		if [[ "$(docker inspect -f '{{.State.Running}}' "$(jq -r '.container' <<< "$spec")" 2> /dev/null || true)" != "true" ]]; then
			rm -f "$run_dir/sidecars.ready"
			autofix_start_sidecar "$spec" "$network" "$run_id" || {
				echo "could not start a copy of the $(jq -r '.host' <<< "$spec") container" >&2
				return 1
			}
		fi
	done < <(jq -c '.runtime.sidecars[]?' "$run_dir/run.json")
}

autofix_wait_sidecars() {
	local run_dir="$1" spec kind container deadline
	[[ -f "$run_dir/sidecars.ready" ]] && return 0
	deadline=$((SECONDS + 120))
	while IFS= read -r spec; do
		[[ -n "$spec" ]] || continue
		kind="$(jq -r '.kind' <<< "$spec")"
		container="$(jq -r '.container' <<< "$spec")"
		until autofix_sidecar_ready "$kind" "$container"; do
			if ((SECONDS >= deadline)); then
				echo "$container did not become ready within 120 s" >&2
				return 1
			fi
			sleep 2
		done
	done < <(jq -c '.runtime.sidecars[]?' "$run_dir/run.json")
	touch "$run_dir/sidecars.ready"
}

autofix_remove_containers() {
	local run_id="$1" ids=()
	have_commands docker || return 0
	mapfile -t ids < <(docker ps -aq --filter "label=pr-autofix=$run_id" 2> /dev/null || true)
	((${#ids[@]} == 0)) || docker rm -f "${ids[@]}" > /dev/null 2>&1 || true
	docker network rm "$(autofix_network_name "$run_id")" > /dev/null 2>&1 || true
}

autofix_remove_worktree() {
	local repo_dir="$1" worktree="$2"
	if [[ -d "$worktree" ]]; then
		git -C "$repo_dir" worktree remove --force "$worktree" > /dev/null 2>&1 || true
	fi
	git -C "$repo_dir" worktree prune > /dev/null 2>&1 || true
	[[ ! -e "$worktree" ]]
}

autofix_worktree_disposable() {
	local worktree="$1" head_ref="$2"
	[[ -d "$worktree" ]] || return 0
	[[ -z "$(git -C "$worktree" status --porcelain --untracked-files=no 2> /dev/null || echo dirty)" ]] || return 1
	git -C "$worktree" rev-parse -q --verify MERGE_HEAD > /dev/null 2>&1 && return 1
	git -C "$worktree" merge-base --is-ancestor HEAD "refs/remotes/origin/$head_ref" 2> /dev/null
}

autofix_write_settings() {
	local run_dir="$1" repo_dir="$2" compose_project="$3" runtime_kind="$4"
	local deny=("${AUTOFIX_DENY_RULES[@]}")

	deny+=(
		"Edit(//${repo_dir#/}/**)"
		"Bash(git -C $repo_dir*)"
		"Bash(cd $repo_dir*)"
	)
	[[ "$runtime_kind" == "container" ]] && deny+=('Bash(make)' 'Bash(make *)')

	printf '%s\n' "${deny[@]}" | jq -R . | jq -s \
		--arg run_dir "$run_dir" \
		--arg project "$compose_project" \
		--arg hook "$LIBEXEC_DIR/autofix-hook" \
		'{
			permissions: {denyInsteadOfPrompting: true, deny: .},
			skillOverrides: {"auto-mode-setup": "off"},
			env: {
				PR_AUTOFIX_RUN_DIR: $run_dir,
				COMPOSE_PROJECT_NAME: $project,
				GIT_CONFIG_COUNT: "1",
				GIT_CONFIG_KEY_0: "core.hooksPath",
				GIT_CONFIG_VALUE_0: "/dev/null"
			},
			hooks: {
				UserPromptSubmit: [{hooks: [{type: "command", command: "\($hook | @sh) started \($run_dir | @sh)"}]}],
				Notification: [{hooks: [{type: "command", command: "\($hook | @sh) notify \($run_dir | @sh)"}]}],
				Stop: [{hooks: [{type: "command", command: "\($hook | @sh) stop \($run_dir | @sh)"}]}]
			}
		}' > "$run_dir/settings.json"
}

autofix_reap_windows() {
	have_commands tmux git jq || return 0
	autofix_lock 60 || return 0
	autofix_reap_locked
	autofix_unlock
}

autofix_reap_locked() {
	local key
	while IFS= read -r key; do
		[[ -n "$key" ]] && autofix_reap_run "$key"
	done < <(jq -r 'keys[]' "$AUTOFIX_RUNS_FILE" 2> /dev/null || true)
}

autofix_reap_run() {
	local key="$1" run label state attach now last_epoch
	local run_id run_dir repo_dir worktree head_ref base_ref base_sha window_id window_name phase pr_url started_epoch

	run="$(autofix_run_json "$key")"
	[[ -n "$run" ]] || return 0
	eval "$(jq -r '@sh "run_id=\(.runId) run_dir=\(.runDir) repo_dir=\(.repoDir) worktree=\(.worktree) head_ref=\(.headRef) base_ref=\(.baseRef) base_sha=\(.baseSha) window_id=\(.windowId // "") window_name=\(.windowName) phase=\(.phase) pr_url=\(.url) started_epoch=\(.startedEpoch)"' <<< "$run")"
	label="${key#*/}"
	attach="tmux attach -t $TMUX_SESSION:$window_name"
	state="$(autofix_status_state "$run_dir")"

	if [[ "$phase" == "staging" ]]; then
		autofix_remove_containers "$run_id"
		autofix_fetch_refs "$repo_dir" "$head_ref" || true
		autofix_worktree_disposable "$worktree" "$head_ref" && autofix_remove_worktree "$repo_dir" "$worktree"
		autofix_drop_run "$key"
		return 0
	fi

	if [[ "$state" == "done" ]]; then
		autofix_fetch_refs "$repo_dir" "$head_ref" || return 0
		if git -C "$repo_dir" merge-base --is-ancestor "$base_sha" "refs/remotes/origin/$head_ref" 2> /dev/null; then
			autofix_window_alive "$window_id" && tmux kill-window -t "$window_id" > /dev/null 2>&1
			autofix_remove_containers "$run_id"
			autofix_remove_worktree "$repo_dir" "$worktree" \
				|| autofix_notify "PR $label: worktree left behind" "Could not remove $worktree; remove it with: git -C $repo_dir worktree remove --force $worktree" "$pr_url"
			autofix_drop_run "$key"
		elif [[ "$(jq -r '.notified.unmerged // false' <<< "$run")" != "true" ]]; then
			autofix_notify "PR $label: done, but not merged" "The session reported done, but origin/$head_ref does not contain $base_ref at ${base_sha:0:8}.
$attach" "$pr_url"
			autofix_flag_run "$key" unmerged
		fi
		return 0
	fi

	if ! autofix_window_alive "$window_id"; then
		autofix_remove_containers "$run_id"
		autofix_fetch_refs "$repo_dir" "$head_ref" || true
		if autofix_worktree_disposable "$worktree" "$head_ref" && autofix_remove_worktree "$repo_dir" "$worktree"; then
			autofix_notify "PR $label: session closed" "It ended in state ${state:-starting} and its worktree was removed. The PR can get a new session." "$pr_url" 10000
		else
			autofix_notify "PR $label: session closed, worktree kept" "It ended in state ${state:-starting}, and $worktree holds work that is not on origin. Inspect it, then: git -C $repo_dir worktree remove --force $worktree" "$pr_url"
		fi
		autofix_drop_run "$key"
		return 0
	fi

	case "$state" in
		blocked | failed) return 0 ;;
	esac

	now="$(date +%s)"
	last_epoch="$(stat -c %Y "$run_dir/status.json" 2> /dev/null || echo "$started_epoch")"
	if ((now - last_epoch > AUTOFIX_STALE_MINUTES * 60)) && [[ "$(jq -r '.notified.stale // false' <<< "$run")" != "true" ]]; then
		autofix_notify "PR $label: no progress" "No status change for over $AUTOFIX_STALE_MINUTES minutes (state ${state:-starting}).
$attach" "$pr_url"
		autofix_flag_run "$key" stale
	fi
}

autofix_stage_conflicted() {
	local stuck_json="$1" eligible_json pr repo owner short_repo url pr_number base_ref head_ref title

	eligible_json="$(jq -c --slurpfile refused "$UPDATE_REFUSED_FILE" '
		[.[] | select(
			.isDraft == false and .isCrossRepository == false
			and (.mergeStateStatus == "DIRTY"
				or (.behind and ($refused[0][.repo + "#" + (.url | split("/") | last)] == .headRefOid)))
		)] as $needs
		| [$needs[] | . as $pr | select([$needs[] | select(.repo == $pr.repo and .headRefName == $pr.baseRefName)] | length == 0)]
	' <<< "$stuck_json")"

	while IFS= read -r pr; do
		[[ -n "$pr" && "$pr" != "null" ]] || continue
		repo="$(jq -r '.repo' <<< "$pr")"
		url="$(jq -r '.url' <<< "$pr")"
		pr_number="$(pr_number_from_url "$url")"

		jq -e --arg k "$repo#$pr_number" 'has($k)' "$AUTOFIX_RUNS_FILE" > /dev/null 2>&1 && continue

		owner="${repo%%/*}"
		short_repo="${repo#*/}"
		base_ref="$(jq -r '.baseRefName' <<< "$pr")"
		head_ref="$(jq -r '.headRefName' <<< "$pr")"
		title="$(jq -r '.title' <<< "$pr")"

		"$LIBEXEC_DIR/stage-pr-autofix" --notify-skips \
			"$owner" "$short_repo" "$pr_number" "$base_ref" "$head_ref" "$url" "$title" < /dev/null || true
	done < <(jq -c '.[]' <<< "$eligible_json")
}
