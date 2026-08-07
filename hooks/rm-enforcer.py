#!/usr/bin/env python3
"""Block destructive Bash commands before they run."""

from __future__ import annotations

import json
import os
import re
import sys
from typing import Optional, Tuple


DISABLED = os.environ.get("CK_DESTRUCTIVE_OK", "0") == "1"

# (regex, human-readable description). First match wins.
RISKY_PATTERNS: list[tuple[str, str]] = [
    (r"\brm\s+-rf\s+/(?!\S)",
     "rm -rf / would delete the root filesystem"),
    (r"\brm\s+-rf\s+/\s",
     "rm -rf / would delete the root filesystem"),
    (r"\brm\s+(-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*|-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*)\s+/(?!\S|\w)",
     "rm with recursive and force flags would delete the root filesystem"),
    (r"\brm\s+-rf\s+~(?:\s|$)",
     "rm -rf ~ would delete the home directory"),
    (r"\brm\s+-rf\s+\$HOME(?:\s|$)",
     "rm -rf $HOME would delete the home directory"),
    (r"\bterraform\s+destroy\b",
     "terraform destroy would destroy managed infrastructure"),
    (r"(?i)\bdrop\s+(database|table|schema)\b",
     "DROP DATABASE/TABLE/SCHEMA would permanently delete data"),
    (r"\bgit\s+push\s+--force(?:-with-lease)?\s+(?:origin\s+)?(main|master)\b",
     "git push --force to main/master could destroy repository history"),
    (r"\bdd\s+(?:[^\s]+\s+)*if=.*\s+of=/dev/",
     "dd output to /dev/ would overwrite a device"),
    (r">\s*~/\.(zshrc|bashrc|zshenv|zprofile|bash_profile)\s*$",
     "overwriting a shell startup file could break the shell environment"),
]


def find_risk(cmd: str) -> Optional[Tuple[str, str]]:
    for pattern, hint in RISKY_PATTERNS:
        if re.search(pattern, cmd):
            return pattern, hint
    return None


def main() -> int:
    try:
        if DISABLED:
            return 0

        data = json.load(sys.stdin)
        if not isinstance(data, dict) or data.get("tool_name") != "Bash":
            return 0

        tool_input = data.get("tool_input") or {}
        if not isinstance(tool_input, dict):
            return 0

        cmd = tool_input.get("command", "")
        if not cmd or not isinstance(cmd, str):
            return 0

        if re.search(r"(?:^|[\s;])CK_DESTRUCTIVE_OK=1\b", cmd):
            return 0

        risk = find_risk(cmd)
        if risk is None:
            return 0

        _, hint = risk
        sys.stderr.write(
            "[rm-enforcer] Blocked a destructive command.\n"
            f"  Reason: {hint}\n"
            f"  Command: {cmd}\n"
            "  If this is intentional, prefix the same Bash command with "
            "CK_DESTRUCTIVE_OK=1.\n"
            "  Example: CK_DESTRUCTIVE_OK=1 rm -rf /tmp/safe-to-delete\n"
        )
        return 2
    except BaseException:
        return 0


if __name__ == "__main__":
    sys.exit(main())
