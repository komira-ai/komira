# =============================================================================
# test_search_sharded_compaction.mojo — compaction across per-writer shard
# lineages: fold the writer sub-lineages into the reserved `_base` lineage and
# remove the drained shards.
# =============================================================================
#
# Correctness is the hard line: across shards there must be no lost split, no
# missing object while a reader still needs it, and no document counted twice.
#
# What a pass over several lineages does, and what this file proves:
#   * `select_merge` runs over the union of all lineages; each candidate
#     carries its source shard id.
#   * the merge output is folded into the reserved `_base` lineage (its single
#     writer is the compactor).
#   * each input is retired in the lineage it came from.
#   * `reap_drained_shards` removes the writer shards that folded fully into
#     `_base`, which bounds the live shard count (and with it the cost of a
#     cross-shard read).
#   * the merged-input skip over the union keeps "publish into `_base`, then
#     retire in the source" atomic to a reader.
#
# The tests:
#   1  test_no_lost_split_across_shards   — ingest into K writer shards, fold:
#      every document is present and searchable in the merged `_base` split.
#   2  test_no_404_mvcc_cross_shard       — a reader during publish(`_base`) ->
#      retire(source) -> grace -> reap never finds an object missing and never
#      counts a document twice; the clock is driven by hand.
#   3  test_shard_count_bounded           — after the fold and the reap the
#      drained writer shards are removed and the live shard count drops to one
#      (`_base`) plus any still-active writer.
#   4  test_back_compat_legacy_folds_in   — the unsharded lineage `<index>/meta`
#      folds in as one more source shard (shard id "").
#   5  test_mergecandidate_carries_shard  — the (shard_id, seq) routing key
#      survives `select_merge`.
#   6  test_perf_read_amp_drops           — many writer shards, fold and reap:
#      the live shard count drops and the cross-shard read still returns the
#      merged survivors. It prints the live-shard counts and the read p50 before
#      and after.
#
# The fold is driven by a small in-file driver that performs the same sequence
# as `compact_once` (cross-shard snapshot, select with shard id, write the
# object and publish into `_base`, retire in the source shard, grace-gated
# reap, drained-shard reap), so the tests can assert the state after each
# stage. `test_search_compact_once.mojo` drives `compact_once` itself. Split
# objects are stored at their object keys in the shared in-memory store.
# =============================================================================

from std.time import perf_counter_ns
from std.testing import (
    TestSuite,
    assert_equal,
    assert_not_equal,
    assert_true,
    assert_false,
)

from komira_objectstore import (
    CasManifestStore,
    RetryPolicy,
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_json import parse_json_value
from komira_objectstore.sublineage_shard_keys import (
    LINEAGE_BASE_SHARD,
    _discover_shard_ids,
)

from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.split import SplitView
from komira_search.source import QueryIR, SearchCore

from komira_search_catalog.generation import read_retired_shards
from komira_search_catalog import (
    SplitSummary,
    SearchMetastore,
    ShardedLiveSplitEntry,
    make_split_summary,
    make_merged_split_summary,
    make_shard_id,
    is_reserved_shard_id,
    shard_manifest_prefix,
    list_live_splits_across_shards,
    list_live_splits_across_shards_with_seq,
    generation_across_shards,
    reap_drained_shards,
    DrainedShardReapResult,
)

from komira_search_compaction.select import (
    MergeCandidate,
    MergePlan,
    select_merge,
    MERGE_FACTOR,
)
from komira_search_compaction.merge_split import (
    merge_split_bytes,
    MergeResult,
    content_addressed_merge_key,
)


# -----------------------------------------------------------------------------
# Builders (mirror test_search_compaction / test_search_sublineage_sharding).
# -----------------------------------------------------------------------------


comptime _META: String = "index/logs/meta"
"""The index meta-root prefix (the dispatcher's `_manifest_prefix` output)."""


def _uuid(seed: Int) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((seed * 7 + i * 13) & 0xFF)
    return u^


def _uuid_eq(a: Array[UInt8, 16], b: Array[UInt8, 16]) -> Bool:
    for i in range(16):
        if a[i] != b[i]:
            return False
    return True


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _one_doc_ndjson(word: String, status: String, price: Int) -> String:
    return String(
        '{"index":{}}\n'
        + '{"body":"alpha '
        + word
        + '","status":"'
        + status
        + '","price":'
        + String(price)
        + "}\n"
    )


def _ingest_to_split(ndjson: String, seed: Int) raises -> List[UInt8]:
    """Bulk NDJSON (an action line, then a document line, per document) into one
    real split: the document lines become a `body` text column, a verbatim
    `_source` column, a `status` keyword column and a `price` int64 column, and
    the `SearchSink` writes them as a split with the UUID of `seed`."""
    var bodies = List[String]()
    var sources = List[String]()
    var statuses = List[String]()
    var prices = List[Int64]()
    for line in ndjson.split("\n"):
        var text = String(line)
        if text.byte_length() == 0:
            continue
        var doc = parse_json_value(text)
        if not doc.has("body"):
            continue  # the action line
        bodies.append(doc.get("body").as_string())
        sources.append(text^)
        statuses.append(doc.get("status").as_string())
        prices.append(doc.get("price").as_int64())
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("status", ArrowType.STRING, False))
    sb.add_field(Field("price", ArrowType.INT64, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(4)
    rb.add_column(Column.from_string(StringArray.from_strings(bodies)))
    rb.add_column(Column.from_string(StringArray.from_strings(sources)))
    rb.add_column(Column.from_string(StringArray.from_strings(statuses)))
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(prices)
        )
    )
    var batch = rb.build(schema.copy())
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String("logs"),
        String("body"),
        _uuid(seed),
    )
    sink.init_sink(schema)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def _search_sources(bytes: List[UInt8], term: String) raises -> List[String]:
    """Search `bytes` for `term`, return each hit's `_source` blob."""
    var core = SearchCore(bytes.copy())
    var q = QueryIR(String("body"), term, 1000, AnalyzerConfig.text("body"))
    var res = core.search(q^)
    var out = List[String]()
    for r in range(res.batch.num_rows()):
        out.append(res.batch.column_at(2).as_string().get(r))
    return out^


def _count_str(xs: List[String], v: String) -> Int:
    var c = 0
    for i in range(len(xs)):
        if xs[i] == v:
            c += 1
    return c


def _contains_str(xs: List[String], v: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def _shard_meta(
    store: SharedInMemoryConditionalStore, shard_id: String
) raises -> SearchMetastore[SharedInMemoryConditionalStore]:
    """A SearchMetastore bound to one writer shard's sub-lineage
    `<_META>/_lineage/<shard_id>` (or `_base` for the fold target) over a CLONE
    of the shared store."""
    var lineage = shard_manifest_prefix(_META, shard_id)
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store.clone(), lineage^, RetryPolicy.fast_test()
    )
    return SearchMetastore[SharedInMemoryConditionalStore](
        manifest^, String("logs")
    )


def _legacy_meta(
    store: SharedInMemoryConditionalStore,
) raises -> SearchMetastore[SharedInMemoryConditionalStore]:
    """A SearchMetastore bound to the LEGACY single lineage (bare `<_META>`)."""
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store.clone(), _META, RetryPolicy.fast_test()
    )
    return SearchMetastore[SharedInMemoryConditionalStore](
        manifest^, String("logs")
    )


def _object_key(idx: Int) -> String:
    return String("prefix/logs/splits/raw" + String(idx) + ".split")


def _publish_raw_to_shard(
    store: SharedInMemoryConditionalStore,
    shard_id: String,
    bts: List[UInt8],
    okey: String,
) raises -> Int64:
    """PUT the `.split` DATA object into the shared store (models the object store) THEN
    CAS-publish the summary into the shard's sub-lineage. Returns the chunk_seq
    the append landed at (for the retire route). The summary's UUID + footer come
    from the real split bytes."""
    _ = store.put(Path.parse(okey), bts.copy())
    var view = SplitView.parse(bts.copy())
    var summ = make_split_summary(
        view.split_uuid(),
        Int64(view.doc_count()),
        Int64(len(bts)),
        Int64(view.min_doc_id()),
        Int64(view.max_doc_id()),
        String("logs"),
        String("body"),
        okey,
    )
    var meta = _shard_meta(store, shard_id)
    var r = meta.publish(summ^)
    return r.chunk_seq


def _resolve_bytes_for_uuid(
    raw: List[List[UInt8]], u: Array[UInt8, 16]
) raises -> List[UInt8]:
    for i in range(len(raw)):
        var v = SplitView.parse(raw[i].copy())
        if _uuid_eq(v.split_uuid(), u):
            return raw[i].copy()
    raise Error("no raw split with the requested UUID")


# =============================================================================
# The CROSS-SHARD compaction DRIVER (the in-memory twin of compact_once's body,
# cross-shard snapshot -> select-with-shard_id -> publish into `_base` ->
# retire in source shards -> per-shard grace reap -> reap_drained_shards).
# =============================================================================


@fieldwise_init
struct _DriveResult(Copyable, Movable, Deinitable):
    var merged: Bool
    var inputs_merged: Int
    var merged_uuid: Array[UInt8, 16]
    var merged_object_key: String
    var merged_bytes_len: Int


def _drive_cross_shard_compaction(
    store: SharedInMemoryConditionalStore,
    raw_bytes: List[List[UInt8]],
    merged_uuid: Array[UInt8, 16],
    now_ms: Int64,
) raises -> _DriveResult:
    """Run ONE cross-shard fold pass (the in-memory twin of compact_once). Does
    NOT reap (the caller drives the grace clock for the MVCC test); shard reap is
    a separate explicit call so the tests can assert the live-shard count at each
    stage."""
    # 1. cross-shard snapshot (+ shard_id).
    var snapshot = list_live_splits_across_shards_with_seq(
        store, _META, String("logs")
    )
    # 2. select over the union (each candidate carries its source shard_id).
    var candidates = List[MergeCandidate]()
    for i in range(len(snapshot)):
        candidates.append(
            MergeCandidate(
                snapshot[i].shard_id.copy(),
                snapshot[i].chunk_seq,
                snapshot[i].summary.copy(),
            )
        )
    var plan = select_merge(candidates)
    if not plan.should_merge():
        return _DriveResult(False, 0, merged_uuid.copy(), String(""), 0)

    # 3a. gather the selected inputs' bytes + their (shard_id, seq) route.
    var input_bytes = List[List[UInt8]]()
    var input_uuids = List[Array[UInt8, 16]]()
    var retire_shards = List[String]()
    var retire_seqs = List[Int64]()
    for i in range(plan.num_selected()):
        ref cand = plan.selected[i]
        input_bytes.append(
            _resolve_bytes_for_uuid(raw_bytes, cand.summary.split_uuid)
        )
        input_uuids.append(cand.summary.split_uuid.copy())
        retire_shards.append(cand.shard_id.copy())
        retire_seqs.append(cand.chunk_seq)

    var object_key = content_addressed_merge_key(
        String("prefix"), String("logs"), input_uuids
    )

    # 3b. merge.
    var mr = merge_split_bytes(
        input_bytes^,
        String("logs"),
        String("bucket"),
        String("prefix"),
        String("body"),
        merged_uuid,
    )
    var merge_ops = mr.merge_ops
    var input_uuids_flat = mr.input_uuids_flat.copy()
    var merged_view = SplitView.parse(mr.split_bytes.copy())
    var merged_doc_count = Int64(merged_view.doc_count())
    var merged_min_id = Int64(merged_view.min_doc_id())
    var merged_max_id = Int64(merged_view.max_doc_id())
    var merged_byte_len = len(mr.split_bytes)
    var split_bytes = mr.take_split_bytes()

    # 3c. PUBLISH the merged split INTO `_base` (PUT the .split first, then the
    # CAS-append — the durability order). The compactor is the sole writer of
    # `_base`.
    _ = store.put(Path.parse(object_key), split_bytes^)
    var m_summ = make_merged_split_summary(
        merged_uuid.copy(),
        merged_doc_count,
        Int64(merged_byte_len),
        merged_min_id,
        merged_max_id,
        String("logs"),
        String("body"),
        object_key.copy(),
        merge_ops,
        input_uuids_flat^,
    )
    var base_meta = _shard_meta(store, LINEAGE_BASE_SHARD)
    _ = base_meta.publish(m_summ^)

    # 3d. RETIRE each input in ITS SOURCE shard lineage (per shard).
    for i in range(len(retire_seqs)):
        var sm: SearchMetastore[SharedInMemoryConditionalStore]
        if retire_shards[i].byte_length() == 0:
            sm = _legacy_meta(store)
        else:
            sm = _shard_meta(store, retire_shards[i])
        sm.retire_at(retire_seqs[i], now_ms)
        _ = sm^

    return _DriveResult(
        True,
        plan.num_selected(),
        merged_uuid.copy(),
        object_key^,
        merged_byte_len,
    )


def _reap_all_shards_past_grace(
    store: SharedInMemoryConditionalStore,
    now_ms: Int64,
    grace_ms: Int64,
) raises -> Int:
    """The cross-shard grace-gated CHUNK reaper (the in-memory twin of
    _reap_past_grace_tombstones_cross_shard, minus the `.split` delete which the
    drained-shard reap handles via list+delete). For every discovered shard +
    the legacy lineage, reap each past-grace tombstoned chunk. Returns the chunk
    reap count."""
    var reaped = 0
    var shard_ids = _discover_for_test(store)
    for si in range(len(shard_ids)):
        var meta = _shard_meta(store, shard_ids[si])
        var tombs = meta.tombstoned_seqs()
        for t in range(len(tombs)):
            # Capture + delete the .split DATA object before the chunk reap.
            try:
                var okey = meta.tombstoned_chunk_object_key(tombs[t])
                if now_ms - meta.tombstone_schedule_ts(tombs[t]) >= grace_ms:
                    if okey.byte_length() > 0:
                        store.delete(Path.parse(okey))
            except e:
                _ = String(e)
            if meta.reap_chunk(tombs[t], now_ms, grace_ms):
                reaped += 1
        _ = meta^
    # The legacy lineage.
    var lmeta = _legacy_meta(store)
    var ltombs = lmeta.tombstoned_seqs()
    for t in range(len(ltombs)):
        try:
            var okey = lmeta.tombstoned_chunk_object_key(ltombs[t])
            if now_ms - lmeta.tombstone_schedule_ts(ltombs[t]) >= grace_ms:
                if okey.byte_length() > 0:
                    store.delete(Path.parse(okey))
        except e:
            _ = String(e)
        if lmeta.reap_chunk(ltombs[t], now_ms, grace_ms):
            reaped += 1
    _ = lmeta^
    return reaped


def _discover_for_test(
    store: SharedInMemoryConditionalStore,
) raises -> List[String]:
    """Re-use the metastore's shard discovery (the `_lineage/` flat scan)."""
    return _discover_shard_ids(store, _META)


def _live_shard_ids(
    store: SharedInMemoryConditionalStore,
) raises -> List[String]:
    """The sub-lineage shards a cross-shard read still replays: those under
    `<_META>/_lineage/` that `reap_drained_shards` has not retired. A retired
    shard keeps a seal (it is never deleted, because deleting it would free
    the slot its writer would publish into next) and is listed in the
    retired-shards record, and the cross-shard read skips it."""
    var retired = read_retired_shards(store, _META)
    var out = List[String]()
    var all_ids = _discover_for_test(store)
    for i in range(len(all_ids)):
        if retired.find(all_ids[i]) < 0:
            out.append(all_ids[i])
        else:
            # A retired shard holds no live split and no pending retirement.
            var mf = CasManifestStore[SharedInMemoryConditionalStore](
                store.clone(),
                shard_manifest_prefix(String(_META), all_ids[i]),
                RetryPolicy.fast_test(),
            )
            var m = SearchMetastore[SharedInMemoryConditionalStore](
                mf^, String("logs")
            )
            assert_equal(len(m.list_live_splits()), 0, "retired: no live split")
            assert_equal(len(m.tombstoned_seqs()), 0, "retired: no retirement")
            _ = m^
    return out^


def _live_shard_count(store: SharedInMemoryConditionalStore) raises -> Int:
    """The number of LIVE sub-lineage shards (the read-amplification metric:
    each costs one HEAD on a cross-shard read). Excludes retired shards and
    the unsharded lineage (it has no `_lineage/` segment)."""
    return len(_live_shard_ids(store))


# =============================================================================
# TEST 5 — MergeCandidate carries the (shard_id, seq) routing key through the
# pure policy (cheap; run it first).
# =============================================================================


def test_mergecandidate_carries_shard() raises:
    # Build candidates from DISTINCT shards; assert select_merge preserves each
    # candidate's source shard_id (a pure carry-through — the policy is unchanged).
    var cands = List[MergeCandidate]()
    for i in range(MERGE_FACTOR):
        var s = make_split_summary(
            _uuid(i), Int64(1), Int64((MERGE_FACTOR - i) * 1000),
            Int64(0), Int64(0),
            String("logs"), String("body"),
            String("k/s" + String(i) + ".split"),
        )
        # shard_id encodes the source so we can assert it survives the sort.
        cands.append(MergeCandidate(String("shard-" + String(i)), Int64(i), s^))
    var plan = select_merge(cands)
    assert_true(plan.should_merge(), "5: >=MERGE_FACTOR raw -> merge")
    assert_equal(plan.num_selected(), MERGE_FACTOR, "5: selects MERGE_FACTOR")
    # Each selected candidate's shard_id matches its seq (the carry-through is
    # intact through the smallest-first sort: candidate i had seq i + shard-i).
    for k in range(plan.num_selected()):
        ref c = plan.selected[k]
        var expect = String("shard-" + String(Int(c.chunk_seq)))
        assert_equal(
            c.shard_id, expect, "5: shard_id carried through the policy sort"
        )

    # The reserved-name guard: a writer can never mint `_base`.
    assert_true(
        is_reserved_shard_id(LINEAGE_BASE_SHARD), "5: _base is reserved"
    )
    assert_false(
        is_reserved_shard_id(make_shard_id(String("node"), 0)),
        "5: a writer shard_id is NOT reserved",
    )


# =============================================================================
# TEST 1 — NO-LOST-SPLIT across shards: ingest into K writer shards, fold ->
# every doc present + searchable in the merged `_base`.
# =============================================================================


def test_no_lost_split_across_shards() raises:
    var store = SharedInMemoryConditionalStore()
    # K writer shards, each publishing one raw single-doc split. K == MERGE_FACTOR
    # so the fold fires. Each doc carries `alpha <wN>` (so all are searchable by
    # "alpha" and each _source is distinct).
    var k = MERGE_FACTOR
    var raw_bytes = List[List[UInt8]]()
    for i in range(k):
        var word = String("w") + String(i)
        var bts = _ingest_to_split(
            _one_doc_ndjson(
                word, "active" if i % 2 == 0 else "sold", 10 * (i + 1)
            ),
            i,
        )
        raw_bytes.append(bts.copy())
        var shard_id = make_shard_id(String("node"), i)
        _ = _publish_raw_to_shard(store, shard_id, bts, _object_key(i))

    # Before the fold: K live writer shards, K live splits.
    assert_equal(_live_shard_count(store), k, "1: K live writer shards pre-fold")
    var before = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(before), k, "1: K live splits pre-fold")

    # FOLD: cross-shard snapshot -> select -> publish merged into `_base` ->
    # retire each input in its source shard.
    var merged_uuid = _uuid(9001)
    comptime NOW: Int64 = 5_000_000
    var dr = _drive_cross_shard_compaction(store, raw_bytes, merged_uuid, NOW)
    assert_true(dr.merged, "1: the cross-shard fold fired")
    assert_equal(dr.inputs_merged, k, "1: all K inputs folded")

    # After the fold (inputs tombstoned in their source shards, merged split live
    # in `_base`): the cross-shard read returns EXACTLY the one merged `_base`
    # split (the merged-input skip hides the still-present-but-tombstoned... here the inputs
    # are tombstoned, so the live set is just the merged split).
    var after = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(after), 1, "1: live set collapsed K -> 1 (merged in _base)")
    assert_true(after[0].is_merged(), "1: the lone live split is the merged one")
    assert_equal(after[0].doc_count, Int64(k), "1: merged carries all K docs")

    # NO LOST SPLIT: every doc is present + searchable in the merged `_base`
    # split (re-search the merged bytes for "alpha" — present in every doc).
    var merged_bytes = store.get(Path.parse(dr.merged_object_key))
    var hits = _search_sources(merged_bytes, String("alpha"))
    assert_equal(len(hits), k, "1: all K docs searchable in the merged _base split")
    for h in range(len(hits)):
        assert_equal(_count_str(hits, hits[h]), 1, "1: each doc EXACTLY once")

    _ = store^


# =============================================================================
# TEST 2 — NO-404 MVCC cross-shard: a reader during publish(`_base`)->
# retire(source)->grace->reap NEVER 404s and NEVER double-counts.
# =============================================================================


def test_no_404_mvcc_cross_shard() raises:
    var store = SharedInMemoryConditionalStore()
    var k = MERGE_FACTOR
    var raw_bytes = List[List[UInt8]]()
    for i in range(k):
        var word = String("w") + String(i)
        var bts = _ingest_to_split(
            _one_doc_ndjson(word, "active", 10 * (i + 1)), i
        )
        raw_bytes.append(bts.copy())
        _ = _publish_raw_to_shard(
            store, make_shard_id(String("node"), i), bts, _object_key(i)
        )

    comptime T0: Int64 = 7_000_000
    comptime GRACE: Int64 = 60_000

    # An in-flight reader snapshots the live set BEFORE the fold (sees the K raw
    # inputs across their shards).
    var pre_fold = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(pre_fold), k, "2: pre-fold reader sees K raw inputs")

    # FOLD: publish merged into `_base` + retire each input in its source shard.
    var dr = _drive_cross_shard_compaction(store, raw_bytes, _uuid(9002), T0)
    assert_true(dr.merged, "2: fold fired")

    # WINDOW: immediately after publish(`_base`)+retire(source) — the inputs are
    # tombstoned but STILL PHYSICALLY PRESENT (within grace). A NEW reader sees
    # ONLY the merged split (the merged-input skip + the retirement), counting each doc
    # exactly once (NO double-count even though both `_base` AND the input shards
    # hold the docs).
    var in_window = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(
        len(in_window), 1, "2: in-window read sees ONLY the merged split (no dup)"
    )
    var merged_bytes = store.get(Path.parse(dr.merged_object_key))
    var window_hits = _search_sources(merged_bytes, String("alpha"))
    assert_equal(
        len(window_hits), k, "2: in-window search returns each doc exactly once"
    )
    for h in range(len(window_hits)):
        assert_equal(
            _count_str(window_hits, window_hits[h]), 1, "2: no double-count"
        )

    # The in-flight reader (holding the pre-fold snapshot) can STILL READ its
    # snapshotted input `.split` objects (NO 404) — they are physically present
    # within the grace window. Prove by GETting every input object_key.
    for i in range(k):
        var still = store.get(Path.parse(_object_key(i)))
        assert_true(len(still) > 0, "2: input .split readable in-window (NO 404)")

    # WITHIN GRACE: the reaper does NOT delete (returns 0 reaped).
    var reaped_early = _reap_all_shards_past_grace(
        store, T0 + GRACE // 2, GRACE
    )
    assert_equal(reaped_early, 0, "2: nothing reaped inside grace (MVCC safe)")
    # The input objects are STILL present (no 404 mid-fold).
    for i in range(k):
        var still2 = store.get(Path.parse(_object_key(i)))
        assert_true(len(still2) > 0, "2: input .split still present pre-grace")

    # AFTER GRACE: the reaper deletes the tombstoned chunks + their `.split`
    # objects. The merged split is UNTOUCHED (it is not tombstoned).
    var reaped_late = _reap_all_shards_past_grace(store, T0 + GRACE + 1, GRACE)
    assert_equal(reaped_late, k, "2: all K input chunks reaped after grace")
    # The cross-shard read STILL returns the merged split (no 404 — `_base` is
    # live), each doc exactly once.
    var post_reap = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(
        len(post_reap), 1, "2: post-reap live set is just the merged _base split"
    )
    assert_true(post_reap[0].is_merged(), "2: merged split survives the reap")
    var merged_bytes2 = store.get(Path.parse(dr.merged_object_key))
    assert_true(len(merged_bytes2) > 0, "2: merged .split present post-reap")

    _ = store^


# =============================================================================
# TEST 3 — SHARD COUNT BOUNDED: after the fold + reap, the drained writer shards
# are GC'd; the live shard count drops to ~1 (`_base`) + any active writer.
# =============================================================================


def test_shard_count_bounded() raises:
    var store = SharedInMemoryConditionalStore()
    var k = MERGE_FACTOR
    var raw_bytes = List[List[UInt8]]()
    for i in range(k):
        var word = String("w") + String(i)
        var bts = _ingest_to_split(
            _one_doc_ndjson(word, "active", 10 * (i + 1)), i
        )
        raw_bytes.append(bts.copy())
        _ = _publish_raw_to_shard(
            store, make_shard_id(String("node"), i), bts, _object_key(i)
        )

    # K live writer shards before the fold (the read-amp == K).
    assert_equal(_live_shard_count(store), k, "3: K live writer shards pre-fold")

    comptime T0: Int64 = 9_000_000
    comptime GRACE: Int64 = 60_000

    # FOLD + RETIRE (inputs tombstoned in their source shards).
    var dr = _drive_cross_shard_compaction(store, raw_bytes, _uuid(9003), T0)
    assert_true(dr.merged, "3: fold fired")
    # After the fold but BEFORE grace: a drained-shard reap must NOT reap (the
    # writer shards still have within-grace tombstones — an in-flight reader may
    # need them). The live shard count INCLUDES the K writer shards + `_base`.
    var early_reap = reap_drained_shards(store, _META, String("logs"))
    assert_equal(
        early_reap.shards_reaped, 0, "3: no shard reaped pre-grace (MVCC safe)"
    )
    # K writer shards + `_base` = K+1 live sub-lineages pre-grace.
    assert_equal(
        _live_shard_count(store),
        k + 1,
        "3: K writer shards + _base live pre-grace",
    )

    # GRACE elapses: reap the past-grace chunk tombstones (so the writer shards
    # drain to empty — zero live + zero pending tombstones).
    _ = _reap_all_shards_past_grace(store, T0 + GRACE + 1, GRACE)

    # Now reap the DRAINED writer shards. All K writer shards folded fully into
    # `_base` -> all K are drained -> all K are GC'd. `_base` is NEVER reaped (the
    # live fold target).
    var shard_reap = reap_drained_shards(store, _META, String("logs"))
    assert_equal(
        shard_reap.shards_examined,
        k,
        "3: K writer shards examined (excludes _base)",
    )
    assert_equal(
        shard_reap.shards_reaped, k, "3: all K drained writer shards reaped"
    )
    assert_true(
        shard_reap.objects_deleted > 0, "3: residual shard objects deleted"
    )

    # THE BOUND: the live shard count drops to 1 (just `_base`). Read-amp went
    # from K -> 1 (the read-amplification control the whole follow-up exists for).
    assert_equal(
        _live_shard_count(store),
        1,
        "3: live shard count BOUNDED to 1 (_base) after the fold + reap",
    )
    # `_base` survived (it is the live fold target — never reaped).
    var surviving = _live_shard_ids(store)
    assert_equal(surviving[0], LINEAGE_BASE_SHARD, "3: the survivor is _base")

    # The cross-shard read still returns the merged split (correctness preserved
    # through the shard reap).
    var live = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(live), 1, "3: merged split still live after shard reap")
    assert_true(live[0].is_merged(), "3: it is the merged split")

    # IDEMPOTENT: a second drained-shard reap finds the shards already gone.
    var reap_again = reap_drained_shards(store, _META, String("logs"))
    assert_equal(
        reap_again.shards_reaped, 0, "3: 2nd reap is a no-op (shards already GC'd)"
    )

    # A still-ACTIVE writer is NOT reaped: publish a fresh raw split to a NEW
    # writer shard, then a drained-shard reap leaves it (it has a live split).
    var fresh_bts = _ingest_to_split(
        _one_doc_ndjson(String("fresh"), "active", 999), 5000
    )
    _ = _publish_raw_to_shard(
        store, make_shard_id(String("node"), 777), fresh_bts, _object_key(777)
    )
    assert_equal(
        _live_shard_count(store), 2, "3: _base + the new active writer shard"
    )
    var reap_active = reap_drained_shards(store, _META, String("logs"))
    assert_equal(
        reap_active.shards_reaped,
        0,
        "3: the active writer shard (live split) is NOT reaped",
    )
    assert_equal(
        _live_shard_count(store), 2, "3: active writer shard preserved"
    )

    _ = store^


# =============================================================================
# TEST 4 — BACK-COMPAT: the legacy single lineage `<index>/meta` folds in as one
# more (shard_id "") source shard.
# =============================================================================


def test_back_compat_legacy_folds_in() raises:
    var store = SharedInMemoryConditionalStore()
    # Publish HALF the inputs to the LEGACY single lineage (the pre-sharding
    # prefix, no `_lineage/` segment) + HALF to writer shards (a mixed index).
    var k = MERGE_FACTOR
    var raw_bytes = List[List[UInt8]]()
    var legacy_seqs = List[Int64]()
    for i in range(k):
        var word = String("w") + String(i)
        var bts = _ingest_to_split(
            _one_doc_ndjson(word, "active", 10 * (i + 1)), i
        )
        raw_bytes.append(bts.copy())
        var okey = _object_key(i)
        _ = store.put(Path.parse(okey), bts.copy())
        var view = SplitView.parse(bts.copy())
        var summ = make_split_summary(
            view.split_uuid(), Int64(view.doc_count()), Int64(len(bts)),
            Int64(view.min_doc_id()), Int64(view.max_doc_id()),
            String("logs"), String("body"), okey,
        )
        if i % 2 == 0:
            # legacy single lineage (the bare prefix).
            var lmeta = _legacy_meta(store)
            var r = lmeta.publish(summ^)
            legacy_seqs.append(r.chunk_seq)
            _ = lmeta^
        else:
            _ = _publish_raw_to_shard(
                store, make_shard_id(String("node"), i), bts, okey
            )

    # The cross-shard read sees the UNION (legacy + sharded) — K live splits.
    var before = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(before), k, "4: mixed (legacy + sharded) union pre-fold")

    comptime T0: Int64 = 11_000_000
    # FOLD: the legacy splits are candidates too (tagged shard_id "") and get
    # retired in the LEGACY lineage by the route.
    var dr = _drive_cross_shard_compaction(store, raw_bytes, _uuid(9004), T0)
    assert_true(dr.merged, "4: the cross-shard fold folded legacy + sharded")
    assert_equal(dr.inputs_merged, k, "4: all K (legacy + sharded) inputs folded")

    # After the fold: the merged `_base` split is the lone live split (the legacy
    # inputs were tombstoned in the LEGACY lineage, the sharded inputs in their
    # shards — the per-shard retire routed correctly).
    var after = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(after), 1, "4: legacy + sharded folded -> 1 merged split")
    assert_true(after[0].is_merged(), "4: merged split")
    assert_equal(after[0].doc_count, Int64(k), "4: merged has all K docs")

    # The legacy lineage's chunks are tombstoned (the retire routed to "" = the
    # bare prefix). Assert the legacy lineage now lists zero live splits.
    var lmeta_check = _legacy_meta(store)
    var legacy_live = lmeta_check.list_live_splits()
    assert_equal(
        len(legacy_live), 0, "4: legacy lineage drained (retire routed to it)"
    )
    _ = lmeta_check^

    # All K docs searchable in the merged split.
    var merged_bytes = store.get(Path.parse(dr.merged_object_key))
    var hits = _search_sources(merged_bytes, String("alpha"))
    assert_equal(len(hits), k, "4: all K (legacy + sharded) docs searchable")

    _ = store^


# =============================================================================
# TEST 6 — PERF: read-amplification drops after the fold + reap. Model MANY
# writer shards -> #live-shards + read p50 BEFORE; fold + reap; #live-shards +
# read p50 AFTER. The read-merge cost is LINEAR in the live shard count, so the
# shard reap is the read-amp control.
# =============================================================================


def _read_p50_ns(
    store: SharedInMemoryConditionalStore, reps: Int
) raises -> Int64:
    """The median (p50) cross-shard read-merge wall over `reps` runs (the
    read-amplification proxy — one HEAD + replay per live shard)."""
    var samples = List[Int64]()
    for _r in range(reps):
        var t0 = perf_counter_ns()
        var live = list_live_splits_across_shards(store, _META, String("logs"))
        var t1 = perf_counter_ns()
        # Touch the result so the read is not optimized away.
        if len(live) < 0:
            print("unreachable")
        samples.append(Int64(t1 - t0))
    # median.
    var n = len(samples)
    for i in range(1, n):
        var key = samples[i]
        var j = i - 1
        while j >= 0 and samples[j] > key:
            samples[j + 1] = samples[j]
            j -= 1
        samples[j + 1] = key
    return samples[n // 2]


def test_perf_read_amp_drops() raises:
    var store = SharedInMemoryConditionalStore()
    # Model MANY writer shards (a node that accumulated shards over restarts).
    # Each writer shard publishes MERGE_FACTOR raw splits so the fold fires and
    # each shard fully drains. n_shards * MERGE_FACTOR total raw splits.
    var n_shards = 6
    var raw_bytes = List[List[UInt8]]()
    var doc_idx = 0
    for s in range(n_shards):
        var shard_id = make_shard_id(String("node"), s)
        for j in range(MERGE_FACTOR):
            var word = String("s") + String(s) + String("d") + String(j)
            var bts = _ingest_to_split(
                _one_doc_ndjson(word, "active", 10 + doc_idx), doc_idx
            )
            raw_bytes.append(bts.copy())
            _ = _publish_raw_to_shard(store, shard_id, bts, _object_key(doc_idx))
            doc_idx += 1

    var total_raw = n_shards * MERGE_FACTOR
    var shards_before = _live_shard_count(store)
    var live_before = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(shards_before, n_shards, "6: n_shards live writer shards before")
    assert_equal(len(live_before), total_raw, "6: all raw splits live before")
    var p50_before = _read_p50_ns(store, 9)

    # FOLD: repeatedly run the cross-shard fold until no merge fires (each pass
    # folds up to MAX_MERGE_FACTOR inputs; loop bounds the passes). Then reap.
    comptime T0: Int64 = 13_000_000
    comptime GRACE: Int64 = 60_000
    var passes = 0
    var merged_uuid_seed = 9100
    while passes < 64:
        var dr = _drive_cross_shard_compaction(
            store, raw_bytes, _uuid(merged_uuid_seed), T0
        )
        merged_uuid_seed += 1
        passes += 1
        if not dr.merged:
            break

    # Reap past-grace tombstones, then the drained writer shards.
    _ = _reap_all_shards_past_grace(store, T0 + GRACE + 1, GRACE)
    var shard_reap = reap_drained_shards(store, _META, String("logs"))

    var shards_after = _live_shard_count(store)
    var p50_after = _read_p50_ns(store, 9)

    # THE READ-AMP BOUND: the live shard count DROPPED (the writer shards drained
    # + reaped; only `_base` remains, plus possibly a `_base` that is itself the
    # only survivor). It MUST be strictly fewer than before.
    assert_true(
        shards_after < shards_before,
        "6: live shard count DROPPED after the fold + reap (read-amp control)",
    )
    assert_true(
        shards_after <= 1,
        "6: live shard count BOUNDED to <=1 (_base) after the full fold",
    )
    assert_true(
        shard_reap.shards_reaped >= n_shards - 1,
        "6: the drained writer shards were reaped",
    )

    # The cross-shard read is still CORRECT after the fold (a non-zero merged
    # result; every doc searchable would be redundant with tests 1/4 — here we
    # just assert the read returns the merged survivors, not a lost/empty set).
    var live_after = list_live_splits_across_shards(store, _META, String("logs"))
    assert_true(len(live_after) >= 1, "6: a merged survivor is live post-fold")

    print(
        "[search-cas sharding step4 PERF] read-amp: shards "
        + String(shards_before)
        + " -> "
        + String(shards_after)
        + " (reaped "
        + String(shard_reap.shards_reaped)
        + "); read p50 "
        + String(Int(p50_before))
        + "ns -> "
        + String(Int(p50_after))
        + "ns ("
        + String(total_raw)
        + " raw splits folded over "
        + String(passes)
        + " passes)"
    )

    _ = store^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
