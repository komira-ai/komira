# =============================================================================
# tests/test_broker_maintenance_authoritative_tail_offline.mojo
#   The MAINTENANCE-path
#   correctness consumers of the manifest tail must read the AUTHORITATIVE
#   (LIST-recovered) tail, NOT the stale-low cached `read_head()`.
# =============================================================================
#
# THE HAZARD CLASS (the same one RetentionPass.run guards against).
# The durable `_HEAD` advance is deferred off the
# warm-append ack path: the FIRST append on a fresh `CasManifestStore`
# instance does a durable `_HEAD` advance (cold/not-from-cache path), but
# every subsequent WARM append only updates the per-instance LOCAL `_HEAD`
# cache and DEFERS the durable `_HEAD` PUT until `_HEAD_ADVANCE_DEFER_CADENCE`
# (=64) advances accumulate. So after a single warm writer commits N chunks,
# the DURABLE `_HEAD` object still points at chunk_seq 0 (stale-low by N-1),
# while the bucket's true tail (LIST of the chunk objects) is N-1.
#
# `read_head()` prefers the LOCAL cache and, on a cold/fresh instance (empty
# cache), reads the DURABLE `_HEAD` object — so a SEPARATE maintenance instance
# (the production background-maintenance shape: a fresh `CasManifestStore` /
# fresh maintenance op over the SAME clone-shared store) reads the stale-low
# durable `_HEAD` and UNDER-reports the tail. The five maintenance ops below
# are CORRECTNESS consumers of the tail; each reads
# `read_head_authoritative()` (LIST-recovered true tail). The chunk objects are
# always durable (unconditional create-CAS), so the authoritative replay sees
# every committed chunk regardless of the deferred `_HEAD`.
#
# Each test reproduces the cold-cache shape:
#   * a WARM writer instance commits N chunks (durable `_HEAD` deferred to 0),
#   * a SEPARATE fresh maintenance instance / op runs over the shared store,
#   * assert it sees the FULL tail.
# A `read_head()`-based implementation would be RED (stale-low -> wrong count /
# boundary); `read_head_authoritative()` is GREEN. The shapes:
#     1. _schedule_parent_chunks_for_delete: would tombstone only seq 0 (stale
#        tail) -> orphan chunks 1..N-1 never tombstoned -> storage leak.
#     2. split_topic: frozen_at_offset == stale-low next_offset (1 record, not N)
#        -> torn freeze offset at the split boundary.
#     3. merge_topic: frozen_a/b_offset == stale-low next_offset for BOTH parents
#        -> torn freeze offsets at the merge boundary.
#     4. _partition_record_count: the stale-low next_offset (1, not N)
#        -> the merge-IN cold signal under-reports the partition's record count.
#     5. resolve_compacted: head.chunk_seq stale-low -> misses the most-recently
#        appended CompactedEntry(s) -> compacted_tail_offset lands too low.
#
# Hard-rule audit: no UnsafePointer in any signature, no wildcard origins,
# no unsafe_from_address / take_pointee.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema

from komira_broker.broker_core import BrokerCore
from komira_broker.partition_map import (
    PartitionMap,
    read_partition_map,
    read_partition_map_with_etag,
    persist_create_if_absent,
)
from komira_broker.partition_split import SplitResult, split_topic
from komira_broker.partition_merge import MergeResult, merge_topic
from komira_broker.partition_merge_driver import _partition_record_count
from komira_broker.partition_compaction import _schedule_parent_chunks_for_delete
from komira_broker.compacted_index import CompactionIndex

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore


def _manifest_prefix(cluster: String, topic: String, pid: Int64) -> String:
    return cluster + "/_meta/topics/" + topic + "/" + String(pid)


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


def _make_broker(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> BrokerCore[_Store]:
    var prefix = _manifest_prefix(cluster, topic, pid)
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
    """A FRESH `CasManifestStore` over the SAME clone-shared store — an empty
    local `_HEAD` cache (the production background-maintenance instance shape)."""
    var prefix = _manifest_prefix(cluster, topic, pid)
    return CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )


def _warm_writer_commits_n(
    store: _Store, cluster: String, topic: String, pid: Int64, n_chunks: Int
) raises:
    """Drive ONE warm writer instance to commit `n_chunks` chunks (one chunk per
    flush). The FIRST flush does the cold/durable `_HEAD` advance; the remaining
    flushes are WARM (defer the durable `_HEAD` advance). So after this returns
    the DURABLE `_HEAD` is stale-low (seq 0), while the bucket holds 0..n-1."""
    var broker = _make_broker(store, cluster, topic, pid)
    var base_ts = Int64(1_700_000_000_000)
    for i in range(n_chunks):
        var rb = _make_int64_batch(Int64(i * 4), 4)
        _ = broker.produce(rb^, base_ts + Int64(i) * Int64(1000))
        _ = broker.flush_if_buffered(base_ts + Int64(i) * Int64(1000))
    _ = broker^


def _assert_durable_head_is_stale_low(
    store: _Store, cluster: String, topic: String, pid: Int64, n_chunks: Int
) raises:
    """Sanity-anchor the cold-cache PRECONDITION: a fresh handle's `read_head()`
    (durable `_HEAD`, deferred) lags the LIST-recovered authoritative tail. If
    this ever stops holding (e.g. the defer cadence drops to 1), these
    tests would silently stop falsifying the hazard — so we assert it."""
    var m = _make_manifest(store, cluster, topic, pid)
    var cached = m.read_head()
    var auth = m.read_head_authoritative()
    _ = m^
    assert_equal(
        auth.chunk_seq,
        Int64(n_chunks - 1),
        "authoritative tail sees all "
        + String(n_chunks)
        + " committed chunks (LIST recovery)",
    )
    assert_true(
        cached.chunk_seq < auth.chunk_seq,
        (
            "PRECONDITION: the durable `_HEAD` (read_head) is STALE-LOW vs the"
            " authoritative tail (deferred advance). cached.chunk_seq="
            + String(cached.chunk_seq)
            + " auth.chunk_seq="
            + String(auth.chunk_seq)
            + " — if this fails the defer cadence changed; the cold-cache repro"
            " no longer falsifies the bug"
        ),
    )


# =============================================================================
# (1) _schedule_parent_chunks_for_delete tombstones EVERY committed chunk, even
#     when the maintenance instance's durable `_HEAD` is stale-low.
#     With `read_head()`: only seq 0 would be tombstoned -> orphans 1..N-1 leak.
# =============================================================================


def test_schedule_parent_chunks_for_delete_sees_full_tail() raises:
    print("[test_schedule_parent_chunks_for_delete_sees_full_tail] starting...")
    var store = _Store()
    var cluster = String("c-tomb")
    var topic = String("t")
    var pid = Int64(0)
    var n = 6

    _warm_writer_commits_n(store, cluster, topic, pid, n)
    _assert_durable_head_is_stale_low(store, cluster, topic, pid, n)

    # The maintenance op runs from a FRESH manifest instance (cold cache).
    var maint = _make_manifest(store, cluster, topic, pid)
    var now_ms = Int64(1_700_000_100_000)
    _schedule_parent_chunks_for_delete[_Store](maint, now_ms)

    # Every committed chunk 0..n-1 must now carry a tombstone schedule. A
    # stale-low head would have tombstoned only seq 0 (the rest raise not_found).
    var verify = _make_manifest(store, cluster, topic, pid)
    var tombstoned = 0
    for seq in range(n):
        try:
            if verify.tombstone_schedule_ts(Int64(seq)) == now_ms:
                tombstoned += 1
        except e:
            # not_found — this chunk was NOT tombstoned (the stale-tail shape for
            # every chunk above the stale-low tail).
            pass
    _ = verify^
    _ = maint^
    assert_equal(
        tombstoned,
        n,
        (
            "ALL "
            + String(n)
            + " committed chunks tombstoned (read_head_authoritative); a"
            " `read_head()` reader would tombstone only seq 0 -> orphans 1.."
            + String(n - 1)
            + " leak"
        ),
    )
    _ = store^
    print(
        "[test_schedule_parent_chunks_for_delete_sees_full_tail] PASS — all",
        n,
        "orphan chunks tombstoned (no storage leak)",
    )


# =============================================================================
# (2) split_topic freezes at the parent's TRUE tail, even from a fresh
#     (cold-cache) parent_manifest.
#     With `read_head()`: frozen_at_offset == stale-low next_offset (4, not n*4).
# =============================================================================


def test_split_freeze_offset_is_authoritative_tail() raises:
    print("[test_split_freeze_offset_is_authoritative_tail] starting...")
    var store = _Store()
    var cluster = String("c-split")
    var topic = String("t")
    var pid = Int64(0)
    var n = 6

    var seed = PartitionMap.auto_seed()
    persist_create_if_absent[_Store](store, cluster, topic, seed)
    _warm_writer_commits_n(store, cluster, topic, pid, n)
    _assert_durable_head_is_stale_low(store, cluster, topic, pid, n)

    var true_next_offset = Int64(n * 4)  # n chunks * 4 records each

    # The split runs over a FRESH parent_manifest (cold cache).
    var pm = _make_manifest(store, cluster, topic, pid)
    var split = split_topic[_Store](store, cluster, topic, pm^, 0)
    assert_equal(
        split.frozen_at_offset,
        true_next_offset,
        (
            "split freezes at the parent's TRUE tail "
            + String(true_next_offset)
            + " (read_head_authoritative); a `read_head()` reader would freeze at"
            " the stale-low durable next_offset (4) -> torn boundary"
        ),
    )
    _ = store^
    print(
        "[test_split_freeze_offset_is_authoritative_tail] PASS — frozen_at_offset"
        " == true tail",
        true_next_offset,
    )


# =============================================================================
# (3) merge_topic freezes BOTH parents at their TRUE tails, from fresh
#     (cold-cache) parent manifests.
#     With `read_head()`: frozen_a/b_offset == stale-low next_offset for each parent.
# =============================================================================


def test_merge_freeze_offsets_are_authoritative_tails() raises:
    print("[test_merge_freeze_offsets_are_authoritative_tails] starting...")
    var store = _Store()
    var cluster = String("c-merge")
    var topic = String("t")
    var n_a = 6
    var n_b = 5

    # Seed + split 0 -> {1,2} to get two ADJACENT live partitions.
    var seed = PartitionMap.auto_seed()
    persist_create_if_absent[_Store](store, cluster, topic, seed)
    var pm0 = _make_manifest(store, cluster, topic, Int64(0))
    var split0 = split_topic[_Store](store, cluster, topic, pm0^, 0)
    var pid_a = Int64(split0.child_a_pid)
    var pid_b = Int64(split0.child_b_pid)

    # Warm-commit into each child (deferring each child's durable `_HEAD`).
    _warm_writer_commits_n(store, cluster, topic, pid_a, n_a)
    _warm_writer_commits_n(store, cluster, topic, pid_b, n_b)
    _assert_durable_head_is_stale_low(store, cluster, topic, pid_a, n_a)
    _assert_durable_head_is_stale_low(store, cluster, topic, pid_b, n_b)

    var true_a = Int64(n_a * 4)
    var true_b = Int64(n_b * 4)

    # The merge runs over FRESH parent manifests (both cold caches).
    var pma = _make_manifest(store, cluster, topic, pid_a)
    var pmb = _make_manifest(store, cluster, topic, pid_b)
    var merge = merge_topic[_Store](
        store, cluster, topic, pma^, pmb^, Int(pid_a), Int(pid_b)
    )
    assert_equal(
        merge.frozen_a_offset,
        true_a,
        (
            "merge freezes parent A at its TRUE tail "
            + String(true_a)
            + " (read_head_authoritative); a `read_head()` reader would freeze at"
            " the stale-low durable next_offset -> torn merge boundary"
        ),
    )
    assert_equal(
        merge.frozen_b_offset,
        true_b,
        (
            "merge freezes parent B at its TRUE tail "
            + String(true_b)
            + " (read_head_authoritative); a `read_head()` reader would freeze at"
            " the stale-low durable next_offset -> torn merge boundary"
        ),
    )
    _ = store^
    print(
        "[test_merge_freeze_offsets_are_authoritative_tails] PASS — both freeze"
        " offsets == true tails (A=",
        true_a,
        ", B=",
        true_b,
        ")",
    )


# =============================================================================
# (4) _partition_record_count returns the TRUE record count from a fresh
#     (cold-cache) per-candidate manifest (the merge-IN cold signal).
#     With `read_head()`: the stale-low next_offset (4, not n*4).
# =============================================================================


def test_partition_record_count_is_authoritative_tail() raises:
    print("[test_partition_record_count_is_authoritative_tail] starting...")
    var store = _Store()
    var cluster = String("c-count")
    var topic = String("t")
    var pid = Int64(0)
    var n = 7

    _warm_writer_commits_n(store, cluster, topic, pid, n)
    _assert_durable_head_is_stale_low(store, cluster, topic, pid, n)

    var true_count = Int64(n * 4)
    # _partition_record_count itself constructs a fresh per-candidate manifest.
    var got = _partition_record_count[_Store](store, cluster, topic, 0)
    assert_equal(
        got,
        true_count,
        (
            "cold-signal record count == the TRUE tail "
            + String(true_count)
            + " (read_head_authoritative); a `read_head()` reader would return"
            " the stale-low durable next_offset (4) -> under-reports -> suppresses a"
            " merge it should not (or bands a busy partition as cold)"
        ),
    )
    _ = store^
    print(
        "[test_partition_record_count_is_authoritative_tail] PASS — count ==",
        true_count,
    )


# =============================================================================
# (5) CompactionIndex.resolve_compacted sees EVERY appended CompactedEntry from
#     a fresh (cold-cache) index instance.
#     With `read_head()`: head.chunk_seq stale-low -> resolve misses recent entries ->
#     compacted_tail_offset lands too low.
# =============================================================================


def test_resolve_compacted_sees_full_tail() raises:
    print("[test_resolve_compacted_sees_full_tail] starting...")
    var store = _Store()
    var cluster = String("c-ci")
    var topic = String("t")
    var prefix = _manifest_prefix(cluster, topic, Int64(0))
    var n = 5

    # WARM writer: append n CompactedEntry's on ONE index instance. The first
    # append does the cold/durable `_HEAD` advance; the rest are warm (deferred),
    # so the durable `_HEAD` of the compacted lineage is stale-low (seq 0).
    var writer = CompactionIndex[_Store].build(
        store.clone(), prefix, RetryPolicy.fast_test()
    )
    for i in range(n):
        _ = writer.append_compacted(
            parquet_key=String("p") + String(i) + String(".parquet"),
            base_offset=Int64(i * 50),
            last_offset=Int64(i * 50 + 49),
            record_count=Int64(50),
            supersedes_lo=Int64(i * 5),
            supersedes_hi=Int64(i * 5 + 4),
        )
    _ = writer^

    var true_tail_offset = Int64(n * 50)  # last_compacted + 1

    # A FRESH index instance (cold cache) resolves the compacted lineage.
    var reader = CompactionIndex[_Store].build(
        store.clone(), prefix, RetryPolicy.fast_test()
    )
    var entries = reader.resolve_compacted()
    assert_equal(
        len(entries),
        n,
        (
            "resolve sees ALL "
            + String(n)
            + " compacted entries (read_head_authoritative); a `read_head()`"
            " reader would see the stale-low durable chunk_seq -> miss the"
            " recent entries"
        ),
    )
    var tail = reader.compacted_tail_offset()
    assert_equal(
        tail,
        true_tail_offset,
        (
            "compacted_tail_offset == the TRUE boundary "
            + String(true_tail_offset)
            + "; a stale-low resolve would land it too low -> the dual-tier"
            " resolve mis-splits live vs compacted"
        ),
    )
    _ = reader^
    _ = store^
    print(
        "[test_resolve_compacted_sees_full_tail] PASS — resolve sees all",
        n,
        "entries; tail ==",
        true_tail_offset,
    )


def main() raises:
    test_schedule_parent_chunks_for_delete_sees_full_tail()
    test_split_freeze_offset_is_authoritative_tail()
    test_merge_freeze_offsets_are_authoritative_tails()
    test_partition_record_count_is_authoritative_tail()
    test_resolve_compacted_sees_full_tail()
    print(
        "[OK] test_broker_maintenance_authoritative_tail_offline —"
        " all 5 maintenance-path tail consumers read the AUTHORITATIVE"
        " (LIST-recovered) tail from a cold-cache instance (no storage leak,"
        " no torn split/merge boundary, correct cold signal + compacted tail)"
    )
