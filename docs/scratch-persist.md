# scratch-persist

## What/Why

`scratch-persist` is the reactive half of context-kit's large-output handling. As a `PostToolUse` hook, it detects tool output at or above a character threshold, saves the complete tool input and output to a scratch Markdown file, and returns one `additionalContext` notice with the file path.

A `PostToolUse` hook cannot replace the tool response that already entered conversation history. It is therefore a safety net, not a context-reduction mechanism for the current response. Use [`lg`](lg.md) proactively for shell commands likely to be verbose; `lg` returns bounded output, so this hook naturally stays below threshold for those calls.

## Prerequisites

- `python3 >= 3.9` must be available to Claude Code.
- On macOS, if `python3` is missing because Command Line Tools are not installed yet, `xcode-select --install` is the usual first step.

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
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "sh -c 'f=\"<CONTEXT_KIT_DIR>/hooks/scratch-persist.sh\"; if [ -f \"$f\" ]; then bash \"$f\"; fi'"
          }
        ]
      }
    ]
  }
}
```

3. Reload hooks.

Restart Claude Code or run `/hooks` so the new wiring is picked up.

The example intentionally omits `matcher`, so the hook fires after every tool call. If you want to scope it, add a matcher such as `"matcher": "Bash|Read|Grep|WebFetch"` on the `PostToolUse` entry.

## Wiring Notes

The guarded command stays silent when `<CONTEXT_KIT_DIR>` has not been replaced or the checkout moves. `PostToolUse` exit codes do not block a completed tool call, but a bare broken path would print an error after every tool call. The file guard avoids that repeated noise.

The launcher resolves `scratch-persist.py` relative to its own location, follows symlinks when `readlink` is available, and fails open if the body or `python3` is unavailable. All controlled error paths exit `0` without stderr or malformed stdout. On success, stdout contains exactly one JSON object with `hookSpecificOutput.additionalContext`.

Export hook environment variables from the shell, launcher, or app wrapper that starts Claude Code. Variables set only in a later interactive shell may not be visible to hooks.

## Environment Variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `CK_SCRATCH_DISABLED` | Set to `1` to disable reactive persistence. | unset |
| `CK_SCRATCH_THRESHOLD` | Minimum extracted output length, in characters, that triggers persistence. Empty or non-numeric values fall back to the default. | `5000` |
| `CK_SCRATCH_DIR` | Target directory for scratch files. Files are written directly into this directory. | `${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory` when `HOME` is set; otherwise `${TMPDIR:-/tmp}/context-kit-scratch` |
| `CK_AGENT` | Scratch subdirectory name when `CK_SCRATCH_DIR` is unset and `HOME` is available. | `agent` |

`CK_SCRATCH_DIR_IS_DEFAULT` is launcher-internal state used to decide whether the hook should harden directory permissions. Do not set it manually.

## Scratch Behavior and Lifecycle

The hook preserves the original response extraction surface: plain strings; `stdout`, `stderr`, `output`, `content`, and `result` dictionary fields; string list items; and list dictionaries containing `text` or `content` strings. Extracted parts retain that key order and are joined with newlines.

Files use the `scratch-<timestamp>-<tool>.md` convention in the same directory as [`lg`](lg.md), with a capped tool slug, same-second collision avoidance that keeps files flat under the scratch directory, `mode: reactive-persist`, creation and expiration timestamps, and a 7-day TTL. A write is completed through an atomic same-directory replacement before the hook emits its notice. If directory creation, permission hardening, writing, syncing, or replacement fails, the hook emits no notice.

Scratch files may contain secrets, tokens, stack traces, or raw customer data. The default scratch directory is created with mode `0700`. A user-supplied `CK_SCRATCH_DIR` keeps its existing permissions; protecting it is your responsibility.

One cleanup job covers files produced by both reactive `scratch-persist` and proactive `lg`:

```sh
if [ -n "${CK_SCRATCH_DIR:-}" ]; then
  scratch_dir="${CK_SCRATCH_DIR}"
elif [ -n "${HOME:-}" ]; then
  scratch_dir="${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory"
else
  scratch_dir="${TMPDIR:-/tmp}/context-kit-scratch"
fi
find "${scratch_dir}" \( -type f -name 'scratch-*.md' -o -type f -name '.scratch-persist-*' \) -mtime +7 -delete
```

## Verify

Run the self-check from the repository root:

```sh
bash tests/test_scratch_persist.sh
```

Above-threshold one-liner: this must create one file and print one valid notice JSON object.

```sh
scratch_dir=$(mktemp -d); export CK_SCRATCH_DIR="$scratch_dir" CK_SCRATCH_THRESHOLD=100; notice=$(python3 -c 'import json; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"demo"},"tool_response":{"stdout":"x" * 6000}}))' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/scratch-persist.sh"; if [ -f "$f" ]; then bash "$f"; fi'); printf '%s\n' "$notice" | python3 -m json.tool >/dev/null && find "$scratch_dir" -type f -name 'scratch-*.md'
```

Below-threshold one-liner: this must print nothing and exit `0`.

```sh
scratch_dir=$(mktemp -d); export CK_SCRATCH_DIR="$scratch_dir" CK_SCRATCH_THRESHOLD=5000; python3 -c 'import json; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"demo"},"tool_response":{"stdout":"small"}}))' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/scratch-persist.sh"; if [ -f "$f" ]; then bash "$f"; fi'; echo $?
```

Optional syntax, AST, and JSON checks:

```sh
bash -n hooks/scratch-persist.sh tests/test_scratch_persist.sh
python3 -B -c "import ast; ast.parse(open('hooks/scratch-persist.py').read())"
python3 -m json.tool examples/settings.json >/dev/null
```
