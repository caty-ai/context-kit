#!/usr/bin/env python3
"""PreToolUse hook that blocks risky large-output Bash commands unless wrapped."""

import json
import os
import re
import sys
from typing import Optional, Tuple

DISABLED = os.environ.get("CK_LG_ENFORCER_DISABLED", "0") == "1"
LG_PATH = os.environ.get("CK_LG_PATH") or "lg"

# Markers that indicate the command already trims its own output.
# If any match, skip enforcement (assume the caller knows what they are doing).
ALREADY_SAFE = [
    r"\blg\b",                          # already wrapped with lg (or /lg)
    r"\|\s*head\b",                     # piped to head
    r"\|\s*tail\b",                     # piped to tail
    r"\|\s*wc\b",                       # piped to wc (count only)
    r"\|\s*sort\s+\|\s*uniq\s+-c\b",    # aggregated
    r"(?:^|[\s|;&])head\s+-",           # leading head -N
    r"(?:^|[\s|;&])tail\s+-",           # leading tail -N
    r">\s*\S",                          # output redirected to file (not history)
]

# (regex, human-readable hint). Order matters — first match wins.
RISKY_PATTERNS = [
    (r"\bgh\s+api\b[^|]*--paginate",
     "gh api --paginate is unbounded"),
    (r"\bfind\s+(?:/|~|\$HOME)\S*(?![^|]*-maxdepth)",
     "find on a broad path without -maxdepth can return huge results"),
    (r"\bjournalctl\b(?![^|]*(?:-n\b|--lines))",
     "journalctl without -n can return the whole journal"),
    (r"\bdmesg\b",
     "dmesg dumps the full kernel buffer"),
    (r"\bcat\s+[^|;&]*\.log\b",
     "cat on a .log file can be huge — use tail -N or lg"),
    (r"\bcat\s+/var/log/",
     "cat on /var/log can be huge — use tail -N or lg"),
    (r"\bgrep\s+-[a-zA-Z]*[rR][a-zA-Z]*\b",
     "grep -r/-R can flood output — pipe to head or wrap with lg"),
]


def is_already_safe(cmd: str) -> bool:
    return any(re.search(pattern, cmd) for pattern in ALREADY_SAFE)


def find_risk(cmd: str) -> Optional[Tuple[str, str]]:
    for pattern, hint in RISKY_PATTERNS:
        if re.search(pattern, cmd):
            return pattern, hint
    return None


def main() -> int:
    try:
        if DISABLED:
            return 0

        try:
            data = json.load(sys.stdin)
        except Exception:
            return 0  # fail open

        if not isinstance(data, dict):
            return 0

        if data.get("tool_name") != "Bash":
            return 0

        tool_input = data.get("tool_input") or {}
        if not isinstance(tool_input, dict):
            return 0

        cmd = tool_input.get("command", "")
        if not cmd or not isinstance(cmd, str):
            return 0

        if is_already_safe(cmd):
            return 0

        risk = find_risk(cmd)
        if risk is None:
            return 0

        _, hint = risk
        sys.stderr.write(
            "[lg-enforcer] Blocked unbounded Bash command.\n"
            f"  Reason : {hint}\n"
            f"  Command: {cmd}\n"
            "  Suggested fix: prefix with the lg wrapper so output is captured to scratch and only head+tail returns to history.\n"
            f"    {LG_PATH} {cmd}\n"
            "  Or pre-trim explicitly: append `| head -N`, `| tail -N`, or use the dedicated head/tail tool.\n"
            "  One-off bypass: set CK_LG_ENFORCER_DISABLED=1 in the same shell line.\n"
        )
        return 2
    except Exception:
        return 0


if __name__ == "__main__":
    sys.exit(main())
