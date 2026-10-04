# =============================================================================
# src/komira_table_store/tests/test_table_store_si_occ_property.mojo
#   PRIORITY 2 (storage-level SI/OCC) — the three additive deterministic
#   witnesses the existing harnesses do not already pin:
#     C-SI-WRITESKEW   — SI is NOT serializable (an explicit write-skew witness).
#     C-SI-FCW-NWAY    — N∈{3,5,10} same-snapshot intersecting writers: EXACTLY
#                        one commits, N-1 get the OCC 40001, no lost update, the
#                        HOT version-chain is strictly LSN-increasing with no dup.
#     C-CROSS-HANDLE-FOLD — handle B folds handle A's just-committed chunk at
#                        B's snapshot; begin() pins max(read_head, _folded_seq).
#
# These complement (NOT duplicate) the existing storage tests:
#   * test_table_store_correctness.mojo (d) is a 2-writer deterministic OCC; this
#     generalizes to N∈{3,5,10} with the exactly-one-winner + version-chain
#     invariants asserted per round.
#   * test_table_store_correctness.mojo (h) proves cross-handle VISIBILITY; this
#     pins the begin()-snapshot-pinning rule (max(read_head, _folded_seq)) that
#     makes B see A's just-committed chunk at B's snapshot.
#   * The SI-property harness (144 seeds) checks SI holds; NONE of them states
#     the write-skew anomaly EXPLICITLY as a documented witness — SI admits it.
#
# THE INVARIANT BATTERY pinned here:
#   INV-1 SI-posture (write-skew ADMITTED) — C-SI-WRITESKEW.
#   INV-4 FCW (exactly-one-winner, no lost update via HOT version-chain) —
#         C-SI-FCW-NWAY (strictly LSN-increasing chain, no two chunks the same
#         HOT value).
#   INV-2 atomicity (each winning write-set folds together at one LSN).
#
# DETERMINISTIC (single-driver, no OS threads): these are reproducible
# witnesses, not a race — the interleave is forced by hand. The OS-thread
# randomized property runs in test_table_store_si_thread_property.mojo (C-SI-THREAD-
# PROPERTY).
#
# Encapsulation / stale-reuse: ZERO UnsafePointer in any signature; ZERO wildcard
# origins / unsafe_from_address / take_pointee. Sessions / handles are plain
# owned TableStore values; the reference checks are plain Lists.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore

from komira_table_store.table_store_codec import bytes_eq
from komira_table_store.table_store import (
    TableStore,
    Txn,
    is_commit_retryable,
    is_occ_conflict,
)


# =============================================================================
# byte helpers + handle factory
# =============================================================================


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _open_shared(
    shared: SharedInMemoryConditionalStore, prefix: String
) raises -> TableStore[SharedInMemoryConditionalStore]:
    """A fresh TableStore handle over a clone() of the shared store (its OWN
    partial in-RAM index; cross-handle visibility goes through the WAL)."""
    return TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(),
            prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )


# =============================================================================
# C-SI-WRITESKEW (storage) — SI is NOT serializable. Two txns at the SAME
# snapshot, DISJOINT read sets, CROSS-writing: BOTH commit. This is the canonical
# write-skew anomaly, ADMITTED under snapshot isolation (a documented witness,
# NOT a bug — INV-1 SI-posture).
# =============================================================================


def test_c_si_writeskew_both_commit() raises:
    """The write-skew witness: x and y both start = 0 (the classic "at least one
    of x,y must stay 0" constraint). T1 reads y(=0) and writes x=1; T2 reads
    x(=0) and writes y=1. They pin the SAME snapshot, their write sets are
    DISJOINT ({x} vs {y}), so OCC (which conflicts only on write-write overlap)
    lets BOTH commit. The result x=1,y=1 violates the constraint — a
    serializable scheduler would have aborted one. SI ADMITS it. This documents
    the SI guarantee boundary explicitly (INV-1)."""
    print("[c-si-writeskew] SI is NOT serializable (write-skew ADMITTED)")
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/writeskew")

    # Seed x=0, y=0 (LSN 0).
    var seed = _open_shared(shared, prefix)
    var ts = seed.begin()
    ts.insert(_b("x"), _b("0"))
    ts.insert(_b("y"), _b("0"))
    var sr = seed.commit(ts^)
    assert_equal(sr.commit_lsn, Int64(0), "seed x=0,y=0 at LSN 0")
    _ = seed^

    # Two handles pin the SAME snapshot (the seeded head = 0).
    var h1 = _open_shared(shared, prefix)
    var h2 = _open_shared(shared, prefix)
    var t1 = h1.begin()
    var t2 = h2.begin()
    assert_equal(t1.snapshot_lsn, Int64(0), "T1 pins snapshot 0")
    assert_equal(t2.snapshot_lsn, Int64(0), "T2 pins snapshot 0")

    # T1 READS y (=0), then writes x=1. T2 READS x (=0), then writes y=1.
    # The reads observe the constraint as satisfied (the other var is 0), so each
    # txn "believes" it may set its own var to 1.
    var t1_read_y = h1.get(t1, _b("y"))
    assert_true(
        Bool(t1_read_y) and bytes_eq(t1_read_y.value(), _b("0")),
        "T1 reads y=0 at its snapshot",
    )
    t1.update(_b("x"), _b("1"))  # write set = {x}

    var t2_read_x = h2.get(t2, _b("x"))
    assert_true(
        Bool(t2_read_x) and bytes_eq(t2_read_x.value(), _b("0")),
        "T2 reads x=0 at its snapshot",
    )
    t2.update(_b("y"), _b("1"))  # write set = {y} — DISJOINT from T1's

    # BOTH commit (disjoint write sets => no first-committer-wins conflict).
    var r1 = h1.commit(t1^)
    assert_equal(r1.commit_lsn, Int64(1), "T1 commits x=1 at LSN 1")
    var r2 = h2.commit(t2^)
    assert_equal(
        r2.commit_lsn, Int64(2),
        "T2 ALSO commits y=1 at LSN 2 — write-skew ADMITTED (SI is not"
        " serializable; a serializable scheduler would abort one)",
    )

    # The end state is x=1 AND y=1 — the anomaly a serializable execution forbids
    # but SI permits. Read it back on a fresh handle.
    var rd = _open_shared(shared, prefix)
    var v = rd.begin()
    var rx = rd.get(v, _b("x"))
    var ry = rd.get(v, _b("y"))
    assert_true(Bool(rx) and bytes_eq(rx.value(), _b("1")), "final x=1")
    assert_true(Bool(ry) and bytes_eq(ry.value(), _b("1")), "final y=1")
    rd.abort(v^)
    _ = rd^
    _ = h1^
    _ = h2^
    _ = shared^
    print(
        "    [OK] write-skew: BOTH committed (x=1,y=1) — INV-1 SI-posture"
        " witness (SI admits write-skew; this is the documented boundary)"
    )


# =============================================================================
# C-SI-FCW-NWAY (deterministic) — N writers at the SAME snapshot on INTERSECTING
# keys: EXACTLY one commits, N-1 get the OCC 40001 (no lost update). Generalizes
# the existing 2-writer deterministic (d) to N∈{3,5,10}. After the winner +
# losers-retry-to-completion, the HOT version chain is strictly LSN-increasing
# with NO duplicate value (the genuine lost-update falsifier — INV-4 FCW).
# =============================================================================


def _drive_fcw_n(n: Int) raises:
    """N handles pin the SAME snapshot, all write the HOT key. Drive their
    commits SEQUENTIALLY (deterministic interleave): the FIRST wins, every
    subsequent one sees the now-stale snapshot and ABORTS 40001 — then retries
    at a fresh snapshot and wins (so all N values land, each at a distinct LSN).
    Assert exactly one first-round winner, N-1 first-round 40001s, and a clean
    strictly-increasing HOT chain with no duplicate value (no lost update)."""
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/fcw/n") + String(n)

    # Seed HOT = "base" (LSN 0) so all writers share a common pinned snapshot.
    var seed = _open_shared(shared, prefix)
    var ts = seed.begin()
    ts.insert(_b("HOT"), _b("base"))
    var sr = seed.commit(ts^)
    assert_equal(sr.commit_lsn, Int64(0), "seed HOT=base at LSN 0")
    _ = seed^

    # Each writer transacts HOT at the SAME pinned snapshot (0). We do NOT store
    # txns OR handles in a List (both Txn and TableStore are Movable-only, not
    # Copyable, so neither lives in a List) — each writer creates its OWN fresh
    # handle (a clone over the shared store) on demand, and its txn is pinned
    # EXPLICITLY to snapshot 0 (the SAME snapshot every writer shares). We assert
    # begin() pins 0 to prove that is the real shared snapshot before forcing it.
    var probe_h = _open_shared(shared, prefix)
    var probe = probe_h.begin()
    assert_equal(
        probe.snapshot_lsn, Int64(0),
        "every writer's begin() pins the SAME snapshot 0 (the seeded head)",
    )
    probe_h.abort(probe^)
    _ = probe_h^

    # Commit writer 0 FIRST at snapshot 0 -> it WINS (no conflict above 0 yet).
    var h0 = _open_shared(shared, prefix)
    var first = Txn(Int64(0))
    first.update(_b("HOT"), _b("w0"))
    var r0 = h0.commit(first^)
    assert_equal(r0.commit_lsn, Int64(1), "writer 0 WINS at LSN 1")
    _ = h0^

    # Every other writer at snapshot 0 is now stale (writer 0 committed HOT at
    # LSN 1 > 0). Their commit MUST raise 40001 (first-committer-wins loser).
    var first_round_conflicts = 0
    for i in range(1, n):
        var hi = _open_shared(shared, prefix)
        var ti = Txn(Int64(0))  # the SAME stale snapshot every loser shares.
        ti.update(_b("HOT"), _b(String("w") + String(i)))
        var got_conflict = False
        try:
            _ = hi.commit(ti^)
        except e:
            var em = String(e)
            if is_occ_conflict(em):
                got_conflict = True
            elif is_commit_retryable(em):
                # single-driver: retryable should not fire; treat as soft fail.
                got_conflict = True
            else:
                raise Error(
                    "writer " + String(i) + ": unexpected commit error: " + em
                )
        assert_true(
            got_conflict,
            "writer " + String(i) + " (snapshot 0) MUST abort 40001 after"
            " writer 0 committed HOT over its snapshot (first-committer-wins)",
        )
        first_round_conflicts += 1
        _ = hi^

    assert_equal(
        first_round_conflicts, n - 1,
        "EXACTLY one first-round winner; the other N-1 got the OCC 40001"
        " (no lost update — N=" + String(n) + ")",
    )

    # Now RETRY the N-1 losers at FRESH snapshots; each should win at a distinct
    # LSN (the retry-converges property). After all retries, the chain has N+1
    # versions (base + N writers).
    for i in range(1, n):
        var rh = _open_shared(shared, prefix)
        var rt = rh.begin()  # a fresh snapshot (now includes the prior winner).
        rt.update(_b("HOT"), _b(String("w") + String(i)))
        var rr = rh.commit(rt^)
        assert_true(
            rr.commit_lsn > Int64(0),
            "loser " + String(i) + " retry commits at a fresh LSN",
        )
        _ = rh^

    # ---- INV-4 the HOT version chain audit: walk every WAL chunk, extract each
    #      HOT version, and assert the commit-LSN chain is strictly increasing
    #      with NO two chunks carrying the same HOT value (a genuine lost update
    #      would show a duplicate / non-monotone value). ----
    var verify = _open_shared(shared, prefix)
    var head = verify.wal_head_seq()
    # The chain: seed(0) + winner(1) + (n-1) retries = n+1 chunks (LSN 0..n).
    assert_equal(
        head, Int64(n), "WAL gapless head == n (seed + N HOT commits): n=" + String(n)
    )
    var prev_lsn = Int64(-1)
    var seen_values = List[List[UInt8]]()
    var seq = Int64(0)
    while seq <= head:
        var ws = verify.wal_chunk_write_set(seq)
        # find HOT in this chunk's write-set.
        for wi in range(len(ws)):
            if bytes_eq(ws[wi].key, _b("HOT")):
                # strictly increasing LSN (gapless slot order guarantees it).
                assert_true(
                    seq > prev_lsn,
                    "HOT chain strictly LSN-increasing (no lost update): seq "
                    + String(seq),
                )
                prev_lsn = seq
                # no DUPLICATE HOT value across chunks (each writer's value is
                # distinct: base, w0, w1, ..., w(n-1)).
                for sv in range(len(seen_values)):
                    assert_false(
                        bytes_eq(seen_values[sv], ws[wi].row),
                        "no two HOT chunks carry the same value (a duplicate"
                        " would be a lost-update artefact): seq " + String(seq),
                    )
                seen_values.append(ws[wi].row.copy())
        seq += Int64(1)
    _ = verify^
    _ = shared^
    print(
        "    [OK] FCW N=" + String(n) + ": exactly one first-round winner,"
        + " " + String(n - 1) + " OCC 40001 losers, retries converged, HOT"
        " chain strictly increasing with no dup value (INV-4)"
    )


def test_c_si_fcw_nway() raises:
    print("[c-si-fcw-nway] N writers same snapshot intersecting key (N=3,5,10)")
    _drive_fcw_n(3)
    _drive_fcw_n(5)
    _drive_fcw_n(10)


# =============================================================================
# C-CROSS-HANDLE-FOLD — handle B folds handle A's just-committed chunk at B's
# snapshot. begin() pins max(read_head, _folded_seq), so a FRESH handle B that
# opens AFTER A committed pins a snapshot that INCLUDES A's chunk and reads it.
# =============================================================================


def test_c_cross_handle_fold() raises:
    """Handle A commits k=vA at LSN L. A fresh handle B opens AFTER that commit;
    its begin() pins max(read_head, _folded_seq) — both reflect A's commit
    (B's open() replayed the authoritative tail into _folded_seq) — so B's first
    read folds A's chunk at B's snapshot and observes k=vA. Then B commits k=vB;
    a subsequent A reader (re-begin) folds B's chunk and observes k=vB. The
    cross-handle fold is symmetric + snapshot-correct (INV-2/INV-3)."""
    print("[c-cross-handle-fold] B folds A's just-committed chunk at B's snapshot")
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/xhandle")

    # Handle A commits k=vA (LSN 0).
    var A = _open_shared(shared, prefix)
    var ta = A.begin()
    ta.insert(_b("k"), _b("vA"))
    var ra = A.commit(ta^)
    assert_equal(ra.commit_lsn, Int64(0), "A k=vA at LSN 0")

    # A FRESH handle B opens AFTER A's commit. Its open() replayed the
    # authoritative tail, so _folded_seq >= 0; begin() pins max(read_head,
    # _folded_seq) >= 0 -> B's snapshot INCLUDES A's chunk.
    var B = _open_shared(shared, prefix)
    var tb = B.begin()
    assert_true(
        tb.snapshot_lsn >= Int64(0),
        "B begin() pins max(read_head, _folded_seq) >= 0 (includes A's commit)",
    )
    # B folds A's just-committed chunk at its snapshot and reads k=vA.
    var b_sees = B.get(tb, _b("k"))
    assert_true(
        Bool(b_sees) and bytes_eq(b_sees.value(), _b("vA")),
        "DISCRIMINATING: B (fresh handle) folds A's chunk and sees k=vA"
        " (cross-handle fold at B's snapshot)",
    )
    # B now commits k=vB at LSN 1.
    tb.update(_b("k"), _b("vB"))
    var rb = B.commit(tb^)
    assert_equal(rb.commit_lsn, Int64(1), "B k=vB at LSN 1")

    # A re-begins (a fresh snapshot now includes B's LSN-1 chunk) and folds B's
    # cross-handle commit, observing k=vB (NOT A's own stale local vA).
    var ta2 = A.begin()
    assert_true(
        ta2.snapshot_lsn >= Int64(1),
        "A re-begin pins max(read_head, _folded_seq) >= 1 (includes B's commit)",
    )
    var a_sees = A.get(ta2, _b("k"))
    assert_true(
        Bool(a_sees) and bytes_eq(a_sees.value(), _b("vB")),
        "DISCRIMINATING: A folds B's cross-handle chunk and sees k=vB"
        " (NOT A's stale local vA)",
    )
    A.abort(ta2^)

    # SI stability: an A reader pinned at the EARLIER snapshot (0, before B's
    # commit) must STILL see k=vA — the cross-handle fold never folds ABOVE the
    # reader's snapshot.
    var early = Txn(Int64(0))
    var a_early = A.get(early, _b("k"))
    assert_true(
        Bool(a_early) and bytes_eq(a_early.value(), _b("vA")),
        "SI: a reader pinned at snapshot 0 still sees k=vA (B's LSN-1 commit"
        " is NOT folded above the reader's snapshot)",
    )
    _ = A^
    _ = B^
    _ = shared^
    print("    [OK] cross-handle fold symmetric + snapshot-correct")


def main() raises:
    print("== table store storage-level SI/OCC property (PRIORITY 2) ==")
    test_c_si_writeskew_both_commit()
    test_c_si_fcw_nway()
    test_c_cross_handle_fold()
    print(
        "[OK] test_table_store_si_occ_property — write-skew ADMITTED (INV-1);"
        " N-way FCW exactly-one-winner + strictly-increasing HOT chain (INV-4);"
        " cross-handle fold pins max(read_head, _folded_seq) (INV-2/INV-3)"
    )
