# recall

## What/Why

`recall` searches up to three memory layers in parallel and returns one bounded, provenance-bearing result list:

- `sm` queries a configured Supermemory container.
- `meili` delegates to a compatible `mem-search` command.
- `grep` searches configured local roots with `rg`, falling back to `grep`.

The command is intended for an individual agent's context-recovery workflow.

## Individual recall and shared FMA

`recall` complements, but does not install or replace, the shared-memory architecture described by [`caty-ai/family-memory-architecture`](https://github.com/caty-ai/family-memory-architecture). `context-kit` supplies the individual recall client; the linked FMA project describes the shared family-memory relationship and operating model. A local-only setup works without the shared system.

## Degrade by default

All three layers are selected by default, but optional integrations are never assumed. Before starting work, `recall` checks each selected layer:

- missing Supermemory credentials or container: `sm` reports `status=skip` without making a network request;
- missing `mem-search`: `meili` reports `status=skip` without starting a subprocess;
- an explicit `CK_RECALL_ROOTS` value that contains no existing roots: `grep` reports `status=skip reason=no roots`.

Every selected layer always emits one `ok`, `skip`, or `error` status with a reason. An error in one layer does not cancel the other layers. If at least one selected layer was runnable and attempted, the command exits `0`, even when that attempted layer reports an error. A selection containing only unavailable layers exits nonzero after printing its skip statuses and writing the result dump.

## Prerequisites

- Python 3.9 or newer.
- No Python packages are required; `bin/recall` uses only the standard library.
- `rg` is preferred for local search. POSIX `grep` is used when `rg` is absent.

## Install

Clone the repository and add its `bin` directory to `PATH`, or copy `bin/recall` to a directory already on `PATH`.

```sh
git clone https://github.com/caty-ai/context-kit.git
cd context-kit
export PATH="$PWD/bin:$PATH"
```

`recall` is a CLI, not a Claude Code hook. It requires no `settings.json` wiring.

## Usage

Search every configured layer:

```sh
recall "release decision"
```

Search only the local layers (`meili,grep`):

```sh
recall "release decision" --local-only
```

Select layers explicitly, cap the merged output, or request machine-readable output:

```sh
recall "release decision" --layers grep --limit 5
recall "release decision" --layers meili,grep --json
```

`--local-only` maps directly to `meili,grep` and therefore takes precedence over `--layers` when both are supplied. Repeated layer names are de-duplicated while preserving their first position. The grep query keeps the source command's regular-expression behavior.

## Layer setup

### Supermemory (`sm`)

Both a nonempty container and API key are required:

```sh
export CK_SM_CONTAINER="my-memory-container"
export SUPERMEMORY_API_KEY="<key>"
recall "onboarding" --layers sm
```

Instead of exporting the key directly, store it in `${HOME}/.config/supermemory/env` or point `CK_SM_ENV` to another env file:

```sh
printf 'SUPERMEMORY_API_KEY=%s\n' '<key>' > /secure/path/supermemory.env
export CK_SM_ENV=/secure/path/supermemory.env
export CK_SM_CONTAINER="my-memory-container"
```

The compatibility name `SUPERMEMORY_CC_API_KEY` is also accepted directly and in the env file. The env file is parsed as simple `KEY=VALUE` or `export KEY=VALUE` lines; it is never sourced as shell code. There is deliberately no default container.

### Meili / `mem-search` (`meili`)

By default, `mem-search` must resolve through `PATH`. Override the executable name or path with `CK_RECALL_MEILI_CMD`:

```sh
export CK_RECALL_MEILI_CMD=/opt/memory/bin/mem-search
recall "onboarding" --layers meili
```

Environment variables and a HOME-backed `~` in `CK_RECALL_MEILI_CMD` are expanded before executable lookup, so values such as `~/bin/mem-search` are supported.

The subprocess contract is stable:

```text
<resolved-command> --json -l <LIMIT> -- <QUERY>
```

Its stdout must be JSON. A top-level list, or an object containing a list under `results`, `hits`, `items`, `data`, `memories`, or `documents`, is accepted.

Absolute file paths are emitted directly. Relative file paths must resolve beneath an existing `CK_RECALL_ROOTS` entry (or the current directory) before they are emitted. Transcript results that provide `project` and `session_id` without a path resolve to an existing `${HOME}/.claude/projects/<project>/<session_id>.jsonl`, matching the source tool's provenance behavior.

### Local search (`grep`)

Set `CK_RECALL_ROOTS` to a colon-separated list on macOS and Linux (`os.pathsep` is used):

```sh
export CK_RECALL_ROOTS="/path/to/private-memory:/path/to/project-notes"
recall "onboarding" --layers grep
```

Nonexistent entries are silently removed. If `CK_RECALL_ROOTS` is unset, the defaults are:

1. `CK_SCRATCH_DIR`, or `${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory` when `HOME` is set, otherwise `${TMPDIR:-/tmp}/context-kit-scratch`;
2. `${HOME}/.claude/projects`, when it exists.

The kit scratch root is prepared before default-root preflight because the validated invocation writes its result there. Consequently, a clean-machine default `grep` layer is runnable with zero hits rather than skipped. Only an explicit empty or all-missing `CK_RECALL_ROOTS` produces `status=skip reason=no roots`.

An explicitly empty `CK_RECALL_ROOTS` selects zero roots and produces `status=skip reason=no roots`.

## Environment variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `SUPERMEMORY_API_KEY` | Preferred Supermemory API key, read directly before any env file. | unset |
| `SUPERMEMORY_CC_API_KEY` | Compatibility API-key name from the source tool. | unset |
| `CK_SM_ENV` | File containing either accepted API-key name. | `${HOME}/.config/supermemory/env` |
| `CK_SM_CONTAINER` | Supermemory `containerTag`; required and intentionally has no personal default. | unset |
| `CK_RECALL_MEILI_CMD` | Executable resolved through `PATH`, or an executable path. | `mem-search` |
| `CK_RECALL_ROOTS` | Local search roots separated by the platform path separator. Empty means no roots. | kit scratch memory root plus existing `${HOME}/.claude/projects` |
| `CK_SCRATCH_DIR` | Directory receiving the complete recall result dump and the first default grep root. | `${HOME}/.claude/scratch/${CK_AGENT:-agent}/memory`, or `${TMPDIR:-/tmp}/context-kit-scratch` without `HOME` |
| `CK_AGENT` | Agent name used in the default scratch path. | `agent` |

Direct environment values take precedence over `CK_SM_ENV`. A configured `CK_SCRATCH_DIR` keeps its existing directory permissions. The kit-created default scratch directory is mode `0700`, and result files are mode `0600`.

Environment variables and a HOME-backed `~` in `CK_SCRATCH_DIR` are expanded. Relative configured paths remain relative to the process working directory. Because any explicit scratch directory is user-owned, `recall` does not change its directory mode.

## Stable output contract

Human output begins with one line per selected layer, in selection order:

```text
layer=<sm|meili|grep> status=<ok|skip|error> hits=<N> latency_ms=<N> reason=<text>
```

It then prints the rejected-hit count and scratch path, followed by up to `--limit` merged hits:

```text
- [<layer>] <provenance-pointer> | <title> | <snippet>
```

Hits are merged round-robin in selected-layer order before the final top limit is applied. Supermemory pointers contain the memory ID and configured container tag; local and Meili pointers are absolute file paths, with line numbers when supplied. Hits without usable provenance are rejected rather than emitted.

`--json` preserves the same information under `layers_queried`, `per_layer`, `hits`, `top_hits`, `scratch_path`, `rejected_hits`, and `stats`. Each selected `per_layer` entry always includes `status`, `reason`, `hits`, and `latency_ms`. The `hits` array contains the full round-robin merge; `top_hits` contains the final bounded view.

Every invocation that passes argument validation writes a complete Markdown dump named `recall-*.md` through the kit scratch contract. Its frontmatter includes `createdAt` and `expiresAt` with the kit's seven-day scratch TTL; cleanup remains user-owned. A whole-command failure, such as an unwritable result directory, prints a clear English `recall: unexpected failure: ...` message to stderr and exits nonzero.

Each adapter has its own ten-second timeout. The parallel fan-out also has a ten-second outer deadline with a small scheduling allowance; unfinished layers report `status=error reason=timeout after 10s` without delaying result assembly further.

## Verify

Run the temp-only self-check from the repository root:

```sh
bash tests/test_recall.sh
```

Local-search one-liner:

```sh
d=$(mktemp -d); printf 'recall-probe\n' > "$d/note.md"; CK_RECALL_ROOTS="$d" CK_SCRATCH_DIR="$d/out" bin/recall recall-probe --layers grep; rm -rf "$d"
```

Default degradation one-liner: unconfigured `sm` and `meili` print skip lines while the seeded `grep` root succeeds.

```sh
d=$(mktemp -d); mkdir -p "$d/root"; printf 'recall-probe\n' > "$d/root/note.md"; env -u SUPERMEMORY_API_KEY -u SUPERMEMORY_CC_API_KEY CK_SM_ENV="$d/missing" CK_SM_CONTAINER= CK_RECALL_MEILI_CMD=context-kit-missing-mem-search CK_RECALL_ROOTS="$d/root" CK_SCRATCH_DIR="$d/out" bin/recall recall-probe; rm -rf "$d"
```

Degraded explicit-selection one-liner (expected exit is nonzero):

```sh
d=$(mktemp -d); env -u SUPERMEMORY_API_KEY -u SUPERMEMORY_CC_API_KEY CK_SM_ENV="$d/missing" CK_SM_CONTAINER= CK_SCRATCH_DIR="$d/out" bin/recall probe --layers sm; test $? -ne 0; rm -rf "$d"
```

Syntax and bytecode-cleanliness checks:

```sh
python3 -B -c "import ast; ast.parse(open('bin/recall', encoding='utf-8').read())"
test ! -e bin/__pycache__
```
