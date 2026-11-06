# Development shortcuts. The canonical commands live in AGENTS.md; this file only wraps them.

.PHONY: build test fmt fmt-check check e2e evals tla smoke clean

JOBS := $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu || nproc || echo 4)

build:
	zig build

test:
	zig build test

fmt:
	zig fmt src/

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

e2e:
	cd tests/e2e && bun install && FX_SOUND=0 bun test

evals:
	cd tests/evals && bun install && bun test

# Model-check one TLA+ folder, e.g. make tla DIR=recovery, or all in parallel: make tla
tla:
	@if [ -z "$(DIR)" ]; then \
		find tests/tla -mindepth 2 -name check.sh -perm +111 | xargs -P $(JOBS) -I{} sh -c \
			'dir=$$(dirname {}); echo "==> $$dir"; (cd "$$dir" && ./check.sh) || echo "FAIL $$dir"'; \
		exit 0; fi
	cd tests/tla/$(DIR) && ./check.sh

smoke: build
	./zig-out/bin/fx --help >/dev/null
	./zig-out/bin/fx status

clean:
	rm -rf zig-out .zig-cache
