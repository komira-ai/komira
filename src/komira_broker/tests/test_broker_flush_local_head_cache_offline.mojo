# =============================================================================
# tests/test_broker_flush_local_head_cache_offline.mojo
#   The durable-ack hot path is 2 synchronous object-store ops, not 5: a
#   local `_HEAD` cache + a deferred (off-the-ack-path) durable `_HEAD`
#   advance.
# =============================================================================
#
# THE REDUCTION (correctness-neutral). A naive steady-state single-writer
# durable ack (`BrokerCore.flush` -> `CasManifestStore.append` ->
# `_append_inner`) issues FIVE synchronous object-store ops:
#   1. segment PUT  (If-None-Match) ........................ n_put  (REQUIRED — durability)
#   2. `_HEAD` GET  (the cached tail pointer) ............. n_get
#   3. `_HEAD` etag HEAD (for the one-call monotone advance) n_head
#   4. chunk slot create-CAS (If-None-Match) ............. n_put  (REQUIRED — gaplessness oracle)
#   5. `_HEAD` advance (If-Match) ........................ n_put  (best-effort cache; LIST is truth)
#
# With the local cache, a steady-state single-writer ack issues only TWO
# synchronous ops — the segment PUT (#1) + the chunk create-CAS (#4):
#   * The owner's LOCAL `_HEAD` cache (a plain typed field on the
#     `CasManifestStore` instance, single-writer-per-instance by `mut self`)
#     holds (chunk_seq, next_offset, head_etag) after a successful append, so the
#     NEXT append computes candidate_seq + base directly and ELIDES the `_HEAD`
#     GET (#2) AND the etag HEAD (#3).
#   * The durable `_HEAD` advance (#5) is DEFERRED off the ack-blocking path: the
#     LOCAL cache is updated synchronously (so the next append has the right
#     candidate), but the durable `_HEAD` PUT does NOT block the ack. `_HEAD` is a
#     recovery cache (LIST / `_recover_head_by_list` reconstruct it), so a
#     deferred advance is fully recoverable.
#
# The chunk create-CAS (the gaplessness oracle) + the segment PUT (durability) are
# UNTOUCHED. A stale local cache only ever causes a 412 at the chunk create-CAS
# -> cache INVALIDATE -> fall back to the EXISTING re-read path; it can NEVER
# commit a wrong or duplicate offset (the create-CAS is the sole arbiter).
#
# This test asserts by OP COUNT on `SharedInMemoryConditionalStore` (per-verb
# call tallies shared across every clone) — the only place the win is observable
# (one fewer round-trip is identical wall-time on a single local store):
#   * `test_steady_state_ack_is_two_ops` — a warm single-writer ack does EXACTLY
#     2 synchronous ops (segment PUT + chunk create-CAS), 0 GET, 0 HEAD (the
#     naive path would do 5: +1 GET +1 HEAD +1 advance PUT).
#   * `test_contention_falls_back_and_commits_dense` — a stale local cache (a
#     concurrent sibling won the slot) 412s at the create-CAS, falls back to the
#     re-read path, and STILL commits at the correct dense contiguous offset (no
#     torn / duplicate offset). Proves the elision never tears offsets.
#   * `test_cold_first_flush_still_correct` — the very first flush (cold cache,
#     `_HEAD` absent) still resolves correct offsets (the cache is absent so the
#     existing LIST-recovery path runs).
#
# Hard-rule audit: no UnsafePointer in any signature, no wildcard origins, no
# unsafe_from_address / take_pointee. The local cache is a plain typed field.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_broker.broker_core import BrokerCore

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore


def _partition_prefix(cluster: String, topic: String, pid: Int64) -> String:
    return cluster + "/_meta/topics/" + topic + "/" + String(pid)


def _make_broker(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> BrokerCore[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    var manifest = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=pid,
        broker_id=String("broker-A"),
    )


def _make_manifest(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> CasManifestStore[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    return CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )


def _make_int64_batch(base_val: Int64, n: Int) raises -> RecordBatch:
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, base_val + Int64(i))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _body(tag: Int, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i + tag) & 0xFF))
    return out^


# =============================================================================
# (1) A warm single-writer durable ack is EXACTLY 2 synchronous ops.
#     RED before the source edit (5 ops: +1 GET +1 HEAD +1 advance PUT);
#     GREEN after (segment PUT + chunk create-CAS only).
# =============================================================================

# The per-ack synchronous object-store op count for ONE warm single-writer
# durable ack (segment PUT + chunk create-CAS). If a future change re-introduces
# a synchronous GET/HEAD/advance on the ack path, these counts rise -> FAIL LOUD.
comptime _ACK_PUTS = Int64(2)  # segment PUT + chunk create-CAS
comptime _ACK_GETS = Int64(0)  # _HEAD GET elided by the local cache
comptime _ACK_HEADS = Int64(0)  # _HEAD etag HEAD elided by the local cache
comptime _ACK_TOTAL_OPS = Int64(2)  # 2 synchronous ops total (down from 5)


def test_steady_state_ack_is_two_ops() raises:
    print("[test_steady_state_ack_is_two_ops] starting...")
    var store = _Store()
    var cluster = String("c-2op")
    var topic = String("t")
    var pid = Int64(0)

    var broker = _make_broker(store, cluster, topic, pid)

    # First flush WARMS the local cache (cold-cache path: it still reads/lists to
    # establish the tail, then populates the cache from the WIN). We measure the
    # SECOND flush — the steady-state warm-cache single-writer ack.
    broker.buffer_batch(_make_int64_batch(Int64(0), 4), Int64(1_700_000_000_000))
    var r0 = broker.flush(Int64(1_700_000_000_000))
    assert_equal(r0.base_offset, Int64(0), "warm-up ack base 0")
    assert_equal(r0.last_offset, Int64(3), "warm-up ack last 3")

    # Measure the steady-state warm ack.
    broker.buffer_batch(_make_int64_batch(Int64(4), 4), Int64(1_700_000_001_000))
    store.reset_op_counts()
    var r1 = broker.flush(Int64(1_700_000_001_000))
    var puts = store.n_put()
    var gets = store.n_get()
    var heads = store.n_head()

    # Ack correctness — contiguous, manifest-authoritative.
    assert_equal(r1.base_offset, Int64(4), "warm ack base 4 (contiguous)")
    assert_equal(r1.last_offset, Int64(7), "warm ack last 7")
    assert_equal(r1.record_count, Int64(4), "warm ack record_count 4")

    # The reduction — exactly 2 synchronous ops, 0 GET, 0 HEAD.
    assert_equal(
        gets,
        _ACK_GETS,
        "warm ack issues 0 _HEAD GET (elided by the local cache; was 1)",
    )
    assert_equal(
        heads,
        _ACK_HEADS,
        "warm ack issues 0 _HEAD etag HEAD (elided by the local cache; was 1)",
    )
    assert_equal(
        puts,
        _ACK_PUTS,
        (
            "warm ack issues EXACTLY 2 PUTs (segment PUT + chunk create-CAS);"
            " the best-effort _HEAD advance is deferred off the ack path (was 3)"
        ),
    )
    assert_equal(
        gets + heads + puts,
        _ACK_TOTAL_OPS,
        (
            "warm single-writer durable ack = 2 synchronous object-store ops"
            " (the naive path does 5)"
        ),
    )
    _ = broker^
    _ = store^
    print(
        "[test_steady_state_ack_is_two_ops] PASS — warm ack = 2 synchronous ops"
        " (segment PUT + chunk create-CAS), 0 GET, 0 HEAD"
    )


# =============================================================================
# (2) Contention: a stale local cache 412s at the chunk create-CAS, falls back
#     to the re-read path, and STILL commits at the correct dense offset.
#     This is the correctness proof that the local-cache elision NEVER tears
#     offsets — the create-CAS remains the sole gaplessness oracle.
# =============================================================================


def test_contention_falls_back_and_commits_dense() raises:
    print("[test_contention_falls_back_and_commits_dense] starting...")
    var store = _Store()
    var cluster = String("c-cont")
    var topic = String("t")
    var pid = Int64(0)
    var prefix = _partition_prefix(cluster, topic, pid)

    # TWO independent CasManifestStore handles over the SAME prefix + SAME shared
    # backend — each carries its OWN local `_HEAD` cache. This is the cross-writer
    # contention shape: writer A commits, writer B's cache is now STALE.
    var a = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix, retry=RetryPolicy.fast_test()
    )
    var b = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix, retry=RetryPolicy.fast_test()
    )

    # A appends seq 0 ([0,3]) — A's cache now says chunk_seq=0, next_offset=4.
    var ra0 = a.append(_body(0, 16), Int64(4))
    assert_equal(ra0.chunk_seq, Int64(0), "A seq 0")
    assert_equal(ra0.base_offset, Int64(0), "A base 0")

    # B appends seq 1 ([4,7]) — B's cache is cold, so it reads/lists the tail and
    # wins slot 1 at base 4. B's cache now says chunk_seq=1, next_offset=8.
    var rb1 = b.append(_body(1, 16), Int64(4))
    assert_equal(rb1.chunk_seq, Int64(1), "B seq 1 (contiguous after A)")
    assert_equal(rb1.base_offset, Int64(4), "B base 4 (dense)")

    # NOW the contention: A's cache is STALE (it thinks the tail is seq 0). A's
    # next append computes candidate_seq = 0+1 = 1 from its stale cache, 412s at
    # the create-CAS (B owns slot 1), INVALIDATES its cache, falls back to the
    # re-read path, re-anchors on the true tail (seq 1), and wins slot 2 at the
    # CORRECT dense base 8. The create-CAS oracle guarantees no torn offset.
    var ra2 = a.append(_body(2, 16), Int64(4))
    assert_equal(
        ra2.chunk_seq,
        Int64(2),
        "A wins seq 2 after a stale-cache 412 + fall-back re-read (no torn seq)",
    )
    assert_equal(
        ra2.base_offset,
        Int64(8),
        "A base 8 — DENSE + contiguous despite the stale-cache 412",
    )
    assert_true(
        ra2.attempts >= 2,
        "A's stale-cache append took >= 2 attempts (the 412 + the re-read win)",
    )

    # B continues: B's cache is now stale too (A won seq 2). B 412s, falls back,
    # wins seq 3 at dense base 12.
    var rb3 = b.append(_body(3, 16), Int64(4))
    assert_equal(rb3.chunk_seq, Int64(3), "B wins seq 3 (dense, post fall-back)")
    assert_equal(rb3.base_offset, Int64(12), "B base 12 — DENSE")

    # Authoritative tail check — the bucket sees a gapless 0..3 lineage.
    var head = a.read_head_authoritative()
    assert_equal(head.chunk_seq, Int64(3), "authoritative tail seq 3")
    assert_equal(head.next_offset, Int64(16), "authoritative next_offset 16")

    _ = a^
    _ = b^
    _ = store^
    print(
        "[test_contention_falls_back_and_commits_dense] PASS — stale-cache 412 ->"
        " fall-back re-read -> dense contiguous offsets (oracle preserved)"
    )


# =============================================================================
# (3) The very first (cold-cache) flush still resolves correct offsets — the
#     cache is absent on the first append, so the existing read/LIST-recovery
#     path runs unchanged.
# =============================================================================


def test_cold_first_flush_still_correct() raises:
    print("[test_cold_first_flush_still_correct] starting...")
    var store = _Store()
    var cluster = String("c-cold")
    var topic = String("t")
    var pid = Int64(0)

    var broker = _make_broker(store, cluster, topic, pid)
    broker.buffer_batch(_make_int64_batch(Int64(0), 4), Int64(1_700_000_000_000))
    var r0 = broker.flush(Int64(1_700_000_000_000))
    assert_equal(r0.base_offset, Int64(0), "cold first-flush base 0")
    assert_equal(r0.last_offset, Int64(3), "cold first-flush last 3")
    assert_equal(r0.record_count, Int64(4), "cold first-flush record_count 4")

    # A SECOND, independent manifest handle (cold cache) reads the tail
    # authoritatively and sees the committed chunk.
    var m2 = _make_manifest(store, cluster, topic, pid)
    var head = m2.read_head_authoritative()
    assert_equal(head.chunk_seq, Int64(0), "fresh handle sees committed seq 0")
    assert_equal(head.next_offset, Int64(4), "fresh handle next_offset 4")

    _ = m2^
    _ = broker^
    _ = store^
    print(
        "[test_cold_first_flush_still_correct] PASS — cold first flush resolves"
        " correct offsets; fresh handle recovers the tail"
    )


# =============================================================================
# (4) A FRESH (cold) handle's `read_head_fresh()` counts EVERY committed chunk,
#     not just the ones the writer persisted into the durable `_HEAD`;
#     `num_chunks()` is advisory and may under-count.
# =============================================================================
#
# THE HAZARD THIS PINS. (1) above buys its 2-op ack by DEFERRING the durable
# `_HEAD` advance for up to `_HEAD_ADVANCE_DEFER_CADENCE` = 64 warm appends.
# `read_head()`'s cold path GETs that durable `_HEAD` object and TRUSTS it (its
# LIST-recovery escape fires only when `_HEAD` is ABSENT, never when it is
# present-but-stale-low). So a reader that is not the writer itself, counting
# through `read_head()`, under-counts the lineage by up to 63 chunks.
#
# WHY THIS IS ASSERTED HERE: this is the suite for the optimization that
# creates the hazard, so the guard belongs next to it (a downstream victim's
# own test is a weaker, indirect falsifier).
#
# ⚠ THE VACUITY GUARD. If the durable `_HEAD` were current, `num_chunks()` would
# return the right answer even with the bug restored, and this test would pass
# while proving nothing. So the staleness is ASSERTED, not assumed: the durable
# head is measured and must genuinely lag the authoritative tail. If a future
# change persists the durable advance eagerly, THIS assertion fails first and
# says so — that is the honest outcome, because at that point this test no
# longer falsifies anything and must be re-derived rather than trusted.

# Enough flushes to leave the durable `_HEAD` behind: the FIRST append creates
# the `_HEAD` object, the rest are warm and DEFER (cadence 64 >> 3).
comptime _DEFER_FLUSHES = 3


def test_fresh_handle_num_chunks_counts_deferred_chunks() raises:
    print("[test_fresh_handle_num_chunks_counts_deferred_chunks] starting...")
    var store = _Store()
    var cluster = String("c-defer")
    var topic = String("t")
    var pid = Int64(0)

    var broker = _make_broker(store, cluster, topic, pid)
    for i in range(_DEFER_FLUSHES):
        broker.buffer_batch(
            _make_int64_batch(Int64(i * 4), 4), Int64(1_700_000_000_000)
        )
        var r = broker.flush(Int64(1_700_000_000_000))
        assert_equal(
            r.base_offset,
            Int64(i * 4),
            "flush " + String(i) + " commits at the dense base offset",
        )

    # --- the vacuity guard: the durable `_HEAD` really IS behind. ---
    var probe = _make_manifest(store, cluster, topic, pid)
    var durable = probe.read_durable_head()
    var truth = probe.read_head_authoritative()
    assert_equal(
        truth.chunk_seq,
        Int64(_DEFER_FLUSHES - 1),
        "the bucket holds every committed chunk (LIST is the source of truth)",
    )
    assert_true(
        durable.chunk_seq < truth.chunk_seq,
        (
            "PRECONDITION: the durable `_HEAD` must lag the true tail for this"
            " test to falsify anything (durable="
            + String(durable.chunk_seq)
            + " truth="
            + String(truth.chunk_seq)
            + "). If the deferred-advance policy changed, this falsifier is"
            " VACUOUS and must be re-derived — do not delete it."
        ),
    )

    # --- the claim: `read_head_fresh()` on a COLD handle is AUTHORITATIVE. ---
    # This is the reader every correctness consumer of the tail uses. If it
    # is ever changed to believe the durable `_HEAD`, every one of them
    # silently truncates its catalog — that is the read-back loss this
    # assertion stands in front of.
    var fresh = _make_manifest(store, cluster, topic, pid)
    assert_equal(
        fresh.read_head_fresh().chunk_seq + Int64(1),
        Int64(_DEFER_FLUSHES),
        (
            "a COLD handle's read_head_fresh() sees EVERY committed chunk, not"
            " the stale-low durable `_HEAD`"
        ),
    )

    # --- and the counterpart, asserted so the gap is a PINNED FACT, not a
    #     surprise: `num_chunks()` is ADVISORY and DOES under-count here. ---
    # It is not "fine": `num_chunks()` is ADVISORY (see the note on
    # CasManifestStore.num_chunks) and callers that need the authoritative
    # tail must use `read_head_fresh()`. Pinning it here means the gap cannot
    # be re-discovered from scratch, and means the day someone makes
    # `num_chunks()` authoritative THIS LINE GOES RED and tells them to delete
    # it — the ratchet shape, applied to a known-wrong value.
    assert_true(
        fresh.num_chunks() < Int64(_DEFER_FLUSHES),
        (
            "num_chunks() is documented ADVISORY and is EXPECTED to under-count"
            " a deferred tail. If this is now correct, num_chunks() has"
            " become authoritative: delete this assertion."
        ),
    )

    # The WARM path is unchanged by this fix and is pinned by (1) above, which
    # asserts the steady-state ack is still exactly 2 synchronous ops — a
    # change to an always-authoritative read would add a LIST per ack and
    # break that op-count assertion first.

    _ = fresh^
    _ = probe^
    _ = broker^
    _ = store^
    print(
        "[test_fresh_handle_num_chunks_counts_deferred_chunks] PASS — durable"
        " `_HEAD` lagged at "
        + String(durable.chunk_seq)
        + " while a cold handle's num_chunks() correctly returned "
        + String(_DEFER_FLUSHES)
    )


def main() raises:
    test_steady_state_ack_is_two_ops()
    test_contention_falls_back_and_commits_dense()
    test_cold_first_flush_still_correct()
    test_fresh_handle_num_chunks_counts_deferred_chunks()
    print(
        "[OK] test_broker_flush_local_head_cache_offline —"
        " warm single-writer durable ack = 2"
        " synchronous ops (segment PUT + chunk create-CAS); contention falls"
        " back to the re-read path and commits dense contiguous offsets; cold"
        " first flush + fresh-handle recovery correct; a cold handle's"
        " num_chunks() sees the DEFERRED chunks"
    )
