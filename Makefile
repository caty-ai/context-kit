.PHONY: test lint

SHELL := /bin/bash

test:
	bash tests/run.sh

# The SC2155 exclusion covers 12 pre-existing findings in `tests/test_safety_hooks.sh`.
# #38 leaves that file untouched because #52 may edit it; remove the exclusion once it is clean.
lint:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "missing-dep: shellcheck" >&2; \
		exit 127; \
	fi; \
	files=(); \
	while IFS= read -r file; do \
		files+=("$$file"); \
	done < <(git ls-files -- '*.sh'); \
	while IFS= read -r file; do \
		first_line=$$(LC_ALL=C sed -n '1p' "$$file"); \
		if [[ "$$first_line" =~ ^\#\!.*[[:space:]/](bash|sh)([[:space:]]|$$) ]]; then \
			seen=0; \
			for listed in "$${files[@]}"; do \
				if [ "$$listed" = "$$file" ]; then seen=1; break; fi; \
			done; \
			if [ "$$seen" -eq 0 ]; then files+=("$$file"); fi; \
		fi; \
	done < <(git ls-files -- bin hooks); \
	if [ "$${#files[@]}" -eq 0 ]; then \
		echo "lint: no shell scripts found"; \
		exit 0; \
	fi; \
	printf 'shellcheck: %s\n' "$${files[@]}"; \
	shellcheck --severity=warning --exclude=SC2155 "$${files[@]}"
