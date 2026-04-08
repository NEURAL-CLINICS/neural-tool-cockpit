# · И E U R A L · neural-tool-cockpit
#
# make install   — copy every artifact into its production location
# make uninstall — remove everything the cockpit installed
# make update    — git pull + make install
#
# DRY_RUN=1 echoes commands without running them.

SHELL := /bin/bash

HOME_DIR         ?= /Users/blucid
CLAUDE_DIR       := $(HOME_DIR)/.claude
COMMANDS_DIR     := $(CLAUDE_DIR)/commands
ZSHRC_D_DIR      := $(HOME_DIR)/.zshrc.d
ORCH_DIR         := $(CLAUDE_DIR)/orchestrator
DASHBOARD_DIR    := $(ORCH_DIR)/dashboard
DASHBOARD_STATIC := $(DASHBOARD_DIR)/static
LOCAL_BIN        := $(HOME_DIR)/.local/bin
HANDOFFS_DIR     := $(CLAUDE_DIR)/handoffs
RESUME_QUEUE_DIR := $(ORCH_DIR)/resume-queue
LOGS_DIR         := $(ORCH_DIR)/logs
STATE_DIR        := $(ORCH_DIR)/state

ifeq ($(DRY_RUN),1)
  RUN := @echo
else
  RUN :=
endif

.PHONY: all install uninstall update dirs check

all: install

dirs:
	$(RUN) mkdir -p $(COMMANDS_DIR)
	$(RUN) mkdir -p $(ZSHRC_D_DIR)
	$(RUN) mkdir -p $(ORCH_DIR)
	$(RUN) mkdir -p $(DASHBOARD_DIR)
	$(RUN) mkdir -p $(DASHBOARD_STATIC)
	$(RUN) mkdir -p $(LOCAL_BIN)
	$(RUN) mkdir -p $(HANDOFFS_DIR)
	$(RUN) mkdir -p $(RESUME_QUEUE_DIR)
	$(RUN) mkdir -p $(LOGS_DIR)
	$(RUN) mkdir -p $(STATE_DIR)

install: dirs
	@echo "Installing neural-tool-cockpit to production locations"
	$(RUN) cp commands/fork-resume.md         $(COMMANDS_DIR)/fork-resume.md
	$(RUN) cp commands/fork-all-resume.md     $(COMMANDS_DIR)/fork-all-resume.md
	$(RUN) cp shell/30-nrl-cockpit.zsh        $(ZSHRC_D_DIR)/30-nrl-cockpit.zsh
	$(RUN) cp shell/vps-wrapper.sh            $(ORCH_DIR)/vps-wrapper.sh
	$(RUN) chmod +x                           $(ORCH_DIR)/vps-wrapper.sh
	$(RUN) cp launcher/nrl-cockpit            $(LOCAL_BIN)/nrl-cockpit
	$(RUN) chmod +x                           $(LOCAL_BIN)/nrl-cockpit
	$(RUN) cp dashboard/server.py             $(DASHBOARD_DIR)/server.py
	$(RUN) cp dashboard/run.sh                $(DASHBOARD_DIR)/run.sh
	$(RUN) chmod +x                           $(DASHBOARD_DIR)/run.sh
	$(RUN) cp dashboard/README.md             $(DASHBOARD_DIR)/README.md
	$(RUN) cp dashboard/com.neuralclinics.cockpit-dashboard.plist $(DASHBOARD_DIR)/com.neuralclinics.cockpit-dashboard.plist
	$(RUN) cp dashboard/static/index.html     $(DASHBOARD_STATIC)/index.html
	$(RUN) cp dashboard/static/style.css      $(DASHBOARD_STATIC)/style.css
	@echo ""
	@echo "Install complete."
	@echo "Next:"
	@echo "  1. Ensure ~/.zshrc sources ~/.zshrc.d/*.zsh"
	@echo "  2. Open a new terminal (or: source ~/.zshrc.d/30-nrl-cockpit.zsh)"
	@echo "  3. Run: nrl-cockpit"
	@echo "  4. Start the dashboard: bash $(DASHBOARD_DIR)/run.sh"

uninstall:
	@echo "Removing neural-tool-cockpit production files (runtime state kept)"
	$(RUN) rm -f $(COMMANDS_DIR)/fork-resume.md
	$(RUN) rm -f $(COMMANDS_DIR)/fork-all-resume.md
	$(RUN) rm -f $(ZSHRC_D_DIR)/30-nrl-cockpit.zsh
	$(RUN) rm -f $(ORCH_DIR)/vps-wrapper.sh
	$(RUN) rm -f $(LOCAL_BIN)/nrl-cockpit
	$(RUN) rm -f $(DASHBOARD_DIR)/server.py
	$(RUN) rm -f $(DASHBOARD_DIR)/run.sh
	$(RUN) rm -f $(DASHBOARD_DIR)/README.md
	$(RUN) rm -f $(DASHBOARD_DIR)/com.neuralclinics.cockpit-dashboard.plist
	$(RUN) rm -f $(DASHBOARD_STATIC)/index.html
	$(RUN) rm -f $(DASHBOARD_STATIC)/style.css
	@echo ""
	@echo "Uninstall complete."
	@echo "Note: runtime state in $(ORCH_DIR) (sessions.json, logs, state)"
	@echo "was preserved. Remove manually if desired."

update:
	@echo "Updating neural-tool-cockpit from origin/main"
	$(RUN) git pull origin main
	$(RUN) $(MAKE) install

check:
	@echo "Verifying installed artifacts"
	@test -f $(COMMANDS_DIR)/fork-resume.md         && echo "  OK  commands/fork-resume.md"         || echo "  MISSING commands/fork-resume.md"
	@test -f $(COMMANDS_DIR)/fork-all-resume.md     && echo "  OK  commands/fork-all-resume.md"     || echo "  MISSING commands/fork-all-resume.md"
	@test -f $(ZSHRC_D_DIR)/30-nrl-cockpit.zsh      && echo "  OK  shell/30-nrl-cockpit.zsh"        || echo "  MISSING shell/30-nrl-cockpit.zsh"
	@test -x $(ORCH_DIR)/vps-wrapper.sh             && echo "  OK  vps-wrapper.sh"                  || echo "  MISSING vps-wrapper.sh"
	@test -x $(LOCAL_BIN)/nrl-cockpit               && echo "  OK  nrl-cockpit"                     || echo "  MISSING nrl-cockpit"
	@test -f $(DASHBOARD_DIR)/server.py             && echo "  OK  dashboard/server.py"             || echo "  MISSING dashboard/server.py"
	@test -f $(DASHBOARD_STATIC)/index.html         && echo "  OK  dashboard/static/index.html"     || echo "  MISSING dashboard/static/index.html"
	@test -f $(DASHBOARD_STATIC)/style.css          && echo "  OK  dashboard/static/style.css"      || echo "  MISSING dashboard/static/style.css"
