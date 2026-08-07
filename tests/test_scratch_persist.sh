#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOK="${ROOT}/hooks/scratch-persist.sh"
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

payload_for() {
  local shape="$1"
  local size="$2"
  python3 - "${shape}" "${size}" <<'PY'
import json
import sys

shape = sys.argv[1]
size = int(sys.argv[2])
text = "x" * size
if shape == "plain":
    response = "PLAIN-BEGIN" + text + "PLAIN-END"
elif shape == "streams":
    response = {"stdout": "STDOUT-BEGIN" + text, "stderr": "STDERR-END"}
elif shape == "content":
    response = {"content": [{"text": "CONTENT-TEXT" + text}, {"content": "CONTENT-FALLBACK"}]}
elif shape == "mixed":
    response = {
        "stdout": "MIXED-STDOUT" + text,
        "stderr": "MIXED-STDERR",
        "output": "MIXED-OUTPUT",
        "content": ["MIXED-LIST", {"text": "MIXED-TEXT"}],
        "result": "MIXED-RESULT",
    }
else:
    response = {"stdout": text}
print(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": "printf full-output"},
    "tool_response": response,
}))
PY
}

first_scratch_file() {
  find "$1" -type f -name 'scratch-*.md' -print 2>/dev/null | head -n 1
}

dir_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

notice_is_valid_for_path() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
notice = data["hookSpecificOutput"]["additionalContext"]
assert data["hookSpecificOutput"]["hookEventName"] == "PostToolUse"
assert sys.argv[2] in notice
assert "Read/Grep" in notice
assert "instead of re-running the tool" in notice
assert "TTL 7 days" in notice
PY
}

case_above_threshold() {
  local case_name="above-threshold-persists-and-notices"
  local scratch_dir="${TMP_DIR}/above"
  local payload
  local scratch_file
  payload=$(payload_for plain 6000)
  run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=5000
  scratch_file=$(first_scratch_file "${scratch_dir}")
  if [ "${RUN_STATUS}" = "0" ] &&
     [ ! -s "${RUN_STDERR}" ] &&
     [ -n "${scratch_file}" ] &&
     [ -f "${scratch_file}" ] &&
     [ "$(wc -l < "${RUN_STDOUT}" | tr -d ' ')" = "1" ] &&
     notice_is_valid_for_path "${RUN_STDOUT}" "${scratch_file}" &&
     grep -Fq 'type: scratch' "${scratch_file}" &&
     grep -Fq 'mode: reactive-persist' "${scratch_file}" &&
     grep -Fq 'tool: Bash' "${scratch_file}" &&
     grep -Fq 'createdAt:' "${scratch_file}" &&
     grep -Fq 'expiresAt:' "${scratch_file}" &&
     grep -Fq 'sizeBytes:' "${scratch_file}" &&
     grep -Fq 'printf full-output' "${scratch_file}" &&
     grep -Fq 'PLAIN-BEGIN' "${scratch_file}" &&
     grep -Fq 'PLAIN-END' "${scratch_file}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a complete scratch file and one valid path-bearing notice"
  fi
}

case_below_threshold() {
  local case_name="below-threshold-silent"
  local scratch_dir="${TMP_DIR}/below"
  local payload
  payload=$(payload_for plain 20)
  run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=5000
  if [ "${RUN_STATUS}" = "0" ] &&
     [ ! -s "${RUN_STDOUT}" ] &&
     [ ! -s "${RUN_STDERR}" ] &&
     [ -z "$(first_scratch_file "${scratch_dir}")" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected no file or output below threshold"
  fi
}

case_disabled() {
  local case_name="disabled-silent"
  local scratch_dir="${TMP_DIR}/disabled"
  local payload
  payload=$(payload_for plain 100)
  run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=1 CK_SCRATCH_DISABLED=1
  if [ "${RUN_STATUS}" = "0" ] &&
     [ ! -s "${RUN_STDOUT}" ] &&
     [ ! -s "${RUN_STDERR}" ] &&
     [ -z "$(first_scratch_file "${scratch_dir}")" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected CK_SCRATCH_DISABLED=1 to do nothing"
  fi
}

case_invalid_inputs() {
  local case_name="invalid-inputs-silent"
  local scratch_dir="${TMP_DIR}/invalid"
  local payload
  local payloads=(
    ''
    'garbage'
    '[]'
    '{"tool_name":"Bash"}'
  )
  for payload in "${payloads[@]}"; do
    run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=1
    if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDOUT}" ] || [ -s "${RUN_STDERR}" ]; then
      record_fail "${case_name}" "expected empty, garbage, non-dict, and missing-field input to fail silently"
      return
    fi
  done
  record_pass "${case_name}"
}

case_extraction_shapes() {
  local case_name="extraction-shapes"
  local shape
  local scratch_dir
  local scratch_file
  local payload
  for shape in plain streams content mixed; do
    scratch_dir="${TMP_DIR}/shape-${shape}"
    payload=$(payload_for "${shape}" 100)
    run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=10
    scratch_file=$(first_scratch_file "${scratch_dir}")
    if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ] || [ -z "${scratch_file}" ]; then
      record_fail "${case_name}" "expected ${shape} output to persist"
      return
    fi
    case "${shape}" in
      plain)
        if ! grep -Fq 'PLAIN-BEGIN' "${scratch_file}" || ! grep -Fq 'PLAIN-END' "${scratch_file}"; then
          record_fail "${case_name}" "plain string text was not captured"
          return
        fi
        ;;
      streams)
        if ! grep -Fq 'STDOUT-BEGIN' "${scratch_file}" || ! grep -Fq 'STDERR-END' "${scratch_file}"; then
          record_fail "${case_name}" "stdout and stderr text were not captured"
          return
        fi
        ;;
      content)
        if ! grep -Fq 'CONTENT-TEXT' "${scratch_file}" || ! grep -Fq 'CONTENT-FALLBACK' "${scratch_file}"; then
          record_fail "${case_name}" "content list dictionaries were not captured"
          return
        fi
        ;;
      mixed)
        if ! python3 - "${scratch_file}" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    output = handle.read().split("## Tool Output\n\n", 1)[1]
expected = "\n".join((
    "MIXED-STDOUT" + ("x" * 100),
    "MIXED-STDERR",
    "MIXED-OUTPUT",
    "MIXED-LIST",
    "MIXED-TEXT",
    "MIXED-RESULT",
))
assert output == expected
PY
        then
          record_fail "${case_name}" "all extraction keys and their original order must be preserved"
          return
        fi
        ;;
    esac
  done
  record_pass "${case_name}"
}

case_threshold_override() {
  local case_name="threshold-override-100"
  local scratch_dir="${TMP_DIR}/override"
  local default_dir="${TMP_DIR}/override-default"
  local payload
  payload=$(payload_for plain 120)
  run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=100
  if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDERR}" ] || [ -z "$(first_scratch_file "${scratch_dir}")" ]; then
    record_fail "${case_name}" "expected 120 characters to exceed the 100-character override"
    return
  fi
  run_hook "${payload}" CK_SCRATCH_DIR="${default_dir}"
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDOUT}" ] && [ ! -s "${RUN_STDERR}" ] &&
     [ -z "$(first_scratch_file "${default_dir}")" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected the same output to stay below the default threshold"
  fi
}

case_invalid_threshold_defaults() {
  local case_name="invalid-threshold-defaults"
  local scratch_dir
  local payload
  local threshold
  local thresholds
  payload=$(payload_for plain 200)
  thresholds=(not-a-number "$(python3 -c 'print("9" * 5000)')")
  for threshold in "${thresholds[@]}"; do
    scratch_dir="${TMP_DIR}/invalid-threshold-${RANDOM}"
    run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD="${threshold}"
    if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDOUT}" ] || [ -s "${RUN_STDERR}" ] ||
       [ -n "$(first_scratch_file "${scratch_dir}")" ]; then
      record_fail "${case_name}" "expected unparseable thresholds to fall back to 5000"
      return
    fi
  done
  record_pass "${case_name}"
}

case_write_failure_no_notice() {
  local case_name="write-failure-no-notice"
  local scratch_dir="${TMP_DIR}/replace-blocked"
  local payload
  mkdir -p "${scratch_dir}"
  python3 - "${scratch_dir}" <<'PY'
import datetime
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
now = datetime.datetime.now()
for offset in range(-2, 4):
    ts = (now + datetime.timedelta(seconds=offset)).strftime("%Y-%m-%dT%H-%M-%S")
    (root / "scratch-{}-bash.md".format(ts)).mkdir()
PY
  payload=$(payload_for plain 100)
  run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=1
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDOUT}" ] && [ ! -s "${RUN_STDERR}" ] &&
     [ -z "$(first_scratch_file "${scratch_dir}")" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected failed atomic replacement to emit no notice or final file"
  fi
}

case_unwritable_dir_root_skip() {
  local case_name="unwritable-dir-root-skip"
  if [ "$(id -u)" = "0" ]; then
    record_pass "${case_name}"
    return
  fi

  local blocked_dir="${TMP_DIR}/unwritable"
  local payload
  mkdir -p "${blocked_dir}"
  chmod 500 "${blocked_dir}"
  payload=$(payload_for plain 100)
  run_hook "${payload}" CK_SCRATCH_DIR="${blocked_dir}" CK_SCRATCH_THRESHOLD=1
  chmod 700 "${blocked_dir}"
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDOUT}" ] && [ ! -s "${RUN_STDERR}" ] &&
     [ -z "$(first_scratch_file "${blocked_dir}")" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected an unwritable directory to fail silently without a notice"
  fi
}

case_user_scratch_keeps_mode() {
  local case_name="user-scratch-keeps-mode"
  local scratch_dir="${TMP_DIR}/user-mode"
  local payload
  mkdir -p "${scratch_dir}"
  chmod 755 "${scratch_dir}"
  payload=$(payload_for plain 100)
  run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=1
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ] &&
     [ "$(dir_mode "${scratch_dir}")" = "755" ] && [ -n "$(first_scratch_file "${scratch_dir}")" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a user-supplied directory to retain mode 755"
  fi
}

case_default_scratch_created_700() {
  local case_name="default-scratch-created-700"
  local temp_home="${TMP_DIR}/default-home"
  local scratch_dir="${temp_home}/.claude/scratch/mode-case/memory"
  local payload
  mkdir -p "${temp_home}"
  payload=$(payload_for plain 100)
  RUN_STDOUT="${TMP_DIR}/stdout.$RANDOM"
  RUN_STDERR="${TMP_DIR}/stderr.$RANDOM"
  if printf '%s' "${payload}" | env -u CK_SCRATCH_DIR HOME="${temp_home}" CK_AGENT=mode-case CK_SCRATCH_THRESHOLD=1 \
    bash "${HOOK}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ] &&
     [ "$(dir_mode "${scratch_dir}")" = "700" ] && [ -n "$(first_scratch_file "${scratch_dir}")" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected the kit-created default directory to use mode 700"
  fi
}

case_home_unset_fallback() {
  local case_name="home-unset-fallback"
  local temp_root="${TMP_DIR}/tmp-root"
  local scratch_dir="${temp_root}/context-kit-scratch"
  local payload
  mkdir -p "${temp_root}"
  payload=$(payload_for plain 100)
  RUN_STDOUT="${TMP_DIR}/stdout.$RANDOM"
  RUN_STDERR="${TMP_DIR}/stderr.$RANDOM"
  if printf '%s' "${payload}" | env -u HOME -u CK_SCRATCH_DIR TMPDIR="${temp_root}" CK_SCRATCH_THRESHOLD=1 \
    bash "${HOOK}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDERR}" ] &&
     [ "$(dir_mode "${scratch_dir}")" = "700" ] && [ -n "$(first_scratch_file "${scratch_dir}")" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected HOME-unset runs to use TMPDIR/context-kit-scratch mode 700"
  fi
}

case_above_threshold
case_below_threshold
case_disabled
case_invalid_inputs
case_extraction_shapes
case_threshold_override
case_invalid_threshold_defaults
case_write_failure_no_notice
case_unwritable_dir_root_skip
case_user_scratch_keeps_mode
case_default_scratch_created_700
case_home_unset_fallback
finish
