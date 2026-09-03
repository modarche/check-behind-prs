# check-behind-prs

Two cron automations for GitHub PR busywork, running every 5 minutes:

1. **Your own PRs falling behind** their base branch get updated, or staged for conflict resolution.
2. **Teammates' PRs you already approved** get re-approved when the only new content is a clean merge, so CI re-runs and its status stays visible.

```bash
git clone git@github.com:modarche/check-behind-prs.git \
  && cd check-behind-prs
# [Optional] run once to check it is working
make run
# add to cron to run every 5 minutes
make add-cron
```

## Part 1 — your PRs that fell behind

Every run sends a desktop notification for each newly detected PR, then acts based on why it can't merge. Draft PRs and PRs from forks are only ever notified about, never acted on.

| PR state | Action |
| --- | --- |
| Behind base, no conflicts | Updated automatically through the GitHub API — no local checkout involved |
| Behind base, with conflicts | A `claude` session is staged in a tmux window with a resolution prompt ready to submit |
| Anything else | Notification only |

### Behind without conflicts

Handled by `PUT /repos/{owner}/{repo}/pulls/{n}/update-branch`, the same call GitHub's "Update branch" button makes. Nothing is cloned, checked out or switched locally, so it also works for repos you don't have on disk. The PR's current head SHA is sent as `expected_head_sha`, so if someone pushes between detection and the update, GitHub refuses instead of merging into an unexpected state. A PR that can't be updated (branch protection, for example) is retried once per new commit rather than every 5 minutes.

### Behind with conflicts

Opens a window in a dedicated `pr-autofix` tmux session, in your existing clone at `~/dev/<repo>`, running `claude` with a prompt **pasted into its input but not submitted**. You review it and press Enter yourself — that manual step is what makes it safe for Claude to then use the project's real test and build tooling (docker containers, databases, `composer`) rather than working blind.

The prompt instructs Claude to:

- check `git status` and stop if there is uncommitted work, or unpushed commits on the PR branch, before switching branches
- read both sides of every conflict with `git log`, `git show` and `git blame` to understand intent before resolving
- never hand-edit a lockfile — regenerate it scoped to the packages whose constraints actually changed (never `composer update --with-all-dependencies`), using the project's own tooling
- verify with the project's tests before committing
- commit with a `Co-Authored-By: Claude <noreply@anthropic.com>` trailer and push without ever force-pushing
- return to the branch that was originally checked out

Force-push is also blocked at the tool level via `--disallowedTools`, independently of the prompt.

Because every PR in a repo shares one working directory, only one session is staged per repo at a time; a repo with no matching clone under `~/dev` is skipped. Claude is the window's root process, so closing Claude closes the window instead of leaving a shell behind. If the window disappears without a fix being pushed — you closed it, or tmux restarted — the PR simply becomes eligible again on a later run.

Completion is detected by checking whether the branch's new head commit carries the `Co-Authored-By: Claude` trailer, so a push by you or a teammate is never misreported as the tool's own work.

## Part 2 — re-approving teammates' PRs after a clean merge

When CI is gated on approval, a teammate merging `master` into an already-approved PR costs the approval (branch protection dismisses it, or it just no longer sits at head) and CI status vanishes from the PR page — even though the merge added nothing to review. `auto-approve-prs.sh` restores it.

**It will only ever approve content that a human has already reviewed.** A PR qualifies only when all of these hold:

- authored by someone in `approve-authors`, not a draft, not from a fork
- up to date and conflict-free (`mergeable`, and not `BEHIND`/`DIRTY`/`UNKNOWN`)
- you have approved it at some point (a dismissed approval counts — the dismissal event's `previousReviewState` is checked, since GitHub overwrites the review's state)
- taking the newest commit approved by anyone in `approve-trusted-reviewers`, **that commit is not the head, and every commit from there to head is a merge with no reviewable content**

The last point is the safety property. So this is allowed:

```
you approve C1 → C2 (real change) → teammate approves C2 → C3 (clean merge)  → approve
```

and this is not, because nobody reviewed C2:

```
you approve C1 → C2 (real change) →                        C3 (clean merge)  → skip
```

A commit counts as having no reviewable content only if it has exactly two parents, its second parent is already contained in the base branch (merging a *sibling feature branch* pulls in unreviewed code, so that is rejected), and its tree is byte-identical to the automatic merge of its parents — meaning nothing was hand-resolved. Anything that can't be evaluated (no local clone, unfetchable SHA, unknown merge state) is skipped, never approved.

There must be a genuine merge delta. If a trusted reviewer's approval already sits at the current head, the PR is skipped — nothing was merged since the content was last reviewed, so there is no dismissed approval to restore and no reason to add your name. That guard is what keeps a colleague approving the head from pulling your approval along with it.

Your clones are used read-only in spirit but not literally: the tree comparison runs `git merge-tree` with `GIT_OBJECT_DIRECTORY` pointed at a temp dir so it writes nothing, while `git fetch` does add objects and update remote-tracking refs in order to inspect the commits at all. Neither touches your working tree, index, branches, or checked-out state.

Approvals are submitted with no body text, and the tool only ever approves — it never comments, requests changes, or merges.

### Dry-run is the default

Out of the box nothing is approved. A qualifying PR instead raises a persistent, clickable notification — *"PR #233 could be approved"* — that opens the PR. Every decision, including skips and their reasons, is appended to `${XDG_STATE_HOME:-~/.local/state}/check-behind-prs/auto-approve.log`.

Once you trust it, add `APPROVE_DRY_RUN=0` to the cron entry. Then it approves for real, and the notification becomes *"PR #233 auto-approved"*, disappearing after 4 seconds since there is nothing to act on.

### Config (not stored in this repo)

Two files in `${XDG_CONFIG_HOME:-~/.config}/check-behind-prs/`, one login per line, `#` comments allowed. Templates: `approve-authors.example`, `approve-trusted-reviewers.example`.

| File | Meaning |
| --- | --- |
| `approve-authors` | Whose PRs may be auto-approved |
| `approve-trusted-reviewers` | Whose approval counts as "a human reviewed this". Include your own login. Never list bots |

If either file is missing or empty, the script does nothing.

## Requirements

`gh` (authenticated), `jq`, `git`, and on Linux `notify-send` and `xdg-open`. Conflict handling additionally needs `tmux` and `claude`; without them that half is skipped and you just get notifications. The clean-merge check needs git ≥ 2.38.

## Configuration

| Variable | Effect |
| --- | --- |
| `DEV_DIR` | Where local clones live (default `~/dev`) |
| `AUTOFIX_DISABLED=1` | Don't stage `claude` sessions for conflicted PRs |
| `AUTOUPDATE_DISABLED=1` | Don't auto-update PRs that are merely behind |
| `APPROVE_DRY_RUN=0` | Actually submit approvals (default: dry-run only) |
| `APPROVE_DISABLED=1` | Turn off auto-approval entirely |
| `APPROVE_ORG` | Org to search for teammates' PRs (default `celesta-tech`) |

State lives in `${XDG_STATE_HOME:-~/.local/state}/check-behind-prs/`.

```bash
make run-approve   # run the approval check once (dry-run unless APPROVE_DRY_RUN=0)
make remove-cron   # stop both automations
```
