# Development shortcuts. The canonical commands live in AGENTS.md; this file only wraps them.

.DEFAULT_GOAL := help
.PHONY: help build test fmt fmt-check check e2e evals tla smoke release clean

JOBS := $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu || nproc || echo 4)

help:
	@grep -E '^# |^[a-z][a-z0-9_-]*:' $(firstword $(MAKEFILE_LIST)) | awk '/^# /{c=$$0; next} /^[a-z][a-z0-9_-]*:/{printf "%-12s %s\n", $$1, substr(c, 3); c=""}'

# zig build
build:
	zig build

# full unit test suite
test:
	zig build test

# format all Zig source
fmt:
	zig fmt src/

# the formatting check CI runs
fmt-check:
	zig fmt --check src/

# Formatting, boundaries, CLI shape, build, and unit tests: what CI runs first.
check: fmt-check
	bash scripts/check-agents-boundary.sh
	bash scripts/check-compactor-boundary.sh
	bash scripts/check-indexer-boundary.sh
	bash scripts/check-recovery-boundary.sh
	bash scripts/check-public-surface.sh
	python3 -m scripts.check_cli_shape
	zig build
	zig build test

# deterministic Bun e2e suite
e2e:
	cd tests/e2e && bun install && FX_SOUND=0 bun test

# LLM evals (needs AI_GATEWAY_API_KEY)
evals:
	cd tests/evals && bun install && bun test

# Model-check one TLA+ folder, e.g. make tla DIR=recovery, or all in parallel: make tla
tla:
	@if [ -z "$(DIR)" ]; then \
		find tests/tla -mindepth 2 -name check.sh -perm +111 | xargs -P $(JOBS) -I{} sh -c \
			'dir=$$(dirname {}); echo "==> $$dir"; (cd "$$dir" && ./check.sh) || echo "FAIL $$dir"'; \
		exit 0; fi
	cd tests/tla/$(DIR) && ./check.sh

# build then run --help and status
smoke: build
	./zig-out/bin/fx --help >/dev/null
	./zig-out/bin/fx status

# ReleaseSafe build with strip (what CI and the release pipeline build), then smoke it.
release:
	zig build -Doptimize=ReleaseSafe
	./zig-out/bin/fx --help >/dev/null
	./zig-out/bin/fx status

# remove build output
clean:
	rm -rf zig-out .zig-cache
