# lg

## What/Why

`lg` is a proactive wrapper for shell commands that may produce too much output for an agent turn. It captures combined stdout and stderr, writes the full transcript to a scratch file, and returns either the complete output or a bounded head-and-tail preview.

This exists because a reactive `PostToolUse` hook cannot replace the standard tool response that already entered history. `lg` solves that earlier in the flow by wrapping the command before it runs. Reactive scratch capture is the next step; `scratch-persist` is coming next, but it is not part of this equipment.

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

3. Wire the Bash hook.

Use `examples/settings.json` as the minimal shape and replace the literal `<CONTEXT_KIT_DIR>` token with your local checkout path.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"<CONTEXT_KIT_DIR>/hooks/lg-enforcer.py\""
          }
        ]
      }
    ]
  }
}
```

If you do not add `<CONTEXT_KIT_DIR>/bin` to `PATH`, set `CK_LG_PATH` in the shell environment that launches Claude Code so the hook suggests the correct wrapper path.

## Environment Variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `CK_AGENT` | Scratch subdirectory name when `CK_SCRATCH_DIR` is unset. | `agent` |
| `CK_SCRATCH_DIR` | Scratch directory used by `lg`. | `${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory` |
| `CK_LG_PATH` | Wrapper path printed by the hook retry hint. | `lg` |
| `CK_LG_ENFORCER_DISABLED` | Set to `1` to bypass the hook for one shell line. | unset |
| `LG_HEAD` | Number of head lines kept in the preview. | `40` |
| `LG_TAIL` | Number of tail lines kept in the preview. | `40` |
| `LG_TTL_DAYS` | Expiration metadata written into the scratch frontmatter. | `7` |

## Verify

Run the self-checks from the repository root:

```sh
bash tests/test_lg.sh
bash tests/test_lg_enforcer.sh
```

Optional syntax and JSON checks:

```sh
bash -n bin/lg tests/test_lg.sh tests/test_lg_enforcer.sh
python3 -m py_compile hooks/lg-enforcer.py
python3 -m json.tool examples/settings.json >/dev/null
```

## Scratch File Lifecycle

`lg` writes scratch files under `CK_SCRATCH_DIR` or, by default, `${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory`. Each file includes `createdAt` and `expiresAt` metadata, and the default convention is a 7-day TTL through `LG_TTL_DAYS`.

Scratch cleanup is intentionally user-owned. Use your own cron job or launchd task to remove expired files on your schedule.

Example cron or launchd command:

```sh
find "${CK_SCRATCH_DIR:-${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory}" -type f -name 'scratch-*.md' -mtime +7 -delete
```
