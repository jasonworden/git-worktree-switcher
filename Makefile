ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
RUST := $(ROOT)rust

.PHONY: help check fmt lint test test-rust test-shell build build-release clean

help: ## Show this help
	@grep -E '^[a-z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ── Quick checks ─────────────────────────────────────────────────
check: fmt lint test ## Run everything (format check + lint + tests)

fmt: ## Check Rust formatting
	cd $(RUST) && cargo fmt --check

lint: ## Run clippy with warnings as errors
	cd $(RUST) && cargo clippy -- -D warnings

# ── Tests ────────────────────────────────────────────────────────
test: test-rust test-shell ## Run all tests

test-rust: ## Run Rust unit tests
	cd $(RUST) && cargo test

test-shell: build ## Run ShellSpec integration tests
	cd $(ROOT) && shellspec

# ── Build ────────────────────────────────────────────────────────
build: ## Build wt-core (debug)
	cd $(RUST) && cargo build

build-release: ## Build wt-core (release, optimized)
	cd $(RUST) && cargo build --release

# ── Fix ──────────────────────────────────────────────────────────
fix: ## Auto-fix formatting and clippy suggestions
	cd $(RUST) && cargo fmt && cargo clippy --fix --allow-dirty -- -D warnings

clean: ## Remove build artifacts
	cd $(RUST) && cargo clean
