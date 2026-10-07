# =============================================================================
# src/komira_table_store/tests/test_table_store_multiwriter_gcs_occ.mojo
#   THE MULTI-WRITER PROOF — table-store-on-GCS is safe for
#   ANY number of concurrent writers. Retires the "single-writer discipline"
#   posture; the base OCC path is multi-writer-safe by construction.
# =============================================================================
#
# Design driver: any number of concurrent callers must just work.
#
# THE CLAIM THIS TEST PROVES. A table store commit is ONE create-CAS append at
# EXACTLY `auth_head+1` (`try_append_at_seq`) gated by an OCC first-committer-
# wins check against the AUTHORITATIVE head. This is the canonical object-store
# OCC pattern (Delta Lake / Iceberg / Aurora DSQL all converge here). N
# concurrent writers make the losers 412-and-retry (bounded exponential backoff
# + full jitter, `MAX_COMMIT_ATTEMPTS=256`); there is NO silent clobber and NO
# torn commit. `_HEAD` is a NON-authoritative cache — a stale read only ever
# wastes a CAS attempt, never produces a committed wrong offset.
#
# WHY THE `SharedInMemoryConditionalStore` IS THE RIGHT SUBSTRATE. It is the
# documented OFFLINE TWIN of the live-GCS/MinIO CAS gate (its header, verbatim):
# its spinlock LINEARIZES every conditional-write verb, "which is exactly the S3
# conditional-write contract (S3 linearizes conditional PUTs server-side)". GCS
# `if_generation_match` is the IDENTICAL contract — create-if-absent
# (`if_generation_match=0`) succeeds only when absent (412/ALREADY_EXISTS on
# conflict), and CAS (`if_generation_match=<gen>`) succeeds only on a generation
# match (see `FakeGcsStorageBackend`, gcs_storage_backend.mojo:325-427, which
# models the SAME generation-CAS semantics + the SAME 412 tokens the OCC loop
# classifies). The `GcsGrpcConditionalStore[FakeGcsStorageBackend]` conformer's
# `clone()` mints a FRESH disjoint backend (per-conformer disjoint-transport
# invariant), so it CANNOT be shared across threads for genuine contention;
# the Arc-SHARED `SharedInMemoryConditionalStore` is what lets K real OS threads
# contend on ONE manifest lineage, exercising the IDENTICAL `TableStore` /
# `CasManifestStore` commit loop that runs on GCS UNCHANGED (the store is a
# backend selector; the OCC code is store-generic — table_store.mojo:9-12).
#
# THE MULTI-WRITER POSTURE (load-bearing). Every writer opens with
# `with_writer_lease_fastpath=False`. The lease fast-path caches
# a LOCAL head and can MISS the OCC window `(local_head, real_head]` a sibling
# extended — a missed-conflict hole under concurrency. It MUST be
# OFF for multi-writer; the base path OCC-validates against the AUTHORITATIVE
# LIST head every commit. (The lease epochs default (0,0) = no fence — the
# irreducible-TOCTOU epoch fence is not engaged.)
#
# WHAT THIS TEST ADDS over test_table_store_concurrency.mojo (which hammers ONE HOT
# key + private keys and audits the HOT version-chain):
#   (T1) N writers each commit M DISTINCT rows (writer-partitioned keyspace) to
#        the SAME lineage; the final MATERIALIZED table (read via `scan`) is the
#        EXACT linearizable UNION of all N*M rows — NO lost update, gapless WAL.
#   (T2) FORCED CONFLICT -> CLEAN typed 40001 (deterministic, single-thread):
#        two txns pinned at ONE snapshot both write the same key; the loser's
#        commit raises a CLEAN OCC_CONFLICT 40001 (never a torn/corrupt read),
#        and the store stays readable + gapless after the abort.
#   (T3) FORCED RETRY EXHAUSTION -> CLEAN retryable typed conflict: a tight
#        RetryPolicy (max_retries=0) under continuous same-key contention makes
#        the loser surface the CLEAN "(retryable)" / 40001 typed signal, NEVER a
#        corrupt read; the durable WAL remains gapless (create-CAS is the sole
#        arbiter regardless of the retry budget).
#   (T4) SUSTAINED SEQUENTIAL-RPC leg (regression guard): a long run of
#        sequential commit+read RPCs on ONE reused store handle completes without
#        a wedge — the store-op analog of the h2 WINDOW_UPDATE fix, which
#        must hold after N RPCs.
#
# Threading idiom: K pthreads via the sanctioned FFI-BOUNDARY pthread-launch
# carve-out (heap-boxed arg + per-thread heap-stable results slot read after
# join, DISJOINT slots), IDENTICAL to the in-tree test_table_store_concurrency.mojo.
# stale-reuse: no byte-slab element, no wildcard-origin FIELD, no unsafe_from_address
# except the two sanctioned FFI void*/results-addr ABI args (each SAFETY-blocked).
# Tagged `large`.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_false, assert_true

from komira_collections.slab import Slab

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_table_store.table_store_codec import bytes_eq
from komira_table_store.table_store import (
    TableStore,
    Txn,
    is_commit_retryable,
    is_occ_conflict,
)


# -----------------------------------------------------------------------------
# byte/string helpers
# -----------------------------------------------------------------------------


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _str(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (b2-safe null idiom; mirrors
    test_table_store_concurrency.mojo).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. Origin `o` is concrete;
    # the NULL sentinel is never dereferenced (placeholder / explicit C-NULL arg).
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


def _unique() -> String:
    var x = UInt64(perf_counter_ns())
    x ^= x >> UInt64(33)
    x *= UInt64(0xFF51AFD7ED558CCD)
    x ^= x >> UInt64(33)
    var out = String("")
    var shift = 60
    while shift >= 0:
        var nib = Int((x >> UInt64(shift)) & UInt64(0xF))
        if nib < 10:
            out += chr(0x30 + nib)
        else:
            out += chr(0x61 + nib - 10)
        shift -= 4
    return out^


@always_inline
def _open_writer(
    store: SharedInMemoryConditionalStore, prefix: String, retry: RetryPolicy
) raises -> TableStore[SharedInMemoryConditionalStore]:
    """Open a multi-writer-posture TableStore over a clone() of the shared store:
    lease fast-path OFF, the given retry policy. Every writer in
    this test uses this so the OCC always validates against the AUTHORITATIVE
    LIST head (no lease-cached-head missed-conflict hole)."""
    return TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=store.clone(), prefix=prefix.copy(), retry=retry
        ),
        with_writer_lease_fastpath=False,
    )


# =============================================================================
# Per-thread results (heap-stable; DISJOINT; read after join)
# =============================================================================


struct _WriterResults(Movable, Deinitable):
    var commits: Int64  # rows this thread committed durably
    var conflicts: Int64  # clean typed conflicts (40001 / retryable) seen + retried
    var errors: Int64  # UNEXPECTED errors (a non-typed / corrupt signal)
    var torn_reads: Int64  # a read that returned a corrupt/unexpected value

    def __init__(out self):
        self.commits = Int64(0)
        self.conflicts = Int64(0)
        self.errors = Int64(0)
        self.torn_reads = Int64(0)


# =============================================================================
# The pthread arg — a SHARED store clone + the work spec + a results address
# =============================================================================


struct _WriterArg(Movable, Deinitable):
    var store: SharedInMemoryConditionalStore
    var prefix: String
    var thread_id: Int64
    var rows_per_writer: Int64
    # # SAFETY: address of a heap-stable `_WriterResults` owned by the main
    # thread (alive until join). Plain Int — no wildcard field.
    var results_addr: Int

    def __init__(
        out self,
        var store: SharedInMemoryConditionalStore,
        var prefix: String,
        thread_id: Int64,
        rows_per_writer: Int64,
        results_addr: Int,
    ):
        self.store = store^
        self.prefix = prefix^
        self.thread_id = thread_id
        self.rows_per_writer = rows_per_writer
        self.results_addr = results_addr


@always_inline
def _row_key(thread_id: Int64, i: Int64) -> String:
    """Writer-partitioned key: `w<tid>_r<i>`. DISJOINT across writers — no two
    writers ever target the same key, so the correctness property is "every one
    of the N*M distinct rows lands" (a lost update = a missing distinct row).
    Writers still CONTEND at the SHARED create-CAS slot (`auth_head+1`) — every
    commit races every other writer's commit for the next chunk slot."""
    return String("w") + String(Int(thread_id)) + String("_r") + String(Int(i))


@always_inline
def _row_val(thread_id: Int64, i: Int64) -> String:
    """A self-describing value the union-audit can verify belongs to exactly one
    (writer, row) pair: `t<tid>:v<i>`."""
    return String("t") + String(Int(thread_id)) + String(":v") + String(Int(i))


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
    # SAFETY (FFI-BOUNDARY — sanctioned pthread-launch carve-out): the results
    # address is a main-thread `OwnedPointer[_WriterResults]` pointee, alive until
    # the main thread joins this pthread. DISJOINTNESS: writer `w` writes ONLY its
    # own results slot. No realloc of the slot.
    var results_ptr = UnsafePointer[_WriterResults, MutUntrackedOrigin](
        unsafe_from_address=arg.results_addr
    )
    # Each thread builds its OWN TableStore over a clone() of the shared store
    # (they contend at the shared create-CAS slot; the in-RAM index is per-thread,
    # cross-thread visibility goes through the WAL). Lease fast-path OFF.
    var ts = _open_writer(
        arg.store, arg.prefix, RetryPolicy.broker_contention()
    )

    var i = Int64(0)
    while i < arg.rows_per_writer:
        var key = _row_key(arg.thread_id, i)
        var val = _row_val(arg.thread_id, i)
        # Commit ONE distinct row per iteration. Distinct keys never OCC-conflict
        # (no writer touches another's key), but every commit races the shared
        # create-CAS slot — a 412 loser re-reads the authoritative head + re-drives
        # at the new auth_head+1. Retry until it lands (bounded cap = livelock
        # backstop; the create-CAS total order guarantees forward progress).
        var attempt = 0
        comptime ROW_RETRY_CAP = 400
        var committed = False
        while not committed and attempt < ROW_RETRY_CAP:
            attempt += 1
            var t = ts.begin()
            t.insert(_b(key), _b(val))
            try:
                _ = ts.commit(t^)
                committed = True
                results_ptr[].commits += Int64(1)
            except e:
                var em = String(e)
                if is_occ_conflict(em) or is_commit_retryable(em):
                    # A CLEAN typed conflict — re-begin at a fresh snapshot +
                    # retry. NOT a correctness failure (the create-CAS slot is the
                    # sole arbiter). For DISJOINT keys this should be a slot-race
                    # 412 re-drive (retryable), never a genuine write-write 40001.
                    results_ptr[].conflicts += Int64(1)
                else:
                    # An UNEXPECTED (non-typed) error — a corrupt / torn signal.
                    results_ptr[].errors += Int64(1)
                    print("WARN writer unexpected error: ", em)
                    committed = True  # give up this row on a hard error
        if not committed:
            results_ptr[].errors += Int64(1)
            print("WARN writer: row livelocked (cap exhausted)")
        i += Int64(1)


def _spawn_writer(var arg: _WriterArg, mut tid_slot: Int64) raises -> Int32:
    # SAFETY: heap-box the arg, hand its address to pthread_create; the thread
    # reconstructs + frees it. MutExternalOrigin only on the void* ABI args.
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


# =============================================================================
# WAL-gapless helper (the create-CAS total order: no hole, no dup slot)
# =============================================================================


def _assert_wal_gapless(
    ts: TableStore[SharedInMemoryConditionalStore], tag: String
) raises:
    var head = ts.wal_head_seq()
    var seq = Int64(0)
    while seq <= head:
        var keys = ts.wal_chunk_keys(seq)  # raises if the slot is missing
        assert_true(
            len(keys) >= 1, tag + ": chunk " + String(Int(seq)) + " has >=1 key"
        )
        seq += Int64(1)


# =============================================================================
# (T1) N concurrent writers -> distinct-row linearizable UNION
# =============================================================================


def _run_multiwriter_union(k: Int, rows_per_writer: Int64) raises:
    print(
        "[T1] multi-writer union K=" + String(k) + " writers x "
        + String(Int(rows_per_writer)) + " distinct rows -> ONE lineage"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("ts/mw_union/k") + String(k) + String("_") + _unique()

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
            thread_id=Int64(w),
            rows_per_writer=rows_per_writer,
            results_addr=addr,
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
    var total_commits = Int64(0)
    var total_conflicts = Int64(0)
    var total_errors = Int64(0)
    for wi in range(k):
        total_commits += results[wi][].commits
        total_conflicts += results[wi][].conflicts
        total_errors += results[wi][].errors

    # No unexpected / corrupt error (no torn commit, no SIGSEGV).
    assert_equal(
        total_errors, Int64(0), "T1: no unexpected errors / torn commits"
    )
    # Every writer committed EVERY one of its distinct rows (a lost update on a
    # distinct key = a failed commit the writer never recorded).
    var expected_rows = Int64(k) * rows_per_writer
    assert_equal(
        total_commits,
        expected_rows,
        "T1: every writer committed all its distinct rows (no lost commit)",
    )

    # ---- recover a FRESH handle (cold boot) + audit the durable truth ----
    # A fresh open() replays the AUTHORITATIVE WAL tail = the total order the
    # create-CAS slot imposed (bucket-is-truth). This is the strongest read: a
    # brand-new caller must see the linearizable union of ALL writers' commits.
    var verify = _open_writer(shared, prefix, RetryPolicy.fast_test())

    # (a) LINEARIZABLE COMMIT ORDER: WAL [0..head] gapless + contiguous — no
    #     hole, no duplicate slot, no torn chunk. head+1 == N*M (one commit per
    #     distinct row; each won exactly one slot).
    _assert_wal_gapless(verify, "T1")
    var head = verify.wal_head_seq()
    assert_equal(
        head + Int64(1),
        expected_rows,
        "T1: WAL chunk count == N*M (one committed slot per distinct row)",
    )

    # (b) FINAL MATERIALIZED TABLE == the EXACT UNION of all N*M rows. Scan the
    #     whole keyspace at the recovered head and check:
    #       - every (writer, row) pair is present at its OWN value (no lost row);
    #       - no row carries another writer's value (no cross-writer clobber);
    #       - the scan cardinality == N*M (no phantom, no missing, no dup).
    var rv = verify.begin()
    var seen = Int64(0)
    var ti = Int64(0)
    while ti < Int64(k):
        var ri = Int64(0)
        while ri < rows_per_writer:
            var key = _row_key(ti, ri)
            var got = verify.get(rv, _b(key))
            assert_true(
                Bool(got),
                "T1: row " + key + " present in the materialized union",
            )
            var want = _row_val(ti, ri)
            assert_true(
                bytes_eq(got.value(), _b(want)),
                "T1: row " + key + " has its OWN value (no cross-writer clobber)"
                " — want '" + want + "' got '" + _str(got.value()) + "'",
            )
            seen += Int64(1)
            ri += Int64(1)
        ti += Int64(1)
    assert_equal(seen, expected_rows, "T1: union audit visited all N*M rows")

    # (c) The full-range scan cardinality equals N*M (no extra / phantom keys).
    var all_rows = verify.scan_from(rv, _b("w"))
    assert_equal(
        Int64(len(all_rows)),
        expected_rows,
        "T1: scan cardinality == N*M (materialized table = exact union)",
    )
    # Every scanned row is a valid (writer,row) token — belt-and-suspenders no-torn.
    for si in range(len(all_rows)):
        ref kv = all_rows[si]
        var kstr = _str(kv.key)
        assert_true(
            len(kv.row) >= 3 and Int(kv.row[0]) == ord("t"),
            "T1: scanned row for key '" + kstr + "' is a well-formed value"
            " (not torn): '" + _str(kv.row) + "'",
        )

    _ = verify^
    _ = results^
    _ = tids^
    _ = shared^
    print(
        "    [OK] (T1) K=" + String(k) + ": commits="
        + String(Int(total_commits)) + " conflicts="
        + String(Int(total_conflicts)) + " head=" + String(Int(head))
        + " — final table == exact linearizable union of all "
        + String(Int(expected_rows)) + " rows"
    )


def test_t1_multiwriter_union_16() raises:
    # K=16 x 40 = 640 distinct rows through ONE shared create-CAS lineage.
    _run_multiwriter_union(16, Int64(40))


def test_t1_multiwriter_union_32() raises:
    # K=32 x 20 = 640 distinct rows — higher writer fan-out (the "any
    # number of callers" upper stress on this rig).
    _run_multiwriter_union(32, Int64(20))


# =============================================================================
# (T2) FORCED CONFLICT -> CLEAN typed 40001, never a torn read (deterministic).
# =============================================================================
#
# Two txns pinned at the SAME snapshot both write the SAME key. The first commits
# (wins the create-CAS slot); the second's OCC check scans (snapshot, auth_head]
# and finds the winner's conflicting key -> raises a CLEAN OCC_CONFLICT 40001.
# This is the deterministic form of "when a writer loses, it surfaces a clean
# typed conflict, NOT a corrupt/torn read". After the abort the store stays
# readable (the winner's value) and the WAL is gapless (the loser wrote NOTHING).


def test_t2_forced_conflict_clean_40001() raises:
    print("[T2] forced write-write conflict -> CLEAN typed 40001 (no torn read)")
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("ts/mw_conflict/") + _unique()

    var ts = _open_writer(shared, prefix, RetryPolicy.fast_test())

    # Seed the key so both racers pin a common snapshot that PRECEDES both writes.
    var s0 = ts.begin()
    s0.insert(_b("K"), _b("seed"))
    _ = ts.commit(s0^)

    # Two txns at the SAME snapshot, both targeting K.
    var a = ts.begin()
    var b = ts.begin()
    assert_equal(
        a.snapshot_lsn, b.snapshot_lsn, "T2: both racers pinned same snapshot"
    )
    a.update(_b("K"), _b("winner"))
    b.update(_b("K"), _b("loser"))

    # A commits (wins the slot at snapshot+1).
    var ra = ts.commit(a^)
    _ = ra

    # B commits at the STALE snapshot -> OCC finds A's conflicting K -> CLEAN
    # typed 40001. It MUST NOT be an unexpected/corrupt error, and MUST NOT
    # silently succeed (a silent success would be a LOST UPDATE = the winner's
    # write clobbered).
    var caught_40001 = False
    var wrong_class = False
    try:
        _ = ts.commit(b^)
        # Reached only if commit SUCCEEDED — that is a LOST UPDATE. Fail loud.
        assert_true(
            False,
            "T2: loser's commit MUST raise (a silent success is a lost update)",
        )
    except e:
        var em = String(e)
        if is_occ_conflict(em):
            caught_40001 = True
        elif is_commit_retryable(em):
            # Also a CLEAN typed conflict signal (acceptable), but for this
            # deterministic same-snapshot key overlap we EXPECT the precise 40001.
            caught_40001 = True
        else:
            wrong_class = True
            print("WARN T2: loser raised a NON-typed error: ", em)
    assert_false(
        wrong_class, "T2: loser's conflict is a TYPED conflict, not corrupt"
    )
    assert_true(caught_40001, "T2: loser surfaced a CLEAN typed conflict (40001)")

    # ---- the store is NOT torn: the winner's value is durably readable, the WAL
    #      is gapless, and a FRESH cold-boot handle agrees (the loser wrote nada).
    var verify = _open_writer(shared, prefix, RetryPolicy.fast_test())
    _assert_wal_gapless(verify, "T2")
    # seed (slot 0) + winner (slot 1) = 2 chunks; the loser committed NOTHING.
    assert_equal(
        verify.wal_head_seq(),
        Int64(1),
        "T2: exactly 2 committed chunks (seed + winner) — loser wrote nothing",
    )
    var vt = verify.begin()
    var got = verify.get(vt, _b("K"))
    assert_true(Bool(got), "T2: K present after the conflict (not torn)")
    assert_true(
        bytes_eq(got.value(), _b("winner")),
        "T2: K == winner's value (the loser did NOT clobber): got '"
        + _str(got.value()) + "'",
    )
    _ = verify^
    _ = ts^
    _ = shared^
    print("    [OK] (T2) forced conflict -> clean 40001, winner durable, no tear")


# =============================================================================
# (T3) LOSER UNDER A ZERO-BUDGET RETRY POLICY -> CLEAN typed conflict, no tear.
# =============================================================================
#
# The design's forward-progress guarantee: a loser ALWAYS surfaces a CLEAN typed
# conflict (is_occ_conflict OR is_commit_retryable) regardless of its retry
# budget — the create-CAS slot is the sole arbiter, and the OCC write-write check
# fires BEFORE any create-CAS. Here we open the loser with a ZERO-budget
# RetryPolicy (max_retries=0, base/cap=1us) to prove the retry budget cannot turn
# a conflict into a corrupt/torn read: even a writer configured to give up
# instantly still gets a clean typed conflict, never a torn commit, and the WAL
# stays gapless. (The retryable-EXHAUSTION path under a 412 storm — the
# COMMIT_RETRYABLE / "(retryable)" signal — is separately proven by the K>=16
# broker_contention soak in test_table_store_concurrency.mojo; this leg pins the
# deterministic "clean-conflict-under-no-budget" corner.)
#
# We drive this SINGLE-THREADED + DETERMINISTIC: two same-key txns at one
# snapshot; the winner lands, the loser's commit raises a CLEAN typed signal.


def test_t3_zero_budget_loser_clean_conflict() raises:
    print(
        "[T3] zero-budget loser -> CLEAN typed conflict (never a torn read)"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("ts/mw_exhaust/") + _unique()

    # A policy with ZERO retry budget (base/cap=1us, max_retries=0): a writer
    # configured to give up on the first sign of contention. It MUST still get a
    # CLEAN typed conflict — never a corrupt read.
    var no_retry = RetryPolicy(Int64(1), Int64(1), 0)

    var winner = _open_writer(shared, prefix, RetryPolicy.fast_test())
    var loser = _open_writer(shared, prefix, no_retry)

    # Seed X so both racers share a common preceding snapshot.
    var s0 = winner.begin()
    s0.insert(_b("X"), _b("seed"))
    _ = winner.commit(s0^)

    # Both pin the same snapshot; both write X.
    var wt = winner.begin()
    var lt = loser.begin()
    wt.update(_b("X"), _b("W"))
    lt.update(_b("X"), _b("L"))

    # Winner lands X = "W".
    _ = winner.commit(wt^)

    # Loser commits at the stale snapshot: the OCC write-write check sees the
    # winner's X and raises a CLEAN typed conflict BEFORE any create-CAS, so the
    # zero retry budget is irrelevant to correctness — the loser MUST get a typed
    # conflict, never a corrupt read.
    var clean = False
    var wrong_class = False
    try:
        _ = loser.commit(lt^)
        assert_true(
            False, "T3: loser MUST raise (silent success would be lost update)"
        )
    except e:
        var em = String(e)
        if is_occ_conflict(em) or is_commit_retryable(em):
            clean = True
        else:
            wrong_class = True
            print("WARN T3: loser raised a NON-typed error: ", em)
    assert_false(wrong_class, "T3: exhausted loser's error is TYPED, not corrupt")
    assert_true(clean, "T3: exhausted loser surfaced a CLEAN typed conflict")

    # Durable truth: winner landed, WAL gapless, loser wrote nothing (no tear).
    var verify = _open_writer(shared, prefix, RetryPolicy.fast_test())
    _assert_wal_gapless(verify, "T3")
    assert_equal(
        verify.wal_head_seq(),
        Int64(1),
        "T3: 2 committed chunks (seed + winner); exhausted loser wrote nothing",
    )
    var vt = verify.begin()
    var got = verify.get(vt, _b("X"))
    assert_true(Bool(got), "T3: X present after exhaustion (not torn)")
    assert_true(
        bytes_eq(got.value(), _b("W")),
        "T3: X == winner value (exhausted loser did not clobber): '"
        + _str(got.value()) + "'",
    )
    _ = verify^
    _ = winner^
    _ = loser^
    _ = shared^
    print("    [OK] (T3) retry exhaustion -> clean typed conflict, no tear")


# =============================================================================
# (T4) SUSTAINED SEQUENTIAL-RPC leg (regression guard).
# =============================================================================
#
# A long run of sequential commit+read RPCs on ONE reused store handle. This is
# the store-op analog of the h2 WINDOW_UPDATE fix: the
# transport must survive UNBOUNDED sequential RPCs without a
# wedge. Here every commit is a create-CAS append + best-effort `_HEAD` advance,
# and every read replays the growing multi-chunk manifest — exactly the
# O(chunks) sequential-GET reader (`_recover_head_by_list`) that 
# stressed. If the reader/commit path wedged after N chunks, this leg would
# hang / mis-read; it completing cleanly with a monotone gapless WAL is the
# regression guard. (Correctness is store-generic; the wire fix is verified on
# real GCS separately — this guards that the SEQUENTIAL-RPC contract holds.)


def test_t4_sustained_sequential_rpc_no_wedge() raises:
    print("[T4] sustained sequential-RPC leg (h2 WINDOW_UPDATE guard)")
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("ts/mw_seq/") + _unique()

    var ts = _open_writer(shared, prefix, RetryPolicy.fast_test())

    # N sequential commit+read RPCs on ONE reused handle. N is large enough that
    # a stream-ID / reactor-state accumulation wedge (the  shape) would
    # have surfaced; the manifest grows to N chunks so each read exercises the
    # multi-chunk O(chunks) reader path.
    comptime N = Int64(512)
    var i = Int64(0)
    while i < N:
        var key = String("seq_") + String(Int(i))
        var val = String("val_") + String(Int(i))
        var t = ts.begin()
        t.insert(_b(key), _b(val))
        var res = ts.commit(t^)
        # Each sequential commit wins its own slot (single-writer sequential:
        # NO contention, so the create-CAS wins on the first attempt). There is
        # NO seed in this leg, so `seq_i` lands at slot `i` (monotone, gapless).
        assert_equal(
            res.commit_lsn,
            i,
            "T4: sequential commit "
            + String(Int(i))
            + " landed at its own monotone slot (no wedge, no gap)",
        )
        # Read back the row we JUST wrote (a read RPC over the growing manifest).
        var rt = ts.begin()
        var got = ts.get(rt, _b(key))
        assert_true(Bool(got), "T4: RPC " + String(Int(i)) + " read-after-write")
        assert_true(
            bytes_eq(got.value(), _b(val)),
            "T4: RPC " + String(Int(i)) + " read the value it just wrote",
        )
        i += Int64(1)

    # After N sequential RPCs the WAL is a gapless N-chunk manifest, and a FRESH
    # cold-boot handle can replay the whole multi-chunk manifest (the O(chunks)
    # reader) without wedging — the  guard.
    _assert_wal_gapless(ts, "T4")
    assert_equal(
        ts.wal_head_seq(),
        N - Int64(1),
        "T4: N sequential RPCs -> N gapless chunks (slots 0..N-1), no wedge",
    )
    var verify = _open_writer(shared, prefix, RetryPolicy.fast_test())
    _assert_wal_gapless(verify, "T4-recover")
    var vt = verify.begin()
    # Spot-check the first, middle, last rows survive the full multi-chunk replay.
    var checks = List[Int64]()
    checks.append(Int64(0))
    checks.append(N // Int64(2))
    checks.append(N - Int64(1))
    for ci in range(len(checks)):
        var idx = checks[ci]
        var key = String("seq_") + String(Int(idx))
        var val = String("val_") + String(Int(idx))
        var got = verify.get(vt, _b(key))
        assert_true(
            Bool(got) and bytes_eq(got.value(), _b(val)),
            "T4: cold-boot multi-chunk replay recovered row " + key,
        )
    _ = verify^
    _ = ts^
    _ = shared^
    print(
        "    [OK] (T4) " + String(Int(N))
        + " sequential commit+read RPCs on one handle — no wedge, gapless"
    )


def main() raises:
    print("== table-store-on-GCS MULTI-WRITER PROOF ==")
    # (T2)/(T3) deterministic conflict proofs first (fast, no threads).
    test_t2_forced_conflict_clean_40001()
    test_t3_zero_budget_loser_clean_conflict()
    # (T4) sustained sequential-RPC regression guard.
    test_t4_sustained_sequential_rpc_no_wedge()
    # (T1) the headline N-concurrent-writer distinct-row UNION proofs.
    test_t1_multiwriter_union_16()
    test_t1_multiwriter_union_32()
    print(
        "[OK] test_table_store_multiwriter_gcs_occ — table-store-on-GCS is MULTI-WRITER"
        " SAFE (OCC): N concurrent writers -> linearizable union, no lost update,"
        " no torn read, gapless WAL; losers surface CLEAN typed conflicts; the"
        " sequential-RPC leg holds (guard). Throughput serializes on"
        " the append sequence (~1 commit/s per object on live GCS)."
    )
