# Contributing to context-kit

Thanks for considering a contribution. This kit is small on purpose; contributions that keep it small are the easiest to accept.

## Ground rules

- **Fail-open is non-negotiable.** Every internal error path in a hook must exit `0` silently. Exit `2` is reserved for a genuine detection. A change that can block tool calls on a broken installation will not be merged.
- **No new dependencies.** Python pieces use the standard library only (3.9+). Node pieces target Node 18+ with no packages.
- **English-only prose in messages.** Corrective messages must read the same in any locale. (The brief validator's default section tokens are deliberately the Japanese headings of the upstream handbook contract; that exception is documented, not a precedent.)
- **`CK_` prefix** for any new environment variable, with an explicit default documented in [docs/reference.md](docs/reference.md).
- **Tests are temp-directory-only** and print one `PASS`/`FAIL` line per case. A behavior change needs a case that fails before and passes after.

## Before you open a PR

1. Run the full suite from the repository root:

```sh
for t in tests/*.sh; do bash "$t"; done
```

2. Update the affected doc under `docs/` — behavior and documentation ship together.
3. Keep one PR to one concern.

## Reporting bugs

Open an issue with the command or hook input that reproduces the problem, what you expected, and what happened. Label suggestions: `bug` plus a `component:*` label. Known pattern gaps in the guards are listed in [docs/safety-hooks.md](docs/safety-hooks.md) — PRs that close them are welcome.

## Security issues

Please do not open a public issue for vulnerabilities — see [SECURITY.md](SECURITY.md).
