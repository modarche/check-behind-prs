#!/usr/bin/env bash
set -euo pipefail

for cmd in gh jq git; do
	command -v "$cmd" > /dev/null 2>&1 || {
		echo "Missing required command: $cmd" >&2
		exit 1
	}
done

PATH="$PATH:$HOME/.local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/notify.sh"
source "$SCRIPT_DIR/lib/clean-merge.sh"

[[ "${APPROVE_DISABLED:-}" == "1" ]] && exit 0

DRY_RUN=true
[[ "${APPROVE_DRY_RUN:-1}" == "0" ]] && DRY_RUN=false

APPROVE_ORG="${APPROVE_ORG:-celesta-tech}"
AUTHORS_FILE="$CONFIG_DIR/approve-authors"
REVIEWERS_FILE="$CONFIG_DIR/approve-trusted-reviewers"

if command -v flock > /dev/null 2>&1; then
	exec 201> "$APPROVE_LOCK_FILE"
	flock -n 201 || exit 0
fi

read_config_list() {
	[[ -f "$1" ]] || return 0
	sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | grep -v '^$' || true
}

log_decision() {
	printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" >> "$APPROVE_LOG_FILE"
}

authors="$(read_config_list "$AUTHORS_FILE")"
reviewers="$(read_config_list "$REVIEWERS_FILE")"

if [[ -z "$authors" || -z "$reviewers" ]]; then
	log_decision "-" "disabled" "no authors or trusted reviewers configured in $CONFIG_DIR"
	exit 0
fi

viewer="$(gh api graphql -f query='query { viewer { login } }' --jq '.data.viewer.login' 2> /dev/null || true)"
[[ -n "$viewer" ]] || exit 1

author_filter=""
while IFS= read -r author; do
	[[ -n "$author" ]] || continue
	author_filter+=" author:$author"
done <<< "$authors"

reviewers_json="$(jq -Rsc 'split("\n") | map(select(length > 0))' <<< "$reviewers")"

search_query="is:pr is:open org:$APPROVE_ORG$author_filter"

response="$(
	gh api graphql -f query='
      query($q: String!) {
        search(query: $q, type: ISSUE, first: 100) {
          nodes {
            ... on PullRequest {
              number
              url
              title
              headRefOid
              baseRefName
              isDraft
              isCrossRepository
              mergeStateStatus
              mergeable
              author { login }
              repository { nameWithOwner }
              reviews(first: 100) {
                nodes { author { login } state commit { oid } submittedAt }
              }
              timelineItems(itemTypes: [REVIEW_DISMISSED_EVENT], first: 100) {
                nodes {
                  ... on ReviewDismissedEvent {
                    previousReviewState
                    review { author { login } commit { oid } }
                  }
                }
              }
            }
          }
        }
      }
    ' -f q="$search_query" 2> /dev/null || true
)"

[[ -n "$response" ]] || exit 1

candidates="$(
	jq -c --arg viewer "$viewer" --argjson trusted "$reviewers_json" '
    .data.search.nodes[]
    | select(.number != null)
    | . as $pr
    | ($pr.timelineItems.nodes // []) as $dismissals
    | [
        ($pr.reviews.nodes // [])[]
        | . as $r
        | select(
            $r.state == "APPROVED"
            or (
              $r.state == "DISMISSED"
              and ($dismissals | any(
                    .previousReviewState == "APPROVED"
                    and .review.author.login == $r.author.login
                    and .review.commit.oid == $r.commit.oid))
            )
          )
        | {login: $r.author.login, oid: $r.commit.oid, submittedAt: $r.submittedAt}
      ] as $approvals
    | {
        repo: $pr.repository.nameWithOwner,
        number: $pr.number,
        url: $pr.url,
        title: $pr.title,
        head: $pr.headRefOid,
        baseRef: $pr.baseRefName,
        isDraft: $pr.isDraft,
        isCrossRepository: $pr.isCrossRepository,
        mergeStateStatus: $pr.mergeStateStatus,
        mergeable: $pr.mergeable,
        mine: ($approvals | map(select(.login == $viewer)) | sort_by(.submittedAt)),
        trusted: ($approvals | map(select(.login as $l | $trusted | index($l))) | sort_by(.submittedAt))
      }
  ' <<< "$response"
)"

while IFS= read -r pr; do
	[[ -n "$pr" && "$pr" != "null" ]] || continue

	repo="$(jq -r '.repo' <<< "$pr")"
	number="$(jq -r '.number' <<< "$pr")"
	url="$(jq -r '.url' <<< "$pr")"
	title="$(jq -r '.title' <<< "$pr")"
	head="$(jq -r '.head' <<< "$pr")"
	base_ref="$(jq -r '.baseRef' <<< "$pr")"
	slug="$repo#$number"

	handled="$(jq -r --arg key "$slug" '.[$key] // ""' "$APPROVED_STATE_FILE")"
	[[ "$handled" == "$head" ]] && continue

	[[ "$(jq -r '.isDraft' <<< "$pr")" == "true" ]] && {
		log_decision "$slug" "skip" "draft"
		continue
	}
	[[ "$(jq -r '.isCrossRepository' <<< "$pr")" == "true" ]] && {
		log_decision "$slug" "skip" "cross-repository"
		continue
	}

	merge_state="$(jq -r '.mergeStateStatus' <<< "$pr")"
	mergeable="$(jq -r '.mergeable' <<< "$pr")"
	if [[ "$mergeable" != "MERGEABLE" ]] || [[ "$merge_state" == "BEHIND" || "$merge_state" == "DIRTY" || "$merge_state" == "UNKNOWN" ]]; then
		log_decision "$slug" "skip" "not up to date (mergeStateStatus=$merge_state mergeable=$mergeable)"
		continue
	fi

	mine_latest="$(jq -r '.mine | if length == 0 then "" else (last | .oid) end' <<< "$pr")"
	if [[ -z "$mine_latest" ]]; then
		log_decision "$slug" "skip" "no previous approval by $viewer"
		continue
	fi
	if [[ "$mine_latest" == "$head" ]]; then
		log_decision "$slug" "skip" "already approved at head"
		continue
	fi

	trusted_latest="$(jq -r '.trusted | if length == 0 then "" else (last | .oid) end' <<< "$pr")"
	if [[ -z "$trusted_latest" ]]; then
		log_decision "$slug" "skip" "no trusted approval found"
		continue
	fi
	if [[ "$trusted_latest" == "$head" ]]; then
		log_decision "$slug" "skip" "trusted approval already at head, no merge to restore"
		continue
	fi

	repo_dir="$DEV_DIR/${repo#*/}"
	if ! git -C "$repo_dir" rev-parse --git-dir > /dev/null 2>&1; then
		log_decision "$slug" "skip" "no local clone at $repo_dir"
		continue
	fi

	git -C "$repo_dir" fetch --quiet origin "$base_ref" > /dev/null 2>&1 || true
	git -C "$repo_dir" fetch --quiet origin "$head" > /dev/null 2>&1 || true

	if ! git -C "$repo_dir" cat-file -e "${head}^{commit}" 2> /dev/null; then
		log_decision "$slug" "skip" "head $head not fetchable"
		continue
	fi
	if ! git -C "$repo_dir" cat-file -e "${trusted_latest}^{commit}" 2> /dev/null; then
		log_decision "$slug" "skip" "approved commit $trusted_latest not fetchable"
		continue
	fi

	if ! chain_is_clean_merges_only "$repo_dir" "$head" "$trusted_latest" "$base_ref"; then
		log_decision "$slug" "skip" "delta $trusted_latest..$head is not clean merges only"
		continue
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		log_decision "$slug" "would-approve" "clean merges only since $trusted_latest"
		send_notification "PR #$number could be approved" "$title
$repo" "$url"
	else
		if gh api --method POST "repos/$repo/pulls/$number/reviews" \
			-f event=APPROVED -f commit_id="$head" > /dev/null 2>&1; then
			log_decision "$slug" "approved" "at $head"
			send_notification "PR #$number auto-approved" "$title
$repo" "" 4000
		else
			log_decision "$slug" "error" "approval request failed"
			continue
		fi
	fi

	jq --arg key "$slug" --arg sha "$head" '.[$key] = $sha' "$APPROVED_STATE_FILE" > "$APPROVED_STATE_FILE.tmp" \
		&& mv "$APPROVED_STATE_FILE.tmp" "$APPROVED_STATE_FILE"
done < <(printf '%s\n' "$candidates")
