# =============================================================================
# test_search_sublineage_sharding.mojo
#   Per-writer manifest sub-lineages for one search index.
# =============================================================================
#
# N concurrent writers appending to one index lineage all race one head slot,
# and most attempts become 412 retries. With sharding, each writer appends to
# its own sub-lineage `<index>/meta/_lineage/<shard_id>/...`, where it is the
# only writer and wins on the first attempt; readers enumerate the
# sub-lineages plus the unsharded lineage and merge the split sets.
#
#   1. test_shard_id_collision_free: `make_shard_id` differs for different
#      (node, worker) pairs and is stable for a fixed pair.
#   2. test_no_412_storm: N writers on distinct shards each win every append on
#      the first attempt, and the cross-shard read returns all N*M splits. A
#      control with two handles on one shard and a staged collision shows the
#      retry path firing, so it is the sharding that removes the contention.
#   3. test_no_lost_split_concurrent: K OS-thread writers, each on its own
#      shard. After join, a fresh cross-shard read sees the whole union, each
#      shard's sequence numbers are gapless, and no append retried.
#   4. test_read_merge_and_generation: the read merges K shards, the
#      generation is the sum of chunk counts, and a split is readable as soon
#      as its append lands.
#   5. test_back_compat_legacy_lineage: an index written before sharding
#      (`<index>/meta/manifest/...`, no `_lineage/`) still reads correctly, and
#      a mixed index serves the union.
#   6. test_merged_split_hides_inputs_across_shards: a merged split in `_base`
#      hides its inputs even when they live in other writers' shards.
#
# Pointers: UnsafePointer appears only in the pthread void* ABI arguments. Each
# writer's results slot is an ArcPointer shared with the main thread, which
# reads it after join. No struct field holds a raw pointer or an address.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer, OwnedPointer, UnsafePointer, alloc
from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_core.collections.slab import Slab

from komira_objectstore import (
    CasManifestStore,
    RetryPolicy,
    SharedInMemoryConditionalStore,
    head_key,
)

from komira_search_meta.metastore import (
    SplitSummary,
    make_split_summary,
    make_merged_split_summary,
    make_shard_id,
    shard_manifest_prefix,
    SearchMetastore,
    list_live_splits_across_shards,
    list_live_splits_across_shards_with_seq,
    generation_across_shards,
)

@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin, for the C NULL arguments
    of pthread_create / pthread_join and the thread entry's return value.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer and `None` is the all-zero (NULL) bit pattern. Origin `o` is
    # concrete; the NULL value is never dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]



# -----------------------------------------------------------------------------
# Builders (mirror test_search_metastore_concurrent.mojo).
# -----------------------------------------------------------------------------


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


def _summary(seed: Int, doc_count: Int64) -> SplitSummary:
    return make_split_summary(
        _uuid(seed),
        doc_count,
        Int64(seed * 16 + 8),
        Int64(seed * 1000),
        Int64(seed * 1000 + Int(doc_count) - 1),
        String("logs"),
        String("body"),
        String("index/logs/splits/node-" + String(seed) + ".split"),
    )


# The index meta-root prefix used across the tests, in the
# `<key_prefix>/<index>/meta` layout.
comptime _META: String = "index/logs/meta"


def _shard_meta_impl(
    store: SharedInMemoryConditionalStore, shard_id: String
) raises -> SearchMetastore[SharedInMemoryConditionalStore]:
    """A SearchMetastore bound to ONE writer shard's sub-lineage
    `<_META>/_lineage/<shard_id>` over a CLONE of the shared store."""
    var lineage = shard_manifest_prefix(_META, shard_id)
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store.clone(), lineage^, RetryPolicy.fast_test()
    )
    return SearchMetastore[SharedInMemoryConditionalStore](
        manifest^, String("logs")
    )


# =============================================================================
# shard_id is collision-free
# =============================================================================


def test_shard_id_collision_free() raises:
    # Distinct worker_idx in the SAME process (same node_id, same pid) ->
    # distinct shard_id (the pid is constant within this test process; the
    # worker_idx is the differentiator).
    var a = make_shard_id(String("nodeA"), 0)
    var b = make_shard_id(String("nodeA"), 1)
    var c = make_shard_id(String("nodeB"), 0)
    assert_true(a != b, "distinct worker_idx -> distinct shard_id")
    assert_true(a != c, "distinct node_id -> distinct shard_id")
    assert_true(b != c, "distinct (node, worker) -> distinct shard_id")
    # STABLE for a fixed (node, worker) within one process (same pid).
    var a2 = make_shard_id(String("nodeA"), 0)
    assert_equal(a, a2, "shard_id stable for a fixed (node, pid, worker)")
    # An empty node_id still yields a per-worker distinct id (pid + worker).
    var e0 = make_shard_id(String(""), 0)
    var e1 = make_shard_id(String(""), 1)
    assert_true(e0 != e1, "empty node_id still distinct per worker_idx")
    # The shard_id is non-empty (carries the pid + worker even with empty node).
    assert_true(e0.byte_length() > 0, "shard_id non-empty even with empty node_id")


# =============================================================================
# No 412 storm: N writers on distinct shards each win every append on the
# first attempt (one thread, deterministic), plus a control on ONE shard.
# =============================================================================


def test_no_412_storm() raises:
    # N "writers", each with its OWN shard_id (the per-worker grain). All publish
    # to the SAME index's metastore root but into DISJOINT sub-lineages -> no
    # shared _HEAD slot -> every append wins on attempt 1.
    var store = SharedInMemoryConditionalStore()
    var n_writers = 8
    var m_per_writer = 4

    var total = 0
    for w in range(n_writers):
        var shard_id = make_shard_id(String("node"), w)
        var meta = _shard_meta_impl(store, shard_id)
        for j in range(m_per_writer):
            var seed = w * 1000 + j
            var r = meta.publish(_summary(seed, Int64(1 + (seed % 5))))
            # THE no-412-storm proof: a sole writer of its sub-lineage wins its
            # _HEAD slot on the FIRST attempt — no 412 retry.
            assert_equal(
                r.attempts,
                1,
                "every append wins first try (sole writer of its shard)",
            )
            total += 1

    # The cross-shard read returns ALL N*M splits with distinct UUIDs (no loss).
    var live = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(
        len(live), total, "cross-shard read returns ALL N*M splits (no loss)"
    )
    # Every published seed's UUID present exactly once.
    var found_each = True
    for w in range(n_writers):
        for j in range(m_per_writer):
            var want = _uuid(w * 1000 + j)
            var hits = 0
            for li in range(len(live)):
                if _uuid_eq(live[li].split_uuid, want):
                    hits += 1
            if hits != 1:
                found_each = False
    assert_true(found_each, "every split UUID present exactly once (sharded)")

    # ---- CONTROL: all writers on ONE shard_id -> the 412-retry path fires. ----
    # This proves the sharding (distinct shard_ids) is what removes the
    # contention. We force the contention deterministically by staling the shared
    # _HEAD so a second handle's append targets a TAKEN slot (the classic
    # CAS-collision the per-op shape pays under concurrency). With one shared
    # shard, two handles racing the SAME _HEAD see the 412 the sharding avoids.
    var control_store = SharedInMemoryConditionalStore()
    var shard_a = make_shard_id(String("nodeX"), 0)
    var meta_a = _shard_meta_impl(control_store, shard_a)
    var meta_b = _shard_meta_impl(control_store, shard_a)  # SAME shard_id.
    var lineage = shard_manifest_prefix(_META, shard_a)
    # A lands at seq 0; snapshot the seq-0 HEAD.
    var ra0 = meta_a.publish(_summary(900, Int64(2)))
    assert_equal(ra0.chunk_seq, Int64(0))
    var head_path = head_key(lineage)
    var stale_head = control_store.get(head_path.copy())
    # B lands at seq 1 (advances the shared HEAD).
    var rb1 = meta_b.publish(_summary(901, Int64(2)))
    assert_equal(rb1.chunk_seq, Int64(1))
    # Re-stale A's view (HEAD points at seq 0); A's next publish targets the
    # TAKEN seq 1 -> 412 -> RETRIES (attempts > 1) -> recovers at seq 2 (the
    # in-memory store is linearizable; with fast_test retries the loop recovers
    # by re-reading the now-current HEAD). The KEY assertion is attempts > 1 —
    # the contention the per-shard write path NEVER pays.
    _ = control_store.put(head_path.copy(), stale_head)
    var ra2 = meta_a.publish(_summary(902, Int64(2)))
    assert_true(
        ra2.attempts > 1,
        "CONTROL: same-shard contention fires the 412-retry path (attempts>1)",
    )

    _ = store^
    _ = control_store^


# =============================================================================
# No lost split under real concurrency: K OS threads, each to its OWN
# shard. After join a FRESH cross-shard read sees the complete union.
# =============================================================================


@fieldwise_init
struct _PubRecord(Copyable, Movable, Deinitable):
    var chunk_seq: Int64
    var seed: Int64
    var attempts: Int64
    var terminal_fail: Int64


struct _WriterResults(Movable, Deinitable):
    var records: List[_PubRecord]

    def __init__(out self):
        self.records = List[_PubRecord]()


struct _WriterArg(Movable, Deinitable):
    var store: SharedInMemoryConditionalStore
    var shard_id: String
    var node_id: Int64
    var num_publishes: Int64
    # This writer's own results slot, shared with the main thread, which
    # reads it only after joining this thread.
    var results: ArcPointer[_WriterResults]

    def __init__(
        out self,
        var store: SharedInMemoryConditionalStore,
        var shard_id: String,
        node_id: Int64,
        num_publishes: Int64,
        var results: ArcPointer[_WriterResults],
    ):
        self.store = store^
        self.shard_id = shard_id^
        self.node_id = node_id
        self.num_publishes = num_publishes
        self.results = results^


def _writer_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin]
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    # SAFETY: `arg` is the heap `_WriterArg*` from `alloc + init_pointee_move`.
    # Reconstruct the OwnedPointer so it frees at scope exit.
    var typed = arg.bitcast[_WriterArg]()
    var owned = OwnedPointer[_WriterArg](unsafe_from_raw_pointer=typed)
    try:
        _run_writer(owned[])
    except e:
        print("WARN _writer_entry: writer raised: ", String(e))
    _ = owned^
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _run_writer(mut arg: _WriterArg) raises:
    # Each writer appends only to its own results slot and publishes only to
    # its own shard sub-lineage, so writers never contend on a slot; the main
    # thread reads the slots after every writer has been joined.
    # Build a SearchMetastore over THIS writer's shard sub-lineage (a clone of
    # the shared store). Distinct shard_id per writer -> disjoint _HEAD slots.
    var lineage = shard_manifest_prefix(_META, arg.shard_id)
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store=arg.store.clone(),
        prefix=lineage^,
        retry=RetryPolicy.fast_test(),
    )
    var meta = SearchMetastore[SharedInMemoryConditionalStore](
        manifest^, String("logs")
    )
    var i = Int64(0)
    while i < arg.num_publishes:
        var seed = Int(arg.node_id) * 1000 + Int(i)
        var seq = Int64(-1)
        var attempts = Int64(0)
        var failed = Int64(0)
        try:
            var r = meta.publish(_summary(seed, Int64(1 + (seed % 5))))
            seq = r.chunk_seq
            attempts = Int64(r.attempts)
        except e:
            failed = Int64(1)
            _ = e
        arg.results[].records.append(
            _PubRecord(seq, Int64(seed), attempts, failed)
        )
        i += Int64(1)


def _spawn_writer(var arg: _WriterArg, mut tid_slot: Int64) raises -> Int32:
    # SAFETY: heap-box the arg, hand its address to pthread_create; the thread
    # reconstructs + frees it. The untracked origin appears only on the void*
    # ABI arguments.
    var raw = alloc[_WriterArg](1)
    UnsafePointer(to=raw[]).unsafe_write(arg^)
    var raw_void = raw.bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var slot_addr = UnsafePointer(to=tid_slot)
    return external_call["pthread_create", Int32](
        slot_addr.bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        _writer_entry,
        raw_void,
    )


def _join_writer(tid: Int64) -> Int32:
    return external_call["pthread_join", Int32](
        tid, _null_ptr[UInt8, MutUntrackedOrigin]()
    )


def _run_k_shard_stress(k: Int, publishes_per_node: Int64) raises:
    print(
        "[search-cas sharding] K="
        + String(k)
        + " writers (DISTINCT shards) x "
        + String(Int(publishes_per_node))
        + " publishes -> ONE index, cross-shard read"
    )

    var shared = SharedInMemoryConditionalStore()

    var results = Slab[ArcPointer[_WriterResults]]()
    for _w in range(k):
        results.append(ArcPointer[_WriterResults](_WriterResults()))
    var tids = List[Int64]()
    for _w in range(k):
        tids.append(Int64(0))

    var w = 0
    while w < k:
        # Each writer gets a DISTINCT shard_id (the per-worker grain).
        var shard_id = make_shard_id(String("node"), w)
        var arg = _WriterArg(
            store=shared.clone(),
            shard_id=shard_id^,
            node_id=Int64(w + 1),  # node ids 1..k (seed base node*1000).
            num_publishes=publishes_per_node,
            results=results[w].copy(),
        )
        var rc = _spawn_writer(arg^, tids[w])
        if rc != Int32(0):
            raise Error("pthread_create failed for writer " + String(w))
        w += 1

    w = 0
    while w < k:
        _ = _join_writer(tids[w])
        w += 1

    # ---- aggregate ----
    var expected = Int64(k) * publishes_per_node
    var commits = Int64(0)
    var terminal_fails = Int64(0)
    var max_attempts = Int64(0)
    # Per-shard seq accounting: each shard's seqs MUST be gapless {0..M-1}.
    for wi in range(k):
        ref recs = results[wi][].records
        var shard_seqs = List[Int64]()
        for ri in range(len(recs)):
            ref r = recs[ri]
            if r.terminal_fail == Int64(1):
                terminal_fails += Int64(1)
                continue
            commits += Int64(1)
            shard_seqs.append(r.chunk_seq)
            if r.attempts > max_attempts:
                max_attempts = r.attempts
        # Sole writer of its shard -> gapless {0..M-1}, no dup.
        _sort_i64(shard_seqs)
        var shard_ok = True
        for idx in range(len(shard_seqs)):
            if shard_seqs[idx] != Int64(idx):
                shard_ok = False
        assert_true(shard_ok, "per-shard seqs gapless {0..M-1} (no loss/dup)")

    # ZERO failures + ZERO retries — the whole point of the per-worker grain
    # (sole writer per sub-lineage). This is the 412-storm-eliminated proof.
    assert_equal(
        terminal_fails, Int64(0), "no terminal fail (sole-writer per shard)"
    )
    assert_equal(commits, expected, "every publish committed (K*M)")
    assert_equal(
        max_attempts,
        Int64(1),
        "ZERO retries: every append won first try (no cross-writer slot race)",
    )

    # ---- THE no-lost-split assertion at the cross-shard read layer: a FRESH
    #      reader (a node that did NOT write) enumerates ALL shards + merges and
    #      sees ALL K*M splits, each with a DISTINCT UUID. ----
    var live = list_live_splits_across_shards(shared, _META, String("logs"))
    assert_equal(
        Int64(len(live)),
        expected,
        "cross-shard read returns ALL published splits (no lost split)",
    )
    var found_each = True
    for wi in range(k):
        ref recs = results[wi][].records
        for ri in range(len(recs)):
            var seed = Int(recs[ri].seed)
            var want = _uuid(seed)
            var hits = 0
            for li in range(len(live)):
                if _uuid_eq(live[li].split_uuid, want):
                    hits += 1
            if hits != 1:
                found_each = False
    assert_true(
        found_each, "every writer's split UUID present EXACTLY once (no loss)"
    )

    print(
        "      commits="
        + String(Int(commits))
        + " live_splits="
        + String(len(live))
        + " max_attempts="
        + String(Int(max_attempts))
        + " terminal_fails="
        + String(Int(terminal_fails))
    )

    _ = results^
    _ = tids^
    _ = shared^


def _sort_i64(mut xs: List[Int64]):
    var n = len(xs)
    var i = 1
    while i < n:
        var key = xs[i]
        var j = i - 1
        while j >= 0 and xs[j] > key:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = key
        i += 1


def test_no_lost_split_concurrent() raises:
    # K = 2, 4, 8, 16 concurrent writers, each to its OWN shard. Every variant
    # asserts ALL K*M splits survive + zero retries + zero failures.
    var publishes_per_node = Int64(4)
    var ks = List[Int]()
    ks.append(2)
    ks.append(4)
    ks.append(8)
    ks.append(16)
    for i in range(len(ks)):
        _run_k_shard_stress(ks[i], publishes_per_node)


# =============================================================================
# Read merge, generation, and searchable on publish.
# =============================================================================


def test_read_merge_and_generation() raises:
    var store = SharedInMemoryConditionalStore()
    var k_shards = 5
    var per_shard = 3

    # Publish into K distinct shards.
    for s in range(k_shards):
        var meta = _shard_meta_impl(store, make_shard_id(String("n"), s))
        for j in range(per_shard):
            var seed = s * 100 + j
            _ = meta.publish(_summary(seed, Int64(1 + (seed % 5))))

    # The cross-shard read merges all shards.
    var live = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(live), k_shards * per_shard, "merged union across K shards")

    # generation == sum-of-num_chunks across shards (+ the legacy lineage, which
    # has 0 chunks here). K shards x per_shard chunks each.
    var gen = generation_across_shards(store, _META, String("logs"))
    assert_equal(
        gen,
        Int64(k_shards * per_shard),
        "generation = sum-of-num_chunks across shards",
    )

    # Searchable-on-publish: a brand-new split in a NEW shard is in the read set
    # the instant its append lands (no refresh/visibility knob).
    var fresh = _shard_meta_impl(store, make_shard_id(String("n"), 999))
    _ = fresh.publish(_summary(424242, Int64(7)))
    var live2 = list_live_splits_across_shards(store, _META, String("logs"))
    var saw_fresh = False
    for li in range(len(live2)):
        if _uuid_eq(live2[li].split_uuid, _uuid(424242)):
            saw_fresh = True
    assert_true(saw_fresh, "a newly-published split is immediately searchable")
    assert_equal(
        len(live2), k_shards * per_shard + 1, "the new split is in the union"
    )

    # generation BUMPED by the new publish (the plan-cache key changed).
    var gen2 = generation_across_shards(store, _META, String("logs"))
    assert_true(gen2 > gen, "generation bumped by the new publish")

    _ = store^


# =============================================================================
# Indexes written before sharding (the unsharded lineage).
# =============================================================================


def test_back_compat_legacy_lineage() raises:
    # (a) A LEGACY-ONLY index: splits at the LEGACY single lineage `<_META>`
    #     (the pre-sharding prefix, NO `_lineage/` segment). The cross-shard read
    #     MUST still serve it (the read path always replays the legacy lineage).
    var store = SharedInMemoryConditionalStore()
    var legacy_manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store.clone(), _META, RetryPolicy.fast_test()
    )
    var legacy_meta = SearchMetastore[SharedInMemoryConditionalStore](
        legacy_manifest^, String("logs")
    )
    var n_legacy = 4
    for s in range(n_legacy):
        _ = legacy_meta.publish(_summary(s, Int64(1 + s)))

    var live = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(
        len(live), n_legacy, "legacy single-lineage index still reads (back-compat)"
    )
    for s in range(n_legacy):
        var want = _uuid(s)
        var hits = 0
        for li in range(len(live)):
            if _uuid_eq(live[li].split_uuid, want):
                hits += 1
        assert_equal(hits, 1, "every legacy split present exactly once")

    # generation includes the legacy lineage's chunks.
    var gen = generation_across_shards(store, _META, String("logs"))
    assert_equal(gen, Int64(n_legacy), "generation counts the legacy lineage")

    # (b) A MIXED index: the legacy splits above PLUS new sharded splits. The
    #     read serves the UNION (the legacy lineage is just one more shard).
    var sharded = _shard_meta_impl(store, make_shard_id(String("node"), 0))
    var n_sharded = 3
    for j in range(n_sharded):
        var seed = 5000 + j
        _ = sharded.publish(_summary(seed, Int64(2)))

    var live_mixed = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(
        len(live_mixed),
        n_legacy + n_sharded,
        "mixed index serves legacy + sharded union (no dup)",
    )
    # No duplicate split: every UUID appears exactly once.
    var all_distinct = True
    for li in range(len(live_mixed)):
        var hits = 0
        for lj in range(len(live_mixed)):
            if _uuid_eq(live_mixed[li].split_uuid, live_mixed[lj].split_uuid):
                hits += 1
        if hits != 1:
            all_distinct = False
    assert_true(all_distinct, "no duplicate split in the mixed union")

    _ = store^


# =============================================================================
# A merged split in shard `_base` hides its inputs even when the inputs live
# in DIFFERENT writer shards.
# =============================================================================


def test_merged_split_hides_inputs_across_shards() raises:
    var store = SharedInMemoryConditionalStore()

    # Two writer shards each publish one raw split (the merge INPUTS).
    var meta_a = _shard_meta_impl(store, make_shard_id(String("node"), 0))
    var meta_b = _shard_meta_impl(store, make_shard_id(String("node"), 1))
    var in0 = _summary(1, Int64(3))  # uuid(1) in shard 0.
    var in1 = _summary(2, Int64(4))  # uuid(2) in shard 1.
    _ = meta_a.publish(in0.copy())
    _ = meta_b.publish(in1.copy())

    # Before the merge: both inputs are live -> the read sees both (2 splits).
    var before = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(len(before), 2, "both raw inputs live before the merge")

    # The compactor publishes a MERGED split into the reserved `_base` shard,
    # whose merge_input_uuids = {uuid(1), uuid(2)} (the inputs in OTHER shards).
    # Both the merged split AND its inputs are now live (the publish->tombstone
    # window). The merge-input filter over the cross-shard UNION must hide the
    # inputs so the read sees the merged docs EXACTLY ONCE.
    var merged_inputs = List[UInt8]()
    var u1 = _uuid(1)
    var u2 = _uuid(2)
    for k in range(16):
        merged_inputs.append(u1[k])
    for k in range(16):
        merged_inputs.append(u2[k])
    var merged = make_merged_split_summary(
        _uuid(7),  # the merged split's own UUID.
        Int64(7),  # 3 + 4 docs.
        Int64(999),
        Int64(0),
        Int64(6),
        String("logs"),
        String("body"),
        String("index/logs/splits/merged-7.split"),
        Int64(1),  # merge_ops > 0 (this is a merged split).
        merged_inputs^,
    )
    var base_meta = _shard_meta_impl(store, String("_base"))
    _ = base_meta.publish(merged^)

    # The merge-input filter over the UNION: the read sees ONLY the merged
    # split (the two inputs in shards 0 & 1 are hidden because their UUIDs are
    # in the live merged split's input set).
    var after = list_live_splits_across_shards(store, _META, String("logs"))
    assert_equal(
        len(after),
        1,
        "cross-shard merge-input filter: only the merged split is live",
    )
    assert_true(
        _uuid_eq(after[0].split_uuid, _uuid(7)),
        "the surviving split is the merged one",
    )

    # The with-seq variant tags each entry with its source shard_id (the
    # compactor needs this to route retire to the right shard). The merged split
    # is tagged with the `_base` shard.
    var with_seq = list_live_splits_across_shards_with_seq(
        store, _META, String("logs")
    )
    assert_equal(len(with_seq), 1, "with-seq variant applies the same merge-input filter")
    assert_equal(
        with_seq[0].shard_id,
        String("_base"),
        "the merged split is tagged with the _base shard_id",
    )

    _ = store^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
