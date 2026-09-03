# check-behind-prs

Watches your open GitHub pull requests and acts when one falls behind its base branch. Runs from cron every 5 minutes.

```bash
git clone git@github.com:modarche/check-behind-prs.git \
  && cd check-behind-prs
# [Optional] run once to check it is working
make run
# add to cron to run every 5 minutes
make add-cron
```

## What it does

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

## Requirements

`gh` (authenticated), `jq`, and on Linux `notify-send` and `xdg-open`. Conflict handling additionally needs `tmux` and `claude`; without them that half is skipped and you just get notifications.

## Configuration

| Variable | Effect |
| --- | --- |
| `DEV_DIR` | Where local clones live (default `~/dev`) |
| `AUTOFIX_DISABLED=1` | Don't stage `claude` sessions for conflicted PRs |
| `AUTOUPDATE_DISABLED=1` | Don't auto-update PRs that are merely behind |

State lives in `${XDG_STATE_HOME:-~/.local/state}/check-behind-prs/`.

```bash
make remove-cron  # stop it
```
