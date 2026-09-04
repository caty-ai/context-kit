#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RM_HOOK="${ROOT}/hooks/rm-enforcer.py"
PRIVATE_HOOK="${ROOT}/hooks/private-repo-enforcer.mjs"
API_HOOK="${ROOT}/hooks/api-key-leak-detector.mjs"
TMP_DIR=$(mktemp -d)
API_SCRATCH="${TMP_DIR}/api-scratch"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
RUN_INDEX=0
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

record_skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  printf 'SKIP %s: %s\n' "$1" "$2"
}

finish() {
  printf 'SUMMARY pass=%s fail=%s skip=%s\n' "${PASS_COUNT}" "${FAIL_COUNT}" "${SKIP_COUNT}"
  if [ "${FAIL_COUNT}" -ne 0 ]; then
    exit 1
  fi
}

payload_for() {
  local tool_name="$1"
  local value="${2:-}"
  local file_path="${3:-}"
  python3 -B - "${tool_name}" "${value}" "${file_path}" <<'PY'
import json
import sys

tool_name, value, file_path = sys.argv[1:]
if tool_name == "Bash":
    tool_input = {"command": value}
elif tool_name == "Write":
    tool_input = {"content": value, "file_path": file_path}
elif tool_name == "Edit":
    tool_input = {"new_string": value, "file_path": file_path}
else:
    tool_input = {"content": value, "file_path": file_path}
print(json.dumps({"tool_name": tool_name, "tool_input": tool_input}))
PY
}

prepare_output_files() {
  RUN_INDEX=$((RUN_INDEX + 1))
  RUN_STDOUT="${TMP_DIR}/stdout.${RUN_INDEX}"
  RUN_STDERR="${TMP_DIR}/stderr.${RUN_INDEX}"
}

run_rm() {
  local payload="$1"
  shift
  prepare_output_files
  if printf '%s' "${payload}" | env -u CK_DESTRUCTIVE_OK "$@" python3 -B "${RM_HOOK}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
}

run_private() {
  local payload="$1"
  shift
  prepare_output_files
  if printf '%s' "${payload}" | env -u CK_PUBLIC_REPO_OK "$@" node "${PRIVATE_HOOK}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
}

run_api() {
  local payload="$1"
  shift
  prepare_output_files
  if printf '%s' "${payload}" | env -u CK_API_KEY_DETECT_DISABLED CK_SCRATCH_DIR="${API_SCRATCH}" "$@" node "${API_HOOK}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
}

file_mode() {
  local path="$1"
  if stat -c '%a' "${path}" >/dev/null 2>&1; then
    stat -c '%a' "${path}"
  else
    stat -f '%Lp' "${path}"
  fi
}

repeat_char() {
  python3 -B - "$1" "$2" <<'PY'
import sys

print(sys.argv[2] * int(sys.argv[1]), end="")
PY
}

case_rm_pattern_families() {
  local case_name="rm-pattern-families-block"
  local entry
  local label
  local command
  local cases=(
    'rm-root|rm -rf /'
    'rm-root-trailing-command|rm -rf / ; echo unreachable'
    'rm-root-reordered-flags|rm -fr /'
    'rm-home-tilde|rm -rf ~'
    'rm-home-variable|rm -rf $HOME'
    'terraform-destroy|terraform destroy -auto-approve'
    'destructive-sql|DROP TABLE customers'
    'forced-protected-branch|git push --force origin main'
    'device-overwrite|dd if=/dev/zero bs=1m of=/dev/disk9'
    'shell-rc-overwrite|echo reset > ~/.zshrc'
  )

  for entry in "${cases[@]}"; do
    label=${entry%%|*}
    command=${entry#*|}
    run_rm "$(payload_for Bash "${command}")"
    if [ "${RUN_STATUS}" != "2" ] || ! grep -Fq '[rm-enforcer] Blocked a destructive command.' "${RUN_STDERR}"; then
      record_fail "${case_name}" "expected ${label} to exit 2 with a detection message"
      return
    fi
  done
  record_pass "${case_name}"
}

case_rm_first_pattern_is_independently_pinned() {
  local case_name="rm-first-pattern-independently-blocks-exact-root"

  if python3 -B - "${RM_HOOK}" <<'PY'
import io
import json
import runpy
import sys

namespace = runpy.run_path(sys.argv[1], run_name="rm_enforcer_test")
first_pattern = namespace["RISKY_PATTERNS"][0]
namespace["find_risk"].__globals__["RISKY_PATTERNS"] = [first_pattern]
namespace["main"].__globals__["DISABLED"] = False

sys.stdin = io.StringIO(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": "rm -rf /"},
}))
sys.stderr = io.StringIO()

status = namespace["main"]()
if status != 2 or "[rm-enforcer] Blocked a destructive command." not in sys.stderr.getvalue():
    raise SystemExit(1)
PY
  then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected pattern #1 alone to block the exact rm -rf / trigger"
  fi
}

case_rm_allow_bypass_and_fail_open() {
  local case_name="rm-allow-bypass-and-fail-open"

  run_rm "$(payload_for Bash 'rm -rf /tmp/foo')"
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected a scoped temporary-directory removal to pass"
    return
  fi

  run_rm "$(payload_for Bash 'rm -rf /')" CK_DESTRUCTIVE_OK=1
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected the process-environment bypass to pass"
    return
  fi

  run_rm "$(payload_for Bash 'CK_DESTRUCTIVE_OK=1 rm -rf /')"
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected the literal same-line bypass to pass"
    return
  fi

  run_rm 'garbage'
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected malformed JSON to fail open"
    return
  fi

  run_rm "$(payload_for Read 'rm -rf /')"
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a non-Bash tool to pass"
  fi
}

case_private_patterns() {
  local case_name="private-repo-three-patterns-block"
  local entry
  local label
  local command
  local cases=(
    'create-public|gh repo create example --public'
    'create-ambiguous|gh repo create example'
    'edit-public|gh repo edit example --visibility public'
  )

  for entry in "${cases[@]}"; do
    label=${entry%%|*}
    command=${entry#*|}
    run_private "$(payload_for Bash "${command}")"
    if [ "${RUN_STATUS}" != "2" ] || ! grep -Fq '[private-repo-enforcer] Blocked' "${RUN_STDERR}"; then
      record_fail "${case_name}" "expected ${label} to exit 2 with a detection message"
      return
    fi
  done
  record_pass "${case_name}"
}

case_private_allow_bypass_and_fail_open() {
  local case_name="private-repo-allow-bypass-and-fail-open"

  run_private "$(payload_for Bash 'gh repo create example --private')"
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected explicit private creation to pass"
    return
  fi

  run_private "$(payload_for Bash 'gh repo create example --public')" CK_PUBLIC_REPO_OK=1
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected the process-environment bypass to pass"
    return
  fi

  run_private "$(payload_for Bash 'CK_PUBLIC_REPO_OK=1 gh repo create example --public')"
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected the literal same-line bypass to pass"
    return
  fi

  run_private 'garbage'
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected malformed JSON to fail open"
    return
  fi

  run_private 'null'
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected a null JSON body to fail open silently"
    return
  fi

  run_private "$(payload_for Write 'gh repo create example --public' '/tmp/example.txt')"
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a non-Bash tool to pass"
  fi
}

case_api_pattern_families() {
  local case_name="api-key-provider-patterns-block"
  local anthropic
  anthropic="sk-ant-$(repeat_char 24 x)"
  local openai
  openai="sk-$(repeat_char 40 x)"
  local google
  google="AIza$(repeat_char 35 x)"
  local aws
  aws="AKIA$(repeat_char 16 X)"
  local gitlab
  gitlab="glpat-$(repeat_char 24 x)"
  local github
  github="ghp_$(repeat_char 40 x)"
  local slack
  slack="xoxb-$(repeat_char 12 x)"
  local entry
  local label
  local token
  local cases=(
    "anthropic|${anthropic}"
    "openai|${openai}"
    "google|${google}"
    "aws|${aws}"
    "gitlab|${gitlab}"
    "github|${github}"
    "slack|${slack}"
  )

  for entry in "${cases[@]}"; do
    label=${entry%%|*}
    token=${entry#*|}
    run_api "$(payload_for Bash "printf ${token}")"
    if [ "${RUN_STATUS}" != "2" ] || ! grep -Fq '[api-key-leak-detector] Blocked a possible API-key leak.' "${RUN_STDERR}"; then
      record_fail "${case_name}" "expected the format-valid fake ${label} token to be blocked"
      return
    fi
  done
  record_pass "${case_name}"
}

case_api_tool_surfaces() {
  local case_name="api-key-write-edit-and-nontarget-surfaces"
  local token
  token="sk-$(repeat_char 40 x)"

  run_api "$(payload_for Write "${token}" '/tmp/example.txt')"
  if [ "${RUN_STATUS}" != "2" ]; then
    record_fail "${case_name}" "expected Write content to be blocked"
    return
  fi

  run_api "$(payload_for Edit "${token}" '/tmp/example.txt')"
  if [ "${RUN_STATUS}" != "2" ]; then
    record_fail "${case_name}" "expected Edit new_string to be blocked"
    return
  fi

  run_api "$(payload_for Read "${token}" '/tmp/example.txt')"
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a non-target tool to pass"
  fi
}

case_api_allow_bypass_exclusion_and_fail_open() {
  local case_name="api-key-allow-bypass-exclusion-and-fail-open"
  local token
  token="sk-$(repeat_char 40 x)"
  local provider_env="provider.env"

  run_api "$(payload_for Bash 'printf safe-value')"
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected ordinary Bash content to pass"
    return
  fi

  run_api "$(payload_for Write "${token}" '/tmp/example.txt')" CK_API_KEY_DETECT_DISABLED=1
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected the process-environment bypass to cover Write"
    return
  fi

  run_api "$(payload_for Bash "CK_API_KEY_DETECT_DISABLED=1 printf ${token}")"
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected the literal same-line Bash bypass to pass"
    return
  fi

  run_api "$(payload_for Write "CK_API_KEY_DETECT_DISABLED=1 ${token}" '/tmp/example.txt')"
  if [ "${RUN_STATUS}" != "2" ]; then
    record_fail "${case_name}" "expected bypass text inside Write content not to bypass the hook"
    return
  fi

  run_api "$(payload_for Write "${token}" '/tmp/.env')"
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected the intentional .env exclusion to pass"
    return
  fi

  run_api "$(payload_for Write "${token}" "/tmp/${provider_env}")"
  if [ "${RUN_STATUS}" != "2" ] || ! grep -Fq '[api-key-leak-detector] Blocked a possible API-key leak.' "${RUN_STDERR}"; then
    record_fail "${case_name}" "expected a non-excluded env filename to be scanned and blocked"
    return
  fi

  run_api 'garbage'
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ]; then
    record_fail "${case_name}" "expected malformed JSON to fail open"
    return
  fi

  run_api 'null'
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a null JSON body to fail open silently"
  fi
}

case_api_evidence_permissions_and_notice() {
  local case_name="api-key-evidence-is-redacted-mode-0600"
  local evidence_dir="${TMP_DIR}/evidence"
  local token
  token="sk-$(repeat_char 40 x)"
  local evidence_file

  mkdir -p "${evidence_dir}"
  chmod 755 "${evidence_dir}"
  run_api "$(payload_for Write "${token}" '/tmp/example.txt')" CK_SCRATCH_DIR="${evidence_dir}"
  evidence_file=$(find "${evidence_dir}" -type f -name 'api-key-leak-*.md' -print -quit)

  if [ "${RUN_STATUS}" = "2" ] &&
     [ -n "${evidence_file}" ] &&
     [ "$(file_mode "${evidence_file}")" = "600" ] &&
     [ "$(file_mode "${evidence_dir}")" = "755" ] &&
     grep -Fq 'Local rotation evidence (mode 0600)' "${RUN_STDERR}" &&
     grep -Fq '***[REDACTED]' "${evidence_file}" &&
     ! grep -Fq "${token}" "${evidence_file}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected one redacted 0600 report without changing custom directory permissions"
  fi
}

case_api_default_root_is_0700() {
  local case_name="api-key-default-scratch-root-is-0700"
  local fake_home="${TMP_DIR}/home"
  local token
  token="sk-$(repeat_char 40 x)"
  local payload
  local default_dir="${fake_home}/.claude/scratch/test-agent/memory"

  payload=$(payload_for Bash "printf ${token}")
  prepare_output_files
  if printf '%s' "${payload}" | env -u CK_API_KEY_DETECT_DISABLED -u CK_SCRATCH_DIR HOME="${fake_home}" CK_AGENT=test-agent node "${API_HOOK}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi

  if [ "${RUN_STATUS}" = "2" ] && [ -d "${default_dir}" ] && [ "$(file_mode "${default_dir}")" = "700" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected the kit-managed default scratch root to be mode 0700"
  fi
}

case_api_relative_scratch_is_not_cwd_relative() {
  local case_name="api-key-relative-scratch-is-not-cwd-relative"
  local fake_home="${TMP_DIR}/relative-home"
  local temp_cwd="${TMP_DIR}/relative-cwd"
  local expected_dir="${fake_home}/.claude/scratch/test-agent/memory/relscratch"
  local token
  token="sk-$(repeat_char 40 x)"
  local payload
  local evidence_file

  mkdir -p "${fake_home}" "${temp_cwd}"
  payload=$(payload_for Bash "printf ${token}")
  prepare_output_files
  if (cd "${temp_cwd}" && printf '%s' "${payload}" | env -u CK_API_KEY_DETECT_DISABLED HOME="${fake_home}" CK_AGENT=test-agent CK_SCRATCH_DIR=relscratch node "${API_HOOK}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"); then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
  evidence_file=$(find "${expected_dir}" -type f -name 'api-key-leak-*.md' -print -quit 2>/dev/null || true)

  if [ "${RUN_STATUS}" = "2" ] &&
     [ -n "${evidence_file}" ] &&
     [ -z "$(find "${temp_cwd}" -mindepth 1 -print -quit)" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected relative evidence under the absolute default scratch root and no files in cwd"
  fi
}

case_rm_pattern_families
case_rm_first_pattern_is_independently_pinned
case_rm_allow_bypass_and_fail_open

if command -v node >/dev/null 2>&1; then
  case_private_patterns
  case_private_allow_bypass_and_fail_open
  case_api_pattern_families
  case_api_tool_surfaces
  case_api_allow_bypass_exclusion_and_fail_open
  case_api_evidence_permissions_and_notice
  case_api_default_root_is_0700
  case_api_relative_scratch_is_not_cwd_relative
else
  record_skip "private-repo-enforcer-node-cases" "node is unavailable"
  record_skip "api-key-leak-detector-node-cases" "node is unavailable"
fi

finish
