# context-kit — Reference

[← Front page](../README.md) ｜ **English** ｜ [日本語](reference.ja.md)

The exact contracts: every environment variable, the scratch-file rules, exit-code semantics, and the hook wiring map. Per-piece behavior details live in each piece's own doc, linked throughout.

## File layout

| Path | Contents |
| --- | --- |
| `bin/` | Standalone CLIs: [`lg`](lg.md), [`recall`](recall.md), [`wt-snapshot`](wt-snapshot.md) |
| `hooks/` | Hook scripts: `lg-enforcer.py`, `scratch-persist.{sh,py}`, `validate-subagent-brief.{sh,py}`, `rm-enforcer.py`, `private-repo-enforcer.mjs`, `api-key-leak-detector.mjs` |
| `examples/settings.json` | Complete wiring example for all hooks, with `<CONTEXT_KIT_DIR>` placeholders |
| `docs/` | This documentation, including [`wt-snapshot`](wt-snapshot.md) |
| `tests/` | Seven self-check suites, temp-directory-only |
| `refs/worktree-snapshots/<worktree-name>/<UTC-timestamp>` | Durable snapshot refs written by `wt-snapshot` into the main repository |

---

## Hook wiring map

All hook entries use the guarded form `sh -c 'f="<CONTEXT_KIT_DIR>/hooks/…"; if [ -f "$f" ]; then …; fi'`. Interpreter availability is also verified everywhere it is needed — in the wiring for `lg-enforcer` and the safety trio, and inside the `sh` launchers for `scratch-persist` and the brief validator. See [`examples/settings.json`](../examples/settings.json) for the exact commands.

| Hook | Event | Matcher |
| --- | --- | --- |
| `lg-enforcer.py` | `PreToolUse` | `Bash` |
| `rm-enforcer.py` | `PreToolUse` | `Bash` |
| `private-repo-enforcer.mjs` | `PreToolUse` | `Bash` |
| `api-key-leak-detector.mjs` | `PreToolUse` | `Bash\|Write\|Edit` |
| `validate-subagent-brief.sh` | `PreToolUse` | `Agent\|Task` |
| `scratch-persist.sh` | `PostToolUse` | none (all tools; scope with a matcher if desired) |

---

## Environment variables

Export hook-related variables from the shell, launcher, or app wrapper that starts Claude Code — variables set in a later interactive shell are not visible to hooks.

### Shared

| Variable | Purpose | Default |
| --- | --- | --- |
| `CK_AGENT` | Scratch subdirectory name when `CK_SCRATCH_DIR` is unset and `HOME` is available | `agent` |
| `CK_SCRATCH_DIR` | Scratch directory used by every persisting piece. A configured directory keeps its own permissions. Use an absolute path — relative values are resolved per piece (see the scratch contract below) | `${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory` when `HOME` is set; otherwise `${TMPDIR:-/tmp}/context-kit-scratch` |

### lg ([details](lg.md))

| Variable | Purpose | Default |
| --- | --- | --- |
| `CK_LG_PATH` | Wrapper path printed in the enforcer's retry hint | `lg` |
| `CK_LG_ENFORCER_DISABLED` | `1` bypasses the enforcer for one shell line | unset |
| `LG_HEAD` | Head lines kept in the preview | `40` |
| `LG_TAIL` | Tail lines kept in the preview | `40` |
| `LG_TTL_DAYS` | Expiration metadata written to scratch frontmatter | `7` |

### scratch-persist ([details](scratch-persist.md))

| Variable | Purpose | Default |
| --- | --- | --- |
| `CK_SCRATCH_DISABLED` | `1` disables reactive persistence | unset |
| `CK_SCRATCH_THRESHOLD` | Minimum extracted output length (characters) that triggers persistence | `5000` |

`CK_SCRATCH_DIR_IS_DEFAULT` is launcher-internal state; do not set it manually.

### brief-validator ([details](brief-validator.md))

| Variable | Purpose | Default |
| --- | --- | --- |
| `CK_SKIP_BRIEF_VALIDATION` | `1` in the launching environment bypasses validation | unset |
| `CK_BRIEF_REQUIRED_SECTIONS` | Pipe-delimited required section tokens | `## 実装仕様\|## 実装チェック\|## レビュー基準` |
| `CK_BRIEF_SKIP_SUBAGENT_TYPES` | Comma-separated subagent types that skip validation | `Explore,explore,general-purpose,claude-code-guide,statusline-setup,writer` |
| `CK_BRIEF_MIN_PROMPT_CHARS` | Minimum prompt length that triggers validation | `500` |

### safety-hooks ([details](safety-hooks.md))

| Variable | Purpose | Default |
| --- | --- | --- |
| `CK_DESTRUCTIVE_OK` | `1` (environment or same-line Bash token) bypasses destructive-command detection | unset |
| `CK_PUBLIC_REPO_OK` | `1` (environment or same-line Bash token) permits an intentional public-repo operation | unset |
| `CK_API_KEY_DETECT_DISABLED` | `1` disables key detection; the same-line form works for Bash only | unset |

### recall ([details](recall.md))

| Variable | Purpose | Default |
| --- | --- | --- |
| `SUPERMEMORY_API_KEY` | Supermemory API key, read before any env file | unset |
| `SUPERMEMORY_CC_API_KEY` | Compatibility API-key name | unset |
| `CK_SM_ENV` | Env file containing either key name (`KEY=VALUE` lines; never sourced) | `${HOME}/.config/supermemory/env` |
| `CK_SM_CONTAINER` | Supermemory `containerTag`; required, deliberately no default | unset |
| `CK_RECALL_MEILI_CMD` | `mem-search`-compatible executable name or path | `mem-search` |
| `CK_RECALL_ROOTS` | Local search roots, separated by the platform path separator; explicitly empty means no roots | kit scratch root plus existing `${HOME}/.claude/projects` |

---

### wt-snapshot ([details](wt-snapshot.md))

| Variable | Purpose | Default |
| --- | --- | --- |
| `CK_WTSNAP_INCLUDE_IGNORED` | Colon- or comma-separated glob list of gitignored paths to include in the snapshot. Unset means ignored paths are excluded entirely | unset |
| `CK_WTSNAP_SECRET_SCAN_CMD` | Optional command that receives each explicitly packed file (plus any staged-index patch) on stdin before snapshot creation. Any nonzero exit aborts fail-closed before snapshot refs or objects are written | unset |
| `CK_WTSNAP_IDENT` | Optional git identity for snapshot git invocations. The tool expands it into author and committer env vars instead of reading user git config | built-in tool identity |
| `CK_WTSNAP_TTL_DAYS` | Age threshold used by `wt-snapshot prune` when listing expired snapshot refs. The command only lists; it never deletes | `30` |

---

## Scratch contract

Every persisting piece follows the same rules:

- **Location** — `CK_SCRATCH_DIR`, or the shared default shown above. Files are written flat into this directory. Prefer an absolute `CK_SCRATCH_DIR`: a relative value is resolved per piece — the API-key hook resolves it under the default scratch root, while `lg`, `scratch-persist`, and `recall` resolve it against the process working directory (`recall` also expands `~` and environment variables).
- **Permissions** — the kit-created default root is hardened to `0700`; result and evidence files are `0600`. A user-supplied `CK_SCRATCH_DIR` keeps its existing permissions — protecting it is the operator's responsibility.
- **Naming** — `scratch-<timestamp>-<tool>.md` (lg and scratch-persist), `recall-*.md` (recall result dumps), plus the API-key hook's redacted rotation-evidence reports. On scratch failure, `lg` can leave `lg.` temp files in `${TMPDIR:-/tmp}`.
- **Frontmatter** — `createdAt` and `expiresAt`, with a 7-day TTL convention (`LG_TTL_DAYS` where applicable).
- **Cleanup is user-owned** — the kit never deletes anything. One job covers lg and scratch-persist output:

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

Scratch content can include secrets, tokens, stack traces, or raw customer data — treat the directory accordingly.

---

## Exit-code semantics

| Context | Code | Meaning |
| --- | --- | --- |
| `PreToolUse` hooks | `0` | Allow — including every fail-open path (missing file, missing interpreter, malformed input, internal error) |
| `PreToolUse` hooks | `2` | Genuine detection; the corrective message explains what to change |
| `PostToolUse` (`scratch-persist`) | `0` | Always; on success stdout carries exactly one JSON object with `hookSpecificOutput.additionalContext` |
| `recall` | `0` | At least one attempted layer completed `status=ok` (a zero-hit search counts) |
| `recall` | nonzero | Every attempted layer errored, no selected layer could be attempted, or a whole-command failure (guidance goes to stderr; stdout stays machine-readable) |
| `wt-snapshot` | `0` | Snapshot written, `restore` completed, `prune` listed zero or more refs, or capture detected a clean no-op and wrote nothing |
| `wt-snapshot` | `64` | Usage error |
| `wt-snapshot` | scanner exit status | `CK_WTSNAP_SECRET_SCAN_CMD` returned nonzero. The snapshot aborts fail-closed, no ref is written, and the scanner's status is preserved |
| `wt-snapshot` | `70` | Git, archive verification, or repository operation failed while building, storing, or restoring the snapshot |
| `wt-snapshot` | `75` | A populated submodule differs from its staged parent gitlink or contains staged, modified, untracked, ignored, or flag-hidden state. Submodule content is not captured in v1, so deletion must stop |
