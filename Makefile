# odin-tomlc: Odin bindings for tomlc17. Consumed via -collection:tomlc=/path/to/odin-tomlc
BRANCH ?= main
REMOTE ?= origin
ROOT_COMMIT_MSG ?= Initial odin-tomlc

# AMBER_ROOT is the Amber tree, the folder holding the suite's checkouts: mise sets it on a
# development machine and the workflow sets it to its workspace. Unset, it is the folder holding
# this checkout: that fallback is for people outside the house, who clone the bindings side by side.
AMBER_ROOT ?= $(abspath $(CURDIR)/..)
# amber-house: the suite's shared checks; `make lint` runs its check-example-hosts where it is
# there. It is private, so a clone outside the house and the public runner go without it.
HOUSE ?= $(AMBER_ROOT)/amber-house

CC ?= cc
CFLAGS ?= -O2 -Wall -std=c17
ODIN ?= odin
# This repository's own collection, as its own checks and examples take it.
COLLECTIONS := -collection:tomlc=.
# The suite's names, the same in every Odin repository: ODIN_FLAGS is what every odin command here
# takes, the collections and the vet; ODIN_TEST_FLAGS adds what only a test run takes.
ODIN_FLAGS = $(COLLECTIONS) -vet -strict-style
ODIN_TEST_FLAGS = $(ODIN_FLAGS) -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $(if $(ASAN),-debug -sanitize:address)
BRANCH ?= main
REMOTE ?= origin

LIB = vendor/tomlc17/libtomlc17.a
UPSTREAM_COMMIT = $(shell sed -n 's/^commit: //p' vendor/tomlc17/VERSION)
CORPUS_COMMIT = $(shell sed -n 's/^corpus: .* //p' vendor/tomlc17/VERSION)
UPSTREAM = build/upstream
CORPUS = build/toml-test

# A test that leaks or frees badly fails, rather than only warning. `make test ASAN=1` runs
# the tests under AddressSanitizer as well.
ASAN ?=

.PHONY: help setup init-packages init-modules init-workstation check-toolchain ols all lib check test test-unit test-spec examples doc ci clean push force-push lint check-no-agent-files check-test-tag fmt check-fmt fmt-sh check-fmt-sh

all: lib examples ## the static library and the example (the default)

lib: $(LIB) ## compile vendor/tomlc17 into libtomlc17.a

$(LIB): vendor/tomlc17/tomlc17.c vendor/tomlc17/tomlc17.h
	$(CC) $(CFLAGS) -c vendor/tomlc17/tomlc17.c -o vendor/tomlc17/tomlc17.o
	ar rcs $@ vendor/tomlc17/tomlc17.o

check: check-test-tag lib ## odin check the package and the example
	$(ODIN) check tomlc $(ODIN_FLAGS) -no-entry-point
	$(ODIN) check examples/tomltest $(ODIN_FLAGS)

examples: build/tomltest ## build the tomltest example driver

build/tomltest: $(LIB) $(wildcard examples/tomltest/*.odin tomlc/*.odin) vendor/tomlc17/VERSION
	@mkdir -p build
	$(ODIN) build examples/tomltest $(ODIN_FLAGS) -out:$@ -o:speed

test: test-unit test-spec ## unit tests, then the toml-test corpus diff against upstream

test-unit: lib ## just the core:testing suite (ASAN=1 adds AddressSanitizer)
	@mkdir -p build
	$(ODIN) test tomlc $(ODIN_TEST_FLAGS) -out:build/tomlc_test

# Byte-identical output and exit code against upstream's own toml-test
# driver, over every file the official corpus lists for TOML 1.1.
test-spec: build/tomltest $(UPSTREAM)/driver $(CORPUS)/.at-$(CORPUS_COMMIT) ## just the corpus diff against upstream's driver
	python3 test/spec-diff.py $(UPSTREAM)/driver build/tomltest $(CORPUS)/tests

# The stamp, not the directory, is the prerequisite: a clone whose checkout
# failed would otherwise pass as done, and the reference driver would be
# built from whatever main is that day, not the C in vendor/, which is the
# whole premise of the comparison.
$(UPSTREAM)/.at-$(UPSTREAM_COMMIT):
	@mkdir -p build
	@test -d $(UPSTREAM)/.git || git clone -q https://github.com/cktan/tomlc17 $(UPSTREAM)
	git -C $(UPSTREAM) checkout -q $(UPSTREAM_COMMIT)
	@test "$$(git -C $(UPSTREAM) rev-parse HEAD)" = "$(UPSTREAM_COMMIT)"
	@touch $@

# Upstream's driver #includes tomlc17.c itself; built without its sanitizer
# flags, which change nothing it prints.
$(UPSTREAM)/driver: $(UPSTREAM)/.at-$(UPSTREAM_COMMIT)
	$(CC) -O2 -std=c17 -I$(UPSTREAM)/src $(UPSTREAM)/test/stdtest/parser.c -o $@

$(CORPUS)/.at-$(CORPUS_COMMIT):
	@mkdir -p build
	@test -d $(CORPUS)/.git || git clone -q https://github.com/toml-lang/toml-test $(CORPUS)
	git -C $(CORPUS) checkout -q $(CORPUS_COMMIT)
	@test "$$(git -C $(CORPUS) rev-parse HEAD)" = "$(CORPUS_COMMIT)"
	@touch $@

doc: lib ## odin doc
	$(ODIN) doc tomlc

push: ## push main to origin
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published: tracked, or present-and-unignored when
# a sweep of the tree would carry them.
check-no-agent-files: ## refuse agent files that are tracked or not ignored
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored"; \
			exit 2; \
		fi; \
	done
	@echo "no agent files staged for publication"

lint: ## the Odin and shell layout, the example hosts, and shellcheck over any shell scripts
	@if [ -x "$(HOUSE)/scripts/check-example-hosts" ]; then "$(HOUSE)/scripts/check-example-hosts" "$(CURDIR)"; \
	else echo "check-example-hosts not found in $(HOUSE)/scripts, skipping (amber-house is private; AMBER_ROOT or HOUSE finds it)"; fi
	@if command -v shellcheck >/dev/null; then \
		git ls-files | while read -r f; do \
			case "$$f" in *.sh|*.bash) echo "$$f";; \
			*) head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh' && echo "$$f";; esac; \
		done | xargs -r shellcheck --severity=warning && echo "shellcheck OK"; \
	elif [ "$$GITHUB_ACTIONS" = true ]; then echo "shellcheck is not installed on this runner; it is in DEPS"; exit 1; \
	else echo "shellcheck not installed, skipping (apt install shellcheck)"; fi

# Everything a push has to pass; CI (.github/workflows/ci.yml) runs the same.
ci: init-modules check test lint check-no-agent-files ## everything a push must pass

clean: ## remove build/ and the compiled library
	rm -rf build vendor/tomlc17/tomlc17.o $(LIB)

# `odin build` compiles a package's _test.odin files like any other file unless they
# start with #+test, so a test's imports and @(init) procs would ship in every program
# that imports the package. Files under tests/ are test programs and suites that no
# program imports.
check-test-tag:
	@bad=$$(git ls-files --cached --others --exclude-standard '*_test.odin' | grep -Ev '(^|/)tests/' | xargs -r grep -L '^#+test' || true); \
	if [ -n "$$bad" ]; then \
		echo "test files without #+test, which odin build compiles into programs:"; \
		printf '  %s\n' $$bad; \
		exit 2; \
	fi

force-push: check check-no-agent-files ## squash history into one signed root commit and force-push
	@test -z "$$(git status --porcelain)" || { \
		echo "Working tree is dirty. Commit, stash, or revert changes first."; \
		exit 2; \
	}
	@set -e; \
	orig_branch="$$(git branch --show-current)"; \
	test -n "$$orig_branch" || { echo "force-push: detached HEAD, check out a branch first"; exit 1; }; \
	tmp_branch="root-squash-$$(date +%s)"; \
	step="starting"; ok=0; \
	trap 'if [ "$$ok" != 1 ]; then echo "force-push FAILED while: $$step. Local history is intact on $$orig_branch; $(REMOTE)/$(BRANCH) was not replaced." >&2; git checkout -f "$$orig_branch" >/dev/null 2>&1 || true; git branch -D "$$tmp_branch" >/dev/null 2>&1 || true; exit 1; fi' EXIT; \
	step="creating the orphan branch"; git checkout --orphan "$$tmp_branch"; \
	step="staging the tree"; git add -A; \
	step="signing the root commit"; git commit -S -m "$(ROOT_COMMIT_MSG)"; \
	step="pushing to $(REMOTE)/$(BRANCH) (refused or unreachable)"; git push --force "$(REMOTE)" "$$tmp_branch:$(BRANCH)"; \
	step="verifying $(REMOTE)/$(BRANCH) equals the new commit"; \
	remote_sha="$$(git ls-remote "$(REMOTE)" "refs/heads/$(BRANCH)" | cut -f1)"; \
	test -n "$$remote_sha" && test "$$remote_sha" = "$$(git rev-parse HEAD)"; \
	ok=1; \
	git branch -M "$$tmp_branch" "$(BRANCH)"; \
	git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null 2>&1 || { git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 && git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null; } || echo "warning: could not set upstream"; \
	echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."

help: ## this list
	@awk 'BEGIN {FS = ":.*## "} \
	    /^##@ / {printf "\n%s\n", substr($$0, 5)} \
	    /^[a-z][a-z0-9-]*:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# The system packages, one list for a desk and for CI. The C is vendored and built here, so the
# list is the tools the targets call: shellcheck in lint, shfmt in fmt-sh. `make init-packages`
# installs it; a package missing on the runner is added here, and the workflow names none.
DEPS := shellcheck shfmt

# --- setup: amber-house scripts/binding/setup.mk, less runic, which this binding does not use ---
# `make init-packages` installs DEPS, the list above. CI runs `sudo apt-get update && make
# init-packages APT_FLAGS=-y`, then `make ci`; at a desk apt asks before it installs.
APT_FLAGS ?=

init-packages: ## install the system packages (sudo apt)
	sudo apt-get install $(APT_FLAGS) --no-install-recommends $(DEPS)

# A binding has no language packages: the C it binds is vendored. `ci` depends on it all the
# same, as in every repository.
init-modules: ## install the language packages from the lock: none here (the C is vendored)

# What apt does not bring is reported and never installed: the Odin compiler and odinfmt (which
# `make fmt` runs).
check-toolchain: ## check the toolchain and report anything missing
	@ok=true; \
	if command -v odin >/dev/null; then echo "odin: $$(odin version)"; \
	else echo "missing: odin (https://odin-lang.org/docs/install)"; ok=false; fi; \
	if command -v $(ODINFMT) >/dev/null; then echo "odinfmt: $$(command -v $(ODINFMT))"; \
	else echo "missing: odinfmt (apt install amber-ols)"; ok=false; fi; \
	$$ok

# ols.json is the Odin language server's settings, which an editor reads for completion and
# go-to-definition. It names the same collections as the build and takes a path as written, with
# no variables: so it is written from the build's collections, with absolute paths, and is not
# tracked. Run it again after a collection moves.
OLS_COLLECTIONS = $(sort $(filter -collection:%,$(COLLECTIONS)))
ols: ## write ols.json, the editor's settings, from the build's collections
	@{ printf '{\n\t"collections": [\n'; sep=''; \
	for c in $(patsubst -collection:%,%,$(OLS_COLLECTIONS)); do \
		printf '%b\t\t{ "name": "%s", "path": "%s" }' "$$sep" "$${c%%=*}" "$$(realpath -m "$${c#*=}")"; sep=',\n'; \
	done; \
	printf '\n\t],\n\t"enable_semantic_tokens": false,\n\t"enable_hover": true,\n\t"enable_snippets": false\n}\n'; } > ols.json
	@echo "ols: wrote ols.json, $(words $(OLS_COLLECTIONS)) collections"

init-workstation: ols check-toolchain ## set up a desk: ols.json and the toolchain report

# The one command after a fresh clone, the same in every repository.
setup: init-packages init-modules init-workstation ## everything a fresh clone needs: packages (sudo apt), ols.json, the toolchain report

# --- formatting: amber-house scripts/binding/fmt.mk, the same in every binding ---
# Hand-written Odin goes through odinfmt (amber-ols; odinfmt.json is amber-house's). What runic
# writes (each rune.yml's `out:`) and type_casts.odin are generated and stay as generated. Shell
# scripts go through shfmt, with tabs.
ODINFMT ?= odinfmt
ODIN_FMT ?= $(HOUSE)/scripts/odin-fmt
GENERATED = $(foreach y,$(wildcard */rune.yml),$(dir $(y))$(shell awk '$$1 == "out:" {print $$2}' $(y))) $(wildcard */type_casts.odin)
ODIN_SOURCES = git ls-files --cached --others --exclude-standard '*.odin' $(foreach g,$(GENERATED),':!$(g)')
# apt's shfmt, the one a CI runner has, before any other on the PATH: versions differ in layout.
SHFMT ?= $(firstword $(wildcard /usr/bin/shfmt) shfmt)
SHFMT_FLAGS = -i 0
SH_SOURCES = git ls-files -z --cached --others --exclude-standard | grep -zv '/$$' | xargs -0 -r $(SHFMT) -f

fmt: fmt-sh ## format the hand-written Odin and the shell scripts in place
	@$(ODIN_SOURCES) | ODINFMT=$(ODINFMT) $(ODIN_FMT)

check-fmt: check-fmt-sh ## fail when hand-written Odin or a shell script is not as make fmt leaves it
	@if ! command -v $(ODINFMT) >/dev/null; then if [ "$$GITHUB_ACTIONS" = true ]; then echo "odinfmt is not installed on this runner; the workflow asks for it (ols: true)"; exit 1; fi; echo "odinfmt not installed, skipping (apt install amber-ols)"; exit 0; fi; \
	bad=0; \
	for f in $$($(ODIN_SOURCES)); do \
		$(ODINFMT) -stdin < "$$f" | cmp -s - "$$f" || { echo "not formatted: $$f"; bad=1; }; \
	done; \
	if [ $$bad = 1 ]; then echo "fix: make fmt"; exit 1; fi; \
	echo "odinfmt OK"

fmt-sh: ## lay the shell scripts out in place
	@$(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -w

check-fmt-sh: ## fail when a shell script is not as make fmt-sh leaves it
	@if ! command -v $(SHFMT) >/dev/null; then \
		if [ "$$GITHUB_ACTIONS" = true ]; then echo "shfmt is not installed on this runner; the workflow installs it"; exit 1; fi; \
		echo "shfmt not installed, skipping (sudo apt install shfmt)"; exit 0; \
	fi; \
	bad=$$($(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -l 2>&1) || true; \
	if [ -n "$$bad" ]; then echo "not formatted:"; echo "$$bad"; echo "fix: make fmt"; exit 1; fi; \
	echo "shfmt OK"

lint: check-fmt
