# =============================================================================
# src/komira_table_store/tests/test_table_store_unique_index.mojo
#   SI-7 UNIQUE enforcement — the STORAGE-LEVEL discriminating falsifiers for
#   the first-committer-wins protocol over a pk-SUFFIXED unique index.
# =============================================================================
#
# These probe the protocol DIRECTLY against the real `TableStore` primitives
# (begin / commit / index_scan_visible / register_index), with the guard
# key + post-conflict 40001-vs-23505 discriminator implemented in test helpers
# (`_commit_unique` / `_apply_unique_insert_statement`) so the falsifiers
# exercise the ACTUAL OCC substrate — not a mock. The SQL-face flip (SI-5
# non-enforcing → enforcing) lives in `sql_executor.mojo`; this file is the
# substrate proof that the protocol is loop-free and correct.
#
# The four named falsifiers:
#   (a) CONCURRENT first-committer-wins — two threads INSERT the same
#       unique value at the SAME pinned snapshot ⇒ EXACTLY ONE commits, the
#       loser terminates 23505 (NOT both-commit, NOT a perpetual 40001 loop,
#       NOT a 23505 for the winner). THE one. Real OS threads + a start barrier
#       that forces the co-pin (without it the OS may serialize the threads and
#       the loser fast-fails at buffer time, a DIFFERENT path that does not
#       exercise the post-conflict recheck).
#   (b) INTRA-TXN same-value — single INSERT of two rows sharing the
#       unique value ⇒ 23505, ZERO heap rows committed (the pre-check fires
#       BEFORE any create-CAS append; `wal_head_seq` is unchanged).
#   (c) NULL trap — multiple NULLs allowed (NULL ≠ NULL); a CONTRAST
#       GUARD proves the unique check is still LIVE for non-null values.
#   (d) COLD-TIER injectivity — the SQL-face form is now LIVE
#       at the DRIVER tier: see the driver's cold-tier lifecycle test,
#       `test_b_cold_aware_unique_rejects_columnarized_reaped_duplicate`. The
#       LEAF-level variant stays out of scope by design (the reuse-safe leaf has
#       NO columnar dep). Documented at the bottom.
#
# THE GUARD KEY (the one net-new keyspace this protocol introduces).
# With pk-SUFFIXED keys two duplicate-value inserts write DISTINCT composite
# keys (`U||pk1` vs `U||pk2`) — so they do NOT naturally OCC-conflict (the
# create-CAS serializes them but absent extra machinery BOTH commit). The guard
# key `guard_prefix(lineage) ++ U` omits the pk, so BOTH committers buffer the
# IDENTICAL guard key ⇒ `_occ_check`'s byte-equal intersection fires ⇒ the loser
# gets a genuine 40001. The post-conflict recheck then converts that 40001 into
# a terminal 23505. The guard rides the ONE write-set / ONE commit_lsn
# (invariant #1) exactly like the index + heap ops.
#
# Discriminators: assert via `is_unique_violation` / `is_occ_conflict` /
# `is_commit_retryable` — NEVER a raw `String(e).find(...)`.
#
# SI-7 of the secondary-index design.
# Tagged: (a) `large` (real threads); (b)/(c) deterministic single-thread.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_false, assert_true

from komira_atomic_alias import AtomicI64

from komira_collections.slab import Slab

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore

from komira_table_store.key_index import KeyValue
from komira_table_store.table_store import (


    TableStore,
    Txn,
    is_commit_retryable,
    is_occ_conflict,
    is_unique_violation,
    UNIQUE_VIOLATION_TOKEN,
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
# Storage-level key helpers — lifted from test_table_store_secondary_index.mojo. We
# hand-encode the 4-byte big-endian lineage-ordinal prefix that
# `TableStore._key_lineage_ord` reads, staying on the table store leaf (no SQL-layer
# codec import). The unique index keyspace + the guard keyspace are two DISJOINT
# high-band ordinals (one guard ordinal per unique index).
# =============================================================================

comptime _IDX_BAND: Int32 = 0x40000000  # the unique index lineage ordinal
comptime _GUARD_BAND: Int32 = 0x50000000  # the disjoint guard keyspace ordinal
comptime _HEAP_TID: Int32 = 0  # the heap table ordinal (low band)

# A 1-byte NULL marker for the unique segment: matches the SQL layer's NULL-marker shape (0x00 =
# NULL, anything else = present). A NULL unique value is EXEMPT from every check.
comptime _NULL_SEG: UInt8 = 0x00


def _ord_prefix(ordinal: Int32) -> List[UInt8]:
    """The 4-byte BIG-ENDIAN lineage-ordinal prefix."""
    var u = UInt32(Int(ordinal))
    var out = List[UInt8]()
    for i in range(4):
        var shift = UInt32(8 * (3 - i))
        out.append(UInt8((u >> shift) & UInt32(0xFF)))
    return out^


def _heap_key(pk: UInt8) -> List[UInt8]:
    """A heap key: low-band table prefix ++ a 1-byte pk."""
    var out = _ord_prefix(_HEAP_TID)
    out.append(pk)
    return out^


def _uidx_key(lineage: Int32, seg: UInt8, pk: UInt8) -> List[UInt8]:
    """A pk-SUFFIXED unique index entry key: high-band lineage prefix ++
    [seg byte][pk byte]. Two rows with the same `seg` (unique value) but
    different `pk` produce DISTINCT keys — the constraint
    is a prefix-multiplicity property, NEVER a key collision."""
    var out = _ord_prefix(lineage)
    out.append(seg)
    out.append(pk)
    return out^


def _guard_key(seg: UInt8) -> List[UInt8]:
    """The guard key: guard-band prefix ++ [seg byte] — NO pk suffix. Two
    inserts of the SAME unique value buffer the IDENTICAL guard key, forcing the
    create-CAS write-WRITE conflict that makes the OCC the uniqueness arbiter."""
    var out = _ord_prefix(_GUARD_BAND)
    out.append(seg)
    return out^


def _uprefix_lo(lineage: Int32, seg: UInt8) -> List[UInt8]:
    """The half-open LOWER bound of the unique value `seg`'s pk-suffix sub-range:
    lineage prefix ++ [seg]. Every `(seg, pk)` key is >= this."""
    var out = _ord_prefix(lineage)
    out.append(seg)
    return out^


def _uprefix_hi(lineage: Int32, seg: UInt8) -> List[UInt8]:
    """The half-open UPPER bound of the unique value `seg`'s sub-range: lineage
    prefix ++ [seg + 1]. Bounds the whole `(seg, *)` sub-tree. (seg < 0xFF in
    these tests, so the +1 successor is exact and in-band.)"""
    var out = _ord_prefix(lineage)
    out.append(seg + UInt8(1))
    return out^


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _new_mem_store(prefix: String) raises -> TableStore[InMemoryConditionalStore]:
    var wal = CasManifestStore[InMemoryConditionalStore](
        store=InMemoryConditionalStore(),
        prefix=prefix,
        retry=RetryPolicy.fast_test(),
    )
    return TableStore[InMemoryConditionalStore].open(wal^)


def _unique() -> String:
    var x = UInt64(perf_counter_ns())
    x ^= x >> UInt64(33)
    x *= UInt64(0xFF51AFD7ED558CCD)
    x ^= x >> UInt64(33)
    var out = String("")
    var shift = 60
    while shift >= 0:
        var nib = Int((x >> UInt64(shift)) & UInt64(0xF))
        out += chr(0x30 + nib) if nib < 10 else chr(0x61 + nib - 10)
        shift -= 4
    return out^


def _live_pks_for_value[
    Store: ConditionalWriteStore
](
    mut store: TableStore[Store], txn: Txn, lineage: Int32, seg: UInt8
) raises -> List[UInt8]:
    """The pk-suffix set of the LIVE unique entries under value `seg` at the txn
    snapshot. The uniqueness probe: `index_scan_visible` over the value's
    pk-suffix sub-range, projected to the distinct decoded pk bytes."""
    var lo = _uprefix_lo(lineage, seg)
    var hi = _uprefix_hi(lineage, seg)
    var entries = store.index_scan_visible(txn, lineage, lo^, hi^)
    var out = List[UInt8]()
    for i in range(len(entries)):
        ref k = entries[i].key
        out.append(k[len(k) - 1])  # the pk byte (final composite-key byte)
    return out^


# =============================================================================
# The protocol, implemented against the real TableStore primitives.
# =============================================================================


def _buffer_unique_insert(
    mut txn: Txn, lineage: Int32, seg: UInt8, pk: UInt8, is_null: Bool
) raises:
    """Buffer ONE unique-index INSERT's three WriteOps into `txn` (invariant #1
    — heap + index + guard share the ONE write-set): the heap PUT, the
    pk-suffixed index PUT, and — for a NON-NULL value — the guard PUT.
    A NULL value buffers heap + index but NO guard (a NULL must never conflict
    with another NULL)."""
    txn.insert(_heap_key(pk), _b("row"))
    txn.insert(_uidx_key(lineage, seg, pk), List[UInt8]())  # non-covering
    if not is_null:
        txn.insert(_guard_key(seg), List[UInt8]())  # the conflict forcer


def _unique_recheck_or_23505[
    Store: ConditionalWriteStore
](
    mut store: TableStore[Store],
    lineage: Int32,
    seg: UInt8,
    self_pk: UInt8,
    is_null: Bool,
) raises -> Bool:
    """Steps 1–3 of the unique-commit protocol — the 40001-vs-23505 discriminator. Called after a `commit`
    returns OCC_CONFLICT 40001. Re-begins at a FRESH snapshot S' (now > the
    winner's commit_lsn) and re-runs the per-unique-key prefix scan:
      * if a LIVE entry under `seg` has a pk != self_pk ⇒ raise TERMINAL 23505
        (the peer committed first; first-committer-wins on the VALUE — NEVER
        retried, which is what makes the loop terminate);
      * else (no competing value) ⇒ return True = the 40001 was on a NON-unique
        key, the caller re-drives the txn body.
    A NULL value never conflicts ⇒ always "retry" (return True)."""
    if is_null:
        return True
    var rd = store.begin()  # S' > winner.commit_lsn
    var live = _live_pks_for_value(store, rd, lineage, seg)
    for i in range(len(live)):
        if live[i] != self_pk:
            raise Error(
                UNIQUE_VIOLATION_TOKEN
                + ": duplicate key value violates unique constraint"
                " (a competing distinct-pk value "
                + String(Int(live[i]))
                + " is live under the unique prefix at the post-conflict"
                " snapshot — first-committer-wins; terminal, NOT retried)"
            )
    return True  # no competing value — the 40001 was on a non-unique key.


def _commit_unique[
    Store: ConditionalWriteStore
](
    mut store: TableStore[Store],
    lineage: Int32,
    seg: UInt8,
    pk: UInt8,
    is_null: Bool,
    cap: Int,
    mut conflicts: Int64,
) raises:
    """The executor-side unique commit protocol, loop-free by construction.
    Begin -> buffer the heap+index+guard writes -> commit. On a 40001, run the
    post-conflict recheck: it RAISES terminal 23505 (and we propagate, never
    retrying) if a competing committed value exists, else re-drives the txn body
    at a fresh snapshot. `cap` bounds the heap-conflict retry path (a livelock
    backstop; the unique path EXITS before re-commit, so it can never spin).

    The (1) buffer-time fast-fail is ALSO applied here on the first
    attempt: an already-committed dup visible at the pinned snapshot S raises
    23505 immediately without paying a commit round-trip. It is a latency
    optimization, NEVER the arbiter (S cannot see a concurrent uncommitted
    peer)."""
    var attempt = 0
    while attempt < cap:
        attempt += 1
        var t = store.begin()
        # (1) buffer-time fast-fail prefix scan — catches an ALREADY-
        # committed dup visible at S. Skipped for NULL.
        if not is_null:
            var pre = _live_pks_for_value(store, t, lineage, seg)
            for i in range(len(pre)):
                if pre[i] != pk:
                    raise Error(
                        UNIQUE_VIOLATION_TOKEN
                        + ": duplicate key value violates unique constraint"
                        " (a committed distinct-pk value is visible at the"
                        " pinned snapshot — buffer-time fast-fail)"
                    )
        _buffer_unique_insert(t, lineage, seg, pk, is_null)
        try:
            _ = store.commit(t^)
            return  # committed — the winner (or an uncontended insert).
        except e:
            var em = String(e)
            if is_unique_violation(em):
                raise e^  # terminal — propagate (should not arise from commit).
            if is_occ_conflict(em) or is_commit_retryable(em):
                conflicts += Int64(1)
                # post-conflict recheck: raises terminal 23505 if a
                # competing value is now live; else returns True to re-drive.
                _ = _unique_recheck_or_23505(store, lineage, seg, pk, is_null)
                continue  # heap-key 40001 (no competing value) — re-drive.
            raise e^  # genuine unexpected error.
    raise Error(
        "TS_COMMIT_RETRYABLE: _commit_unique exhausted "
        + String(cap)
        + " attempts (retryable)"
    )


def _apply_unique_insert_statement[
    Store: ConditionalWriteStore
](
    mut store: TableStore[Store],
    lineage: Int32,
    segs: List[UInt8],
    pks: List[UInt8],
    nulls: List[Bool],
) raises:
    """One logical multi-row INSERT under a unique index. Runs the INTRA-
    STATEMENT pre-check over the statement's OWN rows BEFORE buffering ANY
    WriteOp, then a single commit of the whole statement. The pre-check is
    REQUIRED even under pk-suffixed keying: `Txn._buffer` dedups by EXACT key,
    and two pk-suffixed index PUTs have DISTINCT keys, so the buffer silently
    accepts both — only this pre-check raises (the silent-data-loss hole).

    NULL values never enter `seen` (NULL != NULL). On a duplicate the
    whole statement raises 23505 BEFORE any append (atomic abort: `wal_head_seq`
    is unchanged)."""
    # intra-statement pre-check — scan the statement's own rows.
    var seen_seg = List[UInt8]()
    var seen_pk = List[UInt8]()
    for r in range(len(segs)):
        if nulls[r]:
            continue  # NULL exempt.
        for s in range(len(seen_seg)):
            if seen_seg[s] == segs[r] and seen_pk[s] != pks[r]:
                raise Error(
                    UNIQUE_VIOLATION_TOKEN
                    + ": duplicate key value violates unique constraint (two"
                    " rows of one statement share unique value "
                    + String(Int(segs[r]))
                    + " — intra-statement pre-check, ZERO rows committed)"
                )
        seen_seg.append(segs[r])
        seen_pk.append(pks[r])
    # Pre-check passed: buffer ALL rows into ONE txn + commit once (atomic).
    var t = store.begin()
    for r in range(len(segs)):
        _buffer_unique_insert(t, lineage, segs[r], pks[r], nulls[r])
    _ = store.commit(t^)


# =============================================================================
# (a) CONCURRENT first-committer-wins — THE one. Real OS threads.
# =============================================================================


struct _UResults(Movable, Deinitable):
    var commits: Int64  # successful commits by this thread (0 or 1)
    var unique_violations: Int64  # terminal 23505 seen (the loser)
    var conflicts: Int64  # 40001 seen (informational)
    var errors: Int64  # cap-exhaust / unexpected (a livelock or both-commit bug)

    def __init__(out self):
        self.commits = Int64(0)
        self.unique_violations = Int64(0)
        self.conflicts = Int64(0)
        self.errors = Int64(0)


struct _UArg(Movable, Deinitable):
    var store: SharedInMemoryConditionalStore
    var prefix: String
    var pk: UInt8
    var seg: UInt8
    var lineage: Int32
    # # SAFETY: addresses of heap-stable main-thread pointees (alive until join).
    var results_addr: Int
    var barrier_addr: Int

    def __init__(
        out self,
        var store: SharedInMemoryConditionalStore,
        var prefix: String,
        pk: UInt8,
        seg: UInt8,
        lineage: Int32,
        results_addr: Int,
        barrier_addr: Int,
    ):
        self.store = store^
        self.prefix = prefix^
        self.pk = pk
        self.seg = seg
        self.lineage = lineage
        self.results_addr = results_addr
        self.barrier_addr = barrier_addr


def _u_writer_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin]
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    # SAFETY: `arg` is the heap `_UArg*` from `alloc + init_pointee_move`.
    # Reconstruct the OwnedPointer so it frees at scope exit.
    var typed = arg.bitcast[_UArg]()
    var owned = OwnedPointer[_UArg](unsafe_from_raw_pointer=typed)
    try:
        _run_u_writer(owned[])
    except e:
        print("WARN _u_writer_entry: writer raised: ", String(e))
    _ = owned^
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _run_u_writer(mut arg: _UArg) raises:
    # SAFETY (FFI-BOUNDARY — sanctioned pthread-launch carve-out): the results +
    # barrier addresses are main-thread heap-stable pointees, alive until the
    # main thread joins this pthread. DISJOINTNESS: writer `w` writes ONLY its
    # own results slot; the barrier is an atomic counter (concurrent fetch_add).
    # No realloc of either slot.
    var results_ptr = UnsafePointer[_UResults, MutUntrackedOrigin](
        unsafe_from_address=arg.results_addr
    )
    var barrier_ptr = UnsafePointer[AtomicI64, MutUntrackedOrigin](
        unsafe_from_address=arg.barrier_addr
    )
    var ts = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=arg.store.clone(),
            prefix=arg.prefix.copy(),
            retry=RetryPolicy.broker_contention(),
        )
    )
    # Register the unique lineage on THIS handle so its commit fold routes the
    # index PUTs into the index memtable AND the post-conflict recheck's
    # `index_scan_visible` resolves (cross-handle visibility — the recheck must
    # see the WINNER's committed index entry at the fresh snapshot S').
    ts.register_index(arg.lineage)

    # Pin S, buffer the writes, THEN hit the start barrier so BOTH threads have
    # pinned the SAME head (seeded at LSN 0) before EITHER commits. This forces
    # the recheck path (the buffer-time scan sees nothing at S — the create-CAS
    # guard conflict is the sole arbiter), not the serialized fast-fail path. The
    # FIRST txn is carried in an Optional so the ownership tracker sees a single
    # well-defined liveness across the retry loop (each iteration `take()`s it
    # and the re-drive re-fills it).
    var t0 = ts.begin()
    _buffer_unique_insert(t0, arg.lineage, arg.seg, arg.pk, False)
    var pending = Optional[Txn](t0^)
    # --- barrier: wait for both threads to reach this point ---
    _ = barrier_ptr[].fetch_add(Int64(1))
    while barrier_ptr[].load() < Int64(2):
        pass

    var attempt = 0
    comptime CAP = 64
    var committed = False
    var terminal = False
    while not committed and not terminal and attempt < CAP:
        attempt += 1
        var t = pending.take()  # the txn pinned this iteration (always present)
        try:
            _ = ts.commit(t^)
            committed = True
            results_ptr[].commits += Int64(1)
        except e:
            var em = String(e)
            if is_unique_violation(em):
                results_ptr[].unique_violations += Int64(1)
                terminal = True  # 23505 — TERMINAL, break the loop.
            elif is_occ_conflict(em) or is_commit_retryable(em):
                results_ptr[].conflicts += Int64(1)
                # post-conflict recheck: RAISES terminal 23505 if the peer
                # committed a competing value (the FCW loser path); else returns
                # to re-drive (heap-key 40001 — does not arise in this 2-writer
                # same-value test, so the recheck always terminates here).
                try:
                    _ = _unique_recheck_or_23505(
                        ts, arg.lineage, arg.seg, arg.pk, False
                    )
                    # No competing value yet — re-drive: re-begin + re-buffer.
                    var tn = ts.begin()
                    _buffer_unique_insert(tn, arg.lineage, arg.seg, arg.pk, False)
                    pending = Optional(tn^)
                except re:
                    if is_unique_violation(String(re)):
                        results_ptr[].unique_violations += Int64(1)
                        terminal = True
                    else:
                        results_ptr[].errors += Int64(1)
                        terminal = True
            else:
                results_ptr[].errors += Int64(1)
                terminal = True
    if not committed and not terminal:
        # cap-exhausted without committing OR terminating = a perpetual 40001
        # loop (the bug the discriminator prevents). Surface it as an error.
        results_ptr[].errors += Int64(1)
    # Drop any dangling re-driven txn so the store teardown is clean.
    if pending:
        var leftover = pending.take()
        ts.abort(leftover^)


def _spawn_u_writer(var arg: _UArg, mut tid_slot: Int64) raises -> Int32:
    # SAFETY: heap-box the arg; the thread reconstructs + frees it.
    var raw = alloc[_UArg](1)
    UnsafePointer(to=raw[]).unsafe_write(arg^)
    var raw_void = raw.bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var slot_addr = UnsafePointer(to=tid_slot)
    return external_call["pthread_create", Int32](
        slot_addr.bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        _u_writer_entry,
        raw_void,
    )


def _join_u_writer(tid: Int64) -> Int32:
    return external_call["pthread_join", Int32](
        tid, _null_ptr[UInt8, MutUntrackedOrigin]()
    )


def _run_fcw(seed_committed: Bool) raises -> Int64:
    """Drive the 2-thread FCW race once. Returns the WINNER's pk (the live
    surviving entry's pk). Asserts the invariants. `seed_committed` seeds an
    unrelated heap row so `begin()` pins a real head (the threads still race the
    FIRST insert of the unique value)."""
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("uniq_a/") + _unique()
    var lineage = _IDX_BAND
    var seg: UInt8 = 42  # the shared unique value both threads insert

    # Seed: register the index + commit ONE unrelated heap row at LSN 0 so a
    # fresh begin() pins a real head. Nothing on the unique lineage (both
    # threads race the first insert of `seg`).
    var seed = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    seed.register_index(lineage)
    if seed_committed:
        var st = seed.begin()
        st.insert(_heap_key(99), _b("seed"))
        _ = seed.commit(st^)
    _ = seed^

    var results = Slab[OwnedPointer[_UResults]]()
    for _w in range(2):
        results.append(OwnedPointer[_UResults](_UResults()))
    # Atomic is non-Movable, so it cannot go through OwnedPointer's value ctor.
    # The blessed heap-Atomic idiom (src/mojo-mcp/examples/
    # sequential_phase_state_sharing.mojo:223): alloc + init_pointee_move on
    # `.value`, then OwnedPointer(unsafe_from_raw_pointer=...).
    var barrier_raw = alloc[AtomicI64](1)
    barrier_raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(
        Scalar[DType.int64](0)
    )
    var barrier = OwnedPointer[AtomicI64](
        unsafe_from_raw_pointer=barrier_raw
    )
    var tids = List[Int64]()
    for _w in range(2):
        tids.append(Int64(0))

    var barrier_addr = Int(UnsafePointer(to=barrier[]))
    var pkvals = List[UInt8]()
    pkvals.append(UInt8(1))
    pkvals.append(UInt8(2))
    var w = 0
    while w < 2:
        var addr = Int(UnsafePointer(to=results[w][]))
        var arg = _UArg(
            store=shared.clone(),
            prefix=prefix.copy(),
            pk=pkvals[w],
            seg=seg,
            lineage=lineage,
            results_addr=addr,
            barrier_addr=barrier_addr,
        )
        var rc = _spawn_u_writer(arg^, tids[w])
        if rc != Int32(0):
            raise Error("pthread_create failed for FCW writer " + String(w))
        w += 1

    w = 0
    while w < 2:
        _ = _join_u_writer(tids[w])
        w += 1

    var total_commits = Int64(0)
    var total_uv = Int64(0)
    var total_errors = Int64(0)
    var winner_pk = UInt8(0)
    for wi in range(2):
        total_commits += results[wi][].commits
        total_uv += results[wi][].unique_violations
        total_errors += results[wi][].errors
        if results[wi][].commits == Int64(1):
            winner_pk = pkvals[wi]

    # --- THE assertions ---
    # EXACTLY ONE committed — NOT both-commit.
    assert_equal(
        total_commits, Int64(1), "FCW: EXACTLY ONE thread commits (no both-commit)"
    )
    # The OTHER terminated 23505 — NOT a winner-23505, NOT a silent drop.
    assert_equal(
        total_uv, Int64(1), "FCW: the loser terminates 23505 (exactly one)"
    )
    # NOT a perpetual 40001 loop (cap-exhaust / both-commit counts as error).
    assert_equal(total_errors, Int64(0), "FCW: no livelock / both-commit error")

    # Winner identity (NOT a 23505 for the winner): the surviving LIVE entry's
    # pk == the committing thread's pk. Recover a fresh store + probe.
    var verify = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    verify.register_index(lineage)
    var vr = verify.begin()
    var live = _live_pks_for_value(verify, vr, lineage, seg)
    assert_equal(
        len(live), 1, "FCW: exactly ONE live unique entry at the value"
    )
    assert_equal(
        live[0], winner_pk, "FCW: the WINNER kept its row (live pk == winner)"
    )
    _ = verify^
    _ = results^
    _ = barrier^
    _ = tids^
    _ = shared^
    return Int64(Int(winner_pk))


def test_a_concurrent_first_committer_wins() raises:
    print(
        "[a] CONCURRENT first-committer-wins — 2 threads, same unique value,"
        " EXACTLY ONE commits, loser 23505"
    )
    # Run a few times to shake out scheduling — each run is independently
    # asserted (exactly-one-commit / loser-23505 / no-error / winner-identity).
    for _rep in range(3):
        var winner = _run_fcw(True)
        assert_true(
            winner == Int64(1) or winner == Int64(2),
            "FCW: the winner is one of the two racing pks",
        )
    print("    [OK] (a) concurrent FCW")


# =============================================================================
# (a-disc) DISCRIMINATING SELF-TEST — a stub that retries a unique 40001 like an
# ordinary 40001 (NO post-conflict 23505 conversion) BOTH-COMMITS. This proves
# the FCW falsifier is not a tautology: the discriminator is load-bearing.
# =============================================================================


def _commit_unique_BROKEN_no_recheck[
    Store: ConditionalWriteStore
](
    mut store: TableStore[Store],
    lineage: Int32,
    seg: UInt8,
    pk: UInt8,
    cap: Int,
) raises -> Bool:
    """A deliberately-WRONG variant: on a 40001 it re-drives the txn body WITHOUT
    the post-conflict unique recheck — exactly the stub the design warns
    against. Returns True iff it committed. With the guard key forcing the
    conflict, the loser re-begins at S' (now containing the winner's guard +
    index entry), re-buffers, and — because the guard key already exists at a
    committed chunk — would conflict AGAIN... UNLESS we DROP the guard on
    re-drive (the naive 'simplification'). To model the both-commit hazard the
    design names, the BROKEN variant drops the guard on retry (pk-suffixed index
    keys never collide) ⇒ the second commit SUCCEEDS ⇒ BOTH commit."""
    var attempt = 0
    while attempt < cap:
        attempt += 1
        var t = store.begin()
        t.insert(_heap_key(pk), _b("row"))
        t.insert(_uidx_key(lineage, seg, pk), List[UInt8]())
        # FIRST attempt buffers the guard; retries DROP it (the naive bug).
        if attempt == 1:
            t.insert(_guard_key(seg), List[UInt8]())
        try:
            _ = store.commit(t^)
            return True
        except e:
            if is_occ_conflict(String(e)) or is_commit_retryable(String(e)):
                continue  # re-drive WITHOUT the 23505 recheck — the bug.
            raise e^
    return False


def test_a_disc_stub_both_commits() raises:
    print(
        "[a-disc] DISCRIMINATING — a no-recheck stub BOTH-commits (proves the"
        " discriminator is load-bearing)"
    )
    # Deterministic single-thread reproduction of the both-commit hazard: commit
    # pk=1 (winner), then run the BROKEN no-recheck committer for pk=2 at a stale
    # snapshot. With the correct protocol pk=2 would terminate 23505; the broken
    # stub commits it ⇒ TWO live entries under the same value.
    var store = _new_mem_store(String("uniq_a_disc/") + _unique())
    var lineage = _IDX_BAND
    store.register_index(lineage)
    var seg: UInt8 = 7

    # pk=1 commits cleanly (no contender).
    var conflicts = Int64(0)
    _commit_unique(store, lineage, seg, UInt8(1), False, 64, conflicts)

    # pk=2 via the BROKEN stub. It does NOT do the buffer-time fast-fail nor the
    # post-conflict recheck, so it commits a SECOND entry under the same value.
    var committed = _commit_unique_BROKEN_no_recheck(
        store, lineage, seg, UInt8(2), 64
    )
    assert_true(committed, "the broken stub committed pk=2 (the hazard)")

    var rd = store.begin()
    var live = _live_pks_for_value(store, rd, lineage, seg)
    # The BROKEN stub produced TWO live entries under one unique value — the
    # silent both-commit. The CORRECT protocol (test (a)) yields exactly one.
    assert_equal(
        len(live),
        2,
        "DISCRIMINATING: the no-recheck stub both-commits (2 live entries) —"
        " the correct protocol yields exactly 1",
    )
    print("    [OK] (a-disc) — stub both-commits, so the FCW assert discriminates")


# =============================================================================
# (b) INTRA-TXN same-value — single statement, two rows, same value.
# =============================================================================


def test_b_intra_txn_same_value() raises:
    print(
        "[b] INTRA-TXN same-value — single INSERT of two rows sharing the unique"
        " value ⇒ 23505, ZERO heap rows committed"
    )
    var store = _new_mem_store(String("uniq_b/") + _unique())
    var lineage = _IDX_BAND
    store.register_index(lineage)
    var seg: UInt8 = 11

    var head_before = store.wal_head_seq()  # the pre-statement WAL head

    # Two rows, SAME unique value, distinct pks.
    var segs = List[UInt8]()
    segs.append(seg)
    segs.append(seg)
    var pks = List[UInt8]()
    pks.append(UInt8(1))
    pks.append(UInt8(2))
    var nulls = List[Bool]()
    nulls.append(False)
    nulls.append(False)

    var caught = False
    try:
        _apply_unique_insert_statement(store, lineage, segs, pks, nulls)
    except e:
        caught = is_unique_violation(String(e))
    assert_true(caught, "(b) 23505 raised on the intra-statement duplicate")

    # ZERO heap rows committed — atomic abort (the pre-check fired BEFORE append).
    var rd = store.begin()
    assert_false(Bool(store.get(rd, _heap_key(1))), "(b) pk=1 NOT committed")
    assert_false(Bool(store.get(rd, _heap_key(2))), "(b) pk=2 NOT committed")
    # The load-bearing assert: NO chunk appended (proves the pre-check fired
    # BEFORE the create-CAS, not a post-commit cleanup).
    assert_equal(
        store.wal_head_seq(),
        head_before,
        "(b) NO WAL chunk appended (pre-check fired before create-CAS)",
    )
    # NO index entry at the value.
    var live = _live_pks_for_value(store, rd, lineage, seg)
    assert_equal(len(live), 0, "(b) no index entry committed at the value")
    print("    [OK] (b) intra-txn same-value")


def test_b_disc_buffer_dedup_does_not_catch() raises:
    print(
        "[b-disc] DISCRIMINATING — pk-suffixed keys do NOT collide in _buffer,"
        " so a buffer-dedup 'check' would both-commit (proves (b)'s pre-check"
        " is independently required)"
    )
    # Prove the hazard: WITHOUT the pre-check, buffering two pk-suffixed
    # rows of the same value into one txn commits BOTH heap rows + BOTH index
    # entries (the buffer dedups by EXACT key; the keys differ).
    var store = _new_mem_store(String("uniq_b_disc/") + _unique())
    var lineage = _IDX_BAND
    store.register_index(lineage)
    var seg: UInt8 = 13

    # Buffer two same-value rows directly (bypassing the pre-check) into ONE txn.
    var t = store.begin()
    _buffer_unique_insert(t, lineage, seg, UInt8(1), False)
    _buffer_unique_insert(t, lineage, seg, UInt8(2), False)
    _ = store.commit(t^)

    var rd = store.begin()
    # BOTH heap rows committed (the buffer did NOT overwrite — distinct keys).
    assert_true(Bool(store.get(rd, _heap_key(1))), "(b-disc) pk=1 committed")
    assert_true(Bool(store.get(rd, _heap_key(2))), "(b-disc) pk=2 committed")
    # BOTH index entries live under the same value — the silent violation the
    # pre-check exists to prevent.
    var live = _live_pks_for_value(store, rd, lineage, seg)
    assert_equal(
        len(live),
        2,
        "DISCRIMINATING: without the pre-check, _buffer accepts both pk-suffixed"
        " rows (2 live entries) — so (b)'s intra-statement pre-check is required",
    )
    print("    [OK] (b-disc) — buffer dedup does NOT catch the duplicate")


# =============================================================================
# (c) NULL trap — multiple NULLs allowed; CONTRAST GUARD proves the
#     unique check is still LIVE for non-null values.
# =============================================================================


def test_c_null_multiple_allowed() raises:
    print(
        "[c] NULL trap — multiple NULLs in a unique index all commit; CONTRAST"
        " GUARD: a non-null duplicate still raises 23505"
    )
    var store = _new_mem_store(String("uniq_c/") + _unique())
    var lineage = _IDX_BAND
    store.register_index(lineage)

    # Three rows, ALL with unique value = NULL, distinct pks. NULL != NULL ⇒ all
    # three must commit (the unique check SKIPS a NULL value).
    var segs = List[UInt8]()
    segs.append(_NULL_SEG)
    segs.append(_NULL_SEG)
    segs.append(_NULL_SEG)
    var pks = List[UInt8]()
    pks.append(UInt8(1))
    pks.append(UInt8(2))
    pks.append(UInt8(3))
    var nulls = List[Bool]()
    nulls.append(True)
    nulls.append(True)
    nulls.append(True)
    _apply_unique_insert_statement(store, lineage, segs, pks, nulls)

    var rd = store.begin()
    for pk in range(1, 4):
        assert_true(
            Bool(store.get(rd, _heap_key(UInt8(pk)))),
            "(c) NULL row pk=" + String(pk) + " committed",
        )
    # All three NULL entries live under the NULL-marker sub-range (none
    # suppressed — they are distinct pk-suffixed entries).
    var nulls_live = _live_pks_for_value(store, rd, lineage, _NULL_SEG)
    assert_equal(len(nulls_live), 3, "(c) all 3 NULL entries live (NULL != NULL)")

    # CONTRAST GUARD: a NON-null value V; a second insert of the SAME V ⇒ 23505.
    # Proves the skip is NULL-SPECIFIC (not a disabled check).
    var vseg: UInt8 = 50
    var conflicts = Int64(0)
    _commit_unique(store, lineage, vseg, UInt8(4), False, 64, conflicts)  # ok
    var caught = False
    try:
        _commit_unique(store, lineage, vseg, UInt8(5), False, 64, conflicts)
    except e:
        caught = is_unique_violation(String(e))
    assert_true(
        caught,
        "(c) CONTRAST: the unique check is LIVE for non-null (V dup ⇒ 23505)",
    )
    print("    [OK] (c) NULL multiple allowed + non-null still enforced")


# =============================================================================
# (d) COLD-TIER injectivity — the SQL-face form is NOW
#     COVERED at the driver tier.
# =============================================================================
#
# The SQL-face cold-aware UNIQUE falsifier — INSERT a unique value, columnarize +
# REAP the WAL, then INSERT the SAME value with a DIFFERENT pk and assert 23505 —
# is now LIVE at the DRIVER tier:
# the driver's cold-tier lifecycle test,
# `test_b_cold_aware_unique_rejects_columnarized_reaped_duplicate`. There the
# SQL driver's database owns a paired `ColumnarCatalog` and the SI-7 UNIQUE check
# routes through `index_scan_visible_dual_tier`, so a columnarized+reaped
# committed duplicate is SEEN (a hot-only check silently accepts it — the
# discriminator that test asserts side-by-side).
#
# This LEAF-level (`komira_table_store`) variant stays out of scope BY DESIGN: the
# reuse-safe `komira_table_store` leaf deliberately has NO columnar/Parquet
# dependency (the cycle ban at table_store.mojo:819-832), so the dual-tier
# cold-read machinery (`heap_visible_at_dual_tier` / `index_scan_visible_dual_
# tier` in the columnar adapter package) is consumed by the ADAPTER tier (the
# driver + the SQL executor), not by this leaf. The pk-SUFFIXED keying this file
# enforces is precisely what makes the driver-tier falsifier pass: `(U,pk1)` and
# `(U,pk2)` are distinct `__key`s, so `_assign_xmax` chains each independently
# and a cold read at the reinsert snapshot returns pk2, NEVER the stale pk1.


def main() raises:
    print("== table store SI-7 UNIQUE enforcement (storage-level protocol) ==")
    # Discriminating self-tests FIRST (prove the falsifiers are not tautologies).
    test_a_disc_stub_both_commits()
    test_b_disc_buffer_dedup_does_not_catch()
    # The named falsifiers.
    test_b_intra_txn_same_value()
    test_c_null_multiple_allowed()
    # THE concurrent first-committer-wins falsifier (real OS threads) — last so a
    # failure in the deterministic checks surfaces first.
    test_a_concurrent_first_committer_wins()
    print(
        "[OK] test_table_store_unique_index — (a) concurrent FCW + (b) intra-txn +"
        " (c) NULL + discriminating self-tests — exactly-one-commit, terminal"
        " 23505, no both-commit / no perpetual 40001 loop"
    )
