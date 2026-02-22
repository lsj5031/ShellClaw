SHELL := /bin/bash
UNITS := minusculeclaw.service minusculeclaw-webhook.service minusculeclaw-tunnel.service minusculeclaw-heartbeat.service minusculeclaw-heartbeat.timer
SYSTEMD_DIR := $(HOME)/.config/systemd/user

.PHONY: help install uninstall start stop restart status logs logs-webhook logs-tunnel webhook-register webhook-unregister webhook-status lint test

help: ## Show this help
	@grep -E '^[a-z][-a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Service lifecycle ──────────────────────────────────────────────

install: ## Install systemd units and enable linger
	mkdir -p $(SYSTEMD_DIR)
	cp systemd/minusculeclaw*.service systemd/minusculeclaw*.timer $(SYSTEMD_DIR)/
	systemctl --user daemon-reload
	systemctl --user enable $(UNITS)
	loginctl enable-linger $(USER)
	@echo "✓ units installed, linger enabled (services survive logout & start on boot)"

uninstall: stop ## Remove systemd units
	systemctl --user disable $(UNITS) 2>/dev/null || true
	cd $(SYSTEMD_DIR) && rm -f $(UNITS)
	systemctl --user daemon-reload

start: ## Start all services
	systemctl --user start minusculeclaw-webhook.service
	systemctl --user start minusculeclaw-tunnel.service
	systemctl --user start minusculeclaw.service
	systemctl --user start minusculeclaw-heartbeat.timer
	@$(MAKE) --no-print-directory status

stop: ## Stop all services
	systemctl --user stop minusculeclaw.service minusculeclaw-webhook.service minusculeclaw-tunnel.service minusculeclaw-heartbeat.timer 2>/dev/null || true

restart: ## Restart all services
	$(MAKE) --no-print-directory stop
	sleep 1
	$(MAKE) --no-print-directory start

status: ## Show service status
	@systemctl --user status $(UNITS) --no-pager 2>/dev/null || true

# ── Logs ───────────────────────────────────────────────────────────

logs: ## Follow agent logs
	journalctl --user -u minusculeclaw.service -f

logs-webhook: ## Follow webhook server logs
	journalctl --user -u minusculeclaw-webhook.service -f

logs-tunnel: ## Follow tunnel logs
	journalctl --user -u minusculeclaw-tunnel.service -f

# ── Webhook management ─────────────────────────────────────────────

webhook-register: ## Register Telegram webhook
	./webhook_ctl.sh register

webhook-unregister: ## Unregister Telegram webhook (reverts to poll)
	./webhook_ctl.sh unregister

webhook-status: ## Show Telegram webhook info
	./webhook_ctl.sh status

# ── Dev ────────────────────────────────────────────────────────────

lint: ## Shellcheck all scripts
	shellcheck agent.sh asr.sh send_telegram.sh heartbeat.sh tts_to_voice.sh lib/common.sh

test: ## Quick smoke test (inject text)
	./agent.sh --inject-text "ping"
