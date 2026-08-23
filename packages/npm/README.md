# @caty-ai/context-kit

Context Kit is a small set of command-line tools and Claude Code hooks for keeping agent output manageable, preserving useful context, validating delegation briefs, and guarding risky operations. See the [project repository](https://github.com/caty-ai/context-kit) for the full guide.

## Install

Run the guided installer with `npx`. It previews every file and settings change before writing anything:

```sh
npx @caty-ai/context-kit install
```

To expose `context-kit`, `lg`, `recall`, and `wt-snapshot` on your `PATH`, install the package globally:

```sh
npm i -g @caty-ai/context-kit
context-kit install
```

The package supports macOS and Linux with Node.js 18 or newer.

## Installer usage

Dry-run is the default. Review the file plan and unified settings diff, then repeat the printed command with `--apply`:

```sh
context-kit install --all
context-kit install --all --apply
```

Install only selected pieces by naming them:

```sh
context-kit install lg recall --apply
context-kit install scratch-persist brief-validator safety-hooks --apply
```

Available pieces are `lg`, `scratch-persist`, `brief-validator`, `safety-hooks`, `recall`, and `wt-snapshot`. Use `context-kit --help` for test-oriented `--settings` and `--prefix` overrides.

## Uninstall

There is no uninstall command in this release. To remove the kit manually:

1. Remove `~/.claude/context-kit`.
2. Remove only the hook entries whose commands point into that directory from `~/.claude/settings.json`, or restore the installer backup after confirming it does not discard later settings changes.
3. Remove any shell configuration that added `~/.claude/context-kit/bin` to `PATH`.

For piece-specific behavior and verification, read the absolute project docs for [lg](https://github.com/caty-ai/context-kit/blob/main/docs/lg.md), [scratch-persist](https://github.com/caty-ai/context-kit/blob/main/docs/scratch-persist.md), [brief-validator](https://github.com/caty-ai/context-kit/blob/main/docs/brief-validator.md), [safety hooks](https://github.com/caty-ai/context-kit/blob/main/docs/safety-hooks.md), [recall](https://github.com/caty-ai/context-kit/blob/main/docs/recall.md), and [wt-snapshot](https://github.com/caty-ai/context-kit/blob/main/docs/wt-snapshot.md).
