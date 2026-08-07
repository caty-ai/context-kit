#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOK="${ROOT}/hooks/validate-subagent-brief.sh"
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

long_text() {
  python3 -c 'print("x" * 600, end="")'
}

payload_for() {
  local tool_name="$1"
  local subagent_type="$2"
  local prompt="$3"
  python3 - "${tool_name}" "${subagent_type}" "${prompt}" <<'PY'
import json
import sys

print(json.dumps({
    "tool_name": sys.argv[1],
    "tool_input": {
        "subagent_type": sys.argv[2],
        "prompt": sys.argv[3],
    },
}))
PY
}

run_hook() {
  local payload="$1"
  shift
  RUN_STDOUT="${TMP_DIR}/stdout.$RANDOM"
  RUN_STDERR="${TMP_DIR}/stderr.$RANDOM"
  if printf '%s' "${payload}" | env "$@" bash "${HOOK}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
}

canonical_prompt() {
  printf '## 実装仕様\n## 実装チェック\n## レビュー基準\n%s' "$(long_text)"
}

case_missing_all_blocks() {
  local case_name="missing-all-blocks"
  local payload
  payload=$(payload_for Agent executor "$(long_text)")
  run_hook "${payload}"
  if [ "${RUN_STATUS}" = "2" ] &&
     grep -Fq 'Missing sections: ## 実装仕様, ## 実装チェック, ## レビュー基準' "${RUN_STDERR}" &&
     grep -Fq 'https://github.com/caty-ai/family-dev-handbook/blob/main/docs/07-delegation-brief.md' "${RUN_STDERR}" &&
     grep -Fq 'CK_SKIP_BRIEF_VALIDATION=1' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a long incomplete prompt to name all missing sections and exit 2"
  fi
}

case_compliant_allowed() {
  local case_name="compliant-allowed"
  local payload
  payload=$(payload_for Agent executor "$(canonical_prompt)")
  run_hook "${payload}"
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDOUT}" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected all three canonical sections to pass silently"
  fi
}

case_one_missing_blocks_exactly() {
  local case_name="one-missing-blocks-exactly"
  local prompt
  local payload
  local missing_line
  prompt=$(printf '## 実装仕様\n## レビュー基準\n%s' "$(long_text)")
  payload=$(payload_for Agent executor "${prompt}")
  run_hook "${payload}"
  missing_line=$(grep '^Missing sections:' "${RUN_STDERR}" || true)
  if [ "${RUN_STATUS}" = "2" ] && [ "${missing_line}" = 'Missing sections: ## 実装チェック' ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected the missing-section line to name exactly the absent section"
  fi
}

case_short_allowed() {
  local case_name="short-allowed"
  run_hook "$(payload_for Agent executor 'quick lookup')"
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a short prompt to skip validation"
  fi
}

case_default_skip_allowed() {
  local case_name="default-writer-skip-allowed"
  run_hook "$(payload_for Agent writer "$(long_text)")"
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected the default writer type to skip validation"
  fi
}

case_skip_override_replaces_defaults() {
  local case_name="skip-override-replaces-defaults"
  run_hook "$(payload_for Agent research-lite "$(long_text)")" CK_BRIEF_SKIP_SUBAGENT_TYPES=research-lite
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected the configured research type to skip validation"
    return
  fi
  run_hook "$(payload_for Agent writer "$(long_text)")" CK_BRIEF_SKIP_SUBAGENT_TYPES=research-lite
  if [ "${RUN_STATUS}" = "2" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected an override to replace rather than extend the default skip list"
  fi
}

case_custom_sections_enforced() {
  local case_name="custom-sections-enforced"
  local required='## Goal|## Self-check|## Review criteria'
  local custom_prompt
  custom_prompt=$(printf '## Goal\n## Self-check\n## Review criteria\n%s' "$(long_text)")
  run_hook "$(payload_for Agent executor "${custom_prompt}")" CK_BRIEF_REQUIRED_SECTIONS="${required}"
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected all configured section tokens to pass"
    return
  fi
  run_hook "$(payload_for Agent executor "$(canonical_prompt)")" CK_BRIEF_REQUIRED_SECTIONS="${required}"
  if [ "${RUN_STATUS}" = "2" ] &&
     grep -Fq 'Missing sections: ## Goal, ## Self-check, ## Review criteria' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected canonical tokens alone to fail under a custom required set"
  fi
}

case_matching_is_exact() {
  local case_name="matching-is-case-sensitive-and-not-normalized"
  local required='## Goal|## Self-check|## Review criteria'
  local lowercase_prompt
  local wrong_level_prompt
  lowercase_prompt=$(printf '## goal\n## self-check\n## review criteria\n%s' "$(long_text)")
  run_hook "$(payload_for Agent executor "${lowercase_prompt}")" CK_BRIEF_REQUIRED_SECTIONS="${required}"
  if [ "${RUN_STATUS}" != "2" ]; then
    record_fail "${case_name}" "expected case variants to remain missing"
    return
  fi
  wrong_level_prompt=$(canonical_prompt)
  wrong_level_prompt=${wrong_level_prompt#\#}
  run_hook "$(payload_for Agent executor "${wrong_level_prompt}")"
  if [ "${RUN_STATUS}" = "2" ] &&
     grep -Fxq 'Missing sections: ## 実装仕様' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a one-hash heading not to satisfy the exact token"
  fi
}

case_threshold_override_and_fallback() {
  local case_name="threshold-override-and-fallback"
  local prompt
  prompt=$(python3 -c 'print("x" * 120, end="")')
  run_hook "$(payload_for Agent executor "${prompt}")" CK_BRIEF_MIN_PROMPT_CHARS=100
  if [ "${RUN_STATUS}" != "2" ]; then
    record_fail "${case_name}" "expected the numeric threshold override to trigger validation"
    return
  fi
  run_hook "$(payload_for Agent executor "${prompt}")" CK_BRIEF_MIN_PROMPT_CHARS=not-a-number
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a non-numeric threshold to fall back to 500"
  fi
}

case_task_and_other_tools() {
  local case_name="task-accepted-other-tools-allowed"
  run_hook "$(payload_for Task executor "$(long_text)")"
  if [ "${RUN_STATUS}" != "2" ]; then
    record_fail "${case_name}" "expected Task to use the same validation path as Agent"
    return
  fi
  run_hook "$(payload_for Bash executor "$(long_text)")"
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected non-Agent/Task tools to pass through"
  fi
}

case_malformed_inputs_fail_open() {
  local case_name="malformed-inputs-fail-open"
  local payload
  local payloads=(
    ''
    'garbage'
    '[]'
    '{}'
    '{"tool_name":"Agent"}'
    '{"tool_name":"Agent","tool_input":{"prompt":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}'
    '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":42}}'
  )
  for payload in "${payloads[@]}"; do
    run_hook "${payload}" CK_BRIEF_MIN_PROMPT_CHARS=1
    if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDOUT}" ] || [ -s "${RUN_STDERR}" ]; then
      record_fail "${case_name}" "expected empty, malformed, non-dict, missing-field, and non-string inputs to pass silently"
      return
    fi
  done
  record_pass "${case_name}"
}

case_launcher_bypass() {
  local case_name="launcher-bypass"
  run_hook "$(payload_for Agent executor "$(long_text)")" CK_SKIP_BRIEF_VALIDATION=1
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDOUT}" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected the launcher environment bypass to pass silently"
  fi
}

case_missing_body_fail_open() {
  local case_name="missing-body-fail-open"
  local isolated_dir="${TMP_DIR}/missing-body"
  local isolated_hook="${isolated_dir}/validate-subagent-brief.sh"
  local payload
  mkdir -p "${isolated_dir}"
  cp "${HOOK}" "${isolated_hook}"
  payload=$(payload_for Agent executor "$(long_text)")
  RUN_STDOUT="${TMP_DIR}/missing-body.stdout"
  RUN_STDERR="${TMP_DIR}/missing-body.stderr"
  if bash "${isolated_hook}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}" <<<"${payload}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDOUT}" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a launcher without its Python body to fail open silently"
  fi
}

case_interpreter_status_two_fail_open() {
  local case_name="interpreter-status-two-fail-open"
  local fake_bin="${TMP_DIR}/fake-bin"
  local fake_python="${fake_bin}/python3"
  local payload
  mkdir -p "${fake_bin}"
  printf '#!/bin/sh\nprintf "simulated interpreter failure\\n" >&2\nexit 2\n' > "${fake_python}"
  chmod 755 "${fake_python}"
  payload=$(payload_for Agent executor "$(long_text)")
  run_hook "${payload}" PATH="${fake_bin}:${PATH}"
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDOUT}" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a non-validator status 2 to fail open silently"
  fi
}

case_missing_all_blocks
case_compliant_allowed
case_one_missing_blocks_exactly
case_short_allowed
case_default_skip_allowed
case_skip_override_replaces_defaults
case_custom_sections_enforced
case_matching_is_exact
case_threshold_override_and_fallback
case_task_and_other_tools
case_malformed_inputs_fail_open
case_launcher_bypass
case_missing_body_fail_open
case_interpreter_status_two_fail_open
finish
