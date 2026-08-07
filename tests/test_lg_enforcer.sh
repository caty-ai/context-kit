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

case_disable_env_allowed() {
  local case_name="disable-env-allowed"
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
    record_fail "${case_name}" "expected CK_LG_ENFORCER_DISABLED=1 in the hook environment to bypass enforcement"
  fi
}

case_inline_bypass_allowed() {
  local case_name="inline-bypass-allowed"
  run_hook_command 'CK_LG_ENFORCER_DISABLED=1 grep -r foo /'
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected literal same-line CK_LG_ENFORCER_DISABLED=1 to bypass enforcement"
  fi
}

case_safe_markers_allowed() {
  local case_name="safe-markers-allowed"
  local entry
  local label
  local command
  local commands=(
    'already-wrapped|lg grep -r foo /'
    'pipe-head|grep -r foo / | head -n 5'
    'pipe-tail|grep -r foo / | tail -n 5'
    'pipe-wc|grep -r foo / | wc -l'
    'sort-uniq-count|grep -r foo / | sort | uniq -c'
    'leading-head|head -n 5 /var/log/system.log'
    'leading-tail|tail -n 5 /var/log/system.log'
    'redirect-file|grep -r foo / > out.txt'
    'find-maxdepth|find / -maxdepth 2 -name x'
    'journalctl-lines|journalctl -n 50'
  )

  for entry in "${commands[@]}"; do
    label=${entry%%|*}
    command=${entry#*|}
    run_hook_command "${command}"
    if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
      record_fail "${case_name}" "expected safe marker ${label} to pass"
      return
    fi
  done

  record_pass "${case_name}"
}

case_risky_blocks() {
  local case_name="risky-blocks"
  local entry
  local label
  local command
  local hint
  local cases=(
    'gh-api-paginate|gh api /repos/openai/openai --paginate|gh api --paginate is unbounded'
    'find-broad|find /tmp|find on a broad path without -maxdepth can return huge results'
    'journalctl|journalctl|journalctl without -n can return the whole journal'
    'dmesg|dmesg|dmesg dumps the full kernel buffer'
    'cat-log|cat server.log|cat on a .log file can be huge'
    'cat-var-log|cat /var/log/syslog|cat on /var/log can be huge'
    'grep-recursive|grep -r foo /|grep -r/-R can flood output'
  )

  for entry in "${cases[@]}"; do
    label=${entry%%|*}
    entry=${entry#*|}
    command=${entry%%|*}
    hint=${entry#*|}
    run_hook_command "${command}"
    if [ "${RUN_STATUS}" != "2" ] ||
       ! grep -Fq "${hint}" "${RUN_STDERR}" ||
       ! grep -Fq "${ROOT}/bin/lg ${command}" "${RUN_STDERR}" ||
       ! grep -Fq 'One-off bypass for incomplete nudges' "${RUN_STDERR}" ||
       grep -Fq 'set CK_LG_ENFORCER_DISABLED=1 in the same shell line' "${RUN_STDERR}"; then
      record_fail "${case_name}" "expected risky command ${label} to be blocked with the lg hint and bypass note"
      return
    fi
  done

  record_pass "${case_name}"
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

case_safe_markers_allowed
case_risky_blocks
case_empty_path_falls_back_to_lg
case_inline_bypass_allowed
case_disable_env_allowed
case_read_allowed
case_garbage_allowed
finish
