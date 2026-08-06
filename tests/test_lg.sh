#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LG="${ROOT}/bin/lg"
TMP_DIR=$(mktemp -d)
PASS_COUNT=0
FAIL_COUNT=0
RUN_STDOUT=""
RUN_STDERR=""
RUN_STATUS=0

cleanup() {
  chmod -R u+rwx "${TMP_DIR}" 2>/dev/null || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

run_capture() {
  RUN_STDOUT="${TMP_DIR}/stdout.$RANDOM"
  RUN_STDERR="${TMP_DIR}/stderr.$RANDOM"
  if "$@" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
}

record_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS %s\n' "$1"
}

record_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

finish() {
  if [ "${FAIL_COUNT}" -ne 0 ]; then
    exit 1
  fi
}

scratch_path_from_footer() {
  sed -n 's|^\[lg\] full output preserved: \(.*\) (TTL .*|\1|p' "$1"
}

case_usage() {
  local case_name="usage"
  run_capture env CK_SCRATCH_DIR="${TMP_DIR}/usage-scratch" "${LG}"
  if [ "${RUN_STATUS}" = "64" ] && grep -Fq 'usage: lg <command> [args...]' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected exit 64 with usage text"
  fi
}

case_small_full_temp_scratch() {
  local case_name="small-full-temp-scratch"
  local scratch_dir="${TMP_DIR}/scratch-small"
  run_capture env CK_SCRATCH_DIR="${scratch_dir}" "${LG}" bash -lc 'printf "small-output\n"'
  local scratch_file
  scratch_file=$(scratch_path_from_footer "${RUN_STDOUT}")
  if [ "${RUN_STATUS}" = "0" ] &&
     grep -Fq 'small-output' "${RUN_STDOUT}" &&
     [ -n "${scratch_file}" ] &&
     [ -f "${scratch_file}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected full output and persisted scratch file under temp CK_SCRATCH_DIR"
  fi
}

case_large_preview() {
  local case_name="large-preview-200-lines"
  local scratch_dir="${TMP_DIR}/scratch-preview"
  run_capture env CK_SCRATCH_DIR="${scratch_dir}" "${LG}" \
    bash -lc 'i=1; while [ "$i" -le 200 ]; do printf "line-%03d\n" "$i"; i=$((i + 1)); done'
  local scratch_file
  scratch_file=$(scratch_path_from_footer "${RUN_STDOUT}")
  if [ "${RUN_STATUS}" = "0" ] &&
     grep -Fq 'line-001' "${RUN_STDOUT}" &&
     grep -Fq 'line-040' "${RUN_STDOUT}" &&
     grep -Fq 'line-161' "${RUN_STDOUT}" &&
     grep -Fq 'line-200' "${RUN_STDOUT}" &&
     ! grep -Fq 'line-041' "${RUN_STDOUT}" &&
     ! grep -Fq 'line-160' "${RUN_STDOUT}" &&
     grep -Fq '... [120 lines omitted /' "${RUN_STDOUT}" &&
     [ -n "${scratch_file}" ] &&
     [ -f "${scratch_file}" ] &&
     grep -Fq 'mode: proactive-lg' "${scratch_file}" &&
     grep -Fq 'expiresAt:' "${scratch_file}" &&
     grep -Fq 'line-041' "${scratch_file}" &&
     grep -Fq 'line-160' "${scratch_file}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected 40/40 preview, omitted marker, and scratch metadata"
  fi
}

case_exit_code() {
  local case_name="exit-code-3"
  local scratch_dir="${TMP_DIR}/scratch-exit"
  run_capture env CK_SCRATCH_DIR="${scratch_dir}" "${LG}" bash -lc 'printf "failing-output\n"; exit 3'
  if [ "${RUN_STATUS}" = "3" ] &&
     grep -Fq 'failing-output' "${RUN_STDOUT}" &&
     grep -Fq 'exit_code=3' "${RUN_STDOUT}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected wrapped exit code 3 to be preserved"
  fi
}

case_read_only_fail_safe() {
  local case_name="read-only-scratch-fail-safe"
  local read_only_dir="${TMP_DIR}/read-only-scratch"
  mkdir -p "${read_only_dir}"
  chmod 500 "${read_only_dir}"
  run_capture env CK_SCRATCH_DIR="${read_only_dir}" "${LG}" \
    bash -lc 'printf "one\ntwo\nthree\nfour\n"; exit 7'
  chmod 700 "${read_only_dir}"
  local warning_count
  warning_count=$(grep -Fc 'scratch unavailable; returned full output instead' "${RUN_STDERR}" || true)
  if [ "${RUN_STATUS}" = "7" ] &&
     grep -Fq 'one' "${RUN_STDOUT}" &&
     grep -Fq 'two' "${RUN_STDOUT}" &&
     grep -Fq 'three' "${RUN_STDOUT}" &&
     grep -Fq 'four' "${RUN_STDOUT}" &&
     ! grep -Fq 'lines omitted' "${RUN_STDOUT}" &&
     [ "${warning_count}" = "1" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected full output, exit 7, and one warning on scratch failure"
  fi
}

case_usage
case_small_full_temp_scratch
case_large_preview
case_exit_code
case_read_only_fail_safe
finish
