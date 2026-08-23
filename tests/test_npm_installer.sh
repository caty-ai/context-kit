#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="${ROOT}/packages/npm/bin/context-kit.mjs"
TMP_DIR=$(mktemp -d)
PASS_COUNT=0
FAIL_COUNT=0

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

run_case() {
  local name="$1"
  local function_name="$2"
  if "${function_name}"; then
    record_pass "${name}"
  else
    record_fail "${name}" "case assertions failed"
  fi
}

backup_count() {
  find "$1" -maxdepth 1 -type f -name 'settings.json.ck-backup-*' -print 2>/dev/null | wc -l | tr -d ' '
}

case_fresh_install() {
  local home="${TMP_DIR}/fresh"
  local output="${TMP_DIR}/fresh.out"
  mkdir -p "${home}"
  HOME="${home}" node "${INSTALLER}" install --all --apply >"${output}" 2>&1 || return 1

  local expected_files=(
    bin/lg
    bin/recall
    bin/wt-snapshot
    hooks/api-key-leak-detector.mjs
    hooks/lg-enforcer.py
    hooks/private-repo-enforcer.mjs
    hooks/rm-enforcer.py
    hooks/scratch-persist.py
    hooks/scratch-persist.sh
    hooks/validate-subagent-brief.py
    hooks/validate-subagent-brief.sh
  )
  local relative
  for relative in "${expected_files[@]}"; do
    [ -f "${home}/.claude/context-kit/${relative}" ] || return 1
    cmp "${ROOT}/${relative}" "${home}/.claude/context-kit/${relative}" || return 1
  done
  [ "$(find "${home}/.claude/context-kit" -type f | wc -l | tr -d ' ')" = "11" ] || return 1

  node - "${home}/.claude/settings.json" "${home}/.claude/context-kit" <<'NODE'
const fs = require('node:fs');
const [settingsPath, installRoot] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
if (settings.hooks.PreToolUse.length !== 5) process.exit(1);
if (settings.hooks.PostToolUse.length !== 1) process.exit(1);
const allEntries = [...settings.hooks.PreToolUse, ...settings.hooks.PostToolUse];
if (allEntries.length !== 6) process.exit(1);
const commands = allEntries.flatMap((entry) => entry.hooks.map((hook) => hook.command));
if (commands.length !== 6 || commands.some((command) => !command.includes(installRoot))) process.exit(1);
const scratch = settings.hooks.PostToolUse[0];
if (Object.prototype.hasOwnProperty.call(scratch, 'matcher')) process.exit(1);
NODE

  [ -x "${home}/.claude/context-kit/bin/lg" ] || return 1
  grep -Fq 'Hook entries added: 6; skipped: 0' "${output}" || return 1
}

case_idempotent() {
  local home="${TMP_DIR}/idempotent"
  local first="${TMP_DIR}/idempotent.first"
  local second="${TMP_DIR}/idempotent.second"
  local snapshot="${TMP_DIR}/idempotent.settings"
  mkdir -p "${home}"
  HOME="${home}" node "${INSTALLER}" install --all --apply >"${first}" 2>&1 || return 1
  cp "${home}/.claude/settings.json" "${snapshot}"
  local backups_before
  backups_before=$(backup_count "${home}/.claude")

  HOME="${home}" node "${INSTALLER}" install --all --apply >"${second}" 2>&1 || return 1
  cmp "${snapshot}" "${home}/.claude/settings.json" || return 1
  [ "$(backup_count "${home}/.claude")" = "${backups_before}" ] || return 1
  grep -Fq 'Hook entries added: 0; skipped: 6' "${second}" || return 1
  grep -Fq 'Settings: no changes' "${second}" || return 1
  ! grep -Fq -- '--- ' "${second}" || return 1
}

case_dry_run_purity() {
  local home="${TMP_DIR}/dry-run"
  local output="${TMP_DIR}/dry-run.out"
  local snapshot="${TMP_DIR}/dry-run.settings"
  mkdir -p "${home}/.claude"
  printf '%s\n' '{"theme":"dark"}' >"${home}/.claude/settings.json"
  cp "${home}/.claude/settings.json" "${snapshot}"

  HOME="${home}" node "${INSTALLER}" install lg >"${output}" 2>&1 || return 1
  [ ! -e "${home}/.claude/context-kit" ] || return 1
  cmp "${snapshot}" "${home}/.claude/settings.json" || return 1
  [ "$(backup_count "${home}/.claude")" = "0" ] || return 1
  grep -Fq 'Dry run (no files will be written)' "${output}" || return 1
  grep -Fq -- '--- ' "${output}" || return 1
  grep -Fq -- '--apply' "${output}" || return 1
}

case_byte_preservation_and_backup() {
  local home="${TMP_DIR}/bytes"
  local settings="${home}/.claude/settings.json"
  local snapshot="${TMP_DIR}/bytes.settings"
  mkdir -p "${home}/.claude"
  printf '%s' $'{\n\t"zeta": {"literal": "hooks ] }", "nested": [1, {"x": "} ]"}]},\n\t"hooks": {\n\t\t"PreToolUse": [\n\t\t\t{"matcher":"Read","hooks":[{"type":"command","command":"printf bracket-] brace-} hooks"}]}\n\t\t]\n\t},\n\t"alpha": true\n}' >"${settings}"
  cp "${settings}" "${snapshot}"

  HOME="${home}" node "${INSTALLER}" install lg --apply >"${TMP_DIR}/bytes.out" 2>&1 || return 1
  local backup
  backup=$(find "${home}/.claude" -maxdepth 1 -type f -name 'settings.json.ck-backup-*' -print)
  [ -n "${backup}" ] || return 1
  [ "$(printf '%s\n' "${backup}" | wc -l | tr -d ' ')" = "1" ] || return 1
  cmp "${snapshot}" "${backup}" || return 1

  node - "${snapshot}" "${settings}" <<'NODE'
const fs = require('node:fs');
const [beforePath, afterPath] = process.argv.slice(2);
const before = fs.readFileSync(beforePath, 'utf8');
const after = fs.readFileSync(afterPath, 'utf8');
const needle = '{"matcher":"Read","hooks":[{"type":"command","command":"printf bracket-] brace-} hooks"}]}';
const insertionPoint = before.indexOf(needle) + needle.length;
if (insertionPoint < needle.length) process.exit(1);
if (after.slice(0, insertionPoint) !== before.slice(0, insertionPoint)) process.exit(1);
if (!after.endsWith(before.slice(insertionPoint))) process.exit(1);
if (after.endsWith('\n')) process.exit(1);
const original = JSON.parse(before);
const installed = JSON.parse(after);
if (JSON.stringify(installed.zeta) !== JSON.stringify(original.zeta)) process.exit(1);
if (installed.alpha !== original.alpha) process.exit(1);
if (JSON.stringify(installed.hooks.PreToolUse[0]) !== JSON.stringify(original.hooks.PreToolUse[0])) process.exit(1);
if (installed.hooks.PreToolUse.length !== 2) process.exit(1);
if (!after.includes('\n\t\t\t{\n\t\t\t\t"matcher"')) process.exit(1);
NODE
}

case_partial_selection() {
  local home="${TMP_DIR}/partial"
  mkdir -p "${home}"
  HOME="${home}" node "${INSTALLER}" install lg recall --apply >"${TMP_DIR}/partial.out" 2>&1 || return 1
  [ -f "${home}/.claude/context-kit/bin/lg" ] || return 1
  [ -f "${home}/.claude/context-kit/bin/recall" ] || return 1
  [ -f "${home}/.claude/context-kit/hooks/lg-enforcer.py" ] || return 1
  [ "$(find "${home}/.claude/context-kit" -type f | wc -l | tr -d ' ')" = "3" ] || return 1
  [ ! -e "${home}/.claude/context-kit/bin/wt-snapshot" ] || return 1
  [ ! -e "${home}/.claude/context-kit/hooks/scratch-persist.sh" ] || return 1

  node - "${home}/.claude/settings.json" <<'NODE'
const fs = require('node:fs');
const settings = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (Object.keys(settings.hooks).join(',') !== 'PreToolUse') process.exit(1);
if (settings.hooks.PreToolUse.length !== 1) process.exit(1);
if (!settings.hooks.PreToolUse[0].hooks[0].command.endsWith('hooks/lg-enforcer.py"; if [ -f "$f" ] && [ -r "$f" ] && command -v python3 >/dev/null 2>&1; then python3 "$f"; fi\'')) process.exit(1);
NODE
}

case_invalid_json() {
  local home="${TMP_DIR}/invalid"
  local settings="${home}/.claude/settings.json"
  local snapshot="${TMP_DIR}/invalid.settings"
  mkdir -p "${home}/.claude"
  printf '%s\n' '{"theme": true, // JSONC is intentionally rejected' >"${settings}"
  cp "${settings}" "${snapshot}"

  if HOME="${home}" node "${INSTALLER}" install lg --apply >"${TMP_DIR}/invalid.out" 2>&1; then
    return 1
  fi
  cmp "${snapshot}" "${settings}" || return 1
  [ "$(backup_count "${home}/.claude")" = "0" ] || return 1
  grep -Fqi 'invalid JSON' "${TMP_DIR}/invalid.out" || return 1
}

case_missing_hooks_and_event() {
  local no_hooks_home="${TMP_DIR}/no-hooks"
  local no_event_home="${TMP_DIR}/no-event"
  mkdir -p "${no_hooks_home}/.claude" "${no_event_home}/.claude"
  printf '%s' '{"theme":"dark","nested":{"hooks":"string trap ] }"}}' >"${no_hooks_home}/.claude/settings.json"
  printf '%s' '{"theme":"dark","hooks":{"PostToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"printf existing"}]}]}}' >"${no_event_home}/.claude/settings.json"

  HOME="${no_hooks_home}" node "${INSTALLER}" install lg --apply >"${TMP_DIR}/no-hooks.out" 2>&1 || return 1
  HOME="${no_event_home}" node "${INSTALLER}" install lg --apply >"${TMP_DIR}/no-event.out" 2>&1 || return 1

  node - "${no_hooks_home}/.claude/settings.json" "${no_event_home}/.claude/settings.json" <<'NODE'
const fs = require('node:fs');
const [noHooksPath, noEventPath] = process.argv.slice(2);
const noHooks = JSON.parse(fs.readFileSync(noHooksPath, 'utf8'));
const noEvent = JSON.parse(fs.readFileSync(noEventPath, 'utf8'));
if (noHooks.theme !== 'dark' || noHooks.nested.hooks !== 'string trap ] }') process.exit(1);
if (noHooks.hooks.PreToolUse.length !== 1) process.exit(1);
if (noEvent.theme !== 'dark' || noEvent.hooks.PreToolUse.length !== 1) process.exit(1);
if (noEvent.hooks.PostToolUse.length !== 1) process.exit(1);
if (noEvent.hooks.PostToolUse[0].hooks[0].command !== 'printf existing') process.exit(1);
NODE
}

case_command_based_dedupe() {
  local home="${TMP_DIR}/dedupe"
  local settings="${home}/.claude/settings.json"
  local snapshot="${TMP_DIR}/dedupe.settings"
  mkdir -p "${home}/.claude"
  node - "${settings}" "${home}/.claude/context-kit" <<'NODE'
const fs = require('node:fs');
const [settingsPath, root] = process.argv.slice(2);
const command = `sh -c 'f="${root}/hooks/lg-enforcer.py"; if [ -f "$f" ] && [ -r "$f" ] && command -v python3 >/dev/null 2>&1; then python3 "$f"; fi'`;
fs.writeFileSync(settingsPath, JSON.stringify({
  hooks: { PreToolUse: [{ matcher: 'Read', hooks: [{ type: 'command', command }] }] },
}, null, 2));
NODE
  cp "${settings}" "${snapshot}"
  HOME="${home}" node "${INSTALLER}" install lg --apply >"${TMP_DIR}/dedupe.out" 2>&1 || return 1
  cmp "${snapshot}" "${settings}" || return 1
  [ "$(backup_count "${home}/.claude")" = "0" ] || return 1
  grep -Fq 'Hook entries added: 0; skipped: 1' "${TMP_DIR}/dedupe.out" || return 1
}

case_same_command_different_event() {
  local home="${TMP_DIR}/different-event"
  local settings="${home}/.claude/settings.json"
  mkdir -p "${home}/.claude"
  node - "${settings}" "${home}/.claude/context-kit" <<'NODE'
const fs = require('node:fs');
const [settingsPath, root] = process.argv.slice(2);
const command = `sh -c 'f="${root}/hooks/lg-enforcer.py"; if [ -f "$f" ] && [ -r "$f" ] && command -v python3 >/dev/null 2>&1; then python3 "$f"; fi'`;
fs.writeFileSync(settingsPath, JSON.stringify({
  hooks: { PostToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command }] }] },
}, null, 2));
NODE
  HOME="${home}" node "${INSTALLER}" install lg --apply >"${TMP_DIR}/different-event.out" 2>&1 || return 1
  node - "${settings}" <<'NODE'
const fs = require('node:fs');
const settings = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (settings.hooks.PostToolUse.length !== 1) process.exit(1);
if (settings.hooks.PreToolUse.length !== 1) process.exit(1);
if (settings.hooks.PostToolUse[0].hooks[0].command !== settings.hooks.PreToolUse[0].hooks[0].command) process.exit(1);
NODE
  grep -Fq 'Hook entries added: 1; skipped: 0' "${TMP_DIR}/different-event.out" || return 1
}

if ! command -v node >/dev/null 2>&1; then
  echo 'SKIP test_npm_installer.sh: node is not available'
  echo 'passed: 0, failed: 0 (skipped: node unavailable)'
  exit 0
fi

run_case fresh-install-all case_fresh_install
run_case idempotent-second-apply case_idempotent
run_case dry-run-purity case_dry_run_purity
run_case byte-preservation-and-backup case_byte_preservation_and_backup
run_case partial-selection case_partial_selection
run_case invalid-settings-json case_invalid_json
run_case missing-hooks-and-event-paths case_missing_hooks_and_event
run_case command-based-dedupe case_command_based_dedupe
run_case same-command-different-event case_same_command_different_event

printf 'passed: %d, failed: %d\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [ "${FAIL_COUNT}" -ne 0 ]; then
  exit 1
fi
