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

repeated_text() {
  python3 -c 'import sys; print("x" * int(sys.argv[1]), end="")' "$1"
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
     grep -Fq 'Missing sections: ## 実装仕様 (or ## Goal), ## 実装チェック (or ## Self-verification), ## レビュー基準 (or ## Reviewer criteria)' "${RUN_STDERR}" &&
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
  if [ "${RUN_STATUS}" = "2" ] && [ "${missing_line}" = 'Missing sections: ## 実装チェック (or ## Self-verification)' ]; then
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

case_threshold_boundary() {
  local case_name="threshold-boundary"
  run_hook "$(payload_for Agent executor "$(repeated_text 499)")"
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected a 499-character prompt to skip validation"
    return
  fi
  run_hook "$(payload_for Agent executor "$(repeated_text 500)")"
  if [ "${RUN_STATUS}" = "2" ] &&
     grep -Fq 'Missing sections: ## 実装仕様 (or ## Goal), ## 実装チェック (or ## Self-verification), ## レビュー基準 (or ## Reviewer criteria)' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a 500-character prompt to trigger validation"
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

case_skip_matching_is_exact() {
  local case_name="skip-matching-is-exact"
  run_hook "$(payload_for Agent writer2 "$(long_text)")"
  if [ "${RUN_STATUS}" = "2" ] &&
     grep -Fq "subagent type 'writer2'" "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected writer2 not to inherit the default writer skip"
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

case_skip_override_message_uses_effective_list() {
  local case_name="skip-override-message-uses-effective-list"
  run_hook "$(payload_for Agent writer "$(long_text)")" CK_BRIEF_SKIP_SUBAGENT_TYPES=research-lite
  if [ "${RUN_STATUS}" = "2" ] &&
     grep -Fq 'CK_BRIEF_SKIP_SUBAGENT_TYPES (effective: research-lite).' "${RUN_STDERR}" &&
     ! grep -Fq 'Explore' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected the block message to show only the effective skip list"
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

case_custom_sections_use_generic_skeleton_guidance() {
  local case_name="custom-sections-use-generic-skeleton-guidance"
  local required='## Goal|## Self-check|## Review criteria'
  run_hook "$(payload_for Agent executor "$(long_text)")" CK_BRIEF_REQUIRED_SECTIONS="${required}"
  if [ "${RUN_STATUS}" = "2" ] &&
     grep -Fq '## Goal' "${RUN_STDERR}" &&
     grep -Fq -- '- State what this section requires.' "${RUN_STDERR}" &&
     ! grep -Fq -- '- State the deliverable, constraints, and relevant context.' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected custom required sections to use generic skeleton guidance"
  fi
}

case_reordered_canonical_sections_use_generic_skeleton_guidance() {
  local case_name="reordered-canonical-sections-use-generic-skeleton-guidance"
  local required='## レビュー基準|## 実装仕様|## 実装チェック'
  run_hook "$(payload_for Agent executor "$(long_text)")" CK_BRIEF_REQUIRED_SECTIONS="${required}"
  if [ "${RUN_STATUS}" = "2" ] &&
     grep -Fq '## レビュー基準' "${RUN_STDERR}" &&
     grep -Fq '## 実装仕様' "${RUN_STDERR}" &&
     grep -Fq '## 実装チェック' "${RUN_STDERR}" &&
     [ "$(grep -Fc -- '- State what this section requires.' "${RUN_STDERR}")" = "3" ] &&
     ! grep -Fq -- '- State the deliverable, constraints, and relevant context.' "${RUN_STDERR}" &&
     ! grep -Fq -- '- List concrete self-verification steps and completion checks.' "${RUN_STDERR}" &&
     ! grep -Fq -- '- Define observable reviewer criteria and acceptance conditions.' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected reordered canonical sections to use only generic skeleton guidance"
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
     grep -Fxq 'Missing sections: ## 実装仕様 (or ## Goal)' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a one-hash heading not to satisfy the exact token"
  fi
}

case_malformed_required_sections_fall_back() {
  local case_name="malformed-required-sections-fall-back"
  local malformed_values=('a||b' '|')
  local value
  for value in "${malformed_values[@]}"; do
    run_hook "$(payload_for Agent executor "$(long_text)")" CK_BRIEF_REQUIRED_SECTIONS="${value}"
    if [ "${RUN_STATUS}" != "2" ] ||
       ! grep -Fq 'Missing sections: ## 実装仕様 (or ## Goal), ## 実装チェック (or ## Self-verification), ## レビュー基準 (or ## Reviewer criteria)' "${RUN_STDERR}"; then
      record_fail "${case_name}" "expected malformed required sections (${value}) to fall back to canonical defaults"
      return
    fi
  done
  record_pass "${case_name}"
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

case_subagent_type_is_sanitized() {
  local case_name="subagent-type-is-sanitized"
  local weird_type=$'writer\r\nwith-break'
  local first_line
  run_hook "$(payload_for Agent "${weird_type}" "$(long_text)")"
  first_line=$(head -n 1 "${RUN_STDERR}" || true)
  if [ "${RUN_STATUS}" = "2" ] &&
     [ "${first_line}" = "[validate-subagent-brief] Blocked Agent delegation for subagent type 'writer  with-break'." ] &&
     ! grep -q $'\r' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected CR/LF in the echoed subagent type to be flattened"
  fi
}

case_subagent_type_is_truncated() {
  local case_name="subagent-type-is-truncated"
  local long_type
  local first_line
  long_type=$(python3 -c 'print("t" * 120, end="")')
  run_hook "$(payload_for Agent "${long_type}" "$(long_text)")"
  first_line=$(head -n 1 "${RUN_STDERR}" || true)
  if [ "${RUN_STATUS}" = "2" ] &&
     [ "${#first_line}" = "172" ] &&
     printf '%s\n' "${first_line}" | grep -Eq "^\\[validate-subagent-brief\\] Blocked Agent delegation for subagent type 't{100}'\\.$"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected the echoed subagent type to be truncated to 100 characters"
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

case_interpreter_noise_before_blocked_sentinel() {
  local case_name="interpreter-noise-before-blocked-sentinel"
  local fake_bin="${TMP_DIR}/shim-bin"
  local fake_python="${fake_bin}/python3"
  local payload
  mkdir -p "${fake_bin}"
  cat > "${fake_python}" <<EOF
#!/bin/sh
printf 'python shim noise\n' >&2
exec "$(command -v python3)" "\$@"
EOF
  chmod 755 "${fake_python}"
  payload=$(payload_for Agent executor "$(long_text)")
  run_hook "${payload}" PATH="${fake_bin}:${PATH}"
  if [ "${RUN_STATUS}" = "2" ] &&
     grep -Fq 'python shim noise' "${RUN_STDERR}" &&
     grep -Fq '[validate-subagent-brief] Blocked Agent delegation' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected shim noise before the sentinel to preserve blocking behavior"
  fi
}

case_english_compliant_allowed() {
  local case_name="english-compliant-allowed"
  local prompt
  prompt=$(printf '## Goal\n## Self-verification\n## Reviewer criteria\n%s' "$(long_text)")
  run_hook "$(payload_for Agent executor "${prompt}")"
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDOUT}" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected all three English section tokens to pass silently"
  fi
}

case_mixed_tokens_allowed() {
  local case_name="mixed-tokens-allowed"
  local prompt
  prompt=$(printf '## 実装仕様\n## Self-verification\n## レビュー基準\n%s' "$(long_text)")
  run_hook "$(payload_for Agent executor "${prompt}")"
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDOUT}" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a per-layer mix of Japanese and English tokens to pass silently"
  fi
}

case_english_one_missing_names_both_tokens() {
  local case_name="english-one-missing-names-both-tokens"
  local prompt
  local missing_line
  prompt=$(printf '## Goal\n## Reviewer criteria\n%s' "$(long_text)")
  run_hook "$(payload_for Agent executor "${prompt}")"
  missing_line=$(grep '^Missing sections:' "${RUN_STDERR}" || true)
  if [ "${RUN_STATUS}" = "2" ] &&
     [ "${missing_line}" = 'Missing sections: ## 実装チェック (or ## Self-verification)' ] &&
     grep -Fq 'English section tokens are accepted too: ## Goal / ## Self-verification / ## Reviewer criteria' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected the absent layer to name both accepted tokens and show the English-token note"
  fi
}

case_custom_sections_have_no_aliases() {
  local case_name="custom-sections-have-no-aliases"
  local required='## 実装仕様|## 実装チェック|## レビュー基準'
  local prompt
  local missing_line
  prompt=$(printf '## Goal\n## Self-verification\n## Reviewer criteria\n%s' "$(long_text)")
  run_hook "$(payload_for Agent executor "${prompt}")" CK_BRIEF_REQUIRED_SECTIONS="${required}"
  missing_line=$(grep '^Missing sections:' "${RUN_STDERR}" || true)
  if [ "${RUN_STATUS}" = "2" ] &&
     [ "${missing_line}" = 'Missing sections: ## 実装仕様, ## 実装チェック, ## レビュー基準' ] &&
     ! grep -Fq '(or ' "${RUN_STDERR}" &&
     ! grep -Fq 'English section tokens are accepted too' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected an explicit Japanese set to retain single-token matching and messaging"
  fi
}

case_explicit_japanese_set_keeps_canonical_guidance() {
  local case_name="explicit-japanese-set-keeps-canonical-guidance"
  local required='## 実装仕様|## 実装チェック|## レビュー基準'
  run_hook "$(payload_for Agent executor "$(long_text)")" CK_BRIEF_REQUIRED_SECTIONS="${required}"
  if [ "${RUN_STATUS}" = "2" ] &&
     grep -Fq -- '- State the deliverable, constraints, and relevant context.' "${RUN_STDERR}" &&
     grep -Fq -- '- List concrete self-verification steps and completion checks.' "${RUN_STDERR}" &&
     grep -Fq -- '- Define observable reviewer criteria and acceptance conditions.' "${RUN_STDERR}" &&
     ! grep -Fq -- '- State what this section requires.' "${RUN_STDERR}" &&
     ! grep -Fq 'English section tokens are accepted too' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected an explicit Japanese set to retain canonical guidance without English aliases"
  fi
}

case_default_skeleton_mentions_english_tokens() {
  local case_name="default-skeleton-mentions-english-tokens"
  local required='## Goal|## Self-check|## Review criteria'
  run_hook "$(payload_for Agent executor "$(long_text)")"
  if [ "${RUN_STATUS}" != "2" ] ||
     ! grep -Fq '## 実装仕様' "${RUN_STDERR}" ||
     ! grep -Fq '## 実装チェック' "${RUN_STDERR}" ||
     ! grep -Fq '## レビュー基準' "${RUN_STDERR}" ||
     ! grep -Fq 'English section tokens are accepted too: ## Goal / ## Self-verification / ## Reviewer criteria' "${RUN_STDERR}"; then
    record_fail "${case_name}" "expected the default skeleton to use Japanese headings and mention English aliases"
    return
  fi
  run_hook "$(payload_for Agent executor "$(long_text)")" CK_BRIEF_REQUIRED_SECTIONS="${required}"
  if [ "${RUN_STATUS}" = "2" ] &&
     ! grep -Fq 'English section tokens are accepted too' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a custom skeleton not to mention default English aliases"
  fi
}

case_missing_all_blocks
case_compliant_allowed
case_one_missing_blocks_exactly
case_short_allowed
case_threshold_boundary
case_default_skip_allowed
case_skip_matching_is_exact
case_skip_override_replaces_defaults
case_skip_override_message_uses_effective_list
case_custom_sections_enforced
case_custom_sections_use_generic_skeleton_guidance
case_reordered_canonical_sections_use_generic_skeleton_guidance
case_matching_is_exact
case_malformed_required_sections_fall_back
case_threshold_override_and_fallback
case_subagent_type_is_sanitized
case_subagent_type_is_truncated
case_task_and_other_tools
case_malformed_inputs_fail_open
case_launcher_bypass
case_missing_body_fail_open
case_interpreter_status_two_fail_open
case_interpreter_noise_before_blocked_sentinel
case_english_compliant_allowed
case_mixed_tokens_allowed
case_english_one_missing_names_both_tokens
case_custom_sections_have_no_aliases
case_explicit_japanese_set_keeps_canonical_guidance
case_default_skeleton_mentions_english_tokens
finish
