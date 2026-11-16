# check-behind-prs

GitHub PR busywork, handled for you:

1. **Your own PRs falling behind** their base branch get updated, or handed to an unattended `claude` session that resolves the conflicts, pushes and sees CI through — every 5 minutes, from cron.
2. **Any PR, on demand** — including a teammate's — gets the same conflict-resolution session with one command.
3. **Teammates' PRs you already approved** get re-approved when the only new content is a clean merge, so CI re-runs and its status stays visible — also every 5 minutes.

```bash
git clone git@github.com:modarche/check-behind-prs.git \
  && cd check-behind-prs
# [Optional] run once to check it is working
make run
# add to cron to run every 5 minutes
make add-cron
```

| Command | What it does |
| --- | --- |
| `make run` | check your PRs once |
| `make resolve PR=<url\|owner/repo#n>` | start a conflict-resolution session for one PR |
| `make run-approve` | check teammates' PRs once (dry-run unless `APPROVE_DRY_RUN=0`) |
| `make add-cron` / `make remove-cron` | start / stop the two cron entries |
| `make check` | syntax-check every script |

## Layout

| Path | |
| --- | --- |
| `bin/check-behind-prs` | cron entry point — your own PRs |
| `bin/auto-approve-prs` | cron entry point — teammates' PRs you already approved |
| `bin/resolve-pr-conflicts` | manual — start a conflict-resolution session for one PR |
| `libexec/stage-pr-autofix` | sets up the worktree, containers and run directory, then opens the tmux window; both entry points call it |
| `libexec/autofix-session` | the tmux window's process: `claude` with the run's settings and prompt |
| `libexec/autofix-php` | runs a command in the run's throwaway dev container |
| `libexec/autofix-status` | the session records `waiting-ci`, `done`, `blocked` or `failed` with it |
| `libexec/autofix-hook` | the session's `UserPromptSubmit`, `Notification` and `Stop` hooks |
| `lib/` | shared helpers: state paths, notifications, PR queries, autofix, clean-merge detection |
| `prompts/` | the conflict-resolution prompt template and its per-repo variants |
| `examples/` | config templates |

Upgrading from the flat layout: run `make add-cron` once — it repoints cron at `bin/` and drops the old entries.

## Part 1 — your PRs that fell behind

Every run sends a desktop notification for each newly detected PR, then acts based on why it can't merge. Draft PRs and PRs from forks are only ever notified about, never acted on.

| PR state | Action |
| --- | --- |
| Behind base, no conflicts | Updated automatically through the GitHub API — no local checkout involved |
| Behind base, with conflicts | A `claude` session is staged in a tmux window with a resolution prompt ready to submit |
| Anything else | Notification only |

### Behind without conflicts

GitHub only reports a PR as `BEHIND` when its base branch requires branches to be up to date before merging, so a PR stacked on another feature branch shows `CLEAN` however far behind it is. A PR therefore also counts as behind whenever GitHub would offer you its "Update branch" button (`viewerCanUpdateBranch`), unless it has conflicts or GitHub is still computing its merge state.

Handled by `PUT /repos/{owner}/{repo}/pulls/{n}/update-branch`, the same call GitHub's "Update branch" button makes. Nothing is cloned, checked out or switched locally, so it also works for repos you don't have on disk. The PR's current head SHA is sent as `expected_head_sha`, so if someone pushes between detection and the update, GitHub refuses instead of merging into an unexpected state. A PR that can't be updated (branch protection, for example) is retried once per new commit rather than every 5 minutes.

### Behind with conflicts

Starts an unattended `claude` session in a window of the `pr-autofix` tmux session. Nobody has to press Enter, and nothing touches your clone at `~/dev/<repo>`, so it runs while you're busy there — another branch checked out, tests running in your dev container. Watch any session with `tmux attach -t pr-autofix`.

**Its own checkout.** Each session gets a git worktree at `~/dev/.pr-autofix/<repo>-pr<N>`, detached at the tip of `origin/<head>`, and pushes with `git push origin HEAD:<head>`. Your clone's branches, index and working tree are never involved, and a stale local copy of the PR branch can't make the push fail. Ignored files the app needs (`.env*`, `phpunit.xml`) are copied over from the clone.

**Its own containers.** Your dev containers mount your clone, so the session can't use them, and `make`, `docker compose` and the repos' pre-commit hooks would all reach them. Instead, `libexec/autofix-php <cmd>` runs commands in a throwaway container from the repo's own dev image, read from `docker-compose.dev.yml`:

- it has the worktree mounted where the clone normally is, and runs as your user, so every file stays yours;
- it sits on a private network with fresh, empty copies of the shared `mysql`, `mysql-test` and `localredis` containers that the app's config refers to: same image, credentials and hostnames;
- the session can create, migrate and drop test databases there, but it cannot reach your databases, your dev container, or other services such as queues and search.

Repos without a usable dev image (Go services, front-ends, libraries) get static checks only, and CI is the test signal.

**What it does.** The prompt has Claude:

- merge `origin/<base>` in, and read both sides of every conflict with `git log`, `git show` and `git blame` to understand intent before resolving;
- never hand-edit a lockfile — regenerate it scoped to the packages whose constraints actually changed (never `composer update --with-all-dependencies`);
- verify with the tests covering the conflicted files, in the throwaway container;
- commit as `<PARENT>-<SUB> merge <base>` with a `Co-Authored-By: Claude <noreply@anthropic.com>` trailer, and push without ever force-pushing;
- start CI with `gh workflow run ci.yml --ref <head>` (where `ci.yml` has a manual trigger; otherwise watch what the push started), watch it in the background, and fix failures the merge caused — at most two rounds. A failure that also happens on the base branch, or in code neither side touched, is reported rather than "fixed".

**What it can't do.** The session runs in `auto` permission mode and loads only the repository's settings plus its own, not your user hooks or plugins. Its own settings deny:

- force pushes, and any push that deletes or rewrites;
- `docker`, `make`, `dphp`/`dtest`, and `git` or `cd` into your clone;
- edits to your clone;
- commenting on, reviewing, merging or editing the PR.

Git hooks are off for the session, and `denyInsteadOfPrompting` means nothing ever waits on a permission dialog.

**When it needs you.** The session records its state with `libexec/autofix-status`, and you get a desktop notification with the `tmux attach` command when:

- it records `blocked` (a question it can't answer) or `failed`;
- it stops without recording an outcome;
- the run makes no progress for 3 hours.

`done` gives a short notification. On the next cron run the window is closed and the worktree and containers are removed — once `origin/<head>` contains the base commit the session merged.

**Limits and refusals.**

- Up to 3 sessions run at once, one per PR. A PR stacked on another PR that has a session waits for it.
- A PR is skipped, with a one-time notification, when:
  - its clone isn't trusted by Claude Code yet;
  - you have uncommitted changes or unpushed commits on its branch in the clone;
  - a worktree from an earlier session is still there.
- If you close a window before it finishes, the worktree is removed when it holds nothing that isn't on origin; otherwise it's kept and you're told where. Either way, the PR becomes eligible again.

## Part 2 — resolving conflicts on any PR, on demand

Cron only ever touches your own PRs. When a *teammate's* PR is blocking you, start the same session by hand:

```bash
make resolve PR=https://github.com/acme/widgets/pull/42
make resolve PR=acme/widgets#42
./bin/resolve-pr-conflicts 42                  # inside the repo's clone
./bin/resolve-pr-conflicts --repo acme/widgets 42
```

Same worktree, containers, prompt and CI follow-through, with one addition. When the PR is not yours, the prompt names its author. It tells Claude to only ever add commits on top, never to rebase, amend or squash someone else's commits, and to record `blocked` if the push is rejected for lack of access.

It refuses, with a reason, when:

- the PR is closed;
- it comes from a fork (its branch isn't in your remote, so nothing local can push it);
- it has no clone under `~/dev`;
- a session for that PR is already running;
- it hits one of the refusals above.

A PR that merges cleanly is refused too, since there is nothing to resolve — pass `--force` if you want the session anyway.

| Option | |
| --- | --- |
| `--repo OWNER/REPO` | repository a bare PR number belongs to |
| `--dry-run` | run every check and print the runtime, settings and prompt; start nothing |
| `--force` | start even when the PR merges cleanly already, or when your clone has local work on its branch |

`make resolve` passes extra flags through `ARGS`: `make resolve PR=… ARGS=--dry-run`.

## Part 3 — re-approving teammates' PRs after a clean merge

When CI is gated on approval, a teammate merging `master` into an already-approved PR costs the approval (branch protection dismisses it, or it just no longer sits at head) and CI status vanishes from the PR page — even though the merge added nothing to review. `bin/auto-approve-prs` restores it.

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

Two files in `${XDG_CONFIG_HOME:-~/.config}/check-behind-prs/`, one login per line, `#` comments allowed. Templates live in `examples/`.

| File | Meaning |
| --- | --- |
| `approve-authors` | Whose PRs may be auto-approved |
| `approve-trusted-reviewers` | Whose approval counts as "a human reviewed this". Include your own login. Never list bots |

If either file is missing or empty, the script does nothing.

## Requirements

`gh` (authenticated), `jq`, `git`, and on Linux `notify-send` and `xdg-open`. Conflict resolution additionally needs `tmux`, `claude` (v2.1.319 or later) and `docker`; without them that half is skipped and you just get notifications. The clean-merge check needs git ≥ 2.38.

## Configuration

| Variable | Effect |
| --- | --- |
| `DEV_DIR` | Where local clones live (default `~/dev`) |
| `AUTOFIX_DISABLED=1` | Don't start `claude` sessions for conflicted PRs |
| `AUTOFIX_MODEL` | Model the session runs (default `sonnet`) |
| `AUTOFIX_MAX_RUNS` | Sessions that may run at once (default `3`) |
| `AUTOFIX_SIDECARS` | Shared containers copied into each session's private network when the app refers to them (default `mysql mysql-test localredis`) |
| `AUTOFIX_STALE_MINUTES` | Notify when a session's state hasn't changed for this long (default `180`) |
| `AUTOFIX_WORKTREE_ROOT` | Where session worktrees go (default `$DEV_DIR/.pr-autofix`) |
| `AUTOUPDATE_DISABLED=1` | Don't auto-update PRs that are merely behind |
| `APPROVE_DRY_RUN=0` | Actually submit approvals (default: dry-run only) |
| `APPROVE_DISABLED=1` | Turn off auto-approval entirely |
| `APPROVE_ORG` | Org to search for teammates' PRs (default `celesta-tech`) |

State lives in `${XDG_STATE_HOME:-~/.local/state}/check-behind-prs/`.
