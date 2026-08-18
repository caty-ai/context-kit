# wt-snapshot

## What/Why

`wt-snapshot` makes worktree deletion reversible.

Run it before a human removes a Git worktree. The command captures the worktree's base commit plus every local change needed to rebuild that lane later:

- tracked modifications relative to the worktree `HEAD`
- untracked files, including nested paths
- a configured subset of gitignored paths through `CK_WTSNAP_INCLUDE_IGNORED`

The result is stored as a commit object under a durable ref in the main repository:

```text
refs/worktree-snapshots/<worktree-name>/<UTC-timestamp>
```

The tool never deletes a worktree. It only captures, restores, and lists candidate old snapshots for human review.

## Commands

### Capture

Running `wt-snapshot` with no subcommand captures the current worktree into the main repository.

```sh
wt-snapshot
```

Ignored paths are opt-in. Unset means none are included.

```sh
CK_WTSNAP_INCLUDE_IGNORED='.state/**:.cache/**' wt-snapshot
```

Family preset example, if your lane keeps disposable state under `.omc/`:

```sh
CK_WTSNAP_INCLUDE_IGNORED='.omc/**' wt-snapshot
```

### Restore

Restore a snapshot into a fresh target directory:

```sh
wt-snapshot restore refs/worktree-snapshots/feature-x/20260818T120102Z /tmp/feature-x-restore
```

`restore` refuses a non-empty target. The target must be a fresh directory so the round-trip stays exact.

### Prune

List expired snapshot refs without deleting anything:

```sh
wt-snapshot prune
```

`prune` compares snapshot age against `CK_WTSNAP_TTL_DAYS` (default `30`) and prints candidates for a human to inspect or delete manually later.

## Capture contract

`wt-snapshot` is designed to avoid false safety:

- Dirty tracked files are captured.
- Untracked files are captured.
- Ignored paths are captured only when they match `CK_WTSNAP_INCLUDE_IGNORED`.
- A clean worktree is still a no-op unless the worktree `HEAD` is already reachable from a ref in the main repository.

If the worktree is clean and its `HEAD` is already reachable from the main repository, `wt-snapshot` prints an explicit no-op message, exits `0`, and writes nothing.

## Git hygiene

Snapshot creation uses a temporary index via `GIT_INDEX_FILE`. The real index, `HEAD`, and working tree of both the worktree and the main repository stay untouched.

Every git invocation uses explicit identity env vars:

- `GIT_AUTHOR_NAME`
- `GIT_AUTHOR_EMAIL`
- `GIT_COMMITTER_NAME`
- `GIT_COMMITTER_EMAIL`

The tool must not depend on user git config. Instead it uses env and inert config settings such as `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_SYSTEM=/dev/null`.

Set `CK_WTSNAP_IDENT` when you want a custom identity. If unset, the tool falls back to its built-in identity.

## Secret scan

Set `CK_WTSNAP_SECRET_SCAN_CMD` to stream each candidate file through a scanner before the snapshot is written.

```sh
CK_WTSNAP_SECRET_SCAN_CMD='my-scan-wrapper' wt-snapshot
```

Behavior:

- unset: no pre-snapshot scan runs
- zero exit: snapshot may continue
- nonzero exit: snapshot aborts fail-closed, no ref is written, and the scanner's exit status is returned

The intended shape is a wrapper command with a dedicated nonzero exit code for a hit, so callers can distinguish scan failures from git failures.

## Restore contract

`restore` rebuilds the captured content into a fresh directory:

- base tree from the snapshot parent commit
- tracked modifications
- untracked additions
- the configured ignored subset that was captured at snapshot time

The goal is byte-for-byte round-trip recovery of the captured lane state.

## Verify

Run the worktree snapshot suite from the repository root:

```sh
bash tests/test_wt_snapshot.sh
```
