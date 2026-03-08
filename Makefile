SHELL := /usr/bin/env bash
SCRIPT := check-behind-prs.sh
SCRIPT_PATH := $(abspath $(SCRIPT))
CRON_LINE := */5 * * * * $(SCRIPT_PATH) >/dev/null 2>&1 # check-behind-prs

.PHONY: run add-cron remove-cron

run:
	./$(SCRIPT)

add-cron:
	@chmod +x "$(SCRIPT)"
	@{ crontab -l 2>/dev/null | grep -Fv '# check-behind-prs' || true; echo '$(CRON_LINE)'; } | crontab -
	@echo "Cron entry added"

remove-cron:
	@{ crontab -l 2>/dev/null | grep -Fv '# check-behind-prs' || true; } | crontab -
	@echo "Cron entry removed"
