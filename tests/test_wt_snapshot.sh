#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WT_SNAPSHOT="${ROOT}/bin/wt-snapshot"
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

run_in_dir() {
  local dir="$1"
  shift
  RUN_STDOUT="${TMP_DIR}/stdout.${RANDOM}"
  RUN_STDERR="${TMP_DIR}/stderr.${RANDOM}"
  if (
    cd "${dir}" &&
    "$@"
  ) >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
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
  printf '%d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
  if [ "${FAIL_COUNT}" -ne 0 ]; then
    exit 1
  fi
}

git_env() {
  env \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_AUTHOR_NAME='Context Kit Tests' \
    GIT_AUTHOR_EMAIL='tests@example.invalid' \
    GIT_COMMITTER_NAME='Context Kit Tests' \
    GIT_COMMITTER_EMAIL='tests@example.invalid' \
    "$@"
}

git_setup() {
  git_env git "$@"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

file_mtime() {
  if stat -f '%m' "$1" >/dev/null 2>&1; then
    stat -f '%m' "$1"
  else
    stat -c '%Y' "$1"
  fi
}

repo_index_path() {
  local repo="$1"
  local path
  path=$(git_setup -C "${repo}" rev-parse --git-path index)
  case "${path}" in
    /*) printf '%s\n' "${path}" ;;
    *) printf '%s/%s\n' "${repo}" "${path}" ;;
  esac
}

snapshot_refs() {
  git_setup -C "$1" for-each-ref --format='%(refname)' 'refs/worktree-snapshots/**'
}

reachable_objects() {
  git_setup -C "$1" rev-list --objects --all | LC_ALL=C sort
}

make_fixture_repo() {
  local root="$1"
  local main_repo="${root}/main"
  local worktree="${root}/lane-worktree"
  local lane_branch="lane-snapshot"

  mkdir -p "${main_repo}"
  git_setup init -b main "${main_repo}" >/dev/null

  cat > "${main_repo}/tracked.txt" <<'EOF_TRACKED'
base line
EOF_TRACKED
  mkdir -p "${main_repo}/nested"
  printf 'base nested\n' > "${main_repo}/nested/base.txt"
  printf '.state/\n' > "${main_repo}/.gitignore"
  git_setup -C "${main_repo}" add tracked.txt nested/base.txt .gitignore
  git_setup -C "${main_repo}" commit -m 'initial fixture' >/dev/null

  git_setup -C "${main_repo}" worktree add -b "${lane_branch}" "${worktree}" HEAD >/dev/null

  printf '%s\n%s\n' "${main_repo}" "${worktree}"
}

populate_dirty_payload() {
  local worktree="$1"
  local newline_name=$'untracked\nname.txt'

  printf 'base line\nmodified line\n' > "${worktree}/tracked.txt"
  printf 'plain untracked\n' > "${worktree}/plain.txt"
  printf 'space name\n' > "${worktree}/name with spaces.txt"
  printf 'unicode snow\n' > "${worktree}/snow-雪.txt"
  printf 'newline payload\n' > "${worktree}/${newline_name}"
  mkdir -p "${worktree}/nested/untracked dir"
  printf 'nested bytes\n' > "${worktree}/nested/untracked dir/child.txt"
}

populate_ignored_payload() {
  local worktree="$1"
  local ignored_newline=$'.state/ignored\nname.txt'

  mkdir -p "${worktree}/.state/sub dir"
  printf 'ignored root\n' > "${worktree}/.state/root.txt"
  printf 'ignored nested\n' > "${worktree}/.state/sub dir/nested.txt"
  printf 'ignored unicode\n' > "${worktree}/.state/雪.log"
  printf 'ignored newline\n' > "${worktree}/${ignored_newline}"
}

assert_tree_equal() {
  python3 - "$1" "$2" <<'PY'
import filecmp
import os
import stat
import sys

left, right = sys.argv[1], sys.argv[2]

def filtered_entries(base):
    entries = []
    for root, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d != ".git")
        files = sorted(f for f in files if f != ".git")
        rel_root = os.path.relpath(root, base)
        if rel_root == ".":
            rel_root = ""
        for dirname in dirs:
            rel = os.path.join(rel_root, dirname) if rel_root else dirname
            entries.append(("dir", rel, None, os.lstat(os.path.join(root, dirname)).st_mode & 0o777))
        for filename in files:
            path = os.path.join(root, filename)
            rel = os.path.join(rel_root, filename) if rel_root else filename
            st = os.lstat(path)
            mode = st.st_mode & 0o777
            if stat.S_ISLNK(st.st_mode):
                entries.append(("symlink", rel, os.readlink(path), mode))
            elif stat.S_ISREG(st.st_mode):
                with open(path, "rb") as handle:
                    entries.append(("file", rel, handle.read(), mode))
            else:
                entries.append(("other", rel, st.st_mode, mode))
    return sorted(entries)

lhs = filtered_entries(left)
rhs = filtered_entries(right)
if lhs != rhs:
    print("TREE_MISMATCH")
    only_left = sorted(set(lhs) - set(rhs))
    only_right = sorted(set(rhs) - set(lhs))
    if only_left:
        print("ONLY_LEFT")
        for item in only_left:
            print(repr(item))
    if only_right:
        print("ONLY_RIGHT")
        for item in only_right:
            print(repr(item))
    sys.exit(1)
PY
}

snapshot_ref_for_prefix() {
  local repo="$1"
  local prefix="$2"
  snapshot_refs "${repo}" | grep -F "refs/worktree-snapshots/${prefix}/" || true
}

case_dirty_capture_creates_parented_ref() {
  local case_name="dirty-capture-creates-parented-ref"
  local sandbox="${TMP_DIR}/${case_name}"
  local fixture
  local main_repo
  local worktree
  local head_before
  local worktree_name
  local ref
  local parent
  fixture=$(make_fixture_repo "${sandbox}")
  main_repo=$(printf '%s\n' "${fixture}" | sed -n '1p')
  worktree=$(printf '%s\n' "${fixture}" | sed -n '2p')
  populate_dirty_payload "${worktree}"
  head_before=$(git_setup -C "${worktree}" rev-parse HEAD)
  worktree_name=$(basename "${worktree}")

  run_in_dir "${worktree}" "${WT_SNAPSHOT}"
  ref=$(snapshot_ref_for_prefix "${main_repo}" "${worktree_name}")
  if [ -n "${ref}" ]; then
    parent=$(git_setup -C "${main_repo}" rev-parse "${ref}^")
  else
    parent=""
  fi

  if [ "${RUN_STATUS}" = "0" ] &&
     [ -n "${ref}" ] &&
     [ "${parent}" = "${head_before}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected one snapshot ref under the worktree namespace parented on the worktree HEAD"
  fi
}

case_restore_roundtrip_is_exact() {
  local case_name="restore-roundtrip-is-exact"
  local sandbox="${TMP_DIR}/${case_name}"
  local fixture
  local main_repo
  local worktree
  local worktree_name
  local ref
  local restore_dir="${sandbox}/restore target"
  fixture=$(make_fixture_repo "${sandbox}")
  main_repo=$(printf '%s\n' "${fixture}" | sed -n '1p')
  worktree=$(printf '%s\n' "${fixture}" | sed -n '2p')
  populate_dirty_payload "${worktree}"
  populate_ignored_payload "${worktree}"
  worktree_name=$(basename "${worktree}")

  run_in_dir "${worktree}" env CK_WTSNAP_INCLUDE_IGNORED='.state,.state/**' "${WT_SNAPSHOT}"
  ref=$(snapshot_ref_for_prefix "${main_repo}" "${worktree_name}")

  if [ "${RUN_STATUS}" != "0" ] || [ -z "${ref}" ]; then
    record_fail "${case_name}" "snapshot creation failed before restore verification"
    return
  fi

  run_in_dir "${main_repo}" "${WT_SNAPSHOT}" restore "${ref}" "${restore_dir}"
  if [ "${RUN_STATUS}" = "0" ] &&
     [ -d "${restore_dir}" ] &&
     assert_tree_equal "${worktree}" "${restore_dir}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected restore to rebuild the worktree byte-for-byte, including configured ignored files"
  fi
}

case_snapshot_from_nested_subdir_captures_root_payload() {
  local case_name="snapshot-from-nested-subdir-captures-root-payload"
  local sandbox="${TMP_DIR}/${case_name}"
  local fixture
  local main_repo
  local worktree
  local runner_dir
  local worktree_name
  local ref
  local restore_dir="${sandbox}/restore-nested"
  fixture=$(make_fixture_repo "${sandbox}")
  main_repo=$(printf '%s\n' "${fixture}" | sed -n '1p')
  worktree=$(printf '%s\n' "${fixture}" | sed -n '2p')
  runner_dir="${worktree}/nested/runner"
  mkdir -p "${runner_dir}"
  populate_dirty_payload "${worktree}"
  populate_ignored_payload "${worktree}"
  printf 'runner marker\n' > "${runner_dir}/marker.txt"
  worktree_name=$(basename "${worktree}")

  run_in_dir "${runner_dir}" env CK_WTSNAP_INCLUDE_IGNORED='.state,.state/**' "${WT_SNAPSHOT}"
  ref=$(snapshot_ref_for_prefix "${main_repo}" "${worktree_name}" | tail -n 1)

  if [ "${RUN_STATUS}" != "0" ] ||
     [ -z "${ref}" ] ||
     grep -Eiq 'no-op|noop|nothing to snapshot|already reachable' "${RUN_STDOUT}"; then
    record_fail "${case_name}" "expected snapshotting from a nested subdirectory to create a ref instead of false no-op"
    return
  fi

  run_in_dir "${main_repo}" "${WT_SNAPSHOT}" restore "${ref}" "${restore_dir}"
  if [ "${RUN_STATUS}" = "0" ] &&
     [ -f "${restore_dir}/tracked.txt" ] &&
     [ -f "${restore_dir}/plain.txt" ] &&
     [ -f "${restore_dir}/name with spaces.txt" ] &&
     [ -f "${restore_dir}/snow-雪.txt" ] &&
     [ -f "${restore_dir}/.state/root.txt" ] &&
     [ -f "${restore_dir}/.state/sub dir/nested.txt" ] &&
     assert_tree_equal "${worktree}" "${restore_dir}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a nested-subdirectory invocation to round-trip the worktree root payload exactly"
  fi
}

case_ignored_set_is_captured_only_when_configured() {
  local case_name="ignored-set-is-captured-only-when-configured"
  local sandbox="${TMP_DIR}/${case_name}"
  local fixture
  local main_repo
  local worktree
  local worktree_name
  local refs_before
  local no_ignored_ref
  local with_ignored_ref
  local with_dir="${sandbox}/restore-with"
  fixture=$(make_fixture_repo "${sandbox}")
  main_repo=$(printf '%s\n' "${fixture}" | sed -n '1p')
  worktree=$(printf '%s\n' "${fixture}" | sed -n '2p')
  populate_ignored_payload "${worktree}"
  worktree_name=$(basename "${worktree}")
  refs_before=$(snapshot_refs "${main_repo}")

  run_in_dir "${worktree}" "${WT_SNAPSHOT}"
  no_ignored_ref=$(snapshot_ref_for_prefix "${main_repo}" "${worktree_name}" | tail -n 1)
  if [ "${RUN_STATUS}" != "0" ] ||
     [ -n "${no_ignored_ref}" ] ||
     [ "$(snapshot_refs "${main_repo}")" != "${refs_before}" ] ||
     ! grep -Eiq 'no-op|noop|nothing to snapshot|already reachable' "${RUN_STDOUT}"; then
    record_fail "${case_name}" "expected ignored-only content to be a no-op with no snapshot when CK_WTSNAP_INCLUDE_IGNORED is unset"
    return
  fi

  run_in_dir "${worktree}" env CK_WTSNAP_INCLUDE_IGNORED='.state,.state/**' "${WT_SNAPSHOT}"
  with_ignored_ref=$(snapshot_ref_for_prefix "${main_repo}" "${worktree_name}" | tail -n 1)
  if [ "${RUN_STATUS}" != "0" ] || [ -z "${with_ignored_ref}" ]; then
    record_fail "${case_name}" "configured snapshot did not succeed"
    return
  fi

  run_in_dir "${main_repo}" "${WT_SNAPSHOT}" restore "${with_ignored_ref}" "${with_dir}"
  if [ "${RUN_STATUS}" = "0" ] &&
     [ -f "${with_dir}/.state/root.txt" ] &&
     [ -f "${with_dir}/.state/sub dir/nested.txt" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected configured ignored paths to round-trip while the default snapshot excludes them"
  fi
}

case_restore_rejects_non_empty_target_with_exit_70() {
  local case_name="restore-rejects-non-empty-target-with-exit-70"
  local sandbox="${TMP_DIR}/${case_name}"
  local fixture
  local main_repo
  local worktree
  local worktree_name
  local ref
  local restore_dir="${sandbox}/restore-non-empty"
  fixture=$(make_fixture_repo "${sandbox}")
  main_repo=$(printf '%s\n' "${fixture}" | sed -n '1p')
  worktree=$(printf '%s\n' "${fixture}" | sed -n '2p')
  populate_dirty_payload "${worktree}"
  worktree_name=$(basename "${worktree}")

  run_in_dir "${worktree}" "${WT_SNAPSHOT}"
  ref=$(snapshot_ref_for_prefix "${main_repo}" "${worktree_name}" | tail -n 1)
  if [ "${RUN_STATUS}" != "0" ] || [ -z "${ref}" ]; then
    record_fail "${case_name}" "snapshot setup failed before non-empty restore assertion"
    return
  fi

  mkdir -p "${restore_dir}"
  printf 'occupied\n' > "${restore_dir}/keep.txt"
  run_in_dir "${main_repo}" "${WT_SNAPSHOT}" restore "${ref}" "${restore_dir}"
  if [ "${RUN_STATUS}" = "70" ] &&
     grep -Fq 'restore target must be empty' "${RUN_STDERR}" &&
     [ -f "${restore_dir}/keep.txt" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected restore to refuse a non-empty target directory with exit 70"
  fi
}

case_repo_local_fsmonitor_is_not_executed() {
  local case_name="repo-local-fsmonitor-is-not-executed"
  local sandbox="${TMP_DIR}/${case_name}"
  local fixture
  local main_repo
  local worktree
  local marker="${sandbox}/fsmonitor.marker"
  local hook="${sandbox}/fake-fsmonitor.sh"
  fixture=$(make_fixture_repo "${sandbox}")
  main_repo=$(printf '%s\n' "${fixture}" | sed -n '1p')
  worktree=$(printf '%s\n' "${fixture}" | sed -n '2p')
  populate_dirty_payload "${worktree}"

  cat > "${hook}" <<EOF_HOOK
#!/usr/bin/env bash
printf 'fsmonitor-ran\n' >> "${marker}"
exit 0
EOF_HOOK
  chmod +x "${hook}"
  git_setup -C "${worktree}" config core.fsmonitor "${hook}"

  run_in_dir "${worktree}" "${WT_SNAPSHOT}"

  if [ "${RUN_STATUS}" = "0" ] && [ ! -e "${marker}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected snapshotting to ignore repo-local core.fsmonitor hooks entirely"
  fi
}

case_secret_scan_abort_is_fail_closed() {
  local case_name="secret-scan-abort-is-fail-closed"
  local sandbox="${TMP_DIR}/${case_name}"
  local fixture
  local main_repo
  local worktree
  local refs_before
  local refs_after
  local objs_before
  local objs_after
  local scan_cmd='sh -c '"'"'case "$(cat)" in *FORBIDDEN-SECRET*) exit 17 ;; *) exit 0 ;; esac'"'"''
  fixture=$(make_fixture_repo "${sandbox}")
  main_repo=$(printf '%s\n' "${fixture}" | sed -n '1p')
  worktree=$(printf '%s\n' "${fixture}" | sed -n '2p')

  printf 'FORBIDDEN-SECRET\n' > "${worktree}/secret.txt"
  refs_before=$(snapshot_refs "${main_repo}")
  objs_before=$(reachable_objects "${main_repo}")

  run_in_dir "${worktree}" env CK_WTSNAP_SECRET_SCAN_CMD="${scan_cmd}" "${WT_SNAPSHOT}"
  refs_after=$(snapshot_refs "${main_repo}")
  objs_after=$(reachable_objects "${main_repo}")

  if [ "${RUN_STATUS}" = "17" ] &&
     [ "${refs_before}" = "${refs_after}" ] &&
     [ "${objs_before}" = "${objs_after}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected the secret scanner hit to abort with its own status and leave no reachable refs or objects behind"
  fi
}

case_secret_scan_bytes_match_restored_payload_under_mutation() {
  local case_name="secret-scan-bytes-match-restored-payload-under-mutation"
  local sandbox="${TMP_DIR}/${case_name}"
  local fixture
  local main_repo
  local worktree
  local worktree_name
  local ref
  local race_file
  local restore_dir="${sandbox}/restore-race"
  local scan_cmd='sh -c '"'"'cat >/dev/null; printf "MUTATED\n" > "${RACE_FILE}"; exit 0'"'"''
  fixture=$(make_fixture_repo "${sandbox}")
  main_repo=$(printf '%s\n' "${fixture}" | sed -n '1p')
  worktree=$(printf '%s\n' "${fixture}" | sed -n '2p')
  worktree_name=$(basename "${worktree}")
  race_file="${worktree}/race.txt"

  printf 'SAFE\n' > "${race_file}"
  run_in_dir "${worktree}" env RACE_FILE="${race_file}" CK_WTSNAP_SECRET_SCAN_CMD="${scan_cmd}" "${WT_SNAPSHOT}"
  ref=$(snapshot_ref_for_prefix "${main_repo}" "${worktree_name}" | tail -n 1)

  if [ "${RUN_STATUS}" != "0" ] || [ -z "${ref}" ]; then
    record_fail "${case_name}" "snapshot setup failed before race restore assertion"
    return
  fi

  run_in_dir "${main_repo}" "${WT_SNAPSHOT}" restore "${ref}" "${restore_dir}"
  if [ "${RUN_STATUS}" = "0" ] &&
     [ "$(cat "${restore_dir}/race.txt")" = "SAFE" ] &&
     [ "$(cat "${race_file}")" = "MUTATED" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected restored bytes to match scanned SAFE content even if the live file mutates after scanning"
  fi
}

case_clean_detached_unreachable_head_creates_ref() {
  local case_name="clean-detached-unreachable-head-creates-ref"
  local sandbox="${TMP_DIR}/${case_name}"
  local fixture
  local main_repo
  local worktree
  local worktree_name
  local detached_head
  local ref
  fixture=$(make_fixture_repo "${sandbox}")
  main_repo=$(printf '%s\n' "${fixture}" | sed -n '1p')
  worktree=$(printf '%s\n' "${fixture}" | sed -n '2p')
  worktree_name=$(basename "${worktree}")

  git_setup -C "${worktree}" checkout --detach HEAD >/dev/null
  printf 'detached clean commit\n' > "${worktree}/detached.txt"
  git_setup -C "${worktree}" add detached.txt
  git_setup -C "${worktree}" commit -m 'detached snapshot source' >/dev/null
  detached_head=$(git_setup -C "${worktree}" rev-parse HEAD)

  run_in_dir "${worktree}" "${WT_SNAPSHOT}"
  ref=$(snapshot_ref_for_prefix "${main_repo}" "${worktree_name}" | tail -n 1)

  if [ "${RUN_STATUS}" = "0" ] &&
     [ -n "${ref}" ] &&
     [ "$(git_setup -C "${main_repo}" rev-parse "${ref}^")" = "${detached_head}" ] &&
     ! grep -Eiq 'no-op|noop|nothing to snapshot|already reachable' "${RUN_STDOUT}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a clean detached HEAD that is unreachable from refs to be snapshotted"
  fi
}

case_clean_worktree_is_explicit_noop() {
  local case_name="clean-worktree-is-explicit-noop"
  local sandbox="${TMP_DIR}/${case_name}"
  local fixture
  local main_repo
  local worktree
  local refs_before
  local refs_after
  local objs_before
  local objs_after
  fixture=$(make_fixture_repo "${sandbox}")
  main_repo=$(printf '%s\n' "${fixture}" | sed -n '1p')
  worktree=$(printf '%s\n' "${fixture}" | sed -n '2p')
  refs_before=$(snapshot_refs "${main_repo}")
  objs_before=$(reachable_objects "${main_repo}")

  run_in_dir "${worktree}" "${WT_SNAPSHOT}"
  refs_after=$(snapshot_refs "${main_repo}")
  objs_after=$(reachable_objects "${main_repo}")

  if [ "${RUN_STATUS}" = "0" ] &&
     [ "${refs_before}" = "${refs_after}" ] &&
     [ "${objs_before}" = "${objs_after}" ] &&
     grep -Eiq 'no-op|noop|nothing to snapshot|already reachable' "${RUN_STDOUT}"; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected a clean, already-reachable worktree to report a no-op and write nothing"
  fi
}

case_snapshot_leaves_user_state_untouched() {
  local case_name="snapshot-leaves-user-state-untouched"
  local sandbox="${TMP_DIR}/${case_name}"
  local fixture
  local main_repo
  local worktree
  local fake_global="${sandbox}/global.gitconfig"
  local main_index
  local worktree_index
  local main_index_hash_before
  local main_index_hash_after
  local worktree_index_hash_before
  local worktree_index_hash_after
  local main_index_mtime_before
  local main_index_mtime_after
  local worktree_index_mtime_before
  local worktree_index_mtime_after
  local main_head_before
  local main_head_after
  local worktree_head_before
  local worktree_head_after
  local main_config_before
  local main_config_after
  local worktree_config_before
  local worktree_config_after
  fixture=$(make_fixture_repo "${sandbox}")
  main_repo=$(printf '%s\n' "${fixture}" | sed -n '1p')
  worktree=$(printf '%s\n' "${fixture}" | sed -n '2p')
  populate_dirty_payload "${worktree}"

  cat > "${fake_global}" <<'EOF_CFG'
[user]
	name = booby trapped
	email = booby@example.invalid
[alias]
	breakme = !exit 99
EOF_CFG

  main_index=$(repo_index_path "${main_repo}")
  worktree_index=$(repo_index_path "${worktree}")
  main_index_hash_before=$(sha256_file "${main_index}")
  worktree_index_hash_before=$(sha256_file "${worktree_index}")
  main_index_mtime_before=$(file_mtime "${main_index}")
  worktree_index_mtime_before=$(file_mtime "${worktree_index}")
  main_head_before=$(git_setup -C "${main_repo}" rev-parse HEAD)
  worktree_head_before=$(git_setup -C "${worktree}" rev-parse HEAD)
  main_config_before=$(env GIT_CONFIG_GLOBAL="${fake_global}" GIT_CONFIG_SYSTEM=/dev/null git -C "${main_repo}" config --list --show-origin)
  worktree_config_before=$(env GIT_CONFIG_GLOBAL="${fake_global}" GIT_CONFIG_SYSTEM=/dev/null git -C "${worktree}" config --list --show-origin)

  sleep 1
  run_in_dir "${worktree}" env GIT_CONFIG_GLOBAL="${fake_global}" GIT_CONFIG_SYSTEM=/dev/null "${WT_SNAPSHOT}"

  main_index_hash_after=$(sha256_file "${main_index}")
  worktree_index_hash_after=$(sha256_file "${worktree_index}")
  main_index_mtime_after=$(file_mtime "${main_index}")
  worktree_index_mtime_after=$(file_mtime "${worktree_index}")
  main_head_after=$(git_setup -C "${main_repo}" rev-parse HEAD)
  worktree_head_after=$(git_setup -C "${worktree}" rev-parse HEAD)
  main_config_after=$(env GIT_CONFIG_GLOBAL="${fake_global}" GIT_CONFIG_SYSTEM=/dev/null git -C "${main_repo}" config --list --show-origin)
  worktree_config_after=$(env GIT_CONFIG_GLOBAL="${fake_global}" GIT_CONFIG_SYSTEM=/dev/null git -C "${worktree}" config --list --show-origin)

  if [ "${RUN_STATUS}" = "0" ] &&
     [ "${main_index_hash_before}" = "${main_index_hash_after}" ] &&
     [ "${worktree_index_hash_before}" = "${worktree_index_hash_after}" ] &&
     [ "${main_index_mtime_before}" = "${main_index_mtime_after}" ] &&
     [ "${worktree_index_mtime_before}" = "${worktree_index_mtime_after}" ] &&
     [ "${main_head_before}" = "${main_head_after}" ] &&
     [ "${worktree_head_before}" = "${worktree_head_after}" ] &&
     [ "${main_config_before}" = "${main_config_after}" ] &&
     [ "${worktree_config_before}" = "${worktree_config_after}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected snapshotting to leave HEAD, indexes, and visible git config unchanged in both repos"
  fi
}

case_prune_lists_expired_refs_without_deleting() {
  local case_name="prune-lists-expired-refs-without-deleting"
  local sandbox="${TMP_DIR}/${case_name}"
  local fixture
  local main_repo
  local worktree
  local head
  local expired_ref='refs/worktree-snapshots/lane-worktree/20000101T000000Z'
  local fresh_ref
  fixture=$(make_fixture_repo "${sandbox}")
  main_repo=$(printf '%s\n' "${fixture}" | sed -n '1p')
  worktree=$(printf '%s\n' "${fixture}" | sed -n '2p')
  head=$(git_setup -C "${main_repo}" rev-parse HEAD)
  fresh_ref="refs/worktree-snapshots/$(basename "${worktree}")/$(date -u +%Y%m%dT%H%M%SZ)"

  git_setup -C "${main_repo}" update-ref "${expired_ref}" "${head}"
  git_setup -C "${main_repo}" update-ref "${fresh_ref}" "${head}"

  run_in_dir "${main_repo}" env CK_WTSNAP_TTL_DAYS=30 "${WT_SNAPSHOT}" prune

  if [ "${RUN_STATUS}" = "0" ] &&
     grep -Fq "${expired_ref}" "${RUN_STDOUT}" &&
     [ "$(git_setup -C "${main_repo}" rev-parse "${expired_ref}")" = "${head}" ] &&
     [ "$(git_setup -C "${main_repo}" rev-parse "${fresh_ref}")" = "${head}" ]; then
    record_pass "${case_name}"
  else
    record_fail "${case_name}" "expected prune to list expired refs while leaving both expired and fresh refs untouched"
  fi
}

case_dirty_capture_creates_parented_ref
case_restore_roundtrip_is_exact
case_snapshot_from_nested_subdir_captures_root_payload
case_ignored_set_is_captured_only_when_configured
case_restore_rejects_non_empty_target_with_exit_70
case_repo_local_fsmonitor_is_not_executed
case_secret_scan_abort_is_fail_closed
case_secret_scan_bytes_match_restored_payload_under_mutation
case_clean_detached_unreachable_head_creates_ref
case_clean_worktree_is_explicit_noop
case_snapshot_leaves_user_state_untouched
case_prune_lists_expired_refs_without_deleting
finish
