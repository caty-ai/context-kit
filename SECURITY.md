# Security Policy

## Supported versions

The `main` branch is the only supported version.

## Reporting a vulnerability

Please report vulnerabilities privately via GitHub's **Report a vulnerability** (Security tab of this repository) rather than a public issue. Include the affected hook or CLI, a reproduction, and the impact you see. You can expect an initial response within a week.

## Scope notes

- The guards in this kit are pattern-based safeguards, not a security boundary. Documented pattern gaps ([docs/safety-hooks.md](docs/safety-hooks.md)) are known limitations, not vulnerabilities — though PRs closing them are welcome.
- A finding that makes a hook block legitimate tool calls on a broken installation (a fail-closed path) is a bug we want to hear about; fail-open behavior is the design contract.
- Scratch notes can contain sensitive data by design; the kit hardens only its own default scratch root (`0700` directory, `0600` files). Weaknesses in that hardening are in scope.
