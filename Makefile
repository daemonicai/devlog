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

.PHONY: build test format fmt validate changes gates clean

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

# --- gate sets -----------------------------------------------------------------

gates:
	@$(MAKE) --no-print-directory -k build test format validate; code=$$?; \
	echo "GATES_EXIT:$$code"; exit $$code

# --- release & housekeeping ----------------------------------------------------

clean:
	@rm -rf zig-out .zig-cache; code=$$?; echo "CLEAN_EXIT:$$code"; exit $$code
