#!/usr/bin/env bash
#
# Batch test runner: discovers and runs every tests/test_*.sh suite.
#
# - No fail-fast: every declared suite is executed even if an earlier one
#   fails.
# - Streams each suite's stdout/stderr live (no swallowing).
# - status 77 produces SKIP; status 0 produces PASS; other statuses produce
#   FAIL.
# - The EXIT trap emits the summary for every closed runner outcome.

set -euo pipefail

# DECLARED is the number of discovered suites. An interrupted run intentionally
# reports declared > executed + skipped, exposing a suite that was dropped.
DECLARED=0
EXECUTED=0
SKIP_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0
FAILED_NAMES=""

# shellcheck disable=SC2329 # The EXIT trap invokes finish indirectly.
finish() {
  rc=$?
  trap - EXIT
  printf 'suites: declared=%s executed=%s skipped=%s\n' "${DECLARED}" "${EXECUTED}" "${SKIP_COUNT}"
  printf 'passed: %s, failed: %s\n' "${PASS_COUNT}" "${FAIL_COUNT}"
  if [ -n "${FAILED_NAMES}" ]; then
    printf 'failed suites:%s\n' "${FAILED_NAMES}"
  fi

  if [ "${FAIL_COUNT}" -ne 0 ]; then
    exit 1
  fi

  case "${rc}" in
    0|1|2|127) exit "${rc}" ;;
    *) exit 1 ;;
  esac
}

trap finish EXIT
trap 'exit 1' HUP INT TERM

if [ "$#" -ne 0 ]; then
  printf 'usage: tests/run.sh\n' >&2
  exit 2
fi

if ! command -v bash >/dev/null 2>&1; then
  printf 'missing-dep: bash\n' >&2
  exit 127
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TESTS_DIR="${ROOT}/tests"

# Discover suites once, in glob expansion order. Uses a plain glob
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

  if [ "${status}" -eq 77 ]; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    echo "SKIP ${name}"
  elif [ "${status}" -eq 0 ]; then
    EXECUTED=$((EXECUTED + 1))
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "PASS ${name}"
  else
    FAILED_NAMES="${FAILED_NAMES} ${name}"
    EXECUTED=$((EXECUTED + 1))
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL ${name} (exit ${status})"
  fi
done

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi

exit 0
