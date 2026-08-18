# wt-snapshot

## What/Why

`wt-snapshot` makes worktree deletion reversible.

Run it before a human removes a Git worktree. The command captures a full copy of the parent worktree state (excluding repository metadata) plus any staged-index delta needed to rebuild that lane later:

- tracked modifications relative to the worktree `HEAD`
- staged changes, even when the worktree file itself matches `HEAD`
- untracked files, including nested paths
- empty untracked directories
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

When the snapshot contains staged changes, restore also initializes a Git repository in the target at the saved `HEAD` and reapplies the saved binary patch to its index. The files on disk remain the captured worktree bytes, while commands such as `git diff --cached` and `git show :path` expose the separately saved staged state.

### Prune

List expired snapshot refs without deleting anything:

```sh
wt-snapshot prune
```

`prune` compares snapshot age against `CK_WTSNAP_TTL_DAYS` (default `30`) and prints candidates for a human to inspect or delete manually later.

## Capture contract

`wt-snapshot` is designed to avoid false safety:

- Dirty tracked files are captured.
- The index is compared with `HEAD`; staged-only divergence is captured separately.
- Assume-unchanged and skip-worktree paths are compared directly with `HEAD` instead of trusting porcelain output.
- Untracked files are captured.
- Empty untracked directories are captured.
- Ignored paths are captured only when they match `CK_WTSNAP_INCLUDE_IGNORED`.
- A clean worktree is still a no-op unless the worktree `HEAD` is already reachable from a ref in the main repository.

If the worktree, index, flagged tracked paths, untracked set, and configured ignored set are all clean, and its `HEAD` is already reachable from the main repository, `wt-snapshot` prints an explicit no-op message, exits `0`, and writes nothing.

### Submodules

Version 1 does not recursively snapshot submodule working trees. Clean populated submodules are omitted from the payload, including their `.git` gitfiles. If a populated submodule is checked out at a commit other than its parent gitlink or has staged, modified, untracked, ignored, or hidden flag-masked content (including recursively inspected nested submodules), capture stops with exit `75` and `submodule dirt present — not captured, do not delete`. This refusal is deliberate: the tool never turns uncaptured submodule work into a successful deletion blessing.

Untracked nested repositories are different: their working files are captured explicitly, but every nested `.git` file or directory is excluded.

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

The tool freezes one explicit, non-recursive archive path list and uses that same list for both scanning and packing. Directory roots are expanded first, so files inside an untracked nested repository cannot enter the tar payload without being scanned. Changed index blobs are streamed to the scanner in their raw form (including binary content), and the staged-index patch is also scanned, before any snapshot object is written.

The intended shape is a wrapper command with a dedicated nonzero exit code for a hit, so callers can distinguish scan failures from git failures.

## Restore contract

`restore` extracts the full-copy payload into a fresh staging directory, then materializes it into the empty target. File bytes, symlinks, permission bits, and captured empty directories are preserved. It does not reconstruct a base tree and then apply a worktree delta: the payload itself is the complete captured worktree copy. A saved staged-index patch is applied only to the target's Git index as described above.

Snapshots are trusted local artifacts. Restore rejects absolute archive member names and `..` path components before extraction, extracts with `--no-same-owner`, and stages extraction away from the target. A hand-made hostile ref can still exercise the behavior of the platform `tar` implementation for archive features such as links; do not restore refs from an untrusted repository.

## Verify

Run the worktree snapshot suite from the repository root:

```sh
bash tests/test_wt_snapshot.sh
```
