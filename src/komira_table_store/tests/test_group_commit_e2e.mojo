# =============================================================================
# src/komira_table_store/tests/test_group_commit_e2e.mojo
#   GROUP-COMMIT Phase-3 e2e: N concurrent commits COALESCE into
#   ONE create-CAS chunk via the CoalescingWindow over a slow AsyncCasStore on a
#   real reactor.
# =============================================================================
#
# THE GATE: drive a `CoalescingWindow[PgGroupCommitFactory[_Slow]]` over a
# controllable-slow in-mem AsyncCasStore (SharedInMemorySlowCasStore, slow_ticks
# > 0) on a REAL reactor (kqueue/epoll). Feed N members, force(EXPLICIT) (the
# queue-drain analog), and drive the in-flight spine to done. Assert:
#
#   (1) ONE CHUNK — N non-conflicting commits land as exactly ONE committed chunk
#       (the manifest head advanced by exactly 1), NOT N chunks. The merged chunk
#       carries every winner's write-set.
#   (2) ATOMIC AT THE SHARED commit_lsn — every winner's outcome carries the SAME
#       commit_lsn (the one chunk_seq) with DISTINCT intra_batch_seq (the
#       arbitration order within the slot). All winners visible at that one LSN.
#   (3) EXACTLY-ONE-WINNER-PER-KEY — when two members write the SAME key, exactly
#       one wins (first-in-batch); the loser gets a 40001 outcome; the merged
#       chunk carries the key ONCE.
#   (4) PARK — with slow_ticks > 0 the spine PARKS on the create-CAS (returns a
#       biased op_id, not done); the reactor timer fires it through the demux.
#
# Driver-level proof (the sanctioned shape — same as the async-commit park e2e):
# the window's poll is driven over a slow store on a real reactor; the op the
# spine parks on is a reactor timer that fires through the SAME demux a real S3
# socket completion does.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    OP_ID_ALLOC_BASE,
    Reactor,
)

from komira_core.collections.slab import Slab

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.coalescing_window import (
    CoalescingWindow,
    FLUSH_REASON_EXPLICIT,
    FlushPolicy,
    RamAccumulator,
)

from komira_table_store.table_store_codec import (
    PG_OP_PUT,
    WriteOp,
    bytes_eq,
    decode_commit_chunk,
)
from komira_table_store.group_commit import (
    PG_GC_WIN,
    PgGroupCommitFactory,
    PgGroupCommitItem,
    PgGroupOutcome,
)
from komira_table_store.table_store import TableStore


comptime _Slow = SharedInMemorySlowCasStore
comptime _Factory = PgGroupCommitFactory[_Slow]
comptime _Window = CoalescingWindow[_Factory]


# =============================================================================
# Helpers.
# =============================================================================


def _key(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(0))
    out.append(UInt8(0))
    out.append(UInt8((n >> 8) & 0xFF))
    out.append(UInt8(n & 0xFF))
    return out^


def _row(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(n & 0xFF))
    return out^


def _member(snapshot: Int64, *ks: Int) -> PgGroupCommitItem:
    var ws = List[WriteOp]()
    for i in range(len(ks)):
        ws.append(WriteOp(PG_OP_PUT, _key(ks[i]), _row(ks[i])))
    return PgGroupCommitItem(snapshot, ws^)


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _new_window(
    var slow: _Slow, prefix: String, policy: FlushPolicy
) raises -> _Window:
    var factory = _Factory(slow^, prefix)
    return _Window(RamAccumulator[PgGroupCommitItem](), policy, factory^)


def _drive_to_done(
    mut window: _Window, first_op_id: Int64, mut reactor: Reactor[NoopSink]
) raises -> Bool:
    """Drive the window's in-flight flush to completion. Returns True iff the
    flush PARKED at least once (the create-CAS round-trip went through the
    reactor). Mirrors the async-commit park-e2e drive loop: block on
    poll_completions for the parked op_id, then poll the window one step.
    Bounded so a logic bug terminates."""
    var parked = False
    var park_id = first_op_id
    var rounds = 0
    while park_id >= OP_ID_ALLOC_BASE and window.is_inflight():
        parked = True
        rounds += 1
        if rounds > 1000:
            raise Error("group-commit e2e: flush did not converge in 1000 rounds")
        var completions = reactor.poll_completions(Int32(50_000))
        var fired = False
        for i in range(len(completions)):
            if completions[i].op_id == park_id:
                fired = True
        if not fired:
            continue
        park_id = window.poll[NoopSink](reactor)
    return parked


def _head_seq(slow: _Slow, prefix: String) raises -> Int64:
    """The authoritative manifest head seq (the # of committed chunks - 1)."""
    var wal = CasManifestStore[_Slow](
        slow.clone(), prefix, RetryPolicy.fast_test()
    )
    return wal.read_head_authoritative().chunk_seq


# =============================================================================
# Test 1 — N non-conflicting commits coalesce into ONE chunk, atomic at the
# shared commit_lsn with distinct intra_batch_seq.
# =============================================================================


def test_group_commit_coalesces_disjoint_into_one_chunk() raises:
    """Three members with DISJOINT key sets all WIN and merge into ONE chunk:
      (1) the manifest head advances by exactly 1 (ONE create-CAS, not three);
      (2) every winner's outcome carries the SAME commit_lsn (the one slot);
      (3) the intra_batch_seq values are DISTINCT (0,1,2 — arbitration order);
      (4) the merged chunk carries all three members' keys."""
    var slow = SharedInMemorySlowCasStore(slow_ticks=2)  # park on the create-CAS
    var prefix = String("pg/gc/disjoint")
    var head_before = _head_seq(slow.clone(), prefix)
    assert_equal(head_before, Int64(-1), "empty WAL starts at head -1")

    var window = _new_window(slow.clone(), prefix, FlushPolicy.count_only(1000))
    var reactor = _new_reactor()

    # Buffer three disjoint members (snapshot -1 — empty WAL, no OCC conflict).
    window.buffer(_member(Int64(-1), 10), 1, Int64(0))
    window.buffer(_member(Int64(-1), 20), 1, Int64(0))
    window.buffer(_member(Int64(-1), 30), 1, Int64(0))
    assert_equal(window.pending_count(), 3)

    # Force the flush (the queue-drain analog) + drive it to done.
    var op = window.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor)
    var parked = _drive_to_done(window, op, reactor)
    assert_true(parked, "with slow_ticks=2 the create-CAS must PARK")
    assert_false(window.is_inflight(), "the flush must be done")
    assert_false(window.has_error(), "no error: " + window.err_text())

    # (1) ONE chunk — head advanced by exactly 1 (from -1 to 0).
    var head_after = _head_seq(slow.clone(), prefix)
    assert_equal(
        head_after,
        Int64(0),
        "THREE disjoint commits must land as ONE chunk (head 0), not three",
    )

    # (2) + (3) outcomes — all three win, same commit_lsn, distinct seqs.
    var outcomes = window.take_outcomes()
    assert_equal(len(outcomes), 3, "all three members get an outcome")
    var shared_lsn = Int64(-2)
    var seen_seqs = List[Int]()
    for i in range(len(outcomes)):
        ref pair = outcomes[i]
        assert_equal(
            pair[1].kind, PG_GC_WIN, "disjoint member must WIN, member " + String(pair[0])
        )
        if shared_lsn == Int64(-2):
            shared_lsn = pair[1].commit_lsn
        else:
            assert_equal(
                pair[1].commit_lsn,
                shared_lsn,
                "all winners share the ONE commit_lsn (atomic at the slot)",
            )
        # distinct intra_batch_seq.
        for j in range(len(seen_seqs)):
            assert_true(
                seen_seqs[j] != pair[1].intra_batch_seq,
                "intra_batch_seq must be DISTINCT per winner",
            )
        seen_seqs.append(pair[1].intra_batch_seq)
    assert_equal(shared_lsn, Int64(0), "the shared commit_lsn is the won slot 0")

    # (4) the merged chunk carries all three keys.
    var wal = CasManifestStore[_Slow](
        slow.clone(), prefix, RetryPolicy.fast_test()
    )
    var chunk = decode_commit_chunk(wal.read_chunk(Int64(0)))
    assert_equal(len(chunk.write_set), 3, "the one chunk merges all 3 write-sets")


# =============================================================================
# Test 2 — overlapping members: exactly one winner per key.
# =============================================================================


def test_group_commit_overlap_exactly_one_winner_per_key() raises:
    """Two members write the SAME key 42; a third writes a disjoint key 99.
    First-in-batch-wins: member 0 (key 42) + member 2 (key 99) win; member 1
    (also key 42) is an intra-batch LOSER (40001). The merged chunk carries key
    42 ONCE (no lost update) + key 99."""
    var slow = SharedInMemorySlowCasStore(slow_ticks=1)
    var prefix = String("pg/gc/overlap")

    var window = _new_window(slow.clone(), prefix, FlushPolicy.count_only(1000))
    var reactor = _new_reactor()

    window.buffer(_member(Int64(-1), 42), 1, Int64(0))  # 0: 42 WIN
    window.buffer(_member(Int64(-1), 42), 1, Int64(0))  # 1: 42 LOSS
    window.buffer(_member(Int64(-1), 99), 1, Int64(0))  # 2: 99 WIN

    var op = window.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor)
    _ = _drive_to_done(window, op, reactor)
    assert_false(window.is_inflight())
    assert_false(window.has_error(), "no error: " + window.err_text())

    var outcomes = window.take_outcomes()
    assert_equal(len(outcomes), 3)
    var win_count = 0
    var loss_count = 0
    var loser_idx = -1
    for i in range(len(outcomes)):
        ref pair = outcomes[i]
        if pair[1].kind == PG_GC_WIN:
            win_count += 1
        else:
            loss_count += 1
            loser_idx = pair[0]
    assert_equal(win_count, 2, "exactly 2 winners (members 0 + 2)")
    assert_equal(loss_count, 1, "exactly 1 loser (member 1)")
    assert_equal(loser_idx, 1, "the LATER member (1) loses to the earlier one (0)")

    # The merged chunk carries key 42 ONCE + key 99 == 2 writes (no lost update).
    var wal = CasManifestStore[_Slow](
        slow.clone(), prefix, RetryPolicy.fast_test()
    )
    var chunk = decode_commit_chunk(wal.read_chunk(Int64(0)))
    assert_equal(
        len(chunk.write_set),
        2,
        "the merged chunk carries key 42 ONCE + key 99 (no lost update)",
    )
    # key 42 appears exactly once.
    var k42 = _key(42)
    var c42 = 0
    for i in range(len(chunk.write_set)):
        if bytes_eq(chunk.write_set[i].key, k42):
            c42 += 1
    assert_equal(c42, 1, "key 42 appears EXACTLY once in the merged chunk")


# =============================================================================
# Test 3 — the coalesced batch is readable through a TableStore at the shared LSN.
# =============================================================================


def test_group_commit_winners_visible_through_tablestore() raises:
    """After the coalesced batch lands, a FRESH TableStore handle (which replays
    the WAL at open) sees EVERY winner's row at the shared commit_lsn — the
    atomic-visibility property (all-or-nothing at the one slot)."""
    var slow = SharedInMemorySlowCasStore(slow_ticks=1)
    var prefix = String("pg/gc/visible")

    var window = _new_window(slow.clone(), prefix, FlushPolicy.count_only(1000))
    var reactor = _new_reactor()
    window.buffer(_member(Int64(-1), 1), 1, Int64(0))
    window.buffer(_member(Int64(-1), 2), 1, Int64(0))
    window.buffer(_member(Int64(-1), 3), 1, Int64(0))
    var op = window.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor)
    _ = _drive_to_done(window, op, reactor)
    assert_false(window.has_error(), "no error: " + window.err_text())
    var outcomes = window.take_outcomes()
    assert_equal(len(outcomes), 3)

    # A fresh TableStore replays the WAL and sees all three rows at a snapshot.
    var ts_wal = CasManifestStore[_Slow](
        slow.clone(), prefix, RetryPolicy.fast_test()
    )
    var ts = TableStore[_Slow].open(ts_wal^)
    var txn = ts.begin()
    for k in range(1, 4):
        var v = ts.get(txn, _key(k))
        assert_true(
            Bool(v),
            "winner row for key " + String(k) + " must be visible after coalesce",
        )
    ts.abort(txn^)


def main() raises:
    test_group_commit_coalesces_disjoint_into_one_chunk()
    print("  test_group_commit_coalesces_disjoint_into_one_chunk: PASS")
    test_group_commit_overlap_exactly_one_winner_per_key()
    print("  test_group_commit_overlap_exactly_one_winner_per_key: PASS")
    test_group_commit_winners_visible_through_tablestore()
    print("  test_group_commit_winners_visible_through_tablestore: PASS")
    print("ALL group-commit e2e tests PASSED")
