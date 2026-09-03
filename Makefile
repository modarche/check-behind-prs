SHELL := /usr/bin/env bash
SCRIPT := check-behind-prs.sh
SCRIPT_PATH := $(abspath $(SCRIPT))
APPROVE_SCRIPT := auto-approve-prs.sh
APPROVE_SCRIPT_PATH := $(abspath $(APPROVE_SCRIPT))
CRON_TAG := \# check-behind-prs
APPROVE_CRON_TAG := \# check-behind-prs-approve
CRON_LINE := */5 * * * * $(SCRIPT_PATH) >/dev/null 2>&1 $(CRON_TAG)
APPROVE_CRON_LINE := */5 * * * * $(APPROVE_SCRIPT_PATH) >/dev/null 2>&1 $(APPROVE_CRON_TAG)

.PHONY: run run-approve add-cron remove-cron

run:
	./$(SCRIPT)

run-approve:
	./$(APPROVE_SCRIPT)

CRON_FILTER := grep -Fv '$(SCRIPT)' | grep -Fv '$(APPROVE_SCRIPT)'

add-cron:
	@chmod +x "$(SCRIPT)" "$(APPROVE_SCRIPT)"
	@{ crontab -l 2>/dev/null | $(CRON_FILTER) || true; \
		echo '$(CRON_LINE)'; echo '$(APPROVE_CRON_LINE)'; } | crontab -
	@echo "Cron entries added (auto-approve starts in dry-run)"

remove-cron:
	@{ crontab -l 2>/dev/null | $(CRON_FILTER) || true; } | crontab -
	@echo "Cron entries removed"
