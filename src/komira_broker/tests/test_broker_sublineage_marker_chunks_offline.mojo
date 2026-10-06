# =============================================================================
# tests/test_broker_sublineage_marker_chunks_offline.mojo
#   Sub-lineage readers, the segment fold and the legacy migration over
#   manifest chunks that own no segment object — OFFLINE unit tests.
# =============================================================================
#
# A chunk owns a segment object iff `ManifestBody.has_segment()`: a
# MARKER_NONE body with a non-empty object_key. A txn COMMIT / ABORT marker
# (zero records, empty key) owns none; neither does a MARKER_NONE body with an
# empty key (no producer writes one, but a reader must not GET or copy "").
#
# Chunks are appended DIRECTLY into the shard / `_base` / legacy manifests with
# chosen bodies; the resolver and the fold read manifests only (they never GET
# a `.seg`), so the keys are plain names.
#
# Cases (each names the defect it catches):
#   (1) markers in a shard (ABORT first, COMMIT between data chunks), then a
#       fold, then a marker in `_base`: every resolve path (cached, uncached,
#       tagged, tagged-uncached block mapping) returns exactly the data chunks
#       at the same dense offsets before and after the fold, and the fold
#       re-records only the data chunks. Catches a marker leaking into an index
#       or into `_base`, or a marker shifting dense offsets.
#   (2) a MARKER_NONE chunk with an empty key and 5 records between two data
#       chunks of a shard: every resolve path skips it and keeps the later
#       chunk at source-local offset 15 (the 5 records still count). The fold
#       REFUSES it (raises) instead of copying "" into `_base`, and the serve
#       offsets after the partial fold are unchanged. Catches a GET / copy of
#       "" and an offset shift.
#   (3) the same empty-key chunk in `_base`: the `_base` walks skip it (no
#       empty key in the index, none in the `_base` key set).
#   (4) legacy migration over a marker: migrates only the data chunks, offsets
#       preserved. Catches a marker re-recorded into `_base`.
#   (5) legacy migration over an empty-key chunk with records: REFUSES it.
#       Catches a copy of "" into `_base`.
#   (6) a fold that crashed between materialize and retire, with a marker
#       before the materialized chunk: the `_base`-anchored folded prefix skips
#       the marker and still finds the chunk. Catches a prefix walk that stops
#       at a marker (it would re-serve the folded chunk: a duplicate).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_broker.consume_core import SegmentRef
from komira_broker.manifest_body import (
    MARKER_ABORT,
    MARKER_COMMIT,
    MARKER_NONE,
    ManifestBody,
    encode_manifest_body,
)
from komira_broker.partition_assignment import sublineage_prefix
from komira_broker.sublineage_consume import (
    SubLineageConsumeResolver,
    SubLineageTaggedSegment,
)
from komira_broker.sublineage_migration import SubLineageMigration
from komira_broker.sublineage_segment_fold import SegmentBaseFold

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore


# =============================================================================
# helpers
# =============================================================================


def _base_prefix(cluster: String) -> String:
    return cluster + "/_meta/topics/t/0"


def _manifest(store: _Store, prefix: String) -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](
        store=store.clone(), prefix=prefix, retry=RetryPolicy.fast_test()
    )


def _shard(store: _Store, cluster: String) -> CasManifestStore[_Store]:
    return _manifest(store, sublineage_prefix(_base_prefix(cluster), "w0"))


def _base(store: _Store, cluster: String) -> CasManifestStore[_Store]:
    return _manifest(store, sublineage_prefix(_base_prefix(cluster), "_base"))


def _data(mut m: CasManifestStore[_Store], key: String, n: Int64) raises:
    _ = m.append(
        encode_manifest_body(
            key, n, UInt32(7), Int64(100), Int64(1000)
        ),
        n,
    )


def _marker(mut m: CasManifestStore[_Store], marker_type: Int64) raises:
    _ = m.append(
        encode_manifest_body(
            String(""),
            Int64(0),
            UInt32(0),
            Int64(0),
            Int64(1000),
            Int64(7),
            Int64(1),
            Int64(-1),
            Int64(-1),
            marker_type,
            String("txn-a"),
        ),
        Int64(0),
    )


def _empty_key_chunk(mut m: CasManifestStore[_Store], n: Int64) raises:
    """A MARKER_NONE body with an empty key and `n` records."""
    _ = m.append(encode_manifest_body(String(""), n, UInt32(0)), n)


def _resolver(
    store: _Store, cluster: String
) -> SubLineageConsumeResolver[_Store]:
    return SubLineageConsumeResolver[_Store](
        store.clone(), _base_prefix(cluster)
    )


def _check_refs(
    refs: List[SegmentRef],
    keys: List[String],
    bases: List[Int64],
    counts: List[Int64],
    what: String,
) raises:
    assert_equal(len(refs), len(keys), what + ": ref count")
    for i in range(len(refs)):
        assert_true(refs[i].object_key.byte_length() > 0, what + ": no '' key")
        assert_equal(refs[i].object_key, keys[i], what + ": key")
        assert_equal(refs[i].base_offset, bases[i], what + ": dense base")
        assert_equal(
            refs[i].last_offset,
            bases[i] + counts[i] - Int64(1),
            what + ": dense last",
        )


def _untag(tagged: List[SubLineageTaggedSegment]) -> List[SegmentRef]:
    var out = List[SegmentRef]()
    for i in range(len(tagged)):
        out.append(tagged[i].seg.copy())
    return out^


def _check_all_paths(
    store: _Store,
    cluster: String,
    keys: List[String],
    bases: List[Int64],
    counts: List[Int64],
    what: String,
) raises:
    """Every resolve path returns the same refs: the cached `resolve_index`,
    the un-cached baseline, the tagged path, and the tagged un-cached block
    mapping (`_append_block_segments_tagged`, applied to the base index)."""
    var r = _resolver(store, cluster)
    _check_refs(r.resolve_index(), keys, bases, counts, what + " cached")
    _check_refs(
        r.resolve_index_uncached(), keys, bases, counts, what + " uncached"
    )
    var tagged = r.resolve_index_tagged()
    for i in range(len(tagged)):
        assert_equal(
            tagged[i].tag.marker_type, MARKER_NONE, what + ": tagged data"
        )
    _check_refs(_untag(tagged), keys, bases, counts, what + " tagged")
    # Tagged un-cached block mapping: the base part from the tagged path,
    # then each planned tail block through `_append_block_segments_tagged`.
    var fold = SegmentBaseFold[_Store](store.clone(), _base_prefix(cluster))
    var plan = fold.serve_plan()
    var t2 = List[SubLineageTaggedSegment]()
    for i in range(len(plan)):
        r._append_block_segments_tagged(t2, plan[i])
    var combined = List[SegmentRef]()
    var n_base = len(tagged) - len(t2)
    for i in range(n_base):
        combined.append(tagged[i].seg.copy())
    for i in range(len(t2)):
        combined.append(t2[i].seg.copy())
    _check_refs(combined, keys, bases, counts, what + " tagged-uncached")
    _ = fold^
    _ = r^


def _base_keys(store: _Store, cluster: String) raises -> List[String]:
    var b = _base(store, cluster)
    var out = List[String]()
    # AUTHORITATIVE (LIST) tail: the cached `_HEAD` lags appends.
    var n = b.read_head_authoritative().chunk_seq + Int64(1)
    for seq in range(Int(n)):
        out.append(
            String(ManifestBody.decode(b.read_chunk(Int64(seq))).object_key)
        )
    return out^


# =============================================================================
# (1) markers in a shard, fold, marker in `_base`
# =============================================================================


def test_markers_serve_and_fold() raises:
    print("[test_markers_serve_and_fold] starting...")
    var store = _Store()
    var cluster = String("sl1")
    var sh = _shard(store, cluster)
    _marker(sh, MARKER_ABORT)  # seq 0: a marker FIRST (prefix-walk skip)
    _data(sh, String("k1"), Int64(10))  # seq 1 -> [0, 9]
    _marker(sh, MARKER_COMMIT)  # seq 2
    _data(sh, String("k3"), Int64(10))  # seq 3 -> [10, 19]
    _data(sh, String("k4"), Int64(10))  # seq 4 -> [20, 29]

    var keys: List[String] = [String("k1"), String("k3"), String("k4")]
    var bases: List[Int64] = [Int64(0), Int64(10), Int64(20)]
    var counts: List[Int64] = [Int64(10), Int64(10), Int64(10)]
    _check_all_paths(store, cluster, keys, bases, counts, "pre-fold")

    var fold = SegmentBaseFold[_Store](store.clone(), _base_prefix(cluster))
    var stats = fold.run_once(Int64(5000))
    assert_equal(stats.records_folded, Int64(30), "30 records folded")
    assert_equal(stats.base_chunks_appended, 3, "3 data chunks re-recorded")
    var bk = _base_keys(store, cluster)
    assert_equal(len(bk), 3, "`_base` holds the 3 data chunks only")
    for i in range(len(bk)):
        assert_equal(bk[i], keys[i], "`_base` key")
    _ = fold^
    _check_all_paths(store, cluster, keys, bases, counts, "post-fold")

    # A marker in `_base`, then a new shard data chunk: the marker is skipped
    # and moves no offset (the new chunk lands at 30).
    var b = _base(store, cluster)
    _marker(b, MARKER_COMMIT)
    _ = b^
    _data(sh, String("k5"), Int64(10))
    keys.append(String("k5"))
    bases.append(Int64(30))
    counts.append(Int64(10))
    _check_all_paths(store, cluster, keys, bases, counts, "base marker")
    _ = sh^
    _ = store^
    print("[test_markers_serve_and_fold] PASS")


# =============================================================================
# (2) an empty-key chunk with records in a shard; the fold refuses it
# =============================================================================


def test_empty_key_chunk_in_shard() raises:
    print("[test_empty_key_chunk_in_shard] starting...")
    var store = _Store()
    var cluster = String("sl2")
    var sh = _shard(store, cluster)
    _data(sh, String("k0"), Int64(10))  # seq 0 -> [0, 9]
    _empty_key_chunk(sh, Int64(5))  # seq 1 -> [10, 14], no segment
    _data(sh, String("k2"), Int64(10))  # seq 2 -> [15, 24]
    _ = sh^

    var keys: List[String] = [String("k0"), String("k2")]
    var bases: List[Int64] = [Int64(0), Int64(15)]
    var counts: List[Int64] = [Int64(10), Int64(10)]
    _check_all_paths(store, cluster, keys, bases, counts, "pre-fold")

    var fold = SegmentBaseFold[_Store](store.clone(), _base_prefix(cluster))
    var refused = False
    try:
        _ = fold.run_once(Int64(5000))
    except e:
        refused = True
        assert_true(
            String(e).find("no segment object") >= 0,
            "the fold names the chunk without a segment",
        )
    assert_true(refused, "the fold refuses a chunk with records but no segment")
    _ = fold^
    var bk = _base_keys(store, cluster)
    for i in range(len(bk)):
        assert_true(bk[i].byte_length() > 0, "no '' key copied into `_base`")

    # The partial fold (k0 materialized before the refusal) serves the SAME
    # dense offsets: k0 from `_base`, k2 from the tail at 15.
    _check_all_paths(store, cluster, keys, bases, counts, "after refusal")
    _ = store^
    print("[test_empty_key_chunk_in_shard] PASS")


# =============================================================================
# (3) an empty-key chunk in `_base`
# =============================================================================


def test_empty_key_chunk_in_base() raises:
    print("[test_empty_key_chunk_in_base] starting...")
    var store = _Store()
    var cluster = String("sl3")
    var b = _base(store, cluster)
    _data(b, String("b0"), Int64(10))  # `_base` [0, 9]
    _empty_key_chunk(b, Int64(5))  # `_base` [10, 14], no segment
    _data(b, String("b2"), Int64(10))  # `_base` [15, 24]
    _ = b^

    var r = _resolver(store, cluster)
    var keys: List[String] = [String("b0"), String("b2")]
    var bases: List[Int64] = [Int64(0), Int64(15)]
    var counts: List[Int64] = [Int64(10), Int64(10)]
    _check_refs(r.resolve_index(), keys, bases, counts, "base cached")
    _check_refs(r.resolve_index_uncached(), keys, bases, counts, "base uncached")
    _check_refs(
        _untag(r.resolve_index_tagged()), keys, bases, counts, "base tagged"
    )
    _ = r^
    var fold = SegmentBaseFold[_Store](store.clone(), _base_prefix(cluster))
    var set = fold._inputs.walk_base_object_keys()
    assert_equal(len(set), 2, "`_base` key set: the 2 data keys only")
    for i in range(len(set)):
        assert_true(set[i].byte_length() > 0, "no '' in the `_base` key set")
    _ = fold^
    _ = store^
    print("[test_empty_key_chunk_in_base] PASS")


# =============================================================================
# (4) / (5) legacy migration
# =============================================================================


def test_migration_skips_marker() raises:
    print("[test_migration_skips_marker] starting...")
    var store = _Store()
    var cluster = String("sl4")
    var legacy = _manifest(store, _base_prefix(cluster))
    _data(legacy, String("m0"), Int64(10))  # [0, 9]
    _marker(legacy, MARKER_ABORT)
    _data(legacy, String("m2"), Int64(10))  # [10, 19]
    _ = legacy^

    var mig = SubLineageMigration[_Store](store.clone(), _base_prefix(cluster))
    var stats = mig.migrate_partition(Int64(5000))
    assert_equal(stats.records_migrated, Int64(20), "20 records migrated")
    assert_equal(stats.base_chunks_appended, 2, "2 data chunks migrated")
    _ = mig^
    var bk = _base_keys(store, cluster)
    assert_equal(len(bk), 2, "`_base` holds the 2 data chunks only")
    assert_equal(bk[0], String("m0"), "m0")
    assert_equal(bk[1], String("m2"), "m2")
    var r = _resolver(store, cluster)
    var keys: List[String] = [String("m0"), String("m2")]
    var bases: List[Int64] = [Int64(0), Int64(10)]
    var counts: List[Int64] = [Int64(10), Int64(10)]
    _check_refs(r.resolve_index(), keys, bases, counts, "migrated")
    _ = r^
    _ = store^
    print("[test_migration_skips_marker] PASS")


def test_migration_refuses_empty_key_chunk() raises:
    print("[test_migration_refuses_empty_key_chunk] starting...")
    var store = _Store()
    var cluster = String("sl5")
    var legacy = _manifest(store, _base_prefix(cluster))
    _data(legacy, String("m0"), Int64(10))
    _empty_key_chunk(legacy, Int64(5))
    _data(legacy, String("m2"), Int64(10))
    _ = legacy^

    var mig = SubLineageMigration[_Store](store.clone(), _base_prefix(cluster))
    var refused = False
    try:
        _ = mig.migrate_partition(Int64(5000))
    except e:
        refused = True
        assert_true(
            String(e).find("no segment object") >= 0,
            "the migration names the chunk without a segment",
        )
    assert_true(refused, "the migration refuses a chunk with records, no seg")
    _ = mig^
    var bk = _base_keys(store, cluster)
    for i in range(len(bk)):
        assert_true(bk[i].byte_length() > 0, "no '' key copied into `_base`")
    _ = store^
    print("[test_migration_refuses_empty_key_chunk] PASS")


# =============================================================================
# (6) crash between materialize and retire, with a leading marker
# =============================================================================


def test_crash_window_leading_marker() raises:
    """The fold materialized k1 into `_base` but crashed before retiring the
    shard (its `_LOG_START` still 0). The `_base`-anchored folded prefix must
    skip the leading marker (not stop at it), find k1 in `_base`, and report 10
    folded, so k1 is served once (from `_base`) and k2 from the tail at 10."""
    print("[test_crash_window_leading_marker] starting...")
    var store = _Store()
    var cluster = String("sl6")
    var sh = _shard(store, cluster)
    _marker(sh, MARKER_ABORT)  # seq 0
    _data(sh, String("k1"), Int64(10))  # seq 1 -> [0, 9]
    _data(sh, String("k2"), Int64(10))  # seq 2 -> [10, 19]
    _ = sh^
    var b = _base(store, cluster)
    _data(b, String("k1"), Int64(10))  # what the crashed fold re-recorded
    _ = b^
    var keys: List[String] = [String("k1"), String("k2")]
    var bases: List[Int64] = [Int64(0), Int64(10)]
    var counts: List[Int64] = [Int64(10), Int64(10)]
    _check_all_paths(store, cluster, keys, bases, counts, "crash window")
    _ = store^
    print("[test_crash_window_leading_marker] PASS")


def main() raises:
    test_markers_serve_and_fold()
    test_empty_key_chunk_in_shard()
    test_empty_key_chunk_in_base()
    test_migration_skips_marker()
    test_migration_refuses_empty_key_chunk()
    test_crash_window_leading_marker()
    print("[OK] test_broker_sublineage_marker_chunks_offline")
