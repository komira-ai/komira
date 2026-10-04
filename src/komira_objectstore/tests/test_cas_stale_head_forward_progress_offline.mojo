# =============================================================================
# tests/test_cas_stale_head_forward_progress_offline.mojo
#   Stale-head forward progress — the stale-`_HEAD` livelock guard.
# =============================================================================
#
# REGRESSION for the cross-process CAS livelock: under SUSTAINED contention a
# writer can get wedged behind a stale-LOW `_HEAD` cache. The old
# `_try_advance_head` wrote `_HEAD` UNCONDITIONALLY (last-writer-wins), so an
# OLDER advance could clobber `_HEAD` BACKWARDS to a lower seq after a newer
# advance landed. A retrying writer then re-reads that stale-low `_HEAD`,
# recomputes the SAME already-taken `candidate_seq = head.chunk_seq + 1`, gets a
# PERMANENT 412 (the slot is taken), exhausts the budget, the client retries,
# re-reads the SAME stale `_HEAD` — a LIVELOCK with no forward progress.
#
# THE FIX (cas_manifest.mojo):
#   (1) `_try_advance_head` is MONOTONIC — it reads the current `_HEAD` + etag
#       and never writes a seq <= the current; advances via If-Match. So the
#       cache can ONLY move forward.
#   (2) After N (=3) consecutive 412s, `_append_inner` re-reads HEAD with
#       `force_authoritative=True`, which BYPASSES the cache and LISTs the
#       bucket's true tail (`_recover_head_by_list`). The wedged writer then
#       computes a fresh `candidate_seq` BEYOND all taken slots and makes
#       forward progress.
#
# This test DETERMINISTICALLY reproduces the wedge offline (no MinIO, no
# concurrency): it commits K chunks normally, then OVERWRITES `_HEAD` with a
# stale-LOW value (modeling the backwards-clobber a concurrent stale writer
# could land), then appends. WITHOUT the LIST-escalation the append would
# permanently 412 (every retry recomputes the same already-taken candidate from
# the stale `_HEAD`) and raise the retry-exhausted error. WITH the escalation it
# makes progress: the append wins slot K, the offset log stays gapless/no-dup,
# and `_HEAD` is now monotone-advanced to the true tail.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    ManifestHead,
    RetryPolicy,
    chunk_key,
    decode_chunk_record_count,
    encode_head,
    head_key,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


def _body(tag: Int, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i + tag) & 0xFF))
    return out^


# -----------------------------------------------------------------------------
# TEST 1 — stale-LOW `_HEAD` does NOT wedge the append (LIST escalation kicks
# in and the writer makes forward progress).
# -----------------------------------------------------------------------------
def _test_stale_head_escalation() raises:
    print(
        "[stale-head] TEST 1 — append survives a stale-LOW _HEAD via"
        " LIST escalation"
    )
    var store = SharedInMemoryConditionalStore()
    var prefix = String("stale/p0")
    var rpa = Int64(1)  # 1 record per append → base offset == chunk_seq

    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store=store.clone(),
        prefix=prefix.copy(),
        retry=RetryPolicy.fast_test(),
    )

    # Commit K chunks normally. After this, chunks 0..K-1 exist and the true
    # tail is (chunk_seq=K-1, next_offset=K).
    var K = 6
    for i in range(K):
        var r = manifest.append(_body(i, 16), rpa)
        assert_equal(r.chunk_seq, Int64(i), "chunk i committed at slot i")
        assert_equal(r.base_offset, Int64(i), "base offset == slot (rpa=1)")

    # CLOBBER `_HEAD` BACKWARDS to a stale-LOW value: seq=0, next_offset=1. This
    # models the exact failure the old unconditional `_try_advance_head`
    # allowed — a stale advance regressing `_HEAD` below the true tail. A
    # retrying writer reading this stale cache recomputes candidate_seq = 0+1 =
    # 1, which is ALREADY TAKEN → permanent 412 without the LIST escalation.
    var stale = ManifestHead(Int64(0), Int64(1), String(""))
    _ = store.put(head_key(prefix), encode_head(stale))

    # Now append. WITHOUT the escalation this raises "exhausted ... retries
    # (retryable)" (every retry recomputes candidate_seq=1 from the stale
    # cache). WITH it, the append LIST-escalates to the true tail and wins
    # slot K with base offset K — forward progress.
    var res = manifest.append(_body(99, 16), rpa)
    assert_equal(
        res.chunk_seq,
        Int64(K),
        "append won the next FREE slot K (beyond all taken slots) — forward"
        " progress despite stale-low _HEAD",
    )
    assert_equal(
        res.base_offset,
        Int64(K),
        "base offset is the true running sum (gapless, no renumber)",
    )

    # The offset log invariant MUST hold: chunks 0..K each present, each with
    # record_count rpa, cumulative base offsets contiguous {0..K}.
    var running = Int64(0)
    for i in range(K + 1):
        var c = store.get(chunk_key(prefix, Int64(i)))
        var rc = decode_chunk_record_count(c)
        assert_equal(rc, rpa, "chunk i has the expected record_count")
        running += rc
    assert_equal(
        running,
        Int64(K + 1) * rpa,
        "cumulative record_count == (K+1)*rpa — no gap, no dup, no loss",
    )

    # And `_HEAD` is now monotone-advanced to the true tail (seq=K).
    var head_now = manifest.read_head()
    assert_equal(
        head_now.chunk_seq,
        Int64(K),
        "_HEAD monotone-advanced to the new true tail (seq=K)",
    )
    assert_equal(
        head_now.next_offset,
        Int64(K + 1),
        "_HEAD.next_offset == true running sum after the winning append",
    )
    _ = manifest^
    _ = store^
    print("      OK — wedged writer made forward progress (no livelock)")


# -----------------------------------------------------------------------------
# TEST 2 — `_try_advance_head` is MONOTONE: a later append never regresses
# `_HEAD` below an already-advanced tail (exercised via normal sequential
# appends, then a verification that `_HEAD` only ever increased).
# -----------------------------------------------------------------------------
def _test_head_is_monotone() raises:
    print("[stale-head] TEST 2 — _HEAD advance is monotone (forward-only)")
    var store = SharedInMemoryConditionalStore()
    var prefix = String("mono/p0")
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store=store.clone(),
        prefix=prefix.copy(),
        retry=RetryPolicy.fast_test(),
    )

    var last_seq = Int64(-1)
    for i in range(8):
        _ = manifest.append(_body(i, 8), Int64(1))
        var h = manifest.read_head()
        assert_true(
            h.chunk_seq >= last_seq,
            "_HEAD.chunk_seq never decreases across appends (monotone)",
        )
        last_seq = h.chunk_seq

    # Manually clobber `_HEAD` stale-low, then advance once more via append:
    # the monotone guard + LIST escalation must leave `_HEAD` at the NEW true
    # tail (8), never back at the stale value.
    var stale = ManifestHead(Int64(2), Int64(3), String(""))
    _ = store.put(head_key(prefix), encode_head(stale))
    _ = manifest.append(_body(50, 8), Int64(1))
    var head_after = manifest.read_head()
    assert_equal(
        head_after.chunk_seq,
        Int64(8),
        "after a stale-low clobber + one append, _HEAD is at the true tail"
        " (8), proving forward-only recovery",
    )
    _ = manifest^
    _ = store^
    print("      OK — _HEAD is monotone (never regressed below true tail)")


def main() raises:
    print(
        "[stale-head forward progress] stale-_HEAD livelock"
        " regression (offline, deterministic)"
    )
    _test_stale_head_escalation()
    _test_head_is_monotone()
    print(
        "[OK] test_cas_stale_head_forward_progress_offline — monotone _HEAD"
        " + LIST escalation give a wedged writer forward progress; offset"
        " log stays gapless/no-dup/no-loss"
    )
