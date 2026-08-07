# safety hooks

## What/Why

This equipment provides three independent `PreToolUse` safety hooks:

- `rm-enforcer.py` blocks destructive shell operations such as root or home deletion, infrastructure destruction, destructive SQL, forced pushes to `main` or `master`, device overwrites, and shell-startup-file overwrites.
- `private-repo-enforcer.mjs` requires explicit visibility for `gh repo create`, blocks public creation, and blocks changing a repository to public.
- `api-key-leak-detector.mjs` blocks recognized provider credential patterns in Bash commands and in Write/Edit content before the tool runs.

Together they cover three common failure classes: destructive commands, accidental public repositories, and credential leakage into command lines or files. They are pattern-based safeguards, not shell parsers or secret-management systems.

## Prerequisites

- `python3 >= 3.9` is required for `rm-enforcer.py`.
- `node >= 18` is required for the two `.mjs` hooks.

If the required interpreter is missing from the `PATH` that launches Claude Code, including an nvm/fnm-managed shell, the affected hooks are silently unprotected because exit `127` is non-blocking. Check each interpreter with one line:

```sh
command -v python3 && python3 --version
command -v node && node --version
```

The guarded wiring below checks that the hook is a readable file and that its interpreter exists, then stays quiet with exit `0` when either prerequisite is absent. A bare attempt to run `node` on a machine without Node normally exits `127`; Claude Code treats that hook failure as non-blocking, but the guard avoids the repeated stderr noise. Internal parsing, timeout, and runtime failures also fail open. Exit `2` is reserved for a genuine detection.

## Install

1. Clone the repository.

```sh
git clone https://github.com/caty-ai/context-kit.git
cd context-kit
```

2. Merge each hook as its own entry in `~/.claude/settings.json` or `<project>/.claude/settings.json`. Do not replace unrelated settings.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "sh -c 'f=\"<CONTEXT_KIT_DIR>/hooks/rm-enforcer.py\"; if [ -f \"$f\" ] && [ -r \"$f\" ] && command -v python3 >/dev/null 2>&1; then python3 -B \"$f\"; fi'"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "sh -c 'f=\"<CONTEXT_KIT_DIR>/hooks/private-repo-enforcer.mjs\"; if [ -f \"$f\" ] && [ -r \"$f\" ] && command -v node >/dev/null 2>&1; then node \"$f\"; fi'"
          }
        ]
      },
      {
        "matcher": "Bash|Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "sh -c 'f=\"<CONTEXT_KIT_DIR>/hooks/api-key-leak-detector.mjs\"; if [ -f \"$f\" ] && [ -r \"$f\" ] && command -v node >/dev/null 2>&1; then node \"$f\"; fi'"
          }
        ]
      }
    ]
  }
}
```

Each hook contains its own stdin handling and runtime safety behavior. No shared `lib/` directory or launcher is required, so every hook remains independently installable.

3. Replace `<CONTEXT_KIT_DIR>` with the absolute checkout path, then restart Claude Code or run `/hooks`.

## Bypass Semantics

For Bash hooks, Claude Code includes the shell command in `tool_input.command`. A same-line prefix is therefore visible to the hook and works for all three bypass variables:

```sh
CK_DESTRUCTIVE_OK=1 rm -rf /path-reviewed-for-deletion
CK_PUBLIC_REPO_OK=1 gh repo create example --public
CK_API_KEY_DETECT_DISABLED=1 printf '%s\n' 'known-false-positive'
```

The same-line form is not an environment change for the already-running hook. It works because the literal token appears in the Bash command string.

Write and Edit tool calls have no Bash command string. `CK_API_KEY_DETECT_DISABLED=1` text inside file content does not bypass detection. To bypass a Write/Edit false positive, set the variable in the environment that launches Claude Code and restart it. The process-environment form also bypasses Bash detections.

## Environment Variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `CK_DESTRUCTIVE_OK` | Set to `1` in the hook environment, or use the literal same-line Bash token, to bypass destructive-command detection. | unset |
| `CK_PUBLIC_REPO_OK` | Set to `1` in the hook environment, or use the literal same-line Bash token, to permit an intentional public repository operation. | unset |
| `CK_API_KEY_DETECT_DISABLED` | Set to `1` in the hook environment to disable API-key detection; the literal same-line token also works for Bash only. | unset |
| `CK_SCRATCH_DIR` | Directory for API-key detection evidence. A configured directory keeps its own directory permissions. | `${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory` when `HOME` is set; otherwise `${TMPDIR:-/tmp}/context-kit-scratch` |
| `CK_AGENT` | Scratch subdirectory name when `CK_SCRATCH_DIR` is unset and `HOME` is available. | `agent` |

## API-Key Evidence and Exclusions

On detection, the API-key hook writes a local rotation-evidence report and prints its path to stderr. The report contains the tool name, the target file path when present, provider names, and redacted matches that keep only the first eight characters. It does not store the scanned command/content or the full matched key.

Evidence files are created with mode `0600`. The kit-managed default scratch root is hardened to `0700`; a user-configured `CK_SCRATCH_DIR` retains its existing directory permissions. Relative `CK_SCRATCH_DIR` values resolve under the default scratch root rather than the current working directory. Evidence is never written into the repository unless the operator explicitly points `CK_SCRATCH_DIR` there.

Write/Edit calls targeting these intentional credential-file forms are excluded: `.env`, `.env.<lowercase-suffix>`, `secret.json`, and `secrets.json`. Unlike the source hook, this generalized hook deliberately drops its personal env-file exclusion, so other env filenames are scanned. The exclusion applies only when the file path ends with one of those slash-prefixed names. Bash commands are still scanned even when they mention an env file.

### Known gaps (inherited from the originals)

- `rm -rf /*` glob form
- `git push -f` short flag
- `--visibility=public` equals form
- Repository-visibility changes through `gh api`

These gaps preserve source-hook parity; PRs are welcome.

## Verify

Run the complete trio suite from the repository root:

```sh
bash tests/test_safety_hooks.sh
```

Replace `<CONTEXT_KIT_DIR>` before running the exact-wiring probes below.

### rm-enforcer

```sh
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/rm-enforcer.py"; if [ -f "$f" ] && [ -r "$f" ] && command -v python3 >/dev/null 2>&1; then python3 -B "$f"; fi'; echo $? # 2
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/example"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/rm-enforcer.py"; if [ -f "$f" ] && [ -r "$f" ] && command -v python3 >/dev/null 2>&1; then python3 -B "$f"; fi'; echo $? # 0
echo '{"tool_name":"Bash","tool_input":{"command":"CK_DESTRUCTIVE_OK=1 rm -rf /"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/rm-enforcer.py"; if [ -f "$f" ] && [ -r "$f" ] && command -v python3 >/dev/null 2>&1; then python3 -B "$f"; fi'; echo $? # 0
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/rm-enforcer.py"; if [ -f "$f" ] && [ -r "$f" ] && command -v python3 >/dev/null 2>&1; then python3 -B "$f"; fi'; echo $? # 0 while the token is unreplaced
```

### private-repo-enforcer

```sh
echo '{"tool_name":"Bash","tool_input":{"command":"gh repo create example"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/private-repo-enforcer.mjs"; if [ -f "$f" ] && [ -r "$f" ] && command -v node >/dev/null 2>&1; then node "$f"; fi'; echo $? # 2
echo '{"tool_name":"Bash","tool_input":{"command":"gh repo create example --private"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/private-repo-enforcer.mjs"; if [ -f "$f" ] && [ -r "$f" ] && command -v node >/dev/null 2>&1; then node "$f"; fi'; echo $? # 0
echo '{"tool_name":"Bash","tool_input":{"command":"CK_PUBLIC_REPO_OK=1 gh repo create example --public"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/private-repo-enforcer.mjs"; if [ -f "$f" ] && [ -r "$f" ] && command -v node >/dev/null 2>&1; then node "$f"; fi'; echo $? # 0
echo '{"tool_name":"Bash","tool_input":{"command":"gh repo create example"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/private-repo-enforcer.mjs"; if [ -f "$f" ] && [ -r "$f" ] && command -v node >/dev/null 2>&1; then node "$f"; fi'; echo $? # 0 while the token is unreplaced
```

### api-key-leak-detector

The fake token below is intentionally non-secret but matches the preserved OpenAI regex.

```sh
echo '{"tool_name":"Bash","tool_input":{"command":"printf sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/api-key-leak-detector.mjs"; if [ -f "$f" ] && [ -r "$f" ] && command -v node >/dev/null 2>&1; then node "$f"; fi'; echo $? # 2
echo '{"tool_name":"Bash","tool_input":{"command":"printf safe-value"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/api-key-leak-detector.mjs"; if [ -f "$f" ] && [ -r "$f" ] && command -v node >/dev/null 2>&1; then node "$f"; fi'; echo $? # 0
echo '{"tool_name":"Bash","tool_input":{"command":"CK_API_KEY_DETECT_DISABLED=1 printf sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/api-key-leak-detector.mjs"; if [ -f "$f" ] && [ -r "$f" ] && command -v node >/dev/null 2>&1; then node "$f"; fi'; echo $? # 0
echo '{"tool_name":"Bash","tool_input":{"command":"printf sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/api-key-leak-detector.mjs"; if [ -f "$f" ] && [ -r "$f" ] && command -v node >/dev/null 2>&1; then node "$f"; fi'; echo $? # 0 while the token is unreplaced
```

Write-tool probe through the same guarded command; it must exit `2`:

```sh
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/example.txt","content":"sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/api-key-leak-detector.mjs"; if [ -f "$f" ] && [ -r "$f" ] && command -v node >/dev/null 2>&1; then node "$f"; fi'; echo $?
```

Optional syntax and configuration checks:

```sh
bash -n tests/test_safety_hooks.sh
python3 -B -c "import ast; ast.parse(open('hooks/rm-enforcer.py').read())"
node --check hooks/private-repo-enforcer.mjs
node --check hooks/api-key-leak-detector.mjs
python3 -m json.tool examples/settings.json >/dev/null
```
