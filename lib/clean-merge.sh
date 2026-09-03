#!/usr/bin/env bash

is_clean_merge() {
	local repo_dir="$1"
	local sha="$2"
	local base_ref="$3"

	local parents
	parents="$(git -C "$repo_dir" rev-list --parents -n1 "$sha" 2> /dev/null || true)"
	[[ -n "$parents" ]] || return 1
	[[ "$(wc -w <<< "$parents")" -eq 3 ]] || return 1

	local p1 p2
	p1="$(git -C "$repo_dir" rev-parse "$sha^1" 2> /dev/null || true)"
	p2="$(git -C "$repo_dir" rev-parse "$sha^2" 2> /dev/null || true)"
	[[ -n "$p1" && -n "$p2" ]] || return 1

	git -C "$repo_dir" merge-base --is-ancestor "$p2" "origin/$base_ref" 2> /dev/null || return 1

	local actual auto objects_dir objtmp
	actual="$(git -C "$repo_dir" rev-parse "$sha^{tree}" 2> /dev/null || true)"
	[[ -n "$actual" ]] || return 1

	objects_dir="$(git -C "$repo_dir" rev-parse --absolute-git-dir 2> /dev/null)/objects"
	objtmp="$(mktemp -d)"
	auto="$(
		GIT_OBJECT_DIRECTORY="$objtmp" \
			GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
			git -C "$repo_dir" merge-tree --write-tree "$p1" "$p2" 2> /dev/null | head -1
	)"
	rm -rf "$objtmp"

	[[ -n "$auto" && "$auto" == "$actual" ]]
}

chain_is_clean_merges_only() {
	local repo_dir="$1"
	local head="$2"
	local target="$3"
	local base_ref="$4"
	local max_depth="${5:-50}"

	local target_resolved cur i=0
	target_resolved="$(git -C "$repo_dir" rev-parse "$target" 2> /dev/null || true)"
	cur="$(git -C "$repo_dir" rev-parse "$head" 2> /dev/null || true)"
	[[ -n "$target_resolved" && -n "$cur" ]] || return 1

	while [[ "$i" -lt "$max_depth" ]]; do
		[[ "$cur" == "$target_resolved" ]] && return 0
		is_clean_merge "$repo_dir" "$cur" "$base_ref" || return 1
		cur="$(git -C "$repo_dir" rev-parse "$cur^1" 2> /dev/null || true)"
		[[ -n "$cur" ]] || return 1
		i=$((i + 1))
	done

	return 1
}
