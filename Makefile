# claude-gw — deploy and roll back the gateway's own config.
# Run INSIDE the container as root from the repo checkout (/opt/claude-gw).
#
#   make deploy TAG=v0.1      checkout tag, install units/bin/hooks, restart profiles
#   make deploy               same, but requires HEAD to be exactly on a tag
#   make rollback             redeploy the previously deployed tag
#   make status               what is deployed, unit states, last health
#   make verify               shellcheck + systemd-analyze verify, no changes
#   make rcctl                build dist/rcctl (on a machine with docker) and record its sha256
#   make test-docker          rc-inspect and alert tests in a Debian 13 container (needs docker and network)
#
# Rules enforced here (design: Change control and rollback):
#   - working tree must be clean
#   - HEAD must be on a tag (TAG= checks it out first)
#   - env files in /etc/claude-rc are never written by deploy

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

PREFIX      ?= /usr/local
HOOK_DIR    := $(PREFIX)/lib/claude-rc/hooks
STATE_DIR   := /var/lib/claude-rc
UNIT_DIR    := /etc/systemd/system
PROFILES    ?= $(shell ls /etc/claude-rc/*.env 2>/dev/null | xargs -rn1 basename | sed 's/\.env$$//')
DEPLOYED    := /etc/claude-rc/DEPLOYED_TAG
PREVIOUS    := /etc/claude-rc/PREVIOUS_TAG
GO_IMAGE    := golang:1.27.3-bookworm
TEST_IMAGE  := debian:trixie-slim

.PHONY: deploy rollback status verify rcctl test-docker _preflight _install _restart bootstrap

deploy:
	@if [ -n "$$(git status --porcelain)" ]; then echo "refusing: working tree is dirty"; exit 1; fi
	if [ -n "$(TAG)" ]; then git fetch -q --tags || true; git checkout -q "$(TAG)"; fi
	# Fresh make: the install recipes must come from the Makefile at the tag, not the one make already parsed.
	$(MAKE) --no-print-directory _preflight _install _restart TAG=
	echo "deployed $$(cat $(DEPLOYED)) for profiles: $(PROFILES)"

_preflight:
	@if grep -lE '^[A-Za-z_]+=[^#]*[[:space:]]#' /etc/claude-rc/*.env 2>/dev/null; then echo "refusing: inline # comment in the env file(s) above; systemd keeps it in the value"; exit 1; fi
	tag=$$(git describe --tags --exact-match 2>/dev/null) || { echo "refusing: HEAD is not on a tag (use TAG=vX.Y)"; exit 1; }
	echo "deploying $$tag"
	if [ -f $(DEPLOYED) ] && [ "$$(cat $(DEPLOYED))" != "$$tag" ]; then cp $(DEPLOYED) $(PREVIOUS); fi

_install:
	install -d $(PREFIX)/bin $(HOOK_DIR) $(STATE_DIR) /var/log/claude-rc /etc/claude-rc
	install -m 0755 bin/rc-start bin/rc-health bin/rc-alert bin/rc-update bin/rc-inspect bin/ntfy-send $(PREFIX)/bin/
	install -m 0755 profiles/hooks/*.sh $(HOOK_DIR)/
	install -m 0644 systemd/claude-rc@.service systemd/claude-rc-alert@.service \
	                systemd/claude-rc-health.service systemd/claude-rc-health.timer \
	                systemd/claude-rc-update.service systemd/claude-rc-update.timer $(UNIT_DIR)/
	install -m 0440 systemd/sudoers.d/claude-rc /etc/sudoers.d/claude-rc
	# Traverse-only: rcctl reads DEPLOYED_TAG and CLAUDE_VERSION by name; the env files stay 0600.
	chmod 0751 /etc/claude-rc
	if [ -f dist/rcctl ]; then
	  (cd dist && sha256sum -c --quiet ../rcctl/rcctl.sha256) || { echo "refusing: dist/rcctl does not match rcctl/rcctl.sha256"; exit 1; }
	  id -u rcctl >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin rcctl
	  install -m 0755 dist/rcctl $(PREFIX)/bin/
	  install -m 0644 systemd/rcctl.service $(UNIT_DIR)/
	else
	  echo "no dist/rcctl: control page not installed (make rcctl builds it)"
	fi
	# Root-only dirs: profiles get their own pre-created log file and nothing else (no squatting, no symlinks).
	chown root:root /var/log/claude-rc $(STATE_DIR); chmod 0755 /var/log/claude-rc; chmod 0700 $(STATE_DIR)
	find $(STATE_DIR) -mindepth 1 \( ! -user root -o ! -type f \) -delete
	# Hooks and deny rules as root-owned managed settings: they win over, and cannot be edited by, any profile.
	install -d -m 0755 /etc/claude-code
	install -m 0644 profiles/settings.json /etc/claude-code/managed-settings.json
	for p in $(PROFILES); do
	  # Root-only: systemd reads it as root; no profile can read any env file, its own included (AT11).
	  chown root:root /etc/claude-rc/$$p.env; chmod 0600 /etc/claude-rc/$$p.env
	  l=/var/log/claude-rc/$$p.log
	  if [ -L "$$l" ] || [ ! -f "$$l" ] || [ "$$(stat -c %U "$$l")" != "$$p" ]; then
	    rm -f "$$l"; install -o $$p -g cc-lab -m 0600 /dev/null "$$l"
	  fi
	done
	git describe --tags --exact-match > $(DEPLOYED)
	claude --version > /etc/claude-rc/CLAUDE_VERSION 2>/dev/null || true
	systemctl daemon-reload

_restart:
	systemctl enable --now claude-rc-health.timer
	for p in $(PROFILES); do
	  systemctl reset-failed claude-rc@$$p 2>/dev/null || true
	  systemctl enable claude-rc@$$p
	  systemctl restart claude-rc@$$p
	done
	# Opt-in: only restarted if already enabled and running (systemctl enable --now rcctl).
	systemctl try-restart rcctl 2>/dev/null || true
	# Announce the deploy (or rollback) as soon as every server is healthy and has stayed up 10 s,
	# or after 60 s if not, so a planned restart reads as one on the phone. Here rather than in
	# deploy: this recipe comes from the new tag.
	echo "waiting for the servers to be ready (up to 60 s)"
	now=$$(cat $(DEPLOYED)); was=$$(cat $(PREVIOUS) 2>/dev/null || echo none); kind=deploy-unhealthy
	for i in $$(seq 30); do
	  if $(PREFIX)/bin/rc-health --ready; then kind=deployed; echo "ready after about $$((i * 2)) s"; break; fi
	  sleep 2
	done
	[ $$kind = deployed ] || echo "WARNING: not healthy 60 s after the deploy; consider make rollback"
	for p in $(PROFILES); do PROFILE=$$p $(PREFIX)/bin/rc-alert $$kind "$$now (was $$was)" || true; done
	sleep 3; systemctl --no-pager --plain status 'claude-rc@*' | head -n 40 || true

rollback:
	@[ -f $(PREVIOUS) ] || { echo "no previous tag recorded"; exit 1; }
	$(MAKE) deploy TAG=$$(cat $(PREVIOUS))

status:
	@echo "deployed: $$(cat $(DEPLOYED) 2>/dev/null || echo none)   previous: $$(cat $(PREVIOUS) 2>/dev/null || echo none)"
	echo "claude:   $$(cat /etc/claude-rc/CLAUDE_VERSION 2>/dev/null || echo ?)"
	systemctl --no-pager --plain list-units 'claude-rc*' || true
	for p in $(PROFILES); do echo "-- $$p"; cat $(STATE_DIR)/health-$$p.json 2>/dev/null || echo "no health state"; done

verify:
	bash -n bin/* bootstrap/*.sh proxmox/*.sh profiles/hooks/*.sh
	if command -v shellcheck >/dev/null; then shellcheck -S warning bin/* bootstrap/*.sh proxmox/*.sh profiles/hooks/*.sh; else echo "shellcheck not installed"; fi
	if command -v systemd-analyze >/dev/null; then systemd-analyze verify systemd/*.service systemd/*.timer; else echo "systemd-analyze not installed, units not checked"; fi
	jq . profiles/settings.json >/dev/null && echo "settings.json ok"
	if command -v go >/dev/null; then (cd rcctl && go vet ./... && go test ./...); else echo "go not installed, rcctl not checked"; fi

rcctl:
	# Reproducible: same source and image, same sha256. Commit rcctl/rcctl.sha256 with the release.
	docker run --rm -v "$(CURDIR)":/src -v rcctl-gomod:/go/pkg/mod -w /src/rcctl -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=amd64 -e GOFLAGS=-mod=readonly \
	  $(GO_IMAGE) go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o /src/dist/rcctl .
	cd dist && shasum -a 256 rcctl > ../rcctl/rcctl.sha256 && cat ../rcctl/rcctl.sha256

bootstrap:
	bash bootstrap/bootstrap.sh

test-docker:
	for t in tests/docker/*.sh; do echo "== $$t"; docker run --rm -v "$$PWD":/r:ro $(TEST_IMAGE) bash /r/$$t || exit 1; done
