# =============================================================================
# test_search_metastore_concurrent.mojo
#   Concurrent writers publishing to one index's metastore never lose a split.
# =============================================================================
#
# Independent indexer processes publishing to the same index race for the next
# manifest slot. The manifest store's CAS (If-None-Match create, retry on 412,
# jittered backoff) means exactly one writer wins each slot; the loser re-reads
# the head, retries, and lands at the next free slot, so every split survives.
#
#   * A staged collision on one thread. The head object is only a cache; the
#     committed chunks are the source of truth and a missing head is recovered
#     by LIST. So the race can be staged without threads by rewinding the
#     shared head between two handles' publishes. That shows (i) a publish
#     against a stale head collides (412) instead of overwriting a committed
#     chunk, and (ii) once the stale head is gone, the next publish recovers
#     the true tail and lands at the next contiguous slot, with every split
#     still listed.
#   * K real OS threads, each publishing M distinct summaries through
#     `SearchMetastore.publish` to one shared in-memory store. After join,
#     `list_live_splits()` from a fresh handle returns all K*M summaries with
#     distinct UUIDs, and the claimed sequence numbers are exactly
#     {0 .. K*M-1}. Real concurrency is what drives the retry path a single
#     thread cannot reach.
#   * N sequential publishes on one handle, all listed back in order.
#
# komira_objectstore's test_cas_manifest_concurrent_offline proves the same
# no-gap property on the bare manifest store; this test drives it through
# summary encoding, `publish` and `list_live_splits()`.
#
# Pointers: the only UnsafePointer uses are the pthread void* ABI arguments and
# the heap-stable per-writer results read after join, as in that test. No
# struct field holds a wildcard-origin pointer.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
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
    InMemoryConditionalStore,
    ManifestHead,
    RetryPolicy,
    SharedInMemoryConditionalStore,
    encode_head,
    head_key,
)

from komira_search_meta.metastore import (
    SplitSummary,
    make_split_summary,
    SearchMetastore,
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
# Builders: a distinct SplitSummary per node, keyed by a node-unique seed so
# the UUID, object_key and doc-id range all differ, which makes "no lost
# update" checkable by UUID set membership.
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
        Int64(seed * 16 + 8),  # byte_size (distinct per node)
        Int64(seed * 1000),  # min_doc_id
        Int64(seed * 1000 + Int(doc_count) - 1),  # max_doc_id
        String("logs"),
        String("body"),
        String("index/logs/splits/node-" + String(seed) + ".split"),
    )


# =============================================================================
# Staged collision: A reads HEAD at base S, B publishes at S+1,
# A's stale-base publish collides (412), then RECOVERS at S+2 (no lost update).
# =============================================================================
#
# Single thread, no pthreads — we drive the exact interleave by manipulating the
# shared `_HEAD` cache (advisory) between two handles' publishes. This proves the
# two halves of the no-lost-update guarantee deterministically:
#   (i)  a stale-base append collides on a TAKEN slot -> 412 (the committed chunk
#        is NEVER clobbered — linearization);
#   (ii) clearing the stale cache makes the next publish RECOVER the true tail
#        (bucket-is-truth LIST) and land at the contiguous next seq -> BOTH the
#        racer's split and the recovered split survive in list_live_splits.


def test_staged_collision_recovers_without_losing_a_split() raises:
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("index/logs/meta")
    # Node A and Node B: two independent indexer handles over ONE shared meta.
    var manifest_a = CasManifestStore[SharedInMemoryConditionalStore](
        shared.clone(), prefix.copy(), RetryPolicy(Int64(100), Int64(1000), 0)
    )
    var manifest_b = CasManifestStore[SharedInMemoryConditionalStore](
        shared.clone(), prefix.copy(), RetryPolicy(Int64(100), Int64(1000), 0)
    )
    var meta_a = SearchMetastore[SharedInMemoryConditionalStore](
        manifest_a^, String("logs")
    )
    var meta_b = SearchMetastore[SharedInMemoryConditionalStore](
        manifest_b^, String("logs")
    )

    # ---- A lands its FIRST split at seq 0 (the base state both nodes "saw"). ----
    var ra0 = meta_a.publish(_summary(10, Int64(5)))
    assert_equal(ra0.chunk_seq, Int64(0))
    # `_HEAD` now caches chunk_seq=0. This is the HEAD "A read" (base seq S=0).

    # ---- Snapshot the stale HEAD A is holding (points at seq 0). ----
    var stale_head = shared.get(head_key(prefix))  # the seq-0 HEAD bytes.

    # ---- B publishes -> lands at seq 1 (advances the shared HEAD to seq 1). ----
    var rb1 = meta_b.publish(_summary(20, Int64(7)))
    assert_equal(rb1.chunk_seq, Int64(1))

    # ---- Re-stage A's STALE view: rewind `_HEAD` to the seq-0 snapshot, so A's
    #      next publish computes base from seq 0 and targets seq 1 — the slot B
    #      already took. (Models A having read HEAD BEFORE B's publish.) ----
    _ = shared.put(head_key(prefix), stale_head)

    # A's stale-base publish targets the TAKEN seq 1 -> 412. With max_retries=0
    # AND the stale cache still present, the loop terminally fails (a single
    # thread re-reads the same stale HEAD; only clearing the cache lets the
    # re-read recover). The committed seq-1 chunk (B's split) is NOT clobbered.
    with assert_raises():
        _ = meta_a.publish(_summary(11, Int64(3)))

    # PROOF (i): B's split at seq 1 is INTACT — the collided write never
    # overwrote it. Drop the manually-staled cache so reads recover by LIST.
    shared.delete(head_key(prefix))
    var live_after_collision = meta_a.list_live_splits()
    assert_equal(len(live_after_collision), 2)  # seq0 (A) + seq1 (B), no loss.
    assert_true(_uuid_eq(live_after_collision[0].split_uuid, _uuid(10)))
    assert_true(_uuid_eq(live_after_collision[1].split_uuid, _uuid(20)))

    # PROOF (ii): with the stale cache gone, A re-reads the TRUE tail
    # (bucket-is-truth: seq 1 is the highest committed chunk) and its retry lands
    # at the CONTIGUOUS next seq 2 — the recovered, no-lost-update landing.
    var ra2 = meta_a.publish(_summary(11, Int64(3)))
    assert_equal(ra2.chunk_seq, Int64(2))

    var live_final = meta_a.list_live_splits()
    assert_equal(len(live_final), 3)  # all three splits survive.
    # Contiguous publish order, distinct UUIDs (no dup, no lost update).
    assert_true(_uuid_eq(live_final[0].split_uuid, _uuid(10)))
    assert_true(_uuid_eq(live_final[1].split_uuid, _uuid(20)))
    assert_true(_uuid_eq(live_final[2].split_uuid, _uuid(11)))
    # A fresh metastore handle (a third "node") sees the SAME full set.
    var manifest_c = CasManifestStore[SharedInMemoryConditionalStore](
        shared.clone(), prefix.copy(), RetryPolicy.fast_test()
    )
    var meta_c = SearchMetastore[SharedInMemoryConditionalStore](
        manifest_c^, String("logs")
    )
    assert_equal(len(meta_c.list_live_splits()), 3)


# =============================================================================
# K OS-thread writers through SearchMetastore.publish.
# =============================================================================
#
# K real OS threads, each publishing M distinct SplitSummary records to ONE
# shared metastore. Asserts no lost update, no gap and no duplicate on the
# replayed live split set. Thread launch follows komira_objectstore's
# test_cas_manifest_concurrent_offline, but each append goes through
# SearchMetastore.publish and the result is checked with list_live_splits.


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
    var prefix: String
    var node_id: Int64
    var num_publishes: Int64
    # # SAFETY: address of a heap-stable `_WriterResults` owned by the main
    # thread (kept alive until join). Plain Int — no wildcard field.
    var results_addr: Int

    def __init__(
        out self,
        var store: SharedInMemoryConditionalStore,
        var prefix: String,
        node_id: Int64,
        num_publishes: Int64,
        results_addr: Int,
    ):
        self.store = store^
        self.prefix = prefix^
        self.node_id = node_id
        self.num_publishes = num_publishes
        self.results_addr = results_addr


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
    # SAFETY (pthread launch): the results address is a main-thread
    # OwnedPointer[_WriterResults] pointee, alive until the main thread joins.
    # DISJOINTNESS: writer touches ONLY its own slot.
    var results_ptr = UnsafePointer[_WriterResults, MutUntrackedOrigin](
        unsafe_from_address=arg.results_addr
    )
    # The store is a SHARED handle (Arc to one map) — all K writers contend on
    # the SAME index's metastore. Build a SearchMetastore over this handle.
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store=arg.store.clone(),
        prefix=arg.prefix.copy(),
        retry=RetryPolicy.fast_test(),
    )
    var meta = SearchMetastore[SharedInMemoryConditionalStore](
        manifest^, String("logs")
    )
    var i = Int64(0)
    while i < arg.num_publishes:
        # A node-unique, publish-unique seed so each SplitSummary UUID /
        # object_key is globally distinct: seed = node_id * 1000 + i.
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
        results_ptr[].records.append(
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


def _run_k_node_stress(k: Int, publishes_per_node: Int64) raises:
    print(
        "[search-cas concurrent] K="
        + String(k)
        + " indexer nodes x "
        + String(Int(publishes_per_node))
        + " publishes -> ONE shared metastore"
    )

    var shared = SharedInMemoryConditionalStore()
    var prefix = String("index/logs/meta")

    var results = Slab[OwnedPointer[_WriterResults]]()
    for _w in range(k):
        results.append(OwnedPointer[_WriterResults](_WriterResults()))
    var tids = List[Int64]()
    for _w in range(k):
        tids.append(Int64(0))

    var w = 0
    while w < k:
        var addr = Int(UnsafePointer(to=results[w][]))
        var arg = _WriterArg(
            store=shared.clone(),
            prefix=prefix.copy(),
            node_id=Int64(w + 1),  # node ids 1..k (seed base node*1000).
            num_publishes=publishes_per_node,
            results_addr=addr,
        )
        var rc = _spawn_writer(arg^, tids[w])
        if rc != Int32(0):
            raise Error("pthread_create failed for node " + String(w))
        w += 1

    w = 0
    while w < k:
        _ = _join_writer(tids[w])
        w += 1

    # ---- aggregate the per-node publish records ----
    var expected = Int64(k) * publishes_per_node
    var all_seqs = List[Int64]()
    var commits = Int64(0)
    var terminal_fails = Int64(0)
    var max_attempts = Int64(0)
    for wi in range(k):
        ref recs = results[wi][].records
        for ri in range(len(recs)):
            ref r = recs[ri]
            if r.terminal_fail == Int64(1):
                terminal_fails += Int64(1)
                continue
            commits += Int64(1)
            all_seqs.append(r.chunk_seq)
            if r.attempts > max_attempts:
                max_attempts = r.attempts

    # The offline backend has NO transport flake -> any terminal fail is a real
    # livelock (the retry bound MUST hold).
    assert_equal(
        terminal_fails,
        Int64(0),
        "no terminal fail under contention (livelock bound)",
    )
    assert_equal(commits, expected, "every publish committed (K*M)")

    # No-gap / no-dup on the claimed chunk seqs: the union is {0..K*M-1}, each
    # once. A LOST UPDATE would show as a missing seq (gap) or a duplicate.
    var seqs_sorted = all_seqs.copy()
    _sort_i64(seqs_sorted)
    var no_gap = True
    var no_dup = True
    for idx in range(len(seqs_sorted)):
        if seqs_sorted[idx] != Int64(idx):
            no_gap = False
        if idx > 0 and seqs_sorted[idx] == seqs_sorted[idx - 1]:
            no_dup = False
    assert_true(no_dup, "exactly one winner per manifest slot (no dup)")
    assert_true(no_gap, "chunk seqs gapless {0..K*M-1} (no lost update)")

    # ---- THE no-lost-update assertion at the SearchMetastore.list_live_splits
    #      layer: a fresh metastore handle (a node that did NOT write) replays
    #      the shared lineage and sees ALL K*M splits, each with a DISTINCT UUID
    #      (every node's split survived; none was clobbered). ----
    var reader_manifest = CasManifestStore[SharedInMemoryConditionalStore](
        shared.clone(), prefix.copy(), RetryPolicy.fast_test()
    )
    var reader = SearchMetastore[SharedInMemoryConditionalStore](
        reader_manifest^, String("logs")
    )
    var live = reader.list_live_splits()
    assert_equal(
        Int64(len(live)),
        expected,
        "list_live_splits returns ALL published splits (no lost update)",
    )
    # Every published seed's UUID is present exactly once (set membership).
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
        found_each,
        "every node's split UUID present EXACTLY once (no loss, no dup)",
    )

    # Livelock bound: no publish exceeded max_retries+1 attempts.
    var policy = RetryPolicy.fast_test()
    assert_true(
        max_attempts <= Int64(policy.max_retries + 1),
        "no publish exceeded max_retries+1 (livelock bound held)",
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


def test_concurrent_publish_no_lost_update() raises:
    # K = 2, 4, 8 indexer nodes; each publishes 4 splits to ONE shared metastore.
    # Every variant asserts ALL K*M splits survive (no lost update) + no gap/dup.
    var publishes_per_node = Int64(4)
    var ks = List[Int]()
    ks.append(2)
    ks.append(4)
    ks.append(8)
    for i in range(len(ks)):
        _run_k_node_stress(ks[i], publishes_per_node)


# =============================================================================
# N sequential publishes on one handle all round-trip: the no-contention
# baseline, at N=24 to match the largest threaded fan-out.
# =============================================================================


def test_sequential_publishes_all_survive() raises:
    var store = InMemoryConditionalStore()
    var manifest = CasManifestStore[InMemoryConditionalStore](
        store^, String("index/logs/meta"), RetryPolicy.fast_test()
    )
    var meta = SearchMetastore[InMemoryConditionalStore](
        manifest^, String("logs")
    )
    var n = 24
    for s in range(n):
        var r = meta.publish(_summary(s, Int64(1 + (s % 5))))
        assert_equal(r.chunk_seq, Int64(s))
    var live = meta.list_live_splits()
    assert_equal(len(live), n)
    # Publish order preserved + every UUID distinct.
    for s in range(n):
        assert_true(_uuid_eq(live[s].split_uuid, _uuid(s)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
