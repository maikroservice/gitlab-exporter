.PHONY: test test-unit test-integration lint install install-deps

BATS        := bats
SHELLCHECK  := shellcheck
INSTALL_DIR := /usr/local/bin

test: test-unit test-integration

test-unit:
	$(BATS) tests/unit/

test-integration:
	$(BATS) tests/integration/

lint:
	$(SHELLCHECK) gitlab-exporter.sh lib/*.sh

install:
	install -m 755 gitlab-exporter.sh $(INSTALL_DIR)/gitlab-exporter
	chmod +x $(INSTALL_DIR)/gitlab-exporter

install-deps:
	brew install bats-core jq shellcheck
