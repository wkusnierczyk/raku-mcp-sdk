# ==============================================================================
# Raku MCP SDK
# ==============================================================================
#
# Usage:
#   make              - Show help
#   make all          - Build the complete project
#   make test         - Run test suite
#   make install      - Install the module globally on the local host
#
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

# Project metadata
PROJECT_NAME    := MCP
PROJECT_TITLE   := Raku MCP SDK
PROJECT_DESC    := Raku Implementation of the Model Context Protocol
VERSION         := 0.4.0
DEVELOPER_NAME  := Waclaw Kusnierczyk
DEVELOPER_EMAIL := waclaw.kusnierczyk@gmail.com
SOURCE_URL      := https://github.com/wkusnierczyk/raku-mcp-sdk
LICENSE_NAME    := MIT
LICENSE_URL     := https://opensource.org/licenses/MIT

# Directory structure
SOURCE_DIR      := lib
TEST_DIR        := t
EXAMPLES_DIR    := examples
DOCS_DIR        := docs
BUILD_DIR       := .build
DIST_DIR        := dist
COVERAGE_DIR    := .racoco
COVERAGE_REPORT := coverage-report
ARCH_DIR        := architecture
ARCH_MMD        := $(ARCH_DIR)/architecture.mmd
ARCH_PNG        := $(ARCH_DIR)/architecture.png

# File patterns
RAKU_EXT        := .rakumod
TEST_EXT        := .rakutest
RAKU_FILES      := $(shell find $(SOURCE_DIR) -name '*$(RAKU_EXT)' 2>/dev/null)
TEST_FILES      := $(shell find $(TEST_DIR) -name '*$(TEST_EXT)' 2>/dev/null)
EXAMPLE_FILES   := $(shell find $(EXAMPLES_DIR) -name '*.raku' 2>/dev/null)

# Metadata files
META_FILE       := META6.json
DIST_INI        := dist.ini
CHANGES_FILE    := Changes
README_FILE     := README.md

# Raku toolchain
RAKU            := raku
ZEF             := zef
PROVE           := prove6
MI6             := mi6
FEZ             := fez
RACOCO          := racoco
RACOCO_BIN      := $(shell command -v $(RACOCO) 2>/dev/null)
RACOCO_HOME_BIN := $(shell $(RAKU) -e 'say $$*REPO.repo-chain.grep(*.can("prefix")).first.prefix.Str ~ "/bin"' 2>/dev/null)
RACOCO_SITE_BIN := $(shell $(RAKU) -e 'say $$*REPO.repo-chain.grep(*.can("prefix")).map(*.prefix.Str).grep({ .contains("/site") })[0] ~ "/bin"' 2>/dev/null)
MMDC            := mmdc
MMDC_BIN        := $(shell command -v $(MMDC) 2>/dev/null)

# Tool options
RAKU_FLAGS      := -I$(SOURCE_DIR)
PROVE_FLAGS     := -I. -v
ZEF_FLAGS       := --deps-only
RACOCO_FLAGS    := -l
RACOCO_COVERAGE_FLAGS :=
MMDC_FLAGS      :=

# Installation options
INSTALL_GLOBAL  := --/test
INSTALL_LOCAL   := --to=home

# Colors for output (disable with NO_COLOR=1)
ifndef NO_COLOR
    CLR_GREEN   := \033[0;32m
    CLR_YELLOW  := \033[0;33m
    CLR_RED     := \033[0;31m
    CLR_BLUE    := \033[0;34m
    CLR_CYAN    := \033[0;36m
    CLR_RESET   := \033[0m
    CLR_BOLD    := \033[1m
else
    CLR_GREEN   :=
    CLR_YELLOW  :=
    CLR_RED     :=
    CLR_BLUE    :=
    CLR_CYAN    :=
    CLR_RESET   :=
    CLR_BOLD    :=
endif

# Verbosity (set V=1 for verbose output)
ifndef V
    Q := @
else
    Q :=
endif

# Version command args (allow: make version 1.2.3 "Description")
VERSION_INPUT := $(word 2, $(MAKECMDGOALS))
VERSION_ARGS_DESC := $(wordlist 3, 999, $(MAKECMDGOALS))
# Allow passing VERSION_NEW/VERSION_DESC via variables, or via positional args.
VERSION_NEW ?= $(VERSION_INPUT)
VERSION_DESC ?= $(strip $(VERSION_ARGS_DESC))
ifeq ($(firstword $(MAKECMDGOALS)),version)
    $(foreach word,$(wordlist 2, 999, $(MAKECMDGOALS)),$(eval $(word):;@:))
endif

# ------------------------------------------------------------------------------
# Diagnostic Functions (output to stderr)
# ------------------------------------------------------------------------------

# Print an informational message
# Usage: $(call log-info,message)
define log-info
	@printf "$(CLR_BLUE)→ $(1)$(CLR_RESET)\n" >&2
endef

# Print a success message
# Usage: $(call log-success,message)
define log-success
	@printf "$(CLR_GREEN)✓ $(1)$(CLR_RESET)\n" >&2
endef

# Print a warning message
# Usage: $(call log-warning,message)
define log-warning
	@printf "$(CLR_YELLOW)⚠ $(1)$(CLR_RESET)\n" >&2
endef

# Print an error message
# Usage: $(call log-error,message)
define log-error
	@printf "$(CLR_RED)✗ $(1)$(CLR_RESET)\n" >&2
endef

# Print a step/progress message
# Usage: $(call log-step,message)
define log-step
	@printf "  $(CLR_CYAN)•$(CLR_RESET) $(1)\n" >&2
endef

# Print a header/section message
# Usage: $(call log-header,message)
define log-header
	@printf "\n$(CLR_BOLD)$(CLR_CYAN)$(1)$(CLR_RESET)\n" >&2
	@printf "$(CLR_CYAN)%s$(CLR_RESET)\n" "$$(printf '─%.0s' $$(seq 1 $$(printf '%s' '$(1)' | wc -c)))" >&2
endef

# Print a plain message to stderr
# Usage: $(call log,message)
define log
	@printf "$(1)\n" >&2
endef

# ------------------------------------------------------------------------------
# Default target - Show help
# ------------------------------------------------------------------------------

.PHONY: help
# help: Show Makefile usage and targets
help:
	$(call log,)
	$(call log,$(CLR_CYAN)╔══════════════════════════════════════════════════════════════════╗$(CLR_RESET))
	$(call log,$(CLR_CYAN)║$(CLR_RESET)                  $(CLR_GREEN)$(PROJECT_TITLE)$(CLR_RESET) - Build System                     $(CLR_CYAN)║$(CLR_RESET))
	$(call log,$(CLR_CYAN)╚══════════════════════════════════════════════════════════════════╝$(CLR_RESET))
	$(call log,)
	$(call log,$(CLR_YELLOW)Usage:$(CLR_RESET) make [target])
	$(call log,)
	$(call log,$(CLR_YELLOW)Primary Targets:$(CLR_RESET))
	$(call log,  $(CLR_GREEN)all$(CLR_RESET)                  Build the complete project)
	$(call log,  $(CLR_GREEN)build$(CLR_RESET)                Build/compile the project)
	$(call log,  $(CLR_GREEN)test$(CLR_RESET)                 Run the test suite)
	$(call log,  $(CLR_GREEN)install$(CLR_RESET)              Install the module globally)
	$(call log,  $(CLR_GREEN)clean$(CLR_RESET)                Remove all build artifacts)
	$(call log,)
	$(call log,$(CLR_YELLOW)Development Targets:$(CLR_RESET))
	$(call log,  $(CLR_GREEN)dependencies$(CLR_RESET)         Install project dependencies)
	$(call log,  $(CLR_GREEN)dependencies-dev$(CLR_RESET)     Install development dependencies)
	$(call log,  $(CLR_GREEN)lint$(CLR_RESET)                 Run linter/static analysis)
	$(call log,  $(CLR_GREEN)format$(CLR_RESET)               Format source code)
	$(call log,  $(CLR_GREEN)check$(CLR_RESET)                Run all checks (lint + test))
	$(call log,)
	$(call log,$(CLR_YELLOW)Testing Targets:$(CLR_RESET))
	$(call log,  $(CLR_GREEN)test$(CLR_RESET)                 Run all tests)
	$(call log,  $(CLR_GREEN)test-verbose$(CLR_RESET)         Run tests with verbose output)
	$(call log,  $(CLR_GREEN)test-file$(CLR_RESET)            Run a specific test (FILE=path))
	$(call log,  $(CLR_GREEN)coverage$(CLR_RESET)             Generate test coverage report)
	$(call log,)
	$(call log,$(CLR_YELLOW)Distribution Targets:$(CLR_RESET))
	$(call log,  $(CLR_GREEN)dist$(CLR_RESET)                 Create distribution tarball)
	$(call log,  $(CLR_GREEN)release$(CLR_RESET)              Release to Zef ecosystem)
	$(call log,  $(CLR_GREEN)docs$(CLR_RESET)                 Generate documentation)
	$(call log,  $(CLR_GREEN)architecture-diagram$(CLR_RESET) Build architecture diagram PNG)
	$(call log,)
	$(call log,$(CLR_YELLOW)Utility Targets:$(CLR_RESET))
	$(call log,  $(CLR_GREEN)about$(CLR_RESET)                Show project information)
	$(call log,  $(CLR_GREEN)validate$(CLR_RESET)             Validate META6.json)
	$(call log,  $(CLR_GREEN)repl$(CLR_RESET)                 Start REPL with project loaded)
	$(call log,  $(CLR_GREEN)run-example$(CLR_RESET)          Run an example (EXAMPLE=name))
	$(call log,  $(CLR_GREEN)info$(CLR_RESET)                 Show toolchain information)
	$(call log,)
	$(call log,$(CLR_YELLOW)Environment Variables:$(CLR_RESET))
	$(call log,  V=1           Verbose output)
	$(call log,  NO_COLOR=1    Disable colored output)
	$(call log,  FILE=<path>   Specify file for test-file target)
	$(call log,  EXAMPLE=<n>   Specify example for run-example target)
	$(call log,)

# ------------------------------------------------------------------------------
# About Target
# ------------------------------------------------------------------------------

.PHONY: about
# about: Show project metadata from Makefile variables
about:
	$(call log,)
	$(call log,$(PROJECT_TITLE): $(PROJECT_DESC))
	$(call log,├─ version:    $(VERSION))
	$(call log,├─ developer:  mailto:$(DEVELOPER_EMAIL))
	$(call log,├─ source:     $(SOURCE_URL))
	$(call log,└─ licence:    $(LICENSE_NAME) $(LICENSE_URL))
	$(call log,)

# ------------------------------------------------------------------------------
# Primary Targets
# ------------------------------------------------------------------------------

.PHONY: all
# all: Install deps, build, and test
all: dependencies build test
	$(call log-success,Build complete)

.PHONY: build
# build: Validate metadata and precompile modules
build: validate build-precompile
	$(call log-success,Build successful)

.PHONY: build-precompile
# build-precompile: Precompile the main module
build-precompile: $(RAKU_FILES)
	$(call log-info,Precompiling modules...)
	$(Q)$(RAKU) -I$(SOURCE_DIR) -e 'use $(PROJECT_NAME)' 2>/dev/null || \
		$(RAKU) -I$(SOURCE_DIR) -c $(SOURCE_DIR)/$(PROJECT_NAME)$(RAKU_EXT)
	$(call log-success,Precompilation complete)

.PHONY: test
# test: Build and run the test suite
test: build
	$(call log-info,Running tests...)
	$(Q)$(PROVE) $(PROVE_FLAGS) $(TEST_DIR)
	$(call log-success,All tests passed)

.PHONY: install
# install: Build and install module globally
install: build
	$(call log-info,Installing $(PROJECT_NAME)...)
	$(Q)$(ZEF) install . $(INSTALL_GLOBAL)
	$(call log-success,Installation complete)

.PHONY: clean
# clean: Remove build, coverage, and dist artifacts
clean: clean-build clean-coverage clean-dist
	$(call log-success,Clean complete)

# ------------------------------------------------------------------------------
# Clean Targets
# ------------------------------------------------------------------------------

.PHONY: clean-build
# clean-build: Remove build and precomp artifacts
clean-build:
	$(call log-info,Cleaning build artifacts...)
	$(Q)rm -rf $(BUILD_DIR)
	$(Q)rm -rf .precomp
	$(Q)find . -name '*.precomp' -type d -exec rm -rf {} + 2>/dev/null || true
	$(Q)find . -name '.precomp' -type d -exec rm -rf {} + 2>/dev/null || true

.PHONY: clean-coverage
# clean-coverage: Remove coverage reports
clean-coverage:
	$(call log-info,Cleaning coverage data...)
	$(Q)rm -rf $(COVERAGE_DIR)
	$(Q)rm -rf $(COVERAGE_REPORT)

.PHONY: clean-dist
# clean-dist: Remove distribution artifacts
clean-dist:
	$(call log-info,Cleaning distribution artifacts...)
	$(Q)rm -rf $(DIST_DIR)
	$(Q)rm -f *.tar.gz
	$(Q)rm -f $(PROJECT_NAME)-*.tar.gz

.PHONY: clean-all
# clean-all: Remove all build artifacts including docs build output
clean-all: clean
	$(call log-info,Deep cleaning...)
	$(Q)rm -rf $(DOCS_DIR)/_build
	$(call log-success,Deep clean complete)

# ------------------------------------------------------------------------------
# Dependency Management
# ------------------------------------------------------------------------------

.PHONY: dependencies
# dependencies: Install runtime dependencies
dependencies: $(META_FILE)
	$(call log-info,Installing dependencies...)
	$(Q)$(ZEF) install $(ZEF_FLAGS) .
	$(call log-success,Dependencies installed)

.PHONY: dependencies-dev
# dependencies-dev: Install development-only dependencies
dependencies-dev: dependencies
	$(call log-info,Installing development dependencies...)
	$(Q)$(ZEF) install App::Prove6 || true
	$(Q)$(ZEF) install Test::META || true
	$(Q)$(ZEF) install App::Mi6 || true
	$(Q)$(ZEF) install App::Racoco || true
	$(call log-success,Development dependencies installed)

.PHONY: dependencies-update
# dependencies-update: Update installed dependencies
dependencies-update:
	$(call log-info,Updating dependencies...)
	$(Q)$(ZEF) update
	$(Q)$(ZEF) upgrade
	$(call log-success,Dependencies updated)

# ------------------------------------------------------------------------------
# Code Quality
# ------------------------------------------------------------------------------

.PHONY: lint
# lint: Run syntax and metadata checks
lint: lint-syntax lint-meta
	$(call log-success,Linting complete)

.PHONY: lint-syntax
# lint-syntax: Compile-check all source files
lint-syntax: $(RAKU_FILES)
	$(call log-info,Checking syntax...)
	$(Q)for file in $(RAKU_FILES); do \
		printf "  $(CLR_CYAN)•$(CLR_RESET) Checking %s\n" "$$file" >&2; \
		$(RAKU) -I$(SOURCE_DIR) -c "$$file" || exit 1; \
	done
	$(call log-success,Syntax check passed)

.PHONY: lint-meta
# lint-meta: Validate META6.json required fields
lint-meta: $(META_FILE)
	$(call log-info,Validating META6.json...)
	$(Q)$(RAKU) -e 'use JSON::Fast; my $$m = from-json(slurp "$(META_FILE)"); \
		die "Missing name" unless $$m<name>; \
		die "Missing version" unless $$m<version>; \
		die "Missing provides" unless $$m<provides>;' >&2
	$(call log-success,META6.json is valid)

.PHONY: format
# format: Show formatting guidance and check for common issues
format:
	$(call log-info,Formatting code...)
	$(call log-warning,Raku does not have a standard formatter yet.)
	$(call log-step,Consider using consistent indentation (4 spaces))
	$(call log-step,Following community style guidelines)
	$(call log,)
	$(call log-info,Checking for common issues...)
	$(Q)for file in $(RAKU_FILES); do \
		if grep -q '	' "$$file" 2>/dev/null; then \
			printf "  $(CLR_YELLOW)⚠$(CLR_RESET) Warning: tabs found in %s\n" "$$file" >&2; \
		fi; \
		if grep -qE '\s+$$' "$$file" 2>/dev/null; then \
			printf "  $(CLR_YELLOW)⚠$(CLR_RESET) Warning: trailing whitespace in %s\n" "$$file" >&2; \
		fi; \
	done
	$(call log-success,Format check complete)

.PHONY: format-fix
# format-fix: Remove trailing whitespace from sources/tests
format-fix:
	$(call log-info,Fixing formatting issues...)
	$(Q)for file in $(RAKU_FILES) $(TEST_FILES); do \
		if [ -f "$$file" ]; then \
			sed -i 's/[[:space:]]*$$//' "$$file" 2>/dev/null || \
			sed -i '' 's/[[:space:]]*$$//' "$$file"; \
			printf "  $(CLR_CYAN)•$(CLR_RESET) Fixed trailing whitespace in %s\n" "$$file" >&2; \
		fi; \
	done
	$(call log-success,Formatting fixes applied)

.PHONY: check
# check: Run lint and tests
check: lint test
	$(call log-success,All checks passed)

# ------------------------------------------------------------------------------
# Testing
# ------------------------------------------------------------------------------

.PHONY: test-verbose
# test-verbose: Run tests with verbose output
test-verbose: build
	$(call log-info,Running tests (verbose)...)
	$(Q)$(PROVE) $(PROVE_FLAGS) --verbose $(TEST_DIR)

.PHONY: test-file
# test-file: Run a specific test file (FILE=path)
test-file: build
ifndef FILE
	$(call log-error,FILE not specified)
	$(call log,Usage: make test-file FILE=t/01-types.rakutest)
	@exit 1
endif
	$(call log-info,Running test: $(FILE)...)
	$(Q)$(RAKU) -I. $(FILE)

.PHONY: test-quick
# test-quick: Run tests without a build step
test-quick:
	$(call log-info,Running quick tests...)
	$(Q)$(PROVE) -I. $(TEST_DIR)

.PHONY: coverage
# coverage: Generate coverage report (if Racoco installed)
coverage: dependencies-dev build
	$(call log-info,Generating coverage report...)
	@RACOCO_CMD="$(RACOCO_BIN)"; \
	if [ -z "$$RACOCO_CMD" ]; then RACOCO_CMD="$(RACOCO)"; fi; \
	if ! command -v "$$RACOCO_CMD" >/dev/null 2>&1; then \
		if [ -x "$(RACOCO_HOME_BIN)/racoco" ]; then RACOCO_CMD="$(RACOCO_HOME_BIN)/racoco"; fi; \
		if [ -x "$(RACOCO_SITE_BIN)/racoco" ]; then RACOCO_CMD="$(RACOCO_SITE_BIN)/racoco"; fi; \
	fi; \
	if ! command -v "$$RACOCO_CMD" >/dev/null 2>&1 && [ ! -x "$$RACOCO_CMD" ]; then \
		printf "RaCoCo not found on PATH\\n" >&2; \
		printf "Try: zef install App::RaCoCo\\n" >&2; \
		exit 1; \
	fi; \
	"$$RACOCO_CMD" $(RACOCO_COVERAGE_FLAGS) --html --cache-dir=$(COVERAGE_REPORT) \
		--exec="$(PROVE) $(PROVE_FLAGS) $(TEST_DIR)"
	$(call log-success,Coverage report generated: $(COVERAGE_REPORT)/report.html)

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------

.PHONY: validate
# validate: Validate META6.json and provides entries
validate: validate-meta validate-provides
	$(call log-success,Validation complete)

.PHONY: validate-meta
# validate-meta: Validate required META6.json fields
validate-meta: $(META_FILE)
	$(call log-info,Validating META6.json...)
	$(Q)$(RAKU) -MJSON::Fast -e ' \
		my %meta = from-json(slurp "$(META_FILE)"); \
		my @required = <name version description provides>; \
		for @required -> $$field { \
			die "Missing required field: $$field" unless %meta{$$field}; \
		}' >&2

.PHONY: validate-provides
# validate-provides: Validate META6.json provides paths
validate-provides: $(META_FILE)
	$(call log-info,Validating provides entries...)
	$(Q)$(RAKU) -MJSON::Fast -e ' \
		my %meta = from-json(slurp "$(META_FILE)"); \
		for %meta<provides>.kv -> $$module, $$path { \
			die "Missing file: $$path (for $$module)" unless $$path.IO.e; \
			say "  ✓ $$module → $$path"; \
		}' >&2

# ------------------------------------------------------------------------------
# Distribution
# ------------------------------------------------------------------------------

.PHONY: dist
# dist: Create a source distribution tarball
dist: clean validate
	$(call log-info,Creating distribution...)
	$(Q)mkdir -p $(DIST_DIR)
	$(Q)tar --exclude='$(DIST_DIR)' \
		--exclude='$(BUILD_DIR)' \
		--exclude='$(COVERAGE_DIR)' \
		--exclude='.git' \
		--exclude='.precomp' \
		--exclude='*.tar.gz' \
		-czvf $(DIST_DIR)/$(PROJECT_NAME)-$(VERSION).tar.gz .
	$(call log-success,Distribution created: $(DIST_DIR)/$(PROJECT_NAME)-$(VERSION).tar.gz)

.PHONY: release
# release: Interactive release helper for Zef
release: check dist
	$(call log-info,Releasing to ecosystem...)
	$(call log,$(CLR_YELLOW)Choose release method:$(CLR_RESET))
	$(call log,  1. $(CLR_CYAN)fez upload$(CLR_RESET) - Upload directly to Zef ecosystem)
	$(call log,  2. $(CLR_CYAN)mi6 release$(CLR_RESET) - Use mi6 for release management)
	$(call log,)
	$(call log,$(CLR_YELLOW)To release manually:$(CLR_RESET))
	$(call log,  $$ fez upload)
	$(call log,)
	@read -p "Proceed with fez upload? [y/N] " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		$(FEZ) upload; \
	else \
		printf "Release cancelled.\n" >&2; \
	fi

# ------------------------------------------------------------------------------
# Documentation
# ------------------------------------------------------------------------------

.PHONY: docs
# docs: Generate text documentation into docs/
docs:
	$(call log-info,Generating documentation...)
	$(Q)mkdir -p $(DOCS_DIR)
	$(Q)for file in $(RAKU_FILES); do \
		out="$(DOCS_DIR)/$${file#$(SOURCE_DIR)/}"; \
		out="$${out%$(RAKU_EXT)}.txt"; \
		mkdir -p "$$(dirname "$$out")"; \
		printf "  $(CLR_CYAN)•$(CLR_RESET) %s\n" "$$out" >&2; \
		$(RAKU) -I$(SOURCE_DIR) --doc=Text "$$file" > "$$out"; \
	done
	$(call log-success,Documentation generated)

.PHONY: docs-serve
# docs-serve: Start documentation server (not implemented)
docs-serve: docs
	$(call log-info,Starting documentation server...)
	$(call log-warning,Not yet implemented)

.PHONY: architecture-diagram
# architecture-diagram: Build PNG from architecture/architecture.mmd
architecture-diagram: $(ARCH_PNG)
	$(call log-success,Architecture diagram generated)

$(ARCH_PNG): $(ARCH_MMD)
	$(call log-info,Generating architecture diagram...)
	$(Q)mkdir -p $(ARCH_DIR)
	$(Q)if [ -z "$(MMDC_BIN)" ]; then \
		echo "mmdc not found. Install @mermaid-js/mermaid-cli or set MMDC."; \
		exit 1; \
	fi
	$(Q)$(MMDC) $(MMDC_FLAGS) -i $(ARCH_MMD) -o $(ARCH_PNG)

# ------------------------------------------------------------------------------
# Utility Targets
# ------------------------------------------------------------------------------

.PHONY: repl
# repl: Start REPL with the project loaded
repl:
	$(call log-info,Starting REPL with $(PROJECT_NAME) loaded...)
	$(Q)$(RAKU) -I$(SOURCE_DIR) -M$(PROJECT_NAME)

.PHONY: run-example
# run-example: Run an example (EXAMPLE=name)
run-example:
ifndef EXAMPLE
	$(call log,$(CLR_YELLOW)Available examples:$(CLR_RESET))
	@for ex in $(EXAMPLE_FILES); do \
		printf "  • %s\n" "$$(basename $$ex .raku)" >&2; \
	done
	$(call log,)
	$(call log,Usage: make run-example EXAMPLE=simple-server)
else
	$(call log-info,Running example: $(EXAMPLE)...)
	$(Q)$(RAKU) -I$(SOURCE_DIR) $(EXAMPLES_DIR)/$(EXAMPLE).raku
endif

.PHONY: info
# info: Show toolchain versions and project stats
info:
	$(call log-header,Toolchain Information)
	@$(RAKU) --version 2>/dev/null | head -1 | xargs -I{} printf "  Raku:   %s\n" "{}" >&2 || printf "  Raku:   not found\n" >&2
	@$(ZEF) --version 2>/dev/null | head -1 | xargs -I{} printf "  Zef:    %s\n" "{}" >&2 || printf "  Zef:    not found\n" >&2
	@$(PROVE) --version 2>/dev/null | head -1 | xargs -I{} printf "  Prove6: %s\n" "{}" >&2 || printf "  Prove6: not found\n" >&2
	$(call log,)
	$(call log-header,Project Statistics)
	$(call log,  Source files:  $(words $(RAKU_FILES)) modules)
	$(call log,  Test files:    $(words $(TEST_FILES)) test files)
	$(call log,  Examples:      $(words $(EXAMPLE_FILES)) examples)
	$(call log,)

.PHONY: list-modules
# list-modules: List module files in lib/
list-modules:
	$(call log-header,Modules in $(SOURCE_DIR))
	@for file in $(RAKU_FILES); do \
		printf "  %s\n" "$$file" >&2; \
	done

.PHONY: list-tests
# list-tests: List test files in t/
list-tests:
	$(call log-header,Tests in $(TEST_DIR))
	@for file in $(TEST_FILES); do \
		printf "  %s\n" "$$file" >&2; \
	done

# ------------------------------------------------------------------------------
# Installation Variants
# ------------------------------------------------------------------------------

.PHONY: install-local
# install-local: Build and install module locally (home)
install-local: build
	$(call log-info,Installing $(PROJECT_NAME) locally...)
	$(Q)$(ZEF) install . $(INSTALL_LOCAL)
	$(call log-success,Local installation complete)

.PHONY: install-force
# install-force: Force install module (overwrites)
install-force:
	$(call log-info,Force installing $(PROJECT_NAME)...)
	$(Q)$(ZEF) install . --force-install
	$(call log-success,Force installation complete)

.PHONY: uninstall
# uninstall: Uninstall the module
uninstall:
	$(call log-info,Uninstalling $(PROJECT_NAME)...)
	$(Q)$(ZEF) uninstall $(PROJECT_NAME) || true
	$(call log-success,Uninstallation complete)

# ------------------------------------------------------------------------------
# CI/CD Helpers
# ------------------------------------------------------------------------------

.PHONY: ci
# ci: Run CI pipeline (deps + lint + test)
ci: dependencies lint test
	$(call log-success,CI pipeline complete)

.PHONY: ci-full
# ci-full: Run full CI pipeline (deps-dev + lint + test + coverage)
ci-full: dependencies-dev lint test coverage
	$(call log-success,Full CI pipeline complete)

# ------------------------------------------------------------------------------
# Version Management
# ------------------------------------------------------------------------------

.PHONY: version
# version: Show version (or update version when args provided)
version:
ifneq ($(VERSION_NEW),)
	@if [ -z "$(VERSION_DESC)" ]; then \
		$(call log-error,Description is required); \
		$(call log,Usage: make version 1.2.3 "Description"); \
		exit 1; \
	fi
	$(call log-info,Updating project version to $(VERSION_NEW)...)
	$(Q)perl -0pi -e 's/^VERSION\\s*:=\\s*.*/VERSION := $(VERSION_NEW)/m' Makefile
	$(Q)perl -0pi -e 's/"version"\\s*:\\s*"[^"]*"/"version": "$(VERSION_NEW)"/' $(META_FILE)
	$(call log-success,Version updated in Makefile and $(META_FILE))
	$(call log-info,Creating git tag v$(VERSION_NEW)...)
	$(Q)git tag -a "v$(VERSION_NEW)" -m "$(VERSION_DESC)"
	$(call log-success,Tag created locally: v$(VERSION_NEW))
else
	$(call log,$(PROJECT_NAME) v$(VERSION))
endif

.PHONY: bump-patch
# bump-patch: Placeholder for patch bump
bump-patch:
	$(call log-warning,Version bumping not yet implemented)
	$(call log-step,Edit META6.json manually or use mi6)

.PHONY: bump-minor
# bump-minor: Placeholder for minor bump
bump-minor:
	$(call log-warning,Version bumping not yet implemented)
	$(call log-step,Edit META6.json manually or use mi6)

.PHONY: bump-major
# bump-major: Placeholder for major bump
bump-major:
	$(call log-warning,Version bumping not yet implemented)
	$(call log-step,Edit META6.json manually or use mi6)

# ------------------------------------------------------------------------------
# Special Targets
# ------------------------------------------------------------------------------

# Prevent make from treating these as files
.PHONY: all build test install clean dependencies lint format check \
        validate dist release docs repl info ci about

# Default goal
.DEFAULT_GOAL := help
