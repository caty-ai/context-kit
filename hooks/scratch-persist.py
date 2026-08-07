#!/usr/bin/env python3
"""Persist large Claude Code PostToolUse responses without blocking hooks."""

from __future__ import annotations

import datetime
import json
import os
import re
import sys
import tempfile
from typing import Any, List, Optional, Tuple


DEFAULT_THRESHOLD = 5000
TTL_DAYS = 7
MAX_TOOL_SLUG_LEN = 32
MAX_UNIQUE_PROBES = 1024


def extract_output(resp: Any) -> str:
    """Extract output from the response shapes used by Claude Code tools."""
    if resp is None:
        return ""
    if isinstance(resp, str):
        return resp
    if isinstance(resp, dict):
        parts: List[str] = []
        for key in ("stdout", "stderr", "output", "content", "result"):
            val = resp.get(key)
            if isinstance(val, str):
                parts.append(val)
            elif isinstance(val, list):
                for item in val:
                    if isinstance(item, str):
                        parts.append(item)
                    elif isinstance(item, dict):
                        text = item.get("text") or item.get("content") or ""
                        if isinstance(text, str):
                            parts.append(text)
        return "\n".join(part for part in parts if part)
    return str(resp)


def threshold_from_env() -> int:
    try:
        return int(os.environ.get("CK_SCRATCH_THRESHOLD", str(DEFAULT_THRESHOLD)))
    except (TypeError, ValueError, OverflowError):
        return DEFAULT_THRESHOLD


def default_scratch_dir() -> str:
    home = os.environ.get("HOME")
    if home:
        agent = os.environ.get("CK_AGENT") or "agent"
        return os.path.join(home, ".claude", "scratch", agent, "memory")
    return os.path.join(os.environ.get("TMPDIR") or "/tmp", "context-kit-scratch")


def resolve_scratch_dir() -> Tuple[str, bool]:
    configured = os.environ.get("CK_SCRATCH_DIR")
    if configured:
        launched_as_default = os.environ.get("CK_SCRATCH_DIR_IS_DEFAULT") == "1"
        return os.path.abspath(configured), launched_as_default
    return os.path.abspath(default_scratch_dir()), True


def slugify_tool(tool: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", tool.lower()).strip("-")
    return (slug[:MAX_TOOL_SLUG_LEN] or "tool").rstrip("-") or "tool"


def reserve_scratch_file(
    scratch_dir: str, ts: str, safe_tool: str
) -> Tuple[Optional[str], Optional[int]]:
    pid = os.getpid()
    base = "scratch-{}-{}".format(ts, safe_tool)
    for attempt in range(MAX_UNIQUE_PROBES):
        suffix = "" if attempt == 0 else "-{}-{}".format(pid, attempt)
        scratch_file = os.path.join(scratch_dir, "{}{}.md".format(base, suffix))
        try:
            fd = os.open(scratch_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            return scratch_file, fd
        except FileExistsError:
            continue
        except OSError:
            return None, None
    return None, None


def render_scratch(
    tool: str,
    tool_input: Any,
    output: str,
    created: str,
    expires: str,
) -> str:
    try:
        rendered_input = json.dumps(tool_input, ensure_ascii=False, indent=2)
    except Exception:
        rendered_input = str(tool_input)

    return "".join(
        (
            "---\n",
            "type: scratch\n",
            "mode: reactive-persist\n",
            "tool: {}\n".format(tool),
            "createdAt: {}\n".format(created),
            "expiresAt: {}\n".format(expires),
            "sizeBytes: {}\n".format(len(output.encode("utf-8"))),
            "---\n\n",
            "## Tool Input\n\n",
            "```json\n",
            rendered_input,
            "\n```\n\n",
            "## Tool Output\n\n",
            output,
        )
    )


def write_atomically(scratch_file: str, reserved_fd: int, content: str) -> bool:
    scratch_dir = os.path.dirname(scratch_file)
    temp_path = ""
    try:
        os.close(reserved_fd)
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=scratch_dir,
            prefix=".scratch-persist-",
            delete=False,
        ) as handle:
            temp_path = handle.name
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, scratch_file)
    except Exception:
        try:
            os.close(reserved_fd)
        except OSError:
            pass
        if temp_path:
            try:
                os.unlink(temp_path)
            except OSError:
                pass
        try:
            os.unlink(scratch_file)
        except OSError:
            pass
        return False
    return True


def run() -> int:
    if os.environ.get("CK_SCRATCH_DISABLED") == "1":
        return 0

    raw = sys.stdin.read()
    if not raw.strip():
        return 0

    data = json.loads(raw)
    if not isinstance(data, dict):
        return 0
    if "tool_name" not in data or "tool_response" not in data:
        return 0

    tool = data.get("tool_name")
    if not isinstance(tool, str) or not tool:
        return 0
    tool_input = data.get("tool_input") or {}
    output = extract_output(data.get("tool_response"))
    if len(output) < threshold_from_env():
        return 0

    scratch_dir, is_default = resolve_scratch_dir()
    os.makedirs(scratch_dir, exist_ok=True)
    if is_default:
        os.chmod(scratch_dir, 0o700)

    now = datetime.datetime.now()
    ts = now.strftime("%Y-%m-%dT%H-%M-%S")
    created = now.replace(microsecond=0).isoformat()
    expires = (now + datetime.timedelta(days=TTL_DAYS)).replace(
        microsecond=0
    ).isoformat()
    safe_tool = slugify_tool(tool)
    scratch_file, reserved_fd = reserve_scratch_file(scratch_dir, ts, safe_tool)
    if not scratch_file or reserved_fd is None:
        return 0

    content = render_scratch(tool, tool_input, output, created, expires)
    if not write_atomically(scratch_file, reserved_fd, content):
        return 0

    notice = (
        "[scratch-persist] Saved {} characters of {} output to scratch: {} -- "
        "use Read/Grep on this file instead of re-running the tool when the same "
        "information is needed (TTL 7 days)."
    ).format(len(output), tool, scratch_file)
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "additionalContext": notice,
                }
            },
            ensure_ascii=True,
        )
    )
    return 0


def main() -> int:
    try:
        return run()
    except BaseException:
        return 0


if __name__ == "__main__":
    sys.exit(main())
