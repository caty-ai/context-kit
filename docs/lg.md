# lg

## What/Why

`lg` is a proactive wrapper for shell commands that may produce too much output for an agent turn. It captures combined stdout and stderr, writes the full transcript to a scratch file, and returns either the complete output or a bounded head-and-tail preview.

This exists because a reactive `PostToolUse` hook cannot replace the standard tool response that already entered history. `lg` solves that earlier in the flow by wrapping the command before it runs.

## Prerequisites

- `python3 >= 3.9` must be available to Claude Code.
- On macOS, if `python3` is missing because Command Line Tools are not installed yet, `xcode-select --install` is the usual first step.

## Install

1. Clone the repository.

```sh
git clone https://github.com/caty-ai/context-kit.git
cd context-kit
```

2. Make `lg` available.

Option A: add `<CONTEXT_KIT_DIR>/bin` to your shell `PATH`.

```sh
export PATH="<CONTEXT_KIT_DIR>/bin:$PATH"
```

Option B: copy `bin/lg` into a directory that is already on your `PATH`.

3. Merge the hook into your existing Claude Code settings.

Update either `~/.claude/settings.json` or `<project>/.claude/settings.json`. Merge this hook block into the existing file; do not overwrite unrelated settings.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "sh -c 'f=\"<CONTEXT_KIT_DIR>/hooks/lg-enforcer.py\"; if [ -f \"$f\" ]; then python3 \"$f\"; fi'"
          }
        ]
      }
    ]
  }
}
```

4. Reload hooks.

Restart Claude Code or run `/hooks` so the new wiring is picked up.

## Wiring Notes

The hook command above is intentionally fail-open only when the file is absent. If the file exists, `python3` runs normally and its exit status propagates exactly.
That fail-open form prevents an unreplaced or wrong hook path from blocking Bash before the real hook is in place.

Do not wire a bare command such as `python3 "<wrong-path>/hooks/lg-enforcer.py"` directly. If that path is wrong, Python exits `2`, and Claude Code can treat that as a hook failure that blocks every Bash command.

If you do not add `<CONTEXT_KIT_DIR>/bin` to `PATH`, set `CK_LG_PATH` in the shell, launcher, or app wrapper that starts Claude Code so the hook suggests the correct wrapper path. The same launch point is where `CK_SCRATCH_DIR`, `LG_HEAD`, `LG_TAIL`, and `LG_TTL_DAYS` must be exported if you want hook-triggered runs to see them.

## Usage

Simple command:

```sh
lg rg -n TODO .
```

Pipeline or compound shell idiom:

```sh
lg bash -c 'journalctl -u my-service | grep ERROR | tail -n 50'
```

One-off bypass for an incomplete nudge:

```sh
CK_LG_ENFORCER_DISABLED=1 grep -r foo /
```

The hook is a nudge, not a guarantee. The pattern list is intentionally incomplete, and the matcher does not attempt full shell parsing.

## Environment Variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `CK_AGENT` | Scratch subdirectory name when `CK_SCRATCH_DIR` is unset and `HOME` is available. | `agent` |
| `CK_SCRATCH_DIR` | Scratch directory used by `lg`. | `${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory` when `HOME` is set; otherwise `${TMPDIR:-/tmp}/context-kit-scratch` |
| `CK_LG_PATH` | Wrapper path printed by the hook retry hint. | `lg` |
| `CK_LG_ENFORCER_DISABLED` | Set to `1` to bypass the hook for one shell line. | unset |
| `LG_HEAD` | Number of head lines kept in the preview. Numeric strings are used as-is; empty or non-numeric values fall back to the default. | `40` |
| `LG_TAIL` | Number of tail lines kept in the preview. Numeric strings are used as-is; empty or non-numeric values fall back to the default. | `40` |
| `LG_TTL_DAYS` | Expiration metadata written into the scratch frontmatter. Numeric strings are used as-is; empty or non-numeric values fall back to the default. | `7` |

## Scratch Behavior

`lg` writes scratch files under `CK_SCRATCH_DIR` or, by default, `${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory`. If `HOME` is unset, it falls back to `${TMPDIR:-/tmp}/context-kit-scratch`.

Scratch transcripts can contain secrets, tokens, stack traces, or raw customer data. The default scratch directory is created with mode `0700`. A user-supplied `CK_SCRATCH_DIR` keeps its own permissions; protecting it is your responsibility. If `lg` cannot create the scratch directory or secure the default scratch directory, it falls back instead of blocking the command.

Fallback rules:

- Small output: return the full combined output directly and emit one stderr warning.
- Large output: return the configured head/tail preview, keep a readable temp file with the full output, and print that temp path in the omission marker.
- Scratch failure: suppress the normal `[lg] full output preserved: ...` footer because scratch persistence was not completed.

Each scratch file includes `createdAt` and `expiresAt` metadata, and the default convention is a 7-day TTL through `LG_TTL_DAYS`.

Scratch cleanup is intentionally user-owned. Use your own cron job or launchd task to remove expired files on your schedule.

On scratch failure, large outputs can leave mode `0600` `lg.XXXXXX` temp files in `${TMPDIR:-/tmp}`; remove ones older than seven days with `find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'lg.*' -mtime +7 -delete`.

Example cleanup command:

```sh
if [ -n "${CK_SCRATCH_DIR:-}" ]; then
  scratch_dir="${CK_SCRATCH_DIR}"
elif [ -n "${HOME:-}" ]; then
  scratch_dir="${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory"
else
  scratch_dir="${TMPDIR:-/tmp}/context-kit-scratch"
fi
find "${scratch_dir}" -type f -name 'scratch-*.md' -mtime +7 -delete
```

## Verify

Run the self-checks from the repository root:

```sh
bash tests/test_lg.sh
bash tests/test_lg_enforcer.sh
```

Exact wired-command checks:

Run these after replacing `<CONTEXT_KIT_DIR>` with your actual checkout path.

```sh
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/lg-enforcer.py"; if [ -f "$f" ]; then python3 "$f"; fi'; echo $?
echo '{"tool_name":"Bash","tool_input":{"command":"grep -r foo /"}}' | sh -c 'f="<CONTEXT_KIT_DIR>/hooks/lg-enforcer.py"; if [ -f "$f" ]; then python3 "$f"; fi'; echo $?
```

Expected results:

- `ls` returns `0`
- `grep -r foo /` returns `2`

Optional syntax, AST, and JSON checks:

```sh
bash -n bin/lg tests/test_lg.sh tests/test_lg_enforcer.sh
python3 -B -c "import ast; ast.parse(open('hooks/lg-enforcer.py').read())"
python3 -m json.tool examples/settings.json >/dev/null
```
