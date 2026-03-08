# check-behind-prs

A script that checks whether any of your GitHub pull requests are behind their base branch and sends a clickable desktop notification so you can quickly open and update the PR.

```bash
git clone git@github.com:modarche/check-behind-prs.git \
  && cd check-behind-prs
# [Optional] run once to check it is working
make run
# add to cron to run every 5 minutes
make add-cron
```
