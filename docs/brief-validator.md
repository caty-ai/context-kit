# brief-validator

## What/Why

`brief-validator` is a `PreToolUse` hook for substantial `Agent` and `Task` delegations. It requires a three-layer brief with these canonical section tokens:

- `## 実装仕様`
- `## 実装チェック`
- `## レビュー基準`

The contract comes from the public [`family-dev-handbook`](https://github.com/caty-ai/family-dev-handbook), specifically [`docs/07-delegation-brief.md`](https://github.com/caty-ai/family-dev-handbook/blob/main/docs/07-delegation-brief.md) and [`templates/brief-template.md`](https://github.com/caty-ai/family-dev-handbook/blob/main/templates/brief-template.md). The three layers keep the requested implementation, self-verification, and reviewer acceptance criteria explicit at the delegation boundary.

The hook blocks an incomplete substantial prompt with exit code `2`. Claude Code can then return the corrective message to the model so it retries the `Agent` or `Task` call with a complete brief. Short prompts and configured lightweight research subagent types pass through without validation.

## Prerequisites

- `python3 >= 3.9` must be available to Claude Code.
- On macOS, if `python3` is missing because Command Line Tools are not installed yet, `xcode-select --install` is the usual first step.
- On Linux (including WSL2), install it with your package manager, e.g. `sudo apt install python3` on Debian/Ubuntu.

## Install

1. Clone the repository.

```sh
git clone https://github.com/caty-ai/context-kit.git
cd context-kit
```

2. Merge the hook into your existing Claude Code settings.

Update either `~/.claude/settings.json` or `<project>/.claude/settings.json`. Merge this hook block into the existing file; do not overwrite unrelated settings.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Agent|Task",
        "hooks": [
          {
            "type": "command",
            "command": "sh -c 'f=\"<CONTEXT_KIT_DIR>/hooks/validate-subagent-brief.sh\"; if [ -f \"$f\" ]; then bash \"$f\"; fi'"
          }
        ]
      }
    ]
  }
}
```

3. Reload hooks.

Restart Claude Code or run `/hooks` so the new wiring is picked up.

## Wiring Notes

The guarded command stays silent and exits `0` when `<CONTEXT_KIT_DIR>` has not been replaced or the checkout moves. This prevents a broken path from blocking every delegation before the validator is installed correctly.

The launcher resolves `validate-subagent-brief.py` relative to its own location, follows symlinks when `readlink` is available, and fails open when the body or `python3` is unavailable. The Python body also fails open on malformed input, missing fields, unexpected input types, and internal errors. Exit code `2` is reserved for a genuine validation failure.

Export hook environment variables from the shell, launcher, or app wrapper that starts Claude Code, then restart Claude Code. A variable attached to an unrelated tool command cannot change the environment of this `PreToolUse` hook.

## Environment Variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `CK_SKIP_BRIEF_VALIDATION` | Set to `1` in the environment that launches Claude Code to bypass validation. | unset |
| `CK_BRIEF_REQUIRED_SECTIONS` | Pipe-delimited required section tokens. Empty, unset, or malformed values fall back to the canonical tokens. | `## 実装仕様\|## 実装チェック\|## レビュー基準` |
| `CK_BRIEF_SKIP_SUBAGENT_TYPES` | Comma-separated subagent types that skip validation. An explicitly empty value skips no types. | `Explore,explore,general-purpose,claude-code-guide,statusline-setup,writer` |
| `CK_BRIEF_MIN_PROMPT_CHARS` | Minimum prompt length that triggers validation. Empty or non-numeric values fall back to the default. | `500` |

Required section tokens are matched as plain, case-sensitive substrings. The hook does not normalize case or parse Markdown heading levels.

## Verify

**Replace `<CONTEXT_KIT_DIR>` with your actual checkout path before running these snippets, or the file guard will exit `0` silently.**

Run the self-check from the repository root:

```sh
bash tests/test_brief_validator.sh
```

Blocked probe: this must print a corrective message (English prose naming the three missing canonical tokens — the tokens themselves are Japanese) and exit `2`.

```sh
python3 -c 'import json; print(json.dumps({"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"x" * 500}}))' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/validate-subagent-brief.sh"; if [ -f "$f" ]; then bash "$f"; fi'; echo $?
```

Compliant probe: this must print nothing and exit `0`.

```sh
python3 -c 'import json; print(json.dumps({"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"## 実装仕様\n## 実装チェック\n## レビュー基準\n" + "x" * 500}}))' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/validate-subagent-brief.sh"; if [ -f "$f" ]; then bash "$f"; fi'; echo $?
```

Short-prompt probe: this must print nothing and exit `0`.

```sh
echo '{"tool_name":"Task","tool_input":{"subagent_type":"executor","prompt":"quick lookup"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/validate-subagent-brief.sh"; if [ -f "$f" ]; then bash "$f"; fi'; echo $?
```

Optional syntax, AST, and JSON checks:

```sh
bash -n hooks/validate-subagent-brief.sh tests/test_brief_validator.sh
python3 -B -c "import ast; ast.parse(open('hooks/validate-subagent-brief.py').read())"
python3 -m json.tool examples/settings.json >/dev/null
```
