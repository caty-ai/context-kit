#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RECALL="${ROOT}/bin/recall"
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
  RUN_STDOUT="${TMP_DIR}/stdout.${RANDOM}"
  RUN_STDERR="${TMP_DIR}/stderr.${RANDOM}"
  if "$@" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
}

run_clean() {
  local scratch_dir="$1"
  shift
  run_capture env \
    -u SUPERMEMORY_API_KEY \
    -u SUPERMEMORY_CC_API_KEY \
    HOME="${TMP_DIR}/home" \
    CK_AGENT=test-agent \
    CK_SCRATCH_DIR="${scratch_dir}" \
    CK_SM_ENV="${TMP_DIR}/missing-supermemory-env" \
    CK_SM_CONTAINER= \
    CK_RECALL_MEILI_CMD=context-kit-missing-mem-search \
    "$@"
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
  printf '%d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
  if [ "${FAIL_COUNT}" -ne 0 ]; then
    exit 1
  fi
}

scratch_path_from_human() {
  sed -n 's/^scratch: //p' "$1" | tail -n 1
}

path_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

case_usage_and_validation() {
  local case_name="usage-and-validation"
  run_clean "${TMP_DIR}/usage-scratch" "${RECALL}"
  if [ "${RUN_STATUS}" = "2" ] && grep -Fq 'usage: recall' "${RUN_STDERR}"; then
    :
  else
    record_fail "${case_name}" "missing query should exit 2 with argparse usage"
    return
  fi

  run_clean "${TMP_DIR}/limit-scratch" "${RECALL}" probe --limit 0
  if [ "${RUN_STATUS}" = "2" ] && grep -Fq -- '--limit must be at least 1' "${RUN_STDERR}"; then
    :
  else
    record_fail "${case_name}" "invalid limit should exit 2 with a clear reason"
    return
  fi

  run_clean "${TMP_DIR}/layer-scratch" "${RECALL}" probe --layers unknown
  if [ "${RUN_STATUS}" = "2" ] && grep -Fq "unknown layer 'unknown'" "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "unknown layers should be rejected"
  fi
}

case_default_degrades_and_grep_runs() {
  local case_name="default-degrades-and-grep-runs"
  local root="${TMP_DIR}/default-root"
  local scratch="${TMP_DIR}/default-scratch"
  local scratch_file
  mkdir -p "${root}"
  printf 'the context-kit recall needle\n' > "${root}/note.md"

  run_clean "${scratch}" env CK_RECALL_ROOTS="${root}" "${RECALL}" needle
  scratch_file=$(scratch_path_from_human "${RUN_STDOUT}")
  if [ "${RUN_STATUS}" = "0" ] &&
     grep -Fq 'layer=sm status=skip hits=0 latency_ms=0 reason=CK_SM_CONTAINER and SUPERMEMORY_API_KEY are not configured' "${RUN_STDOUT}" &&
     grep -Fq 'layer=meili status=skip hits=0 latency_ms=0 reason=mem-search command is unavailable' "${RUN_STDOUT}" &&
     grep -Fq 'layer=grep status=ok hits=1' "${RUN_STDOUT}" &&
     grep -Fq "[grep] ${root}/note.md:1" "${RUN_STDOUT}" &&
     [ -n "${scratch_file}" ] && [ -f "${scratch_file}" ] &&
     grep -Fq 'mode: proactive-recall' "${scratch_file}" &&
     grep -Fq 'expiresAt:' "${scratch_file}" &&
     grep -Fq 'layer=sm status=skip' "${scratch_file}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected two skips, one successful grep, provenance, and a result dump"
  fi
}

case_no_roots_and_explicit_unavailable_nonzero() {
  local case_name="no-roots-and-explicit-unavailable-nonzero"
  run_clean "${TMP_DIR}/no-roots-scratch" env CK_RECALL_ROOTS= "${RECALL}" probe --layers grep
  if [ "${RUN_STATUS}" = "1" ] &&
     grep -Fq 'layer=grep status=skip hits=0 latency_ms=0 reason=no roots' "${RUN_STDOUT}"; then
    :
  else
    record_fail "${case_name}" "empty roots should skip grep and exit nonzero"
    return
  fi

  run_clean "${TMP_DIR}/missing-roots-scratch" env \
    CK_RECALL_ROOTS="${TMP_DIR}/missing-one:${TMP_DIR}/missing-two" \
    "${RECALL}" probe --layers grep
  if [ "${RUN_STATUS}" = "1" ] &&
     grep -Fq 'layer=grep status=skip hits=0 latency_ms=0 reason=no roots' "${RUN_STDOUT}"; then
    :
  else
    record_fail "${case_name}" "all-missing explicit roots should skip grep and exit nonzero"
    return
  fi

  run_clean "${TMP_DIR}/sm-only-scratch" "${RECALL}" probe --layers sm
  if [ "${RUN_STATUS}" = "1" ] &&
     grep -Fq 'layer=sm status=skip hits=0 latency_ms=0 reason=CK_SM_CONTAINER and SUPERMEMORY_API_KEY are not configured' "${RUN_STDOUT}" &&
     [ -f "$(scratch_path_from_human "${RUN_STDOUT}")" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "an unavailable-only explicit selection should exit nonzero after reporting"
  fi
}

case_nonexistent_roots_are_dropped() {
  local case_name="nonexistent-roots-are-dropped"
  local root="${TMP_DIR}/existing-root"
  mkdir -p "${root}"
  printf 'root-filter-probe\n' > "${root}/memory.txt"
  run_clean "${TMP_DIR}/root-filter-scratch" env \
    CK_RECALL_ROOTS="${TMP_DIR}/does-not-exist:${root}:${TMP_DIR}/also-missing" \
    "${RECALL}" root-filter-probe --layers grep
  if [ "${RUN_STATUS}" = "0" ] &&
     grep -Fq 'layer=grep status=ok hits=1' "${RUN_STDOUT}" &&
     ! grep -Fq 'does-not-exist' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected missing roots to disappear silently while the existing root runs"
  fi
}

case_local_only_maps_exactly() {
  local case_name="local-only-maps-exactly"
  local root="${TMP_DIR}/local-root"
  mkdir -p "${root}"
  printf 'local-map-probe\n' > "${root}/local.md"
  run_clean "${TMP_DIR}/local-scratch" env CK_RECALL_ROOTS="${root}" \
    "${RECALL}" local-map-probe --layers sm --local-only --json
  if [ "${RUN_STATUS}" = "0" ] && python3 - "${RUN_STDOUT}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
assert result["layers_queried"] == ["meili", "grep"]
assert list(result["per_layer"]) == ["grep", "meili"] or set(result["per_layer"]) == {"meili", "grep"}
assert result["per_layer"]["meili"]["status"] == "skip"
assert result["per_layer"]["grep"]["status"] == "ok"
assert all("reason" in item for item in result["per_layer"].values())
PY
  then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "--local-only should select meili,grep regardless of --layers"
  fi
}

case_fake_meili_parse_and_round_robin_merge() {
  local case_name="fake-meili-parse-and-round-robin-merge"
  local root="${TMP_DIR}/merge-root"
  local scratch="${TMP_DIR}/merge-scratch"
  local fake_meili="${TMP_DIR}/fake-mem-search"
  local meili_file_one="${TMP_DIR}/meili-one.md"
  local meili_file_two="${TMP_DIR}/meili-two.md"
  local args_file="${TMP_DIR}/meili-args"
  mkdir -p "${root}"
  printf 'merge-probe grep one\nmerge-probe grep two\n' > "${root}/grep.md"
  printf 'one\n' > "${meili_file_one}"
  printf 'two\n' > "${meili_file_two}"

  cat > "${fake_meili}" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "${MEILI_ARGS_FILE}"
printf '{"hits":[{"path":"%s","title":"Meili One","content":"first remote"},{"path":"%s","title":"Meili Two","content":"second remote"}]}\n' "${MEILI_FILE_ONE}" "${MEILI_FILE_TWO}"
SH
  chmod +x "${fake_meili}"

  run_clean "${scratch}" env \
    CK_RECALL_ROOTS="${root}" \
    CK_RECALL_MEILI_CMD="${fake_meili}" \
    MEILI_ARGS_FILE="${args_file}" \
    MEILI_FILE_ONE="${meili_file_one}" \
    MEILI_FILE_TWO="${meili_file_two}" \
    "${RECALL}" merge-probe --layers meili,grep --limit 3 --json

  if [ "${RUN_STATUS}" = "0" ] &&
     [ "$(sed -n '1p' "${args_file}")" = "--json" ] &&
     [ "$(sed -n '2p' "${args_file}")" = "-l" ] &&
     [ "$(sed -n '3p' "${args_file}")" = "3" ] &&
     [ "$(sed -n '4p' "${args_file}")" = "--" ] &&
     [ "$(sed -n '5p' "${args_file}")" = "merge-probe" ] &&
     python3 - "${RUN_STDOUT}" "${meili_file_one}" "${root}/grep.md" "${meili_file_two}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
assert result["per_layer"]["meili"]["status"] == "ok"
assert result["per_layer"]["grep"]["status"] == "ok"
assert [hit["layer"] for hit in result["top_hits"]] == ["meili", "grep", "meili"]
assert [hit["pointer"] for hit in result["top_hits"]] == [sys.argv[2], sys.argv[3] + ":1", sys.argv[4]]
assert len(result["hits"]) >= len(result["top_hits"]) == 3
assert result["top_hits"][0]["title"] == "Meili One"
assert result["top_hits"][0]["snippet"] == "first remote"
PY
  then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected original mem-search argv, JSON parsing, provenance, and meili/grep round robin"
  fi
}

case_runnable_error_is_fail_soft() {
  local case_name="runnable-error-is-fail-soft"
  local fake_meili="${TMP_DIR}/bad-mem-search"
  cat > "${fake_meili}" <<'SH'
#!/bin/sh
printf 'not-json\n'
SH
  chmod +x "${fake_meili}"

  run_clean "${TMP_DIR}/error-scratch" env CK_RECALL_MEILI_CMD="${fake_meili}" \
    "${RECALL}" probe --layers meili
  if [ "${RUN_STATUS}" = "0" ] &&
     grep -Fq 'layer=meili status=error hits=0' "${RUN_STDOUT}" &&
     grep -Fq 'reason=mem-search returned invalid JSON:' "${RUN_STDOUT}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "a runnable layer error should be reported but still exit 0"
  fi
}

case_outer_timeout_bounds_library_call() {
  local case_name="outer-timeout-bounds-library-call"
  if env \
    RECALL_PATH="${RECALL}" \
    CK_SCRATCH_DIR="${TMP_DIR}/outer-timeout-scratch" \
    python3 -B - <<'PY'
import importlib.machinery
import importlib.util
import os
import time

path = os.environ["RECALL_PATH"]
loader = importlib.machinery.SourceFileLoader("context_kit_recall_timeout", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

def slow_adapter(query, limit):
    time.sleep(0.25)
    return []

module.build_layer_plans = lambda selected: ({"grep": slow_adapter}, {})
started = time.monotonic()
result = module.recall("probe", ["grep"], 1, timeout=0.01)
elapsed = time.monotonic() - started
assert elapsed < 0.15, elapsed
assert result["exit_code"] == 0
assert result["per_layer"]["grep"]["status"] == "error"
assert result["per_layer"]["grep"]["reason"] == "timeout after 0.01s"
PY
  then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "outer future deadline should return a timeout result without awaiting a slow adapter"
  fi
}

case_rg_preferred_and_grep_fallback() {
  local case_name="rg-preferred-and-grep-fallback"
  local root="${TMP_DIR}/tool-root"
  local preferred_bin="${TMP_DIR}/preferred-bin"
  local fallback_bin="${TMP_DIR}/fallback-bin"
  local python_path
  mkdir -p "${root}" "${preferred_bin}" "${fallback_bin}"
  printf 'tool-probe\n' > "${root}/tool.md"
  python_path=$(command -v python3)
  ln -s "${python_path}" "${preferred_bin}/python3"
  ln -s "${python_path}" "${fallback_bin}/python3"

  cat > "${preferred_bin}/rg" <<'SH'
#!/bin/sh
: > "${RG_MARKER}"
exit 1
SH
  cat > "${preferred_bin}/grep" <<'SH'
#!/bin/sh
: > "${GREP_MARKER}"
exit 1
SH
  chmod +x "${preferred_bin}/rg" "${preferred_bin}/grep"
  run_clean "${TMP_DIR}/preferred-scratch" env \
    PATH="${preferred_bin}" CK_RECALL_ROOTS="${root}" \
    RG_MARKER="${TMP_DIR}/rg-used" GREP_MARKER="${TMP_DIR}/grep-not-used" \
    "${RECALL}" tool-probe --layers grep
  if [ "${RUN_STATUS}" = "0" ] && [ -f "${TMP_DIR}/rg-used" ] && [ ! -f "${TMP_DIR}/grep-not-used" ]; then
    :
  else
    record_fail "${case_name}" "rg should be selected when both commands resolve"
    return
  fi

  cat > "${fallback_bin}/grep" <<'SH'
#!/bin/sh
: > "${GREP_MARKER}"
printf '%s:7:fallback tool-probe\n' "${GREP_HIT_FILE}"
SH
  chmod +x "${fallback_bin}/grep"
  run_clean "${TMP_DIR}/fallback-scratch" env \
    PATH="${fallback_bin}" CK_RECALL_ROOTS="${root}" \
    GREP_MARKER="${TMP_DIR}/grep-used" GREP_HIT_FILE="${root}/tool.md" \
    "${RECALL}" tool-probe --layers grep
  if [ "${RUN_STATUS}" = "0" ] &&
     [ -f "${TMP_DIR}/grep-used" ] &&
     grep -Fq "[grep] ${root}/tool.md:7" "${RUN_STDOUT}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "grep should run and parse provenance when rg is absent"
  fi
}

case_configured_path_expansion() {
  local case_name="configured-path-expansion"
  local temp_home="${TMP_DIR}/path-home"
  local scratch_dir="${temp_home}/scratch-out"
  local shim="${temp_home}/bin/mem-search"
  mkdir -p "${scratch_dir}" "${temp_home}/bin"
  chmod 755 "${scratch_dir}"
  cat > "${shim}" <<'SH'
#!/bin/sh
printf '[]\n'
SH
  chmod +x "${shim}"

  run_capture env \
    -u SUPERMEMORY_API_KEY -u SUPERMEMORY_CC_API_KEY \
    HOME="${temp_home}" CK_SCRATCH_DIR='~/scratch-out' CK_RECALL_ROOTS= \
    CK_SM_ENV="${TMP_DIR}/missing" CK_SM_CONTAINER= \
    CK_RECALL_MEILI_CMD='~/bin/mem-search' \
    "${RECALL}" path-probe --layers meili
  if [ "${RUN_STATUS}" = "0" ] &&
     grep -Fq 'layer=meili status=ok hits=0' "${RUN_STDOUT}" &&
     [ "$(path_mode "${scratch_dir}")" = "755" ] &&
     case "$(scratch_path_from_human "${RUN_STDOUT}")" in "${scratch_dir}/"*) true ;; *) false ;; esac; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "literal tilde paths should expand for scratch output and the Meili executable"
  fi
}

case_supermemory_key_resolution() {
  local case_name="supermemory-key-resolution"
  local env_file="${TMP_DIR}/supermemory.env"
  printf 'export SUPERMEMORY_CC_API_KEY="legacy-file-key"\n' > "${env_file}"
  if env \
    -u SUPERMEMORY_API_KEY \
    -u SUPERMEMORY_CC_API_KEY \
    CK_SM_ENV="${env_file}" \
    RECALL_PATH="${RECALL}" \
    python3 -B - <<'PY'
import importlib.machinery
import importlib.util
import os

path = os.environ["RECALL_PATH"]
loader = importlib.machinery.SourceFileLoader("context_kit_recall", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
assert module.resolve_sm_api_key() == "legacy-file-key"
os.environ["SUPERMEMORY_CC_API_KEY"] = "legacy-direct-key"
assert module.resolve_sm_api_key() == "legacy-direct-key"
os.environ["SUPERMEMORY_API_KEY"] = "canonical-direct-key"
assert module.resolve_sm_api_key() == "canonical-direct-key"
os.environ["CK_SM_CONTAINER"] = ""
adapters, skips = module.build_layer_plans(["sm"])
assert adapters == {}
assert skips["sm"] == "CK_SM_CONTAINER is not configured"
os.environ.pop("SUPERMEMORY_API_KEY")
os.environ.pop("SUPERMEMORY_CC_API_KEY")
os.environ["CK_SM_ENV"] = os.path.join(os.path.dirname(path), "missing-sm-env")
os.environ["CK_SM_CONTAINER"] = "configured-container"
adapters, skips = module.build_layer_plans(["sm"])
assert adapters == {}
assert skips["sm"] == "SUPERMEMORY_API_KEY is not configured"
os.environ["SUPERMEMORY_API_KEY"] = "canonical-direct-key"
adapters, skips = module.build_layer_plans(["sm"])
assert "sm" in adapters and "sm" not in skips
PY
  then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected canonical/direct precedence and legacy env-file compatibility"
  fi
}

case_default_scratch_and_home_unset() {
  local case_name="default-scratch-and-home-unset"
  local seeded_home="${TMP_DIR}/seeded-home"
  local seeded_root="${seeded_home}/.claude/scratch/recall-agent/memory"
  local clean_home="${TMP_DIR}/clean-home"
  local clean_root="${clean_home}/.claude/scratch/clean-agent/memory"
  mkdir -p "${seeded_root}" "${clean_home}"
  printf 'default-root-probe\n' > "${seeded_root}/seeded.md"
  run_capture env \
    -u CK_SCRATCH_DIR -u CK_RECALL_ROOTS -u SUPERMEMORY_API_KEY -u SUPERMEMORY_CC_API_KEY \
    HOME="${seeded_home}" CK_AGENT=recall-agent CK_SM_ENV="${TMP_DIR}/missing" CK_SM_CONTAINER= \
    CK_RECALL_MEILI_CMD=context-kit-missing-mem-search \
    "${RECALL}" default-root-probe
  if [ "${RUN_STATUS}" = "0" ] &&
     grep -Fq 'layer=sm status=skip hits=0 latency_ms=0 reason=CK_SM_CONTAINER and SUPERMEMORY_API_KEY are not configured' "${RUN_STDOUT}" &&
     grep -Fq 'layer=meili status=skip hits=0 latency_ms=0 reason=mem-search command is unavailable' "${RUN_STDOUT}" &&
     grep -Fq 'layer=grep status=ok hits=1' "${RUN_STDOUT}" &&
     grep -Fq "[grep] ${seeded_root}/seeded.md:1" "${RUN_STDOUT}" &&
     [ "$(path_mode "${seeded_root}")" = "700" ] &&
     case "$(scratch_path_from_human "${RUN_STDOUT}")" in "${seeded_root}/"*) true ;; *) false ;; esac; then
    :
  else
    record_fail "${case_name}" "seeded default scratch should be searched with degraded optional layers"
    return
  fi

  run_capture env \
    -u CK_SCRATCH_DIR -u CK_RECALL_ROOTS -u SUPERMEMORY_API_KEY -u SUPERMEMORY_CC_API_KEY \
    HOME="${clean_home}" CK_AGENT=clean-agent CK_SM_ENV="${TMP_DIR}/missing" CK_SM_CONTAINER= \
    CK_RECALL_MEILI_CMD=context-kit-missing-mem-search \
    "${RECALL}" absent-probe --layers grep
  if [ "${RUN_STATUS}" = "0" ] &&
     grep -Fq 'layer=grep status=ok hits=0' "${RUN_STDOUT}" &&
     [ -d "${clean_root}" ] &&
     [ "$(path_mode "${clean_root}")" = "700" ] &&
     case "$(scratch_path_from_human "${RUN_STDOUT}")" in "${clean_root}/"*) true ;; *) false ;; esac; then
    :
  else
    record_fail "${case_name}" "clean HOME should prepare the default root and run grep with zero hits"
    return
  fi

  run_capture env \
    -u HOME -u CK_SCRATCH_DIR -u CK_RECALL_ROOTS -u SUPERMEMORY_API_KEY -u SUPERMEMORY_CC_API_KEY \
    TMPDIR="${TMP_DIR}/tmp-root" CK_SM_ENV= CK_SM_CONTAINER= \
    CK_RECALL_MEILI_CMD=context-kit-missing-mem-search \
    "${RECALL}" probe --layers grep
  if [ "${RUN_STATUS}" = "0" ] &&
     grep -Fq 'layer=grep status=ok hits=0' "${RUN_STDOUT}" &&
     [ "$(path_mode "${TMP_DIR}/tmp-root/context-kit-scratch")" = "700" ] &&
     case "$(scratch_path_from_human "${RUN_STDOUT}")" in "${TMP_DIR}/tmp-root/context-kit-scratch/"*) true ;; *) false ;; esac; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "HOME-unset runs should use TMPDIR/context-kit-scratch"
  fi
}

case_whole_failure_is_clear_english() {
  local case_name="whole-failure-is-clear-english"
  local blocked="${TMP_DIR}/scratch-is-file"
  printf 'not a directory\n' > "${blocked}"
  run_clean "${blocked}" env CK_RECALL_ROOTS= "${RECALL}" probe --layers grep
  if [ "${RUN_STATUS}" = "1" ] &&
     [ ! -s "${RUN_STDOUT}" ] &&
     grep -Fq 'recall: unexpected failure:' "${RUN_STDERR}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "whole-command crashes should emit a clear English stderr message and exit nonzero"
  fi
}

case_python39_stdlib_executable_and_clean() {
  local case_name="python39-stdlib-executable-and-clean"
  local before="${TMP_DIR}/before-bytecode"
  local after="${TMP_DIR}/after-bytecode"
  find "${ROOT}/bin" -type d -name __pycache__ -o -name '*.pyc' | sort > "${before}"
  run_clean "${TMP_DIR}/clean-scratch" env CK_RECALL_ROOTS= \
    python3 -B "${RECALL}" probe --layers grep --json
  find "${ROOT}/bin" -type d -name __pycache__ -o -name '*.pyc' | sort > "${after}"
  if [ "${RUN_STATUS}" = "1" ] &&
     [ -x "${RECALL}" ] &&
     cmp -s "${before}" "${after}" &&
     python3 -B - "${RECALL}" <<'PY'
import ast
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    source = handle.read()
ast.parse(source, filename=sys.argv[1], feature_version=(3, 9))
PY
  then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected executable Python 3.9-compatible stdlib code and no new bytecode artifacts under bin"
  fi
}

case_no_personal_residue() {
  local case_name="no-personal-residue"
  local forbidden
  forbidden="[p]ersonal-[a]lpha|[s]hojikumaru|[S]haredHub|[a]lpha-wiki|[c]laude-workspace|/[U]sers"
  if ! grep -Eqi "${forbidden}" \
    "${RECALL}" "${ROOT}/docs/recall.md" "${ROOT}/tests/test_recall.sh"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "ported files must not retain operator-specific defaults"
  fi
}

case_usage_and_validation
case_default_degrades_and_grep_runs
case_no_roots_and_explicit_unavailable_nonzero
case_nonexistent_roots_are_dropped
case_local_only_maps_exactly
case_fake_meili_parse_and_round_robin_merge
case_runnable_error_is_fail_soft
case_outer_timeout_bounds_library_call
case_rg_preferred_and_grep_fallback
case_configured_path_expansion
case_supermemory_key_resolution
case_default_scratch_and_home_unset
case_whole_failure_is_clear_english
case_python39_stdlib_executable_and_clean
case_no_personal_residue
finish
