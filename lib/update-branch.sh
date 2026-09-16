#!/usr/bin/env bash

update_behind_prs() {
	local stuck_json="$1"
	local behind_json pr repo url head_oid pr_number attempt_key last_attempt

	behind_json="$(jq -c '[.[] | select(.isDraft == false and .isCrossRepository == false and .mergeStateStatus == "BEHIND")]' <<< "$stuck_json")"

	while IFS= read -r pr; do
		[[ -n "$pr" && "$pr" != "null" ]] || continue
		repo="$(jq -r '.repo' <<< "$pr")"
		url="$(jq -r '.url' <<< "$pr")"
		head_oid="$(jq -r '.headRefOid' <<< "$pr")"
		pr_number="$(pr_number_from_url "$url")"
		attempt_key="$repo#$pr_number"

		last_attempt="$(jq -r --arg key "$attempt_key" '.[$key] // ""' "$UPDATE_ATTEMPT_FILE" 2> /dev/null || true)"
		[[ "$last_attempt" == "$head_oid" ]] && continue

		json_update "$UPDATE_ATTEMPT_FILE" --arg key "$attempt_key" --arg sha "$head_oid" '.[$key] = $sha'

		gh api --method PUT "repos/$repo/pulls/$pr_number/update-branch" \
			-f expected_head_sha="$head_oid" > /dev/null 2>&1 || true
	done < <(jq -c '.[]' <<< "$behind_json")
}
