#!/usr/bin/env bash

MY_STUCK_PRS_QUERY='
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

gh_my_stuck_prs() {
	local cursor="null" response page all='[]'

	while :; do
		response="$(gh api graphql -f query="$MY_STUCK_PRS_QUERY" -F endCursor="$cursor")" || return 1

		page="$(
			jq -c '
        [ .data.viewer.pullRequests.nodes[]
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
        ]
      ' <<< "$response" 2> /dev/null
		)"
		[[ -n "$page" ]] || return 1
		all="$(jq -c --argjson page "$page" '. + $page' <<< "$all")"

		[[ "$(jq -r '.data.viewer.pullRequests.pageInfo.hasNextPage' <<< "$response")" == "true" ]] || break
		cursor="$(jq -r '.data.viewer.pullRequests.pageInfo.endCursor' <<< "$response")"
	done

	printf '%s' "$all"
}

pr_number_from_url() {
	printf '%s' "${1##*/}"
}
