# container-compose — build & install as a `container` CLI plugin.

PREFIX ?= /usr/local
PLUGIN_DIR := $(PREFIX)/libexec/container-plugins/compose
BUILD_CONFIG ?= release
BIN := .build/$(BUILD_CONFIG)/container-compose

.PHONY: build release debug test clean install uninstall fmt

build: release

release:
	swift build -c release

debug:
	swift build -c debug

# Runtime-layer tests (ContainerComposeKit) live here; spec-parser tests live in
# the ComposeKit package.
test:
	swift test

clean:
	swift package clean
	rm -rf .build

# Install as a `container` CLI plugin. The binary MUST be named `compose`
# inside <plugin>/bin so that `container compose ...` resolves to it.
install: release
	install -d "$(PLUGIN_DIR)/bin"
	install -m 0755 "$(BIN)" "$(PLUGIN_DIR)/bin/compose"
	install -m 0644 config.toml "$(PLUGIN_DIR)/config.toml"
	@echo "Installed to $(PLUGIN_DIR)"
	@echo "Restart services if running:  container system stop && container system start"
	@echo "Then:  container compose up"

uninstall:
	rm -rf "$(PLUGIN_DIR)"
	@echo "Removed $(PLUGIN_DIR)"

fmt:
	swift format --in-place --recursive Sources Package.swift
