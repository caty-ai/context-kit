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
  find "$1" -type f -name 'scratch-*.md' -print 2>/dev/null | head -n 1 || true
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
    '{"tool_name":"Bash","tool_input":{"command":"demo"}}'
  )
  for payload in "${payloads[@]}"; do
    run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=1
    if [ "${RUN_STATUS}" != "0" ] || [ -s "${RUN_STDOUT}" ] || [ -s "${RUN_STDERR}" ]; then
      record_fail "${case_name}" "expected empty, garbage, non-dict, and missing-tool_response input to fail silently"
      return
    fi
  done
  record_pass "${case_name}"
}

case_missing_tool_input_persists() {
  local case_name="missing-tool-input-persists"
  local scratch_dir="${TMP_DIR}/missing-tool-input"
  local payload
  local scratch_file
  payload=$(python3 - <<'PY'
import json

print(json.dumps({
    "tool_name": "Bash",
    "tool_response": {"stdout": "Y" * 6000},
}))
PY
)
  run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=5000
  scratch_file=$(first_scratch_file "${scratch_dir}")
  if [ "${RUN_STATUS}" = "0" ] &&
     [ ! -s "${RUN_STDERR}" ] &&
     [ -n "${scratch_file}" ] &&
     [ -f "${scratch_file}" ] &&
     notice_is_valid_for_path "${RUN_STDOUT}" "${scratch_file}" &&
     grep -Fq '## Tool Input' "${scratch_file}" &&
     grep -Fq '{}' "${scratch_file}" &&
     grep -Fq 'YYYY' "${scratch_file}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected missing tool_input to default to {} and still persist"
  fi
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
  local scratch_dir="${TMP_DIR}/write-blocked"
  local payload
  printf 'not-a-directory' > "${scratch_dir}"
  payload=$(payload_for plain 100)
  run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=1
  if [ "${RUN_STATUS}" = "0" ] && [ ! -s "${RUN_STDOUT}" ] && [ ! -s "${RUN_STDERR}" ] &&
     [ -z "$(first_scratch_file "${scratch_dir}")" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a non-directory scratch target to emit no notice or final file"
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

case_collision_gets_unique_files() {
  local case_name="collision-gets-unique-files"
  local scratch_dir="${TMP_DIR}/collision"
  local result_file="${TMP_DIR}/collision-result.json"
  if env PYTHONDONTWRITEBYTECODE=1 CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=1 HOOK_PATH="${ROOT}/hooks/scratch-persist.py" RESULT_PATH="${result_file}" \
    python3 - <<'PY'
import contextlib
import datetime
import importlib.util
import io
import json
import os
import sys

hook_path = os.environ["HOOK_PATH"]
result_path = os.environ["RESULT_PATH"]
spec = importlib.util.spec_from_file_location("scratch_persist_hook", hook_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class FrozenDatetime(datetime.datetime):
    @classmethod
    def now(cls, tz=None):
        value = cls(2026, 8, 7, 12, 34, 56)
        if tz is not None:
            return tz.fromutc(value.replace(tzinfo=tz))
        return value

module.datetime.datetime = FrozenDatetime

payloads = (
    {
        "tool_name": "Bash",
        "tool_input": {"command": "first"},
        "tool_response": {"stdout": "FIRST-CONTENT"},
    },
    {
        "tool_name": "Bash",
        "tool_input": {"command": "second"},
        "tool_response": {"stdout": "SECOND-CONTENT"},
    },
)

notices = []
for payload in payloads:
    stdout = io.StringIO()
    stdin = io.StringIO(json.dumps(payload))
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
        original_stdin = sys.stdin
        sys.stdin = stdin
        try:
            rc = module.run()
        finally:
            sys.stdin = original_stdin
    notices.append({"rc": rc, "stdout": stdout.getvalue().strip()})

files = sorted(
    os.path.join(os.environ["CK_SCRATCH_DIR"], name)
    for name in os.listdir(os.environ["CK_SCRATCH_DIR"])
    if name.startswith("scratch-") and name.endswith(".md")
)

with open(result_path, "w", encoding="utf-8") as handle:
    json.dump({"files": files, "notices": notices}, handle)
PY
  then
    :
  else
    record_fail "${case_name}" "expected deterministic same-second runs to complete"
    return
  fi

  if python3 - "${result_file}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert len(data["files"]) == 2
assert len(set(data["files"])) == 2

expected_markers = ("FIRST-CONTENT", "SECOND-CONTENT")
seen_paths = set()
for item, marker in zip(data["notices"], expected_markers):
    assert item["rc"] == 0
    payload = json.loads(item["stdout"])
    notice = payload["hookSpecificOutput"]["additionalContext"]
    matching_paths = [path for path in data["files"] if path in notice]
    assert len(matching_paths) == 1
    path = matching_paths[0]
    assert path not in seen_paths
    seen_paths.add(path)
    with open(path, encoding="utf-8") as handle:
        content = handle.read()
    assert marker in content

assert seen_paths == set(data["files"])
PY
  then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected same-second same-tool runs to produce two distinct files and notices"
  fi
}

case_tool_slug_capped() {
  local case_name="tool-slug-capped"
  local scratch_dir="${TMP_DIR}/slug-cap"
  local long_name
  local payload
  local scratch_file
  long_name=$(python3 - <<'PY'
print("A" * 300)
PY
)
  payload=$(python3 - "${long_name}" <<'PY'
import json
import sys

print(json.dumps({
    "tool_name": sys.argv[1],
    "tool_input": {"command": "slug-check"},
    "tool_response": {"stdout": "Z" * 6000},
}))
PY
)
  run_hook "${payload}" CK_SCRATCH_DIR="${scratch_dir}" CK_SCRATCH_THRESHOLD=5000
  scratch_file=$(first_scratch_file "${scratch_dir}")
  if [ "${RUN_STATUS}" = "0" ] &&
     [ ! -s "${RUN_STDERR}" ] &&
     [ -n "${scratch_file}" ] &&
     [ -f "${scratch_file}" ] &&
     notice_is_valid_for_path "${RUN_STDOUT}" "${scratch_file}" &&
     python3 - "${scratch_file}" <<'PY'
import os
import re
import sys

name = os.path.basename(sys.argv[1])
match = re.fullmatch(r"scratch-[0-9T-]+-([a-z0-9-]+)\.md", name)
assert match is not None
assert len(match.group(1)) <= 32
assert match.group(1) == "a" * 32
PY
  then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected long tool names to persist with a 32-character slug"
  fi
}

case_above_threshold
case_below_threshold
case_disabled
case_invalid_inputs
case_missing_tool_input_persists
case_extraction_shapes
case_threshold_override
case_invalid_threshold_defaults
case_write_failure_no_notice
case_unwritable_dir_root_skip
case_user_scratch_keeps_mode
case_default_scratch_created_700
case_home_unset_fallback
case_collision_gets_unique_files
case_tool_slug_capped
finish
