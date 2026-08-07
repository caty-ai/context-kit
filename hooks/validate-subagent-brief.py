#!/usr/bin/env python3
"""Require a three-layer brief for substantial Agent/Task delegations."""

from __future__ import annotations

import json
import os
import sys
from typing import List, Set


DEFAULT_REQUIRED_SECTIONS = [
    "## 実装仕様",
    "## 実装チェック",
    "## レビュー基準",
]
DEFAULT_SKIP_SUBAGENT_TYPES = {
    "Explore",
    "explore",
    "general-purpose",
    "claude-code-guide",
    "statusline-setup",
    "writer",
}
DEFAULT_MIN_PROMPT_CHARS = 500
SUPPORTED_TOOLS = {"Agent", "Task"}


def required_sections_from_env() -> List[str]:
    raw = os.environ.get("CK_BRIEF_REQUIRED_SECTIONS")
    if not raw:
        return list(DEFAULT_REQUIRED_SECTIONS)

    sections = [section.strip() for section in raw.split("|")]
    if any(not section for section in sections):
        return list(DEFAULT_REQUIRED_SECTIONS)
    return sections


def skip_subagent_types_from_env() -> Set[str]:
    raw = os.environ.get("CK_BRIEF_SKIP_SUBAGENT_TYPES")
    if raw is None:
        return set(DEFAULT_SKIP_SUBAGENT_TYPES)
    return {entry.strip() for entry in raw.split(",") if entry.strip()}


def min_prompt_chars_from_env() -> int:
    try:
        return int(
            os.environ.get(
                "CK_BRIEF_MIN_PROMPT_CHARS", str(DEFAULT_MIN_PROMPT_CHARS)
            )
        )
    except (TypeError, ValueError, OverflowError):
        return DEFAULT_MIN_PROMPT_CHARS


def render_skeleton(sections: List[str]) -> str:
    canonical_guidance = [
        "- State the deliverable, constraints, and relevant context.",
        "- List concrete self-verification steps and completion checks.",
        "- Define observable reviewer criteria and acceptance conditions.",
    ]
    use_canonical_guidance = sections == DEFAULT_REQUIRED_SECTIONS
    blocks = []
    for index, section in enumerate(sections):
        if use_canonical_guidance and index < len(canonical_guidance):
            detail = canonical_guidance[index]
        else:
            detail = "- State what this section requires."
        blocks.append("{}\n{}".format(section, detail))
    return "\n\n".join(blocks)


def sanitize_subagent_type(subagent_type: str) -> str:
    return subagent_type.replace("\r", " ").replace("\n", " ")[:100]


def block_message(
    tool_name: str,
    subagent_type: str,
    missing: List[str],
    sections: List[str],
    skip_subagent_types: Set[str],
) -> str:
    effective_skips = ", ".join(sorted(skip_subagent_types))
    return (
        "[validate-subagent-brief] Blocked {} delegation for subagent type '{}'.\n\n"
        "A substantial delegation prompt must include the active three-layer brief.\n"
        "Missing sections: {}\n\n"
        "Minimal skeleton:\n\n"
        "{}\n\n"
        "Canonical rulebook:\n"
        "- https://github.com/caty-ai/family-dev-handbook/blob/main/docs/07-delegation-brief.md\n"
        "- https://github.com/caty-ai/family-dev-handbook/blob/main/templates/brief-template.md\n\n"
        "For lightweight research, use a subagent type listed in "
        "CK_BRIEF_SKIP_SUBAGENT_TYPES (effective: {}).\n"
        "To bypass temporarily, set CK_SKIP_BRIEF_VALIDATION=1 in the environment "
        "that launches Claude Code, then restart it."
    ).format(
        tool_name,
        sanitize_subagent_type(subagent_type),
        ", ".join(missing),
        render_skeleton(sections),
        effective_skips,
    )


def run() -> int:
    if os.environ.get("CK_SKIP_BRIEF_VALIDATION") == "1":
        return 0

    raw = sys.stdin.read()
    if not raw.strip():
        return 0

    data = json.loads(raw)
    if not isinstance(data, dict):
        return 0

    tool_name = data.get("tool_name")
    if tool_name not in SUPPORTED_TOOLS:
        return 0

    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        return 0

    subagent_type = tool_input.get("subagent_type")
    prompt = tool_input.get("prompt")
    if not isinstance(subagent_type, str) or not subagent_type:
        return 0
    if not isinstance(prompt, str):
        return 0

    skip_subagent_types = skip_subagent_types_from_env()
    if subagent_type in skip_subagent_types:
        return 0
    if len(prompt) < min_prompt_chars_from_env():
        return 0

    sections = required_sections_from_env()
    missing = [section for section in sections if section not in prompt]
    if not missing:
        return 0

    print(
        block_message(
            tool_name,
            subagent_type,
            missing,
            sections,
            skip_subagent_types,
        ),
        file=sys.stderr,
    )
    return 2


def main() -> int:
    try:
        return run()
    # Hooks fail open even on SystemExit; callers should rely on the return value, not sys.exit.
    except BaseException:
        return 0


if __name__ == "__main__":
    sys.exit(main())
