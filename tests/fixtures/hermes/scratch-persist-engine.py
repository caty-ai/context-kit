"""Scratch-Persist Context Engine for Hermes.

Extends the built-in ContextCompressor with OpenClaw-style scratch
persistence. Large tool results are scratch-persisted on every tool turn
via a run_agent monkeypatch, while threshold-driven summarization remains
available through the normal ContextCompressor flow.

Selection:
  config.yaml -> context.engine: "scratch_persist"
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any, Dict, List

from .persistor import THRESHOLD_CHARS, _extract_text

from agent.context_compressor import ContextCompressor

from .persistor import ScratchPersistor

logger = logging.getLogger(__name__)


def _default_scratch_dir() -> Path:
    """Resolve the scratch directory, tolerant of either HERMES_HOME layout.

    - If HERMES_HOME already points at a profile directory
      (``.../profiles/<name>``), use it directly. This handles the
      case where Hermes has set HERMES_HOME to the profile root.
    - Otherwise, treat HERMES_HOME as the Hermes root (``~/.hermes``)
      and append ``profiles/<HERMES_PROFILE>``.
    """
    hermes_home = os.environ.get("HERMES_HOME") or str(Path.home() / ".hermes")
    root = Path(hermes_home)
    # If HERMES_HOME is already a profile dir, just use it
    if root.parent.name == "profiles":
        return root / "scratch"
    profile = os.environ.get("HERMES_PROFILE", "default")
    return root / "profiles" / profile / "scratch"


class ScratchPersistEngine(ContextCompressor):
    """ContextCompressor + scratch persistence fast path.

    Every tool turn, oversized tool results are scratch-persisted before they
    ever reach the next prompt. When the normal compression threshold is later
    exceeded, ``compress()`` runs a second scratch sweep and only then delegates
    to the built-in summarizer.
    """

    # ContextEngine requires a `name` property that returns a short id.
    @property
    def name(self) -> str:  # type: ignore[override]
        return "scratch-persist"

    def __init__(self, *args, scratch_dir: str | Path | None = None,
                 agent_name: str = "cero", **kwargs):
        super().__init__(*args, **kwargs)
        self._scratch_dir = Path(scratch_dir) if scratch_dir else _default_scratch_dir()
        self._persistor = ScratchPersistor(self._scratch_dir, agent_name=agent_name)
        if not getattr(self, "quiet_mode", False):
            logger.info(
                "scratch-persist engine initialized: scratch_dir=%s threshold_tokens=%d",
                self._scratch_dir, self.threshold_tokens,
            )

    def should_compress_preflight(self, messages: List[Dict[str, Any]]) -> bool:
        """Cheap per-turn trigger for scratch offload candidates.

        We intentionally avoid file I/O here. The check mirrors the message
        selection rules for layer-1 scratch persistence:
        - role == "tool"
        - older than protect_last_n
        - text content longer than 2000 chars
        - not already replaced with a ``[scratch]`` placeholder
        """
        try:
            if not messages:
                return False

            cutoff = max(0, len(messages) - max(0, getattr(self, "protect_last_n", 6)))
            for idx, msg in enumerate(messages):
                if idx >= cutoff:
                    continue
                if not isinstance(msg, dict) or msg.get("role") != "tool":
                    continue

                text, has_image = _extract_text(msg.get("content"))
                if has_image or not text:
                    continue
                if len(text) <= THRESHOLD_CHARS:
                    continue
                if text.lstrip().startswith("[scratch]"):
                    continue
                return True
        except Exception as exc:
            logger.debug("scratch-persist preflight failed: %s", exc)

        return False

    def persist_tool_result_inline(self, content: Any, *, tool_name: str = "tool", tool_call_id: str = "") -> Any:
        """Fast path used from the per-tool monkeypatch in run_agent."""
        try:
            return self._persistor.persist_tool_result(
                content,
                tool_name=tool_name,
                tool_call_id=tool_call_id,
            )
        except Exception as exc:
            logger.warning("scratch-persist inline pass failed for %s: %s", tool_name, exc)
            return content

    # ------------------------------------------------------------------
    def compress(
        self,
        messages: List[Dict[str, Any]],
        current_tokens: int | None = None,
        focus_topic: str | None = None,
    ) -> List[Dict[str, Any]]:
        # Layer 1: sweep older oversized tool results into scratch files.
        try:
            protect_last_n = getattr(self, "protect_last_n", 6)
            new_messages, persisted = self._persistor.process_messages(
                messages, protect_last_n=protect_last_n
            )
        except Exception as e:  # never break the conversation
            logger.warning("scratch-persist pre-pass failed, falling through: %s", e)
            new_messages, persisted = messages, 0

        if persisted and not getattr(self, "quiet_mode", False):
            logger.info(
                "scratch-persist: offloaded %d tool-result(s) to %s",
                persisted,
                self._scratch_dir,
            )

        # Layer 2: only summarize when the normal threshold is actually hit.
        # Preflight-driven calls can still invoke compress(); in that case we only
        # want layer 1 unless the caller also tells us the threshold is exceeded.
        effective_tokens = current_tokens if current_tokens is not None else self.last_prompt_tokens
        if effective_tokens is not None and effective_tokens >= self.threshold_tokens:
            return super().compress(
                new_messages,
                current_tokens=current_tokens,
                focus_topic=focus_topic,
            )

        return new_messages
