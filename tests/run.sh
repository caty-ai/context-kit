#!/usr/bin/env bash
#
# Batch test runner: discovers and runs every tests/test_*.sh suite,
# including tests/test_npm_installer.sh.
#
# - No fail-fast: every declared suite is executed even if an earlier one
#   fails.
# - Streams each suite's stdout/stderr live (no swallowing).
# - Prints a PASS/FAIL verdict per suite and a declared/executed summary.
# - Exits non-zero if any suite fails, or if zero suites are discovered.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TESTS_DIR="${ROOT}/tests"

DECLARED=0
EXECUTED=0
PASS_COUNT=0
FAIL_COUNT=0
FAILED_NAMES=""

# Discover suites: tests/test_*.sh, in glob expansion order. Uses a plain glob
# (bash 3.2 safe; no mapfile / associative arrays).
SUITES=()
for suite in "${TESTS_DIR}"/test_*.sh; do
  if [ -e "${suite}" ] || [ -L "${suite}" ]; then
    SUITES+=("${suite}")
  fi
done

DECLARED=${#SUITES[@]}

if [ "${DECLARED}" -eq 0 ]; then
  echo "FAIL: no test suites discovered under ${TESTS_DIR}/test_*.sh" >&2
  echo "declared: 0, executed: 0, passed: 0, failed: 0"
  exit 1
fi

for suite in "${SUITES[@]}"; do
  name=$(basename "${suite}")
  echo "==> running ${name}"

  status=0
  if bash "${suite}"; then
    status=0
  else
    status=$?
  fi

  EXECUTED=$((EXECUTED + 1))

  if [ "${status}" -eq 0 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "PASS ${name}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_NAMES="${FAILED_NAMES} ${name}"
    echo "FAIL ${name} (exit ${status})"
  fi
done

echo ""
echo "declared: ${DECLARED}, executed: ${EXECUTED}"
echo "passed: ${PASS_COUNT}, failed: ${FAIL_COUNT}"

if [ -n "${FAILED_NAMES}" ]; then
  echo "failed suites:${FAILED_NAMES}"
fi

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi

exit 0
