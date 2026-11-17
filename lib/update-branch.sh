#!/usr/bin/env bash

UPDATE_LAND_TIMEOUT=60
UPDATE_POLL_INTERVAL=2
UPDATE_BASE_MOVED_ATTEMPTS=5

update_behind_prs() {
	local graph_json queue=() visited=$'\n' i=0 pr child attempts new_head
	local url repo head_ref head_oid base_oid base_moved held eligible

	graph_json="$(jq -c '[.[] | select(.isCrossRepository == false)]' <<< "$1")"

	while IFS= read -r pr; do
		queue+=("$pr")
	done < <(jq -c '
		. as $all
		| .[]
		| select(. as $pr | any($all[]; .repo == $pr.repo and .headRefName == $pr.baseRefName) | not)
		| .baseMoved = false
		| .held = false
	' <<< "$graph_json")

	while ((i < ${#queue[@]})); do
		pr="${queue[i]}"
		i=$((i + 1))

		IFS=$'\x1f' read -r url repo head_ref head_oid base_oid base_moved held eligible < <(jq -r '
			[ .url, .repo, .headRefName, .headRefOid, (.baseRefOid // "-"), .baseMoved, .held,
			  (.isDraft == false and .mergeStateStatus != "DIRTY" and (.behind or .baseMoved)) ]
			| map(tostring)
			| join("\u001f")
		' <<< "$pr")

		[[ "$visited" == *$'\n'"$url"$'\n'* ]] && continue
		visited+="$url"$'\n'

		new_head=""
		if [[ "$held" != "true" && "$eligible" == "true" ]]; then
			attempts=1
			[[ "$base_moved" == "true" ]] && attempts="$UPDATE_BASE_MOVED_ATTEMPTS"

			if update_pr_branch "$repo" "$(pr_number_from_url "$url")" "$head_oid" "$base_oid" "$attempts" \
				&& jq -e --arg repo "$repo" --arg ref "$head_ref" \
					'any(.[]; .repo == $repo and .baseRefName == $ref and .isDraft == false)' <<< "$graph_json" > /dev/null; then
				new_head="$(wait_for_new_head "$repo" "$head_ref" "$head_oid")" || held=true
			fi
		fi

		while IFS= read -r child; do
			queue+=("$child")
		done < <(jq -c --arg repo "$repo" --arg ref "$head_ref" --arg oid "$new_head" --argjson held "$held" '
			.[]
			| select(.repo == $repo and .baseRefName == $ref)
			| .baseMoved = ($oid != "")
			| if $oid != "" then .baseRefOid = $oid else . end
			| .held = $held
		' <<< "$graph_json")
	done
}

update_pr_branch() {
	local repo="$1" pr_number="$2" head_oid="$3" base_oid="$4" attempts="$5"
	local key="$repo#$pr_number" mark="$head_oid:$base_oid"

	[[ "$(jq -r --arg key "$key" '.[$key] // ""' "$UPDATE_ATTEMPT_FILE" 2> /dev/null || true)" == "$mark" ]] && return 1
	json_update "$UPDATE_ATTEMPT_FILE" --arg key "$key" --arg mark "$mark" '.[$key] = $mark'

	until gh api --method PUT "repos/$repo/pulls/$pr_number/update-branch" \
		-f expected_head_sha="$head_oid" > /dev/null 2>&1; do
		attempts=$((attempts - 1))
		if ((attempts <= 0)); then
			json_update "$UPDATE_REFUSED_FILE" --arg key "$key" --arg oid "$head_oid" '.[$key] = $oid'
			return 1
		fi
		sleep "$UPDATE_POLL_INTERVAL"
	done
}

wait_for_new_head() {
	local repo="$1" head_ref="$2" old_oid="$3" sha
	local deadline=$((SECONDS + UPDATE_LAND_TIMEOUT))

	while ((SECONDS < deadline)); do
		sleep "$UPDATE_POLL_INTERVAL"
		sha="$(gh api "repos/$repo/git/ref/heads/$head_ref" --jq '.object.sha' 2> /dev/null || true)"
		if [[ -n "$sha" && "$sha" != "$old_oid" ]]; then
			printf '%s' "$sha"
			return 0
		fi
	done
	return 1
}
