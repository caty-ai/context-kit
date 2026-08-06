#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOK="${ROOT}/hooks/lg-enforcer.py"
TMP_DIR=$(mktemp -d)
PASS_COUNT=0
FAIL_COUNT=0
RUN_STDOUT=""
RUN_STDERR=""
RUN_STATUS=0

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

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

run_hook_json() {
  local payload="$1"
  RUN_STDOUT="${TMP_DIR}/stdout.$RANDOM"
  RUN_STDERR="${TMP_DIR}/stderr.$RANDOM"
  if printf '%s' "${payload}" | env CK_LG_PATH="${ROOT}/bin/lg" python3 "${HOOK}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
}

run_hook_command() {
  local command="$1"
  run_hook_json "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${command}\"}}"
}

case_read_allowed() {
  local case_name="read-allowed"
  run_hook_json '{"tool_name":"Read","tool_input":{"command":"grep -r foo /"}}'
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected non-Bash tool to pass through"
  fi
}

case_garbage_allowed() {
  local case_name="garbage-allowed"
  run_hook_json 'garbage'
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected malformed input to fail open"
  fi
}

case_disable_allowed() {
  local case_name="disable-allowed"
  local stdout_file="${TMP_DIR}/disabled.stdout"
  local stderr_file="${TMP_DIR}/disabled.stderr"
  local status_value=0
  if printf '%s' '{"tool_name":"Bash","tool_input":{"command":"grep -r foo /"}}' | env CK_LG_ENFORCER_DISABLED=1 python3 "${HOOK}" >"${stdout_file}" 2>"${stderr_file}"; then
    status_value=0
  else
    status_value=$?
  fi
  if [ "${status_value}" = "0" ] && [ ! -s "${stderr_file}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected CK_LG_ENFORCER_DISABLED=1 to bypass enforcement"
  fi
}

case_head_allowed() {
  local case_name="piped-head-allowed"
  run_hook_command 'grep -r foo / | head -n 5'
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected pre-trimmed command to pass"
  fi
}

case_recursive_grep_blocked() {
  local case_name="recursive-grep-blocked"
  run_hook_command 'grep -r foo /'
  if [ "${RUN_STATUS}" = "2" ] &&
     grep -Fq 'grep -r/-R can flood output' "${RUN_STDERR}" &&
     grep -Fq "${ROOT}/bin/lg grep -r foo /" "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected recursive grep to be blocked with lg hint"
  fi
}

case_empty_path_falls_back_to_lg() {
  local case_name="empty-path-falls-back-to-lg"
  RUN_STDOUT="${TMP_DIR}/stdout.$RANDOM"
  RUN_STDERR="${TMP_DIR}/stderr.$RANDOM"
  if printf '%s' '{"tool_name":"Bash","tool_input":{"command":"grep -r foo /"}}' | env CK_LG_PATH= python3 "${HOOK}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
  if [ "${RUN_STATUS}" = "2" ] &&
     grep -Fq '    lg grep -r foo /' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected empty CK_LG_PATH to fall back to lg"
  fi
}

case_head_allowed
case_recursive_grep_blocked
case_empty_path_falls_back_to_lg
case_disable_allowed
case_read_allowed
case_garbage_allowed
finish
