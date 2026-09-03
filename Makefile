SHELL := /usr/bin/env bash
SCRIPT := check-behind-prs.sh
SCRIPT_PATH := $(abspath $(SCRIPT))
APPROVE_SCRIPT := auto-approve-prs.sh
APPROVE_SCRIPT_PATH := $(abspath $(APPROVE_SCRIPT))
CRON_LINE := */5 * * * * $(SCRIPT_PATH) >/dev/null 2>&1 # check-behind-prs
APPROVE_CRON_LINE := */5 * * * * $(APPROVE_SCRIPT_PATH) >/dev/null 2>&1 # check-behind-prs-approve

.PHONY: run run-approve add-cron remove-cron

run:
	./$(SCRIPT)

run-approve:
	./$(APPROVE_SCRIPT)

add-cron:
	@chmod +x "$(SCRIPT)" "$(APPROVE_SCRIPT)"
	@{ crontab -l 2>/dev/null | grep -Fv '# check-behind-prs' | grep -Fv '# check-behind-prs-approve' || true; \
		echo '$(CRON_LINE)'; echo '$(APPROVE_CRON_LINE)'; } | crontab -
	@echo "Cron entries added (auto-approve starts in dry-run)"

remove-cron:
	@{ crontab -l 2>/dev/null | grep -Fv '# check-behind-prs' | grep -Fv '# check-behind-prs-approve' || true; } | crontab -
	@echo "Cron entries removed"
