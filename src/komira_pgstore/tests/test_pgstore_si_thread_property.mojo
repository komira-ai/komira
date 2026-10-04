# =============================================================================
# tests/komira_pgstore/test_pgstore_si_thread_property.mojo
#   C-SI-THREAD-PROPERTY (PRIORITY 2) — true OS-thread randomized N-conn x M-op
#   interleavings, audited against a MERGED-HISTORY REFERENCE MODEL after join.
# =============================================================================
#
# The SI-property harness (test_pgstore_si_property.mojo, 144 seeds) drives a
# SINGLE-THREAD seeded interleave (the PRNG, not the OS scheduler, picks the
# next micro-action) and self-checks each read against a totally-ordered
# reference model. That proves the generic code is SI-correct, but it does NOT
# exercise REAL OS-thread races on the shared create-CAS slot. THIS test does:
# K real pthreads each drive a randomized stream of begin/read/write/delete/
# commit/abort micro-actions over OVERLAPPING keys against ONE shared store.
#
# THE CHECKER under real concurrency (the load-bearing part). You cannot predict
# the OS interleave, so the reference is built FROM the durable truth after the
# race:
#
#   (A) IN-THREAD per-read self-check. A read at a PINNED snapshot S is checked
#       against the WAL's snapshot-visible version at S, reconstructed from the
#       store's OWN WAL surface (wal_chunk_write_set over [0..S]) overlaid with
#       the txn's RYOW buffer. A divergence is a hard FAIL with thread+step+seed.
#       (This is the SI invariant under real concurrency: a pinned snapshot is
#       stable + equals the merged committed history <= S.)
#
#   (B) POST-JOIN merged-history auditor (the reference model). After all threads
#       join, a fresh recovered handle replays the WAL [0..head] = the TOTAL
#       ORDER the create-CAS slot imposed (bucket-is-truth). The auditor asserts
#       the INVARIANT BATTERY over THAT merged history:
#         INV-2 atomicity      — every committed chunk's write-set is intact
#                                (decodes, >=1 op, all keys present).
#         INV-4 FCW / no lost  — for every HOT key, the version chain across the
#              update             WAL is strictly commit-LSN-increasing AND no two
#                                committed chunks carry the same (key,value) pair
#                                for a contended key (a duplicate is a lost-update
#                                artefact: two writers both "won" the same value).
#         INV-6 monotone slots — the WAL slot sequence is gapless 0..head, no
#                                holes, no dups (the create-CAS total order).
#         INV-3 durability     — every commit a thread RECORDED as successful is
#                                present in the recovered WAL (CAS-landed ->
#                                recoverable on a fresh open).
#       Plus the global accounting: total threads' recorded commits == the count
#       of committed chunks above the seed (no phantom commit, no dropped commit).
#
# A run FAILS on any single violation and prints seed (+ thread/step where the
# in-thread check fires). The seed makes the PER-THREAD action stream
# reproducible (the OS interleave is not, but the invariant battery holds for
# ANY interleave — that is the property).
#
# Threading: K pthreads via the sanctioned FFI carve-out (mirror of
# test_pgstore_concurrency.mojo's _spawn_writer). Each thread owns its
# TableStore over a clone() of the shared store; cross-thread visibility goes
# through the WAL. Per-thread results are heap-stable OwnedPointer pointees read
# after join (DISJOINT slots — writer w writes only its own).
#
# Encapsulation / stale-reuse: ZERO UnsafePointer in any PUBLIC signature; the only
# UnsafePointer uses are the sanctioned FFI-BOUNDARY pthread-launch carve-out
# (heap-box arg + results-addr), each with a SAFETY block, identical to the
# established in-tree concurrency test. The shared store is ArcPointer-backed
# (genuine cross-thread sharing). No byte-slab element, no unsafe_from_address
# outside the FFI carve-out, no take_pointee.
# =============================================================================

from std.ffi import external_call
from std.memory import alloc, OwnedPointer, UnsafePointer

from komira_collections.slab import Slab

from std.testing import assert_equal, assert_true, assert_false

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore

from komira_pgstore.pgstore_codec import (
    PG_OP_PUT,
    PG_OP_TOMBSTONE,
    WriteOp,
    bytes_eq,
)
from komira_pgstore.table_store import (


    TableStore,
    Txn,
    is_commit_retryable,
    is_occ_conflict,
)

@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed null
    UnsafePointer ctor / the `_unsafe_null=()` b1 idiom).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Origin `o` is concrete; the NULL sentinel is never
    # dereferenced (placeholder / explicit C-NULL arg).
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]



# =============================================================================
# splitmix64 PRNG (mirror the SI-property harness) + byte helpers.
# =============================================================================


struct Rng(Movable, Deinitable):
    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next_u64(mut self) -> UInt64:
        self.state += UInt64(0x9E3779B97F4A7C15)
        var z = self.state
        z = (z ^ (z >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B9)
        z = (z ^ (z >> UInt64(27))) * UInt64(0x94D049BB133111EB)
        return z ^ (z >> UInt64(31))

    def next_int(mut self, n: Int) -> Int:
        if n <= 1:
            return 0
        return Int(self.next_u64() % UInt64(n))


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _key(i: Int) -> List[UInt8]:
    return _b(String("k") + String(i))


# =============================================================================
# Per-thread results (heap-stable; read after join). Plain POD counters.
# =============================================================================


struct _ThreadResults(Movable, Deinitable):
    var commits: Int64  # successful APPENDING commits (did_append; one WAL chunk
    #                     above seed each — read-only commits are NOT counted)
    var conflicts: Int64  # OCC 40001 / retryable aborts seen
    var reads_checked: Int64  # in-thread SI read self-checks performed
    var errors: Int64  # unexpected errors / SI read mismatches

    def __init__(out self):
        self.commits = Int64(0)
        self.conflicts = Int64(0)
        self.reads_checked = Int64(0)
        self.errors = Int64(0)


# =============================================================================
# The pthread arg — a shared store clone + the work spec + a results address.
# =============================================================================


struct _ThreadArg(Movable, Deinitable):
    var store: SharedInMemoryConditionalStore
    var prefix: String
    var thread_id: Int64
    var seed: UInt64
    var n_keys: Int
    var n_steps: Int
    # # SAFETY: address of a heap-stable `_ThreadResults` owned by the main
    # thread (alive until the join). Plain Int — no wildcard field.
    var results_addr: Int

    def __init__(
        out self,
        var store: SharedInMemoryConditionalStore,
        var prefix: String,
        thread_id: Int64,
        seed: UInt64,
        n_keys: Int,
        n_steps: Int,
        results_addr: Int,
    ):
        self.store = store^
        self.prefix = prefix^
        self.thread_id = thread_id
        self.seed = seed
        self.n_keys = n_keys
        self.n_steps = n_steps
        self.results_addr = results_addr


# =============================================================================
# In-thread SI read self-check: the version VISIBLE at the txn's snapshot,
# reconstructed from the store's OWN WAL ([0..snapshot]) overlaid with the txn's
# RYOW buffer. This is the reference the live `get()` must match — it folds only
# committed chunks <= the snapshot (SI stability), so it is the ground truth a
# correct read at that pinned snapshot must agree with.
# =============================================================================


def _wal_visible_at[
    Store: ConditionalWriteStore
](
    mut ts: TableStore[Store], snapshot: Int64, key: List[UInt8]
) raises -> Optional[List[UInt8]]:
    """The newest committed version of `key` with commit_lsn <= snapshot,
    reconstructed by walking the WAL [0..snapshot] (descending — the highest
    matching LSN wins; a tombstone => None). The store's `get()` at this
    snapshot MUST equal this (SI: a pinned snapshot is stable + reflects the
    merged committed history <= S across ALL handles)."""
    var seq = snapshot
    if seq < Int64(0):
        return Optional[List[UInt8]](None)
    while seq >= Int64(0):
        var found = False
        var ws: List[WriteOp]
        try:
            ws = ts.wal_chunk_write_set(seq)
        except e:
            # A slot at/below the snapshot that does not exist (e.g. the
            # snapshot was pinned above the committed tail under a race) — keep
            # walking down; gapless log means nothing else above exists either.
            _ = e
            seq -= Int64(1)
            continue
        # The newest write to `key` within THIS chunk decides for this LSN.
        var j = len(ws) - 1
        while j >= 0:
            if bytes_eq(ws[j].key, key):
                if ws[j].op == PG_OP_TOMBSTONE:
                    return Optional[List[UInt8]](None)
                return Optional(ws[j].row.copy())
            j -= 1
        _ = found
        seq -= Int64(1)
    return Optional[List[UInt8]](None)


@always_inline
def _opt_eq(a: Optional[List[UInt8]], b: Optional[List[UInt8]]) -> Bool:
    if Bool(a) != Bool(b):
        return False
    if not a:
        return True
    return bytes_eq(a.value(), b.value())


# =============================================================================
# The per-thread driver — a randomized stream of micro-actions, self-checking
# each read against the WAL-visible reference at the pinned snapshot.
# =============================================================================


def _run_thread(mut arg: _ThreadArg) raises:
    # SAFETY (FFI-BOUNDARY — sanctioned pthread-launch carve-out): the results
    # address is a main-thread `OwnedPointer[_ThreadResults]` pointee, alive
    # until the main thread joins this pthread. DISJOINTNESS: thread `t` writes
    # ONLY its own results slot. No realloc of the slot.
    var results_ptr = UnsafePointer[_ThreadResults, MutUntrackedOrigin](
        unsafe_from_address=arg.results_addr
    )
    # Each thread owns its TableStore over a clone() of the shared store; threads
    # contend at the shared create-CAS slot, cross-thread visibility via the WAL.
    var ts = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=arg.store.clone(),
            prefix=arg.prefix.copy(),
            retry=RetryPolicy.broker_contention(),
        )
    )
    var rng = Rng(arg.seed)

    # An open txn (held in an Optional so the compiler tracks the
    # moved-in/moved-out state precisely — `cur.take()` deinitializes it on
    # abort/commit, `cur` carries the live Txn between) + a mirror of its
    # buffered writes (op/key/value) for the RYOW overlay in the read self-check.
    # Txn is Movable-only and cannot live in a List, so we hold ONE at a time.
    # The buffer mirror is inlined (NO nested-def closures over mutable locals —
    # Mojo 1.0.0b1 closures capturing-by-ref mutable locals are unreliable).
    var cur = Optional[Txn](None)
    var buf_ops = List[UInt8]()
    var buf_keys = List[List[UInt8]]()
    var buf_vals = List[List[UInt8]]()

    for step in range(arg.n_steps):
        if not cur:
            cur = Optional(ts.begin())
            buf_ops = List[UInt8]()
            buf_keys = List[List[UInt8]]()
            buf_vals = List[List[UInt8]]()
            continue

        var action = rng.next_int(10)
        var k = _key(rng.next_int(arg.n_keys))

        if action < 4:
            # READ + SI self-check against the WAL-visible reference.
            var snap = cur.value().snapshot_lsn
            var got = ts.get(cur.value(), k.copy())
            # RYOW probe: 0 = none, 1 = buffered PUT, 2 = buffered TOMBSTONE.
            var bs = 0
            var bval = List[UInt8]()
            for bi in range(len(buf_keys)):
                if bytes_eq(buf_keys[bi], k):
                    if buf_ops[bi] == PG_OP_TOMBSTONE:
                        bs = 2
                    else:
                        bs = 1
                        bval = buf_vals[bi].copy()
                    break
            var want: Optional[List[UInt8]]
            if bs == 1:
                want = Optional(bval^)  # RYOW: own buffered PUT
            elif bs == 2:
                want = Optional[List[UInt8]](None)  # own buffered TOMBSTONE
            else:
                want = _wal_visible_at(ts, snap, k)  # committed version <= snap
            if not _opt_eq(got, want):
                results_ptr[].errors += Int64(1)
                print(
                    "FAIL SI READ MISMATCH seed=", Int(arg.seed),
                    " thread=", Int(arg.thread_id), " step=", step,
                    " snapshot=", Int(snap),
                )
            results_ptr[].reads_checked += Int64(1)

        elif action < 7:
            # WRITE (PUT): buffer in the txn + mirror (inline upsert).
            var v = _b(
                String("t") + String(Int(arg.thread_id)) + String("_st")
                + String(step)
            )
            cur.value().update(k.copy(), v.copy())
            var found = False
            for bi in range(len(buf_keys)):
                if bytes_eq(buf_keys[bi], k):
                    buf_ops[bi] = PG_OP_PUT
                    buf_vals[bi] = v.copy()
                    found = True
                    break
            if not found:
                buf_ops.append(PG_OP_PUT)
                buf_keys.append(k.copy())
                buf_vals.append(v.copy())

        elif action < 8:
            # DELETE (TOMBSTONE): buffer + mirror (inline upsert).
            cur.value().delete(k.copy())
            var found = False
            for bi in range(len(buf_keys)):
                if bytes_eq(buf_keys[bi], k):
                    buf_ops[bi] = PG_OP_TOMBSTONE
                    buf_vals[bi] = List[UInt8]()
                    found = True
                    break
            if not found:
                buf_ops.append(PG_OP_TOMBSTONE)
                buf_keys.append(k.copy())
                buf_vals.append(List[UInt8]())

        elif action < 9:
            # ABORT: drop the txn (nothing persists).
            var t = cur.take()
            ts.abort(t^)

        else:
            # COMMIT: attempt; classify OCC/retryable vs success vs hard error.
            var t = cur.take()
            try:
                var res = ts.commit(t^)
                # Count ONLY commits that actually appended a chunk. A read-only
                # / empty-write-set commit returns did_append=False (no chunk
                # written) — counting it would over-count vs the WAL head (the
                # accounting INV-3 below is head == seed + appended commits - 1).
                if res.did_append:
                    results_ptr[].commits += Int64(1)
            except e:
                var em = String(e)
                if is_occ_conflict(em) or is_commit_retryable(em):
                    results_ptr[].conflicts += Int64(1)
                else:
                    results_ptr[].errors += Int64(1)
                    print(
                        "FAIL unexpected commit error seed=", Int(arg.seed),
                        " thread=", Int(arg.thread_id), " step=", step,
                        " err=", em,
                    )

    # Close any dangling open txn (read-only -> a no-op abort).
    if cur:
        var t = cur.take()
        ts.abort(t^)
    _ = ts^


def _thread_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin]
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    # SAFETY (FFI-BOUNDARY — sanctioned pthread-launch carve-out): `arg` is the
    # heap `_ThreadArg*` from `alloc + init_pointee_move`; reconstruct the
    # OwnedPointer so it frees at scope exit. Mirror of the concurrency test.
    var typed = arg.bitcast[_ThreadArg]()
    var owned = OwnedPointer[_ThreadArg](unsafe_from_raw_pointer=typed)
    try:
        _run_thread(owned[])
    except e:
        print("WARN _thread_entry: thread raised: ", String(e))
    _ = owned^
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _spawn_thread(var arg: _ThreadArg, mut tid_slot: Int64) raises -> Int32:
    # SAFETY (FFI-BOUNDARY): heap-box the arg, hand its address to
    # pthread_create; the thread reconstructs + frees it. MutExternalOrigin
    # only on the void* ABI args.
    var raw = alloc[_ThreadArg](1)
    UnsafePointer(to=raw[]).unsafe_write(arg^)
    var raw_void = raw.bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var slot_addr = UnsafePointer(to=tid_slot)
    return external_call["pthread_create", Int32](
        slot_addr.bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        _thread_entry,
        raw_void,
    )


def _join_thread(tid: Int64) -> Int32:
    return external_call["pthread_join", Int32](
        tid, _null_ptr[UInt8, MutUntrackedOrigin]()
    )


# =============================================================================
# POST-JOIN merged-history auditor — the INVARIANT BATTERY over the WAL total
# order (bucket-is-truth) after the race.
# =============================================================================


def _audit_merged_history(
    shared: SharedInMemoryConditionalStore,
    prefix: String,
    n_keys: Int,
    seed_chunks: Int64,
    total_recorded_commits: Int64,
) raises:
    """Replay the WAL [0..head] on a FRESH recovered handle (the total order the
    create-CAS slot imposed) and assert the invariant battery."""
    var verify = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(),
            prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var head = verify.wal_head_seq()

    # INV-6 monotone gapless slots: every chunk 0..head decodes + has >=1 op.
    # INV-2 atomicity: each committed chunk's write-set is intact (>=1 op, every
    #       op carries a key).
    var seq = Int64(0)
    while seq <= head:
        var ws = verify.wal_chunk_write_set(seq)  # raises if the slot is missing
        assert_true(
            len(ws) >= 1,
            "INV-2/INV-6: chunk " + String(seq) + " has >=1 op (atomic, gapless)",
        )
        for wi in range(len(ws)):
            assert_true(
                len(ws[wi].key) > 0,
                "INV-2: chunk " + String(seq) + " op " + String(wi)
                + " carries a key",
            )
        seq += Int64(1)

    # INV-3 durability + global accounting: every commit a thread RECORDED is a
    # distinct WAL chunk above the seed. head == seed_chunks - 1 + recorded.
    # (The seed pre-committed `seed_chunks` chunks: LSNs 0..seed_chunks-1.)
    assert_equal(
        head, seed_chunks - Int64(1) + total_recorded_commits,
        "INV-3 durability + accounting: head == (seed chunks) + (total recorded"
        " commits) - 1; no phantom commit, no dropped commit. head="
        + String(Int(head)) + " seed_chunks=" + String(Int(seed_chunks))
        + " recorded=" + String(Int(total_recorded_commits)),
    )

    # INV-4 FCW / no lost update: for EACH key, the committed version chain across
    # the WAL is strictly commit-LSN-increasing (gapless slots guarantee it) AND
    # no two committed chunks carry the SAME (key,value) for that key (a
    # duplicate value for a contended key is a lost-update artefact — two writers
    # both "won" the same write). We check it per key over all chunks.
    for ki in range(n_keys):
        var key = _key(ki)
        var prev = Int64(-1)
        var vals = List[List[UInt8]]()
        var s2 = Int64(0)
        while s2 <= head:
            var ws = verify.wal_chunk_write_set(s2)
            for wi in range(len(ws)):
                if bytes_eq(ws[wi].key, key):
                    assert_true(
                        s2 > prev,
                        "INV-4: key chain strictly LSN-increasing (no lost"
                        " update) for k" + String(ki) + " at seq " + String(s2),
                    )
                    prev = s2
                    if ws[wi].op == PG_OP_PUT:
                        for vv in range(len(vals)):
                            assert_false(
                                bytes_eq(vals[vv], ws[wi].row),
                                "INV-4: no two committed PUTs carry the same"
                                " value for contended k" + String(ki)
                                + " (duplicate => lost-update artefact) at seq "
                                + String(s2),
                            )
                        vals.append(ws[wi].row.copy())
            s2 += Int64(1)
    _ = verify^


# =============================================================================
# THE DRIVER — K threads x M steps over n_keys, then the merged-history audit.
# =============================================================================


def _run_thread_property(
    k: Int,
    n_keys: Int,
    n_steps: Int,
    base_seed: UInt64,
    require_conflicts: Bool = False,
) raises:
    print(
        "[si-thread-prop] K=" + String(k) + " threads x " + String(n_steps)
        + " steps over " + String(n_keys) + " overlapping keys"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/sithread/k") + String(k) + String("_s")
    prefix += String(Int(base_seed % UInt64(100000)))

    # Seed a known starting value for every key (so reads have a defined base).
    var seeder = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var st = seeder.begin()
    for ki in range(n_keys):
        st.insert(_key(ki), _b(String("seed") + String(ki)))
    var sr = seeder.commit(st^)
    assert_equal(sr.commit_lsn, Int64(0), "seed all keys in ONE chunk at LSN 0")
    _ = seeder^
    var seed_chunks = Int64(1)  # the seed pre-committed exactly 1 chunk (LSN 0).

    # Heap-stable per-thread results (DISJOINT slots; read after join).
    var results = Slab[OwnedPointer[_ThreadResults]]()
    for _w in range(k):
        results.append(OwnedPointer[_ThreadResults](_ThreadResults()))
    var tids = List[Int64]()
    for _w in range(k):
        tids.append(Int64(0))

    # Spawn K threads, each with a DISTINCT per-thread seed (distinct action
    # streams) over the SAME overlapping keyspace.
    var w = 0
    while w < k:
        var addr = Int(UnsafePointer(to=results[w][]))
        var thread_seed = base_seed + UInt64(w) * UInt64(0x1000193)
        var arg = _ThreadArg(
            store=shared.clone(),
            prefix=prefix.copy(),
            thread_id=Int64(w),
            seed=thread_seed,
            n_keys=n_keys,
            n_steps=n_steps,
            results_addr=addr,
        )
        var rc = _spawn_thread(arg^, tids[w])
        if rc != Int32(0):
            raise Error("pthread_create failed for thread " + String(w))
        w += 1

    w = 0
    while w < k:
        _ = _join_thread(tids[w])
        w += 1

    # ---- aggregate + the global no-error gate (INV-11 connection-survivability:
    #      a 40001 is a recoverable conflict, NOT a hard error; errors counts
    #      ONLY genuine failures incl. SI read mismatches). ----
    var total_commits = Int64(0)
    var total_conflicts = Int64(0)
    var total_reads = Int64(0)
    var total_errors = Int64(0)
    for wi in range(k):
        total_commits += results[wi][].commits
        total_conflicts += results[wi][].conflicts
        total_reads += results[wi][].reads_checked
        total_errors += results[wi][].errors

    assert_equal(
        total_errors, Int64(0),
        "no SI read mismatch + no unexpected commit error across the race"
        " (seed=" + String(Int(base_seed)) + "); a non-zero count printed the"
        " thread+step above",
    )

    # ---- NON-VACUITY gate (the high-contention K8-hot case). A randomized
    #      interleave that produced ZERO OCC conflicts would pass every
    #      invariant above VACUOUSLY (it never exercised first-committer-wins).
    #      For the deliberately-contended shape (8 threads x 3 keys) the test is
    #      only meaningful if it actually raced the write-write overlap, so we
    #      REQUIRE at least one observed 40001 / retryable abort. ----
    if require_conflicts:
        assert_true(
            total_conflicts > Int64(0),
            "high-contention K=" + String(k) + " must observe at least one OCC"
            " conflict (else the SI/FCW invariants held only vacuously);"
            " seed=" + String(Int(base_seed)),
        )

    # ---- the POST-JOIN merged-history audit (the invariant battery). ----
    _audit_merged_history(
        shared, prefix, n_keys, seed_chunks, total_commits
    )
    _ = results^
    _ = tids^
    _ = shared^
    print(
        "    [OK] K=" + String(k) + ": commits=" + String(Int(total_commits))
        + " conflicts=" + String(Int(total_conflicts)) + " reads_checked="
        + String(Int(total_reads)) + " — every SI read matched the WAL-visible"
        " reference; merged-history invariant battery clean"
    )


def test_si_thread_property_k4() raises:
    _run_thread_property(4, 6, 80, UInt64(0xC0FFEE01))


def test_si_thread_property_k8_hot() raises:
    # High-contention: 8 threads, few keys (max overlap). require_conflicts=True
    # enforces non-vacuity — this deliberately-contended shape MUST actually
    # race the write-write overlap (observe >=1 OCC 40001), else the SI/FCW
    # invariants would be passing only because nothing collided.
    _run_thread_property(8, 3, 100, UInt64(0x5EED9001), require_conflicts=True)


def test_si_thread_property_seed_sweep() raises:
    # A small sweep of distinct base seeds (distinct per-thread action streams);
    # the invariant battery must hold for EVERY interleave the OS produces.
    for s in range(4):
        _run_thread_property(6, 4, 60, UInt64(0xBADC0DE0 + s * 0x1000193))


def main() raises:
    print("== pgstore SI thread property (C-SI-THREAD-PROPERTY, PRIORITY 2) ==")
    test_si_thread_property_k4()
    test_si_thread_property_k8_hot()
    test_si_thread_property_seed_sweep()
    print(
        "[OK] test_pgstore_si_thread_property — K real OS threads x randomized"
        " interleavings: every pinned-snapshot read matched the WAL-visible"
        " reference (in-thread SI self-check) AND the post-join merged-history"
        " auditor held the invariant battery (INV-2/3/4/6/11) for every"
        " interleave the OS produced"
    )
