SHELL := /usr/bin/env bash
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

CHECK := $(ROOT)/bin/check-behind-prs
APPROVE := $(ROOT)/bin/auto-approve-prs
RESOLVE := $(ROOT)/bin/resolve-pr-conflicts
WORKER := $(ROOT)/libexec/stage-pr-autofix

EXECUTABLES := $(CHECK) $(APPROVE) $(RESOLVE) $(WORKER)
SOURCES := $(EXECUTABLES) $(wildcard $(ROOT)/lib/*.sh)

CRON_TAG := \# check-behind-prs
APPROVE_CRON_TAG := \# check-behind-prs-approve
CRON_LINE := */5 * * * * $(CHECK) >/dev/null 2>&1 $(CRON_TAG)
APPROVE_CRON_LINE := */5 * * * * $(APPROVE) >/dev/null 2>&1 $(APPROVE_CRON_TAG)
CRON_FILTER := grep -Fv '$(CRON_TAG)' | grep -Fv 'check-behind-prs.sh' | grep -Fv 'auto-approve-prs.sh'

.PHONY: help run run-approve resolve add-cron remove-cron check

help:
	@echo 'make run                          check your PRs once'
	@echo 'make run-approve                  check teammates PRs once (dry-run unless APPROVE_DRY_RUN=0)'
	@echo 'make resolve PR=<url|owner/repo#n>  stage a conflict-resolution session for one PR'
	@echo 'make add-cron                     run both checks every 5 minutes'
	@echo 'make remove-cron                  stop both checks'
	@echo 'make check                        syntax-check every script'

run:
	@$(CHECK)

run-approve:
	@$(APPROVE)

resolve:
	@test -n "$(PR)" || { echo 'usage: make resolve PR=<url|owner/repo#number> [ARGS=--dry-run]' >&2; exit 1; }
	@$(RESOLVE) $(ARGS) '$(PR)'

add-cron:
	@chmod +x $(EXECUTABLES)
	@{ crontab -l 2>/dev/null | $(CRON_FILTER) || true; \
		echo '$(CRON_LINE)'; echo '$(APPROVE_CRON_LINE)'; } | crontab -
	@echo "Cron entries added (auto-approve starts in dry-run)"

remove-cron:
	@{ crontab -l 2>/dev/null | $(CRON_FILTER) || true; } | crontab -
	@echo "Cron entries removed"

check:
	@for f in $(SOURCES); do bash -n "$$f" || exit 1; done
	@if command -v shellcheck >/dev/null 2>&1; \
		then shellcheck -x -P bin:libexec -e SC2016 $(EXECUTABLES); \
		else echo "(shellcheck not installed, syntax only)"; fi
	@echo "Scripts OK"
