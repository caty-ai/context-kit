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

temp_path_from_marker() {
  sed -n 's|^... \[[0-9][0-9]* lines omitted / [0-9][0-9]* bytes - scratch unavailable, full output temp: \(.*\)\] ...$|\1|p' "$1"
}

dir_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
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
  run_capture env CK_SCRATCH_DIR="${scratch_dir}" "${LG}" bash -c 'printf "small-output\n"'
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
    bash -c 'i=1; while [ "$i" -le 200 ]; do printf "line-%03d\n" "$i"; i=$((i + 1)); done'
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

case_invalid_numeric_defaults() {
  local case_name="invalid-numeric-defaults"
  local scratch_dir="${TMP_DIR}/scratch-defaults"
  run_capture env CK_SCRATCH_DIR="${scratch_dir}" LG_HEAD=bogus LG_TAIL=nope LG_TTL_DAYS=bad "${LG}" \
    bash -c 'i=1; while [ "$i" -le 200 ]; do printf "line-%03d\n" "$i"; i=$((i + 1)); done'
  local scratch_file
  scratch_file=$(scratch_path_from_footer "${RUN_STDOUT}")
  if [ "${RUN_STATUS}" = "0" ] &&
     grep -Fq 'line-040' "${RUN_STDOUT}" &&
     grep -Fq 'line-161' "${RUN_STDOUT}" &&
     ! grep -Fq 'line-041' "${RUN_STDOUT}" &&
     ! grep -Fq 'line-160' "${RUN_STDOUT}" &&
     grep -Fq '(TTL 7 days, exit_code=0, 200 lines,' "${RUN_STDOUT}" &&
     [ -n "${scratch_file}" ] &&
     [ -f "${scratch_file}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected invalid numeric env values to fall back to default preview and TTL settings"
  fi
}

case_env_preview_override() {
  local case_name="env-preview-override"
  local scratch_dir="${TMP_DIR}/scratch-override"
  run_capture env CK_SCRATCH_DIR="${scratch_dir}" LG_HEAD=3 LG_TAIL=2 "${LG}" \
    bash -c 'i=1; while [ "$i" -le 10 ]; do printf "line-%03d\n" "$i"; i=$((i + 1)); done'
  local scratch_file
  scratch_file=$(scratch_path_from_footer "${RUN_STDOUT}")
  if [ "${RUN_STATUS}" = "0" ] &&
     grep -Fq 'line-001' "${RUN_STDOUT}" &&
     grep -Fq 'line-003' "${RUN_STDOUT}" &&
     grep -Fq 'line-009' "${RUN_STDOUT}" &&
     grep -Fq 'line-010' "${RUN_STDOUT}" &&
     ! grep -Fq 'line-004' "${RUN_STDOUT}" &&
     ! grep -Fq 'line-008' "${RUN_STDOUT}" &&
     grep -Fq '... [5 lines omitted /' "${RUN_STDOUT}" &&
     [ -n "${scratch_file}" ] &&
     [ -f "${scratch_file}" ] &&
     grep -Fq 'line-004' "${scratch_file}" &&
     grep -Fq 'line-008' "${scratch_file}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected LG_HEAD/LG_TAIL overrides to change the preview window"
  fi
}

case_exit_code() {
  local case_name="exit-code-3"
  local scratch_dir="${TMP_DIR}/scratch-exit"
  run_capture env CK_SCRATCH_DIR="${scratch_dir}" "${LG}" bash -c 'printf "failing-output\n"; exit 3'
  if [ "${RUN_STATUS}" = "3" ] &&
     grep -Fq 'failing-output' "${RUN_STDOUT}" &&
     grep -Fq 'exit_code=3' "${RUN_STDOUT}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected wrapped exit code 3 to be preserved"
  fi
}

case_home_unset_fallback() {
  local case_name="home-unset-fallback"
  local temp_home_root="${TMP_DIR}/tmp-home-root"
  mkdir -p "${temp_home_root}"
  run_capture env -u HOME TMPDIR="${temp_home_root}" CK_AGENT=case-home "${LG}" \
    bash -c 'printf "home-fallback\n"'
  local scratch_file
  scratch_file=$(scratch_path_from_footer "${RUN_STDOUT}")
  if [ "${RUN_STATUS}" = "0" ] &&
     [ -n "${scratch_file}" ] &&
     [ -f "${scratch_file}" ] &&
     case "${scratch_file}" in
       "${temp_home_root}/context-kit-scratch/"*) true ;;
       *) false ;;
     esac; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected HOME-unset runs to fall back under TMPDIR/context-kit-scratch"
  fi
}

case_user_scratch_keeps_mode() {
  local case_name="user-scratch-keeps-mode"
  local scratch_dir="${TMP_DIR}/scratch-user-mode"
  mkdir -p "${scratch_dir}"
  chmod 755 "${scratch_dir}"
  run_capture env CK_SCRATCH_DIR="${scratch_dir}" "${LG}" bash -c 'printf "mode-check\n"'
  local scratch_file
  local mode
  scratch_file=$(scratch_path_from_footer "${RUN_STDOUT}")
  mode=$(dir_mode "${scratch_dir}")
  if [ "${RUN_STATUS}" = "0" ] &&
     [ "${mode}" = "755" ] &&
     [ -n "${scratch_file}" ] &&
     [ -f "${scratch_file}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected user-supplied scratch directory to keep mode 755 and receive a scratch file"
  fi
}

case_default_scratch_created_700() {
  local case_name="default-scratch-created-700"
  local temp_home="${TMP_DIR}/default-home"
  local scratch_dir="${temp_home}/.claude/scratch/mode-case/memory"
  mkdir -p "${temp_home}"
  run_capture env -u CK_SCRATCH_DIR HOME="${temp_home}" CK_AGENT=mode-case "${LG}" \
    bash -c 'printf "default-mode-check\n"'
  local scratch_file
  local mode
  scratch_file=$(scratch_path_from_footer "${RUN_STDOUT}")
  mode=$(dir_mode "${scratch_dir}")
  if [ "${RUN_STATUS}" = "0" ] &&
     [ "${mode}" = "700" ] &&
     [ -n "${scratch_file}" ] &&
     [ -f "${scratch_file}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected default scratch directory to be created mode 700 and receive a scratch file"
  fi
}

case_large_scratch_fail_keeps_temp() {
  local case_name="large-scratch-fail-keeps-temp"
  local fake_scratch="${TMP_DIR}/scratch-as-file"
  printf 'not-a-dir\n' > "${fake_scratch}"
  run_capture env CK_SCRATCH_DIR="${fake_scratch}" "${LG}" \
    bash -c 'i=1; while [ "$i" -le 200 ]; do printf "line-%03d\n" "$i"; i=$((i + 1)); done; exit 9'
  local temp_file
  local warning_count
  local stdout_lines
  temp_file=$(temp_path_from_marker "${RUN_STDOUT}")
  warning_count=$(grep -Fc 'scratch unavailable; using fallback output mode' "${RUN_STDERR}" || true)
  stdout_lines=$(wc -l < "${RUN_STDOUT}" | tr -d ' ')
  if [ "${RUN_STATUS}" = "9" ] &&
     grep -Fq 'line-001' "${RUN_STDOUT}" &&
     grep -Fq 'line-040' "${RUN_STDOUT}" &&
     grep -Fq 'line-161' "${RUN_STDOUT}" &&
     grep -Fq 'line-200' "${RUN_STDOUT}" &&
     ! grep -Fq 'line-041' "${RUN_STDOUT}" &&
     ! grep -Fq 'line-160' "${RUN_STDOUT}" &&
     grep -Fq 'scratch unavailable, full output temp:' "${RUN_STDOUT}" &&
     ! grep -Fq '[lg] full output preserved:' "${RUN_STDOUT}" &&
     [ "${warning_count}" = "1" ] &&
     [ "${stdout_lines}" -le 81 ] &&
     [ -n "${temp_file}" ] &&
     [ -r "${temp_file}" ] &&
     grep -Fq 'line-041' "${temp_file}" &&
     grep -Fq 'line-160' "${temp_file}"; then
    record_pass "${case_name}"
    rm -f "${temp_file}"
  else
    record_fail "${case_name}" "expected preview-only fallback, retained temp output, no footer, and preserved exit code"
  fi
}

case_read_only_dir_root_skip() {
  local case_name="read-only-dir-root-skip"
  if [ "$(id -u)" = "0" ]; then
    record_pass "${case_name}"
    return
  fi

  local read_only_parent="${TMP_DIR}/read-only-scratch"
  local blocked_child="${read_only_parent}/child"
  local warning_count
  mkdir -p "${read_only_parent}"
  chmod 500 "${read_only_parent}"
  run_capture env CK_SCRATCH_DIR="${blocked_child}" "${LG}" \
    bash -c 'printf "one\ntwo\nthree\nfour\n"; exit 7'
  chmod 700 "${read_only_parent}"
  warning_count=$(grep -Fc 'scratch unavailable; using fallback output mode' "${RUN_STDERR}" || true)
  if [ "${RUN_STATUS}" = "7" ] &&
     grep -Fq 'one' "${RUN_STDOUT}" &&
     grep -Fq 'two' "${RUN_STDOUT}" &&
     grep -Fq 'three' "${RUN_STDOUT}" &&
     grep -Fq 'four' "${RUN_STDOUT}" &&
     ! grep -Fq '[lg] full output preserved:' "${RUN_STDOUT}" &&
     [ "${warning_count}" = "1" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected non-root chmod-500 parent to block child scratch creation, force fallback output, and suppress footer"
  fi
}

case_usage
case_small_full_temp_scratch
case_large_preview
case_invalid_numeric_defaults
case_env_preview_override
case_exit_code
case_home_unset_fallback
case_user_scratch_keeps_mode
case_default_scratch_created_700
case_large_scratch_fail_keeps_temp
case_read_only_dir_root_skip
finish
