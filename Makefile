# dmons-scaffold: 0.5.0
# devlog — gate targets.
#
# Every gate prints its own exit code as `LABEL_EXIT:<n>` and exits with it, so a
# report can quote the code rather than an agent's reading of the output. This is
# not cosmetic: a tool can exit non-zero while printing output that reads exactly
# like a clean run. `zig fmt --check .` exits 1 while printing nothing but a list
# of file paths — output that scans like an inventory, not a failure.
#
# `gates` runs every gate in its set WITHOUT stopping at the first failure, so one
# invocation reports the whole picture instead of hiding the rest behind gate one.
#
# The active OpenSpec changes are discovered, not hardcoded, so the command string
# stays stable as changes come and go.

SHELL := /bin/bash

CHANGES := $(notdir $(patsubst %/,%,$(filter-out %/archive/,$(wildcard openspec/changes/*/))))

.PHONY: build test format fmt validate actions changes gates release clean

WORKFLOWS := $(wildcard .github/workflows/*.yml) $(wildcard .github/workflows/*.yaml)

# --- zig -----------------------------------------------------------------------

build:
	@zig build; code=$$?; echo "BUILD_EXIT:$$code"; exit $$code

test:
	@zig build test; code=$$?; echo "TEST_EXIT:$$code"; exit $$code

format:
	@zig fmt --check .; code=$$?; echo "FORMAT_EXIT:$$code"; exit $$code

# The fixer, not a gate — `format` above checks and reports, this one rewrites.
# It exists so that a worker whose diff fails FORMAT_EXIT has a target to reach
# for: without it the only way to fix formatting is `zig fmt` directly, which is
# exactly the raw-toolchain call the boundary tells workers not to make. Added
# during block 4B, when a worker hit that gap and (correctly) reported it.
# Prints its own exit code like every other target, but nothing gates on it.
fmt:
	@zig fmt .; code=$$?; echo "FMT_EXIT:$$code"; exit $$code

# --- spec ----------------------------------------------------------------------

# Validates every active change (archive excluded). No active change is a failure,
# not a silent pass — an empty run would otherwise report VALIDATE_EXIT:0 while
# having validated nothing.
validate:
	@fail=0; \
	if [ -z "$(CHANGES)" ]; then \
		echo "no active change found under openspec/changes/"; fail=1; \
	else \
		for c in $(CHANGES); do openspec validate $$c --strict || fail=1; done; \
	fi; \
	echo "VALIDATE_EXIT:$$fail"; exit $$fail

changes:
	@echo "$(CHANGES)"

# --- github actions ------------------------------------------------------------

# Lints the workflow files. Worth a gate because the release workflow is the one
# thing here that cannot be run locally: its first real execution is a tag push,
# and a typo in it surfaces as a failed release rather than a failed build.
#
# Two ways to pass vacuously, both refused, following `validate` above:
#   - actionlint missing -> fail with an install hint, never skip. A gate that
#     prints 0 because the checker was absent is exactly the failure this
#     Makefile exists to prevent.
#   - no workflow files -> fail. In this repo that means the release workflow
#     was deleted, not that there is nothing to check.
#
# actionlint shells out to shellcheck for `run:` blocks when shellcheck is on
# PATH, so it finds strictly more on a machine that has it. It never finds less
# that matters: the workflow-level errors are actionlint's own either way.
actions:
	@fail=0; \
	if ! command -v actionlint >/dev/null 2>&1; then \
		echo "actionlint not found — install it (brew install actionlint)"; fail=1; \
	elif [ -z "$(WORKFLOWS)" ]; then \
		echo "no workflow files found under .github/workflows/"; fail=1; \
	else \
		actionlint || fail=1; \
	fi; \
	echo "ACTIONS_EXIT:$$fail"; exit $$fail

# --- gate sets -----------------------------------------------------------------

gates:
	@$(MAKE) --no-print-directory -k build test format validate actions; code=$$?; \
	echo "GATES_EXIT:$$code"; exit $$code

# --- release & housekeeping ----------------------------------------------------

# The split is deliberate. `build.zig` owns cross-compilation — it is the thing
# that knows the targets, the optimize mode and how the version reaches the
# binary — and leaves three binaries under zig-out/release/<triple>/devlog. This
# target owns packaging, because `tar` and `shasum` are shell tools and the
# Makefile is the shell surface. Neither half reaches into the other's job.
#
# VERSION is read from build.zig.zon, which is the single source of the semver
# in tracked code. It is NOT passed back in as -Dversion: the default path
# already embeds this exact string, and passing it would make the override path
# — the one that can disagree with the manifest — the one every release uses.
#
# Not a gate, and `gates` does not run it: it cross-compiles three targets and
# is far too slow to sit in the inner loop. It prints its exit code like
# everything else here, because a release that half-failed must not read as
# clean either.
VERSION := $(shell sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' build.zig.zon)
TRIPLES := aarch64-macos x86_64-linux-musl aarch64-linux-musl

# macOS ships `shasum` and no `sha256sum`; a stock Ubuntu (including the image
# CI builds in) ships `sha256sum` and no `shasum`. Hardcoding either one means
# the checksum step fails on the other platform — and since `make release` is
# the last thing a tag push runs, that failure would first appear in CI, after
# the tarballs were already built. Verified by running both in a container.
SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo "sha256sum" || echo "shasum -a 256")

release:
	@set -o pipefail; fail=0; \
	if [ -z "$(VERSION)" ]; then \
		echo "could not read .version from build.zig.zon"; \
		echo "RELEASE_EXIT:1"; exit 1; \
	fi; \
	rm -rf zig-out/release zig-out/dist; \
	zig build release || fail=1; \
	if [ $$fail -eq 0 ]; then \
		mkdir -p zig-out/dist; \
		for t in $(TRIPLES); do \
			bin="zig-out/release/$$t/devlog"; \
			if [ ! -x "$$bin" ]; then echo "missing binary for $$t"; fail=1; continue; fi; \
			stage="zig-out/dist/devlog-$(VERSION)-$$t"; \
			mkdir -p "$$stage"; \
			cp "$$bin" LICENSE README.md "$$stage"/ || { fail=1; continue; }; \
			tar -C zig-out/dist -czf "zig-out/dist/devlog-$(VERSION)-$$t.tar.gz" \
				"devlog-$(VERSION)-$$t" || fail=1; \
			rm -rf "$$stage"; \
		done; \
		( cd zig-out/dist && $(SHA256) *.tar.gz > SHA256SUMS ) || fail=1; \
	fi; \
	echo "RELEASE_EXIT:$$fail"; exit $$fail

clean:
	@rm -rf zig-out .zig-cache; code=$$?; echo "CLEAN_EXIT:$$code"; exit $$code
