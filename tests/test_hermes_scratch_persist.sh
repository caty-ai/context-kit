#!/usr/bin/env bash
# Portable offline regression suite; no Hermes install or credentials required.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "${ROOT}/tests/test_hermes_scratch_persist.py"
