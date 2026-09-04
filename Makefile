.PHONY: test lint

SHELL := /bin/bash

test:
	bash tests/run.sh

lint:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "missing-dep: shellcheck" >&2; \
		exit 127; \
	fi; \
	if ! command -v git >/dev/null 2>&1; then \
		echo "missing-dep: git" >&2; \
		exit 127; \
	fi; \
	files=(); \
	sh_files=$$(git ls-files -- '*.sh') || { echo "lint: git ls-files failed" >&2; exit 1; }; \
	discovered_files=$$(git ls-files -- bin hooks) || { echo "lint: git ls-files failed" >&2; exit 1; }; \
	if [ -n "$$sh_files" ]; then \
		while IFS= read -r file; do \
			files+=("$$file"); \
		done <<< "$$sh_files"; \
	fi; \
	if [ -n "$$discovered_files" ]; then \
		while IFS= read -r file; do \
			first_line=$$(LC_ALL=C sed -n '1p' "$$file"); \
			if [[ "$$first_line" =~ ^\#\!.*[[:space:]/](bash|sh)([[:space:]]|$$) ]]; then \
				seen=0; \
				for listed in "$${files[@]}"; do \
					if [ "$$listed" = "$$file" ]; then seen=1; break; fi; \
				done; \
				if [ "$$seen" -eq 0 ]; then files+=("$$file"); fi; \
			fi; \
		done <<< "$$discovered_files"; \
	fi; \
	if [ "$${#files[@]}" -eq 0 ]; then \
		echo "lint: no shell scripts discovered — refusing to pass an empty lint (fail-closed)" >&2; \
		exit 1; \
	fi; \
	printf 'shellcheck: %s\n' "$${files[@]}"; \
	shellcheck --severity=warning "$${files[@]}"
