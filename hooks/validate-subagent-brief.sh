#!/usr/bin/env bash
# validate-subagent-brief - fail-open launcher for the Agent/Task PreToolUse hook.

set -u

if [ "${CK_SKIP_BRIEF_VALIDATION:-0}" = "1" ]; then
  exit 0
fi

# This duplicated launcher pattern is intentionally copy-kept so each hook stays single-file installable.
SCRIPT_PATH=$0
if command -v readlink >/dev/null 2>&1; then
  LINK_COUNT=0
  MAX_LINKS=40
  while [ -L "${SCRIPT_PATH}" ]; do
    if [ "${LINK_COUNT}" -ge "${MAX_LINKS}" ]; then
      exit 0
    fi
    LINK_COUNT=$((LINK_COUNT + 1))
    LINK_TARGET=$(readlink "${SCRIPT_PATH}" 2>/dev/null) || break
    case "${LINK_TARGET}" in
      /*)
        SCRIPT_PATH="${LINK_TARGET}"
        ;;
      *)
        SCRIPT_DIR=$(dirname "${SCRIPT_PATH}" 2>/dev/null) || break
        SCRIPT_PATH="${SCRIPT_DIR}/${LINK_TARGET}"
        ;;
    esac
  done
fi

BODY_DIR=$(cd "$(dirname "${SCRIPT_PATH}")" 2>/dev/null && pwd -P) || exit 0
BODY="${BODY_DIR}/validate-subagent-brief.py"
if [ ! -f "${BODY}" ] || [ ! -r "${BODY}" ] || ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

ERROR_FILE=$(mktemp -t ck-brief-validator.XXXXXX 2>/dev/null) || exit 0
cleanup() {
  rm -f "${ERROR_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

python3 "${BODY}" >/dev/null 2>"${ERROR_FILE}"
STATUS=$?
if [ "${STATUS}" -ne 2 ]; then
  exit 0
fi

if grep -Fq '[validate-subagent-brief] Blocked ' "${ERROR_FILE}"; then
  cat "${ERROR_FILE}" >&2
  exit 2
fi
exit 0
