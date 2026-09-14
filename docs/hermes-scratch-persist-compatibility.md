# Hermes scratch-persist zero-estimate compatibility patch

This is a narrow compatibility patch for an **existing legacy Hermes extension**, not an installer and not a change to context-kit's Claude Code PostToolUse hook. Do not apply it to an arbitrary similarly named plugin.

## Symptom and contract

When Hermes adopts a newer durable transcript before compression, its core can pass `current_tokens=0` to request a fresh estimate. The supported legacy extension instead compares that literal zero to its summary threshold, returning the unchanged transcript when its scratch pre-pass has nothing new to offload. The core may then report `no_progress` without calling a summarizer.

The patch recalculates the zero-sentinel count from the **current post-offload messages** using Hermes's existing `estimate_messages_tokens_rough` helper. The fresh value is used for both threshold selection and the superclass call. It does not substitute potentially stale `last_prompt_tokens`.

- Positive supplied counts keep their existing behavior.
- `None` keeps the existing unknown-usage/preflight behavior.
- Small or empty snapshots remain no-ops.
- If scratch offloading alone brings the current snapshot below threshold, no LLM summary is forced.
- No authentication, model selection, retention policy, database writer or session-rotation logic is changed.

## Supported preimage

- Target: `plugins/context_engine/scratch_persist/engine.py` in an existing Hermes installation.
- Exact SHA-256: `97ae9c88608aa7f7e862925812702616e8c8f6d8fd082e1d859dcc20ef2d554a`.
- Regression fixture: `tests/fixtures/hermes/scratch-persist-engine.py`, preserved byte-for-byte from that legacy source. It is a test fixture, not an alternative installation source.
- Core compatibility checked against Hermes v0.21.1, commit `2237be355906fbe6065ce1815711eee52b2d646e`. The caller contract also exists in v0.21.0. Future versions require revalidation; a clean textual patch application alone is not a compatibility guarantee.
- Patch: `patches/hermes/scratch-persist-zero-estimate.patch`.

## Verification

```sh
# Portable offline fixture/patch tests (Python 3 and git; no API credentials):
bash tests/test_hermes_scratch_persist.sh

# Show the original defect before applying the patch to the test fixture:
CONTEXT_KIT_TEST_UNPATCHED=1 bash tests/test_hermes_scratch_persist.sh
```

The second command is deliberately expected to fail. The normal suite checks patch target and preimage, applies it only in a temporary directory, then executes the actual `compress` method with explicit persistor/estimator/superclass doubles. It does not call an LLM or represent an end-to-end live compression test.

The implementation lane additionally ran the actual Hermes class, actual token estimator and actual scratch persistor in an isolated pytest process, using temporary scratch storage and a mocked LLM-summary superclass call. The original failed the large adopted-transcript assertion; the candidate passed that regression and the existing scratch-engine tests. Those results establish local compatibility, not live activation in another installation.

## Guarded application and rollback

1. Obtain the installation owner's approval and determine every consumer of the shared extension. Keep unrelated dirty files untouched.
2. Check the exact preimage digest above and the core version. If either differs, stop for review; do not force or fuzzy-apply the patch.
3. Back up the original target with restrictive permissions and record its digest. Do not rely on git rollback: this legacy plugin may be untracked.
4. In the Hermes repository root, run `git apply --check /absolute/path/to/scratch-persist-zero-estimate.patch`. Inspect the patch: it must change only the declared engine file.
5. Apply the reviewed patch, compare the resulting target to the tested candidate, and run relevant engine tests without live conversations or model calls.
6. Activate only the explicitly approved consumers. A shared file change does not authorize restarting every gateway. If an agent runtime blocks self-restart, use an authorized external operator instead of trying to evade that boundary.
7. Verify the loaded engine and a harmless compression canary, then confirm normal conversation and durable session health. A passing fixture test or successful process start alone is not activation evidence.
8. If activation fails, restore the backed-up target and restart only the affected approved consumer. Preserve diagnostic evidence; do not delete history as a workaround.

Each future core update should re-run both scratch offloading and summary-dispatch compatibility checks. Successful scratch-file creation by itself cannot prove that the summarizer branch still works.
