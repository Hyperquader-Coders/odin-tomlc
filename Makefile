# odin-tomlc: Odin bindings for tomlc17. Consumed via -collection:tomlc=/path/to/odin-tomlc
BRANCH ?= main
REMOTE ?= origin
ROOT_COMMIT_MSG ?= Initial odin-tomlc

CC ?= cc
CFLAGS ?= -O2 -Wall -std=c17
ODIN ?= odin
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
TEST_FLAGS = -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $(if $(ASAN),-debug -sanitize:address)

.PHONY: all lib check test test-unit test-spec examples doc push lint ci help check-no-agent-files clean check-test-tag force-push

all: lib examples ## the static library and the example (the default)

lib: $(LIB) ## compile vendor/tomlc17 into libtomlc17.a

$(LIB): vendor/tomlc17/tomlc17.c vendor/tomlc17/tomlc17.h
	$(CC) $(CFLAGS) -c vendor/tomlc17/tomlc17.c -o vendor/tomlc17/tomlc17.o
	ar rcs $@ vendor/tomlc17/tomlc17.o

check: check-test-tag lib ## odin check the package and the example
	$(ODIN) check tomlc -no-entry-point
	$(ODIN) check examples/tomltest -collection:tomlc=.

examples: build/tomltest ## build the tomltest example driver

build/tomltest: $(LIB) $(wildcard examples/tomltest/*.odin tomlc/*.odin) vendor/tomlc17/VERSION
	@mkdir -p build
	$(ODIN) build examples/tomltest -out:$@ -o:speed -collection:tomlc=.

test: test-unit test-spec ## unit tests, then the toml-test corpus diff against upstream

test-unit: lib ## just the core:testing suite (ASAN=1 adds AddressSanitizer)
	@mkdir -p build
	$(ODIN) test tomlc $(TEST_FLAGS) -out:build/tomlc_test

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

lint: ## shellcheck any shell scripts
	@if command -v shellcheck >/dev/null; then \
		git ls-files | while read -r f; do \
			case "$$f" in *.sh|*.bash) echo "$$f";; \
			*) head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh' && echo "$$f";; esac; \
		done | xargs -r shellcheck --severity=warning && echo "shellcheck OK"; \
	else echo "shellcheck not installed, skipping (apt install shellcheck)"; fi

ci: check test lint check-no-agent-files ## everything a push must pass

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
