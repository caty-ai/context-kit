"""Offline regression tests for the narrowly pinned Hermes compatibility patch.

Compile the real fixture's compress method, with explicit persistence, estimator
and superclass doubles. Never import a live Hermes profile or invoke a model.
The real-engine integration run is recorded separately in the compatibility doc.
"""
import ast
import copy
import hashlib
import logging
import os
from pathlib import Path
import subprocess
import tempfile
from typing import Any, Dict, List
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/hermes/scratch-persist-engine.py"
PATCH = ROOT / "patches/hermes/scratch-persist-zero-estimate.patch"
TARGET = "plugins/context_engine/scratch_persist/engine.py"
PREIMAGE_SHA256 = "97ae9c88608aa7f7e862925812702616e8c8f6d8fd082e1d859dcc20ef2d554a"


def patched_source():
    source = FIXTURE.read_bytes()
    if hashlib.sha256(source).hexdigest() != PREIMAGE_SHA256:
        raise AssertionError("unsupported fixture preimage")
    if os.environ.get("CONTEXT_KIT_TEST_UNPATCHED") == "1":
        return source.decode()
    with tempfile.TemporaryDirectory(prefix="context-kit-hermes-test-") as tmp:
        path = Path(tmp) / TARGET
        path.parent.mkdir(parents=True)
        path.write_bytes(source)
        stats = subprocess.run(["git", "apply", "--numstat", str(PATCH)], cwd=tmp,
                               text=True, capture_output=True, check=True)
        targets = [line.split("\t")[-1] for line in stats.stdout.splitlines()]
        if targets != [TARGET]:
            raise AssertionError("patch must change only the supported engine")
        subprocess.run(["git", "apply", "--check", str(PATCH)], cwd=tmp, check=True)
        subprocess.run(["git", "apply", str(PATCH)], cwd=tmp, check=True)
        return path.read_text()


class SuperclassDouble:
    def compress(self, messages, current_tokens=None, focus_topic=None):
        self.summary_calls.append((messages, current_tokens, focus_topic))
        return messages + [{"role": "assistant", "content": "OFFLINE SUMMARY DOUBLE"}]


class PersistorDouble:
    def __init__(self, replacement=None):
        self.replacement = replacement

    def process_messages(self, messages, protect_last_n):
        if self.replacement is None:
            return messages, 0
        return self.replacement, 1


class ScratchEstimateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = patched_source()
        cls.source = source

    def engine(self, *, estimate=150, cached=1, replacement=None):
        self.estimated_messages = []

        def estimate_messages_tokens_rough(messages):
            self.estimated_messages.append(messages)
            return estimate

        tree = ast.parse(self.source)
        cls = next(n for n in tree.body if isinstance(n, ast.ClassDef)
                   and n.name == "ScratchPersistEngine")
        cls.body = [copy.deepcopy(next(n for n in cls.body
                    if isinstance(n, ast.FunctionDef) and n.name == "compress"))]
        namespace = dict(ContextCompressor=SuperclassDouble, List=List, Dict=Dict,
                         Any=Any, logger=logging.getLogger("offline-test"),
                         estimate_messages_tokens_rough=estimate_messages_tokens_rough)
        module = ast.fix_missing_locations(ast.Module(body=[cls], type_ignores=[]))
        exec(compile(module, str(FIXTURE), "exec"), namespace)
        engine = namespace["ScratchPersistEngine"]()
        engine._persistor = PersistorDouble(replacement)
        engine.last_prompt_tokens = cached
        engine.threshold_tokens = 100
        engine.protect_last_n = 2
        engine.quiet_mode = True
        engine.summary_calls = []
        return engine

    def test_zero_reestimates_large_adopted_transcript_with_stale_low_usage(self):
        engine = self.engine(estimate=150, cached=1)
        messages = [{"role": "user", "content": "adopted fixture"}]
        engine.compress(messages, current_tokens=0, focus_topic="keep decisions")
        self.assertEqual(len(engine.summary_calls), 1)
        self.assertEqual(engine.summary_calls[0], (messages, 150, "keep decisions"))
        self.assertEqual(self.estimated_messages, [messages])

    def test_zero_reestimates_at_threshold(self):
        engine = self.engine(estimate=100)
        engine.compress([{"role": "user", "content": "fixture"}], current_tokens=0)
        self.assertEqual(len(engine.summary_calls), 1)
        self.assertEqual(engine.summary_calls[0][1], 100)

    def test_zero_small_transcript_does_not_use_stale_high_usage(self):
        engine = self.engine(estimate=12, cached=999)
        messages = [{"role": "user", "content": "small"}]
        self.assertEqual(engine.compress(messages, current_tokens=0), messages)
        self.assertEqual(self.estimated_messages, [messages])
        self.assertEqual(engine.summary_calls, [])

    def test_zero_estimates_post_offload_snapshot(self):
        replacement = [{"role": "tool", "content": "[scratch] fixture"}]
        engine = self.engine(estimate=12, cached=999, replacement=replacement)
        original = [{"role": "tool", "content": "large fixture"}]
        self.assertEqual(engine.compress(original, current_tokens=0), replacement)
        self.assertEqual(len(self.estimated_messages), 1)
        self.assertIs(self.estimated_messages[0], replacement)
        self.assertEqual(engine.summary_calls, [])

    def test_empty_zero_estimate_stays_noop(self):
        engine = self.engine(estimate=0, cached=999)
        self.assertEqual(engine.compress([], current_tokens=0), [])
        self.assertEqual(engine.summary_calls, [])
        self.assertEqual(self.estimated_messages, [[]])

    def test_positive_usage_is_not_reestimated(self):
        for tokens, calls in [(12, 0), (100, 1), (150, 1)]:
            with self.subTest(tokens=tokens):
                engine = self.engine(estimate=999, cached=999)
                engine.compress([{"role": "user", "content": "fixture"}], current_tokens=tokens)
                self.assertEqual(len(engine.summary_calls), calls)
                self.assertEqual(self.estimated_messages, [])
                if calls:
                    self.assertEqual(engine.summary_calls[0][1], tokens)

    def test_unknown_usage_preserves_cached_behavior(self):
        for cached, calls in [(None, 0), (12, 0), (150, 1)]:
            with self.subTest(cached=cached):
                engine = self.engine(cached=cached)
                engine.compress([{"role": "user", "content": "fixture"}], current_tokens=None)
                self.assertEqual(len(engine.summary_calls), calls)
                self.assertEqual(self.estimated_messages, [])
                if calls:
                    self.assertIsNone(engine.summary_calls[0][1])

    def test_patched_import_is_explicit(self):
        if os.environ.get("CONTEXT_KIT_TEST_UNPATCHED") == "1":
            self.skipTest("pre-fix behavior run; production patch not authored yet")
        tree = ast.parse(self.source)
        imported = [alias.name for node in tree.body if isinstance(node, ast.ImportFrom)
                    and node.module == "agent.model_metadata" for alias in node.names]
        self.assertIn("estimate_messages_tokens_rough", imported)


if __name__ == "__main__":
    unittest.main(verbosity=2)
