.PHONY: test lint

test:
	bash tests/run.sh

# lint is intentionally a no-op placeholder until a linter is adopted for
# this repo. Replace this target once shellcheck (or similar) is wired in.
lint:
	@echo "lint: no linter configured yet (placeholder)"
