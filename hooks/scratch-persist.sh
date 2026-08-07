#!/usr/bin/env bash
# scratch-persist - fail-open launcher for the reactive PostToolUse hook.

set -u

if [ "${CK_SCRATCH_DISABLED:-0}" = "1" ]; then
  exit 0
fi

export CK_SCRATCH_THRESHOLD="${CK_SCRATCH_THRESHOLD:-5000}"

if [ -n "${CK_SCRATCH_DIR:-}" ]; then
  export CK_SCRATCH_DIR_IS_DEFAULT=0
elif [ -n "${HOME:-}" ]; then
  export CK_SCRATCH_DIR="${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory"
  export CK_SCRATCH_DIR_IS_DEFAULT=1
else
  export CK_SCRATCH_DIR="${TMPDIR:-/tmp}/context-kit-scratch"
  export CK_SCRATCH_DIR_IS_DEFAULT=1
fi

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
BODY="${BODY_DIR}/scratch-persist.py"
if [ ! -f "${BODY}" ] || ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

python3 "${BODY}" 2>/dev/null || true
exit 0
