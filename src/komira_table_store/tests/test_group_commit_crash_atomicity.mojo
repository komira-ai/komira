# =============================================================================
# src/komira_pgstore/tests/test_group_commit_crash_atomicity.mojo
#   GROUP-COMMIT Phase-3 CRASH-ATOMICITY: a batch = exactly ONE
#   encode body = exactly ONE create-CAS slot. Recovery folds ALL N winners at
#   the shared commit_lsn, or NONE — never a partial subset.
# =============================================================================
#
# THE STRUCTURAL CONTRACT (the correctness crux): object stores have no atomic
# multi-object PUT, so the spine NEVER splits a coalesced batch across two
# create-CAS slots. One batch = one encode body = one `If-None-Match` create-CAS.
# That single PUT is the lone linearization point: the slot exists (all N winners
# durable, atomically visible at the shared commit_lsn) or it does not.
# Intra-batch losers are runtime-only — they NEVER enter the merged write-set, so
# replay only ever sees winners.
#
# THE GATES:
#   (1) ALL-OR-NOTHING ON A WIN — after a coalesced batch lands, a FRESH
#       TableStore (open() replays the WAL from log_start) sees EVERY winner at
#       the shared commit_lsn — never a partial subset. The merged chunk is ONE
#       atomic unit; replay folds it whole.
#   (2) NOTHING ON A CRASH-BEFORE-CAS — if the process crashes BEFORE the
#       create-CAS completes (the window is dropped mid-park, the slot never
#       written), a fresh TableStore sees NONE of the batch's rows + the head did
#       NOT advance. No half-batch, no LSN gap.
#   (3) LOSERS NEVER PERSISTED — an intra-batch loser's write to a contended key
#       is NEVER in the durable chunk (the winner's value is the only one that
#       survives a crash+recovery). This is the no-lost-update property AT THE
#       DURABILITY layer.
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

from komira_pgstore.pgstore_codec import (
    PG_OP_PUT,
    WriteOp,
    bytes_eq,
    decode_commit_chunk,
)
from komira_pgstore.group_commit import (
    PG_GC_WIN,
    PgGroupCommitFactory,
    PgGroupCommitItem,
    PgGroupOutcome,
)
from komira_pgstore.table_store import TableStore


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


def _row(tag: Int) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(tag & 0xFF))
    return out^


def _member(snapshot: Int64, key: Int, tag: Int) -> PgGroupCommitItem:
    var ws = List[WriteOp]()
    ws.append(WriteOp(PG_OP_PUT, _key(key), _row(tag)))
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
) raises:
    var park_id = first_op_id
    var rounds = 0
    while park_id >= OP_ID_ALLOC_BASE and window.is_inflight():
        rounds += 1
        if rounds > 1000:
            raise Error("crash-atomicity: flush did not converge in 1000 rounds")
        var completions = reactor.poll_completions(Int32(50_000))
        var fired = False
        for i in range(len(completions)):
            if completions[i].op_id == park_id:
                fired = True
        if not fired:
            continue
        park_id = window.poll[NoopSink](reactor)


def _head_seq(slow: _Slow, prefix: String) raises -> Int64:
    var wal = CasManifestStore[_Slow](
        slow.clone(), prefix, RetryPolicy.fast_test()
    )
    return wal.read_head_authoritative().chunk_seq


def _visible_count(
    slow: _Slow, prefix: String, keys: List[Int]
) raises -> Int:
    """How many of `keys` a FRESH TableStore (open()-replays the WAL) sees."""
    var wal = CasManifestStore[_Slow](
        slow.clone(), prefix, RetryPolicy.fast_test()
    )
    var ts = TableStore[_Slow].open(wal^)
    var txn = ts.begin()
    var seen = 0
    for i in range(len(keys)):
        if ts.get(txn, _key(keys[i])):
            seen += 1
    ts.abort(txn^)
    return seen


# =============================================================================
# Test 1 — ALL-OR-NOTHING on a WIN: recovery folds every winner at the shared
# commit_lsn (never a partial subset).
# =============================================================================


def test_crash_atomicity_recovery_folds_all_winners_whole() raises:
    """A 4-member disjoint batch lands as ONE chunk. A fresh TableStore (a
    cold-boot recovery) replays the WAL and sees ALL FOUR rows — never a partial
    subset. The merged chunk is one atomic create-CAS unit; replay folds it
    whole, so there is no 'some winners committed, some lost' state."""
    var slow = SharedInMemorySlowCasStore(slow_ticks=2)  # park on the create-CAS
    var prefix = String("pg/gc/crash/win")

    var window = _new_window(slow.clone(), prefix, FlushPolicy.count_only(1000))
    var reactor = _new_reactor()
    var keys: List[Int] = [100, 200, 300, 400]
    for i in range(len(keys)):
        window.buffer(_member(Int64(-1), keys[i], i), 1, Int64(0))

    var op = window.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor)
    _drive_to_done(window, op, reactor)
    assert_false(window.has_error(), "no error: " + window.err_text())
    var outcomes = window.take_outcomes()
    assert_equal(len(outcomes), 4)
    for i in range(len(outcomes)):
        ref pair = outcomes[i]
        assert_equal(pair[1].kind, PG_GC_WIN, "all four disjoint members win")

    # COLD-BOOT RECOVERY: a fresh TableStore replays the WAL — ALL FOUR visible.
    assert_equal(
        _visible_count(slow.clone(), prefix, keys),
        4,
        "recovery must fold ALL FOUR winners at the shared commit_lsn (whole,"
        " never a partial subset)",
    )
    # ONE chunk only (head == 0).
    assert_equal(_head_seq(slow.clone(), prefix), Int64(0), "exactly ONE chunk")


# =============================================================================
# Test 2 — NOTHING on a crash BEFORE the create-CAS lands.
# =============================================================================


def test_crash_atomicity_crash_before_cas_persists_nothing() raises:
    """The window PARKS on the create-CAS, then the process 'crashes' (the window
    is DROPPED mid-park BEFORE the create-CAS completes — the slot is never
    written). A fresh TableStore sees NONE of the batch's rows + the head did NOT
    advance. No half-batch, no LSN gap — the single create-CAS is the lone
    linearization point.

    The crash is modeled by dropping the window while it is still in flight (the
    parked op never gets driven to completion), exactly the stale-reuse 'parked-then-
    dropped' shape the primitive's soak exercises. The in-mem slow store does the
    actual PUT only on the FINAL tick (after slow_ticks PENDINGs), so dropping
    before that tick means the slot bytes were never written."""
    var slow = SharedInMemorySlowCasStore(slow_ticks=3)
    var prefix = String("pg/gc/crash/none")
    var keys: List[Int] = [11, 22, 33]

    var head_before = _head_seq(slow.clone(), prefix)
    assert_equal(head_before, Int64(-1), "empty WAL")

    # Scope the window so it is DROPPED at the end of the block (the crash) while
    # still parked — the create-CAS never completed.
    var reactor = _new_reactor()
    var parked_id: Int64
    if True:
        var window = _new_window(
            slow.clone(), prefix, FlushPolicy.count_only(1000)
        )
        for i in range(len(keys)):
            window.buffer(_member(Int64(-1), keys[i], i), 1, Int64(0))
        parked_id = window.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor)
        # GATE: it PARKED (the create-CAS is in flight, NOT yet landed).
        assert_true(
            parked_id >= OP_ID_ALLOC_BASE,
            "the flush must PARK on the create-CAS (slow_ticks=3)",
        )
        assert_true(window.is_inflight(), "the flush is in flight (not done)")
        # DO NOT drive it to completion — let the window drop here (the crash).
        _ = window^

    # CRASH RECOVERY: a fresh TableStore sees NONE of the rows + head unchanged.
    assert_equal(
        _visible_count(slow.clone(), prefix, keys),
        0,
        "a crash BEFORE the create-CAS persists NOTHING (no half-batch)",
    )
    assert_equal(
        _head_seq(slow.clone(), prefix),
        Int64(-1),
        "the head did NOT advance (the slot was never written — no LSN gap)",
    )


# =============================================================================
# Test 3 — intra-batch LOSERS are never persisted (no-lost-update at durability).
# =============================================================================


def test_crash_atomicity_loser_never_in_durable_chunk() raises:
    """Two members write the SAME key 55 with DIFFERENT values (winner tag=1,
    loser tag=2). The winner's value is the ONLY one in the durable chunk; the
    loser's write is NEVER persisted — so after a crash+recovery the key reads
    the WINNER's value, never the loser's. The no-lost-update property AT the
    durability layer: a missed intersection would have merged BOTH writes for key
    55 into the chunk (two records for one key)."""
    var slow = SharedInMemorySlowCasStore(slow_ticks=1)
    var prefix = String("pg/gc/crash/loser")

    var window = _new_window(slow.clone(), prefix, FlushPolicy.count_only(1000))
    var reactor = _new_reactor()
    window.buffer(_member(Int64(-1), 55, 1), 1, Int64(0))  # WINNER: 55 -> tag 1
    window.buffer(_member(Int64(-1), 55, 2), 1, Int64(0))  # LOSER:  55 -> tag 2
    var op = window.force[NoopSink](FLUSH_REASON_EXPLICIT, reactor)
    _drive_to_done(window, op, reactor)
    assert_false(window.has_error(), "no error: " + window.err_text())

    # The durable chunk carries key 55 EXACTLY once (the loser was never merged).
    var wal = CasManifestStore[_Slow](
        slow.clone(), prefix, RetryPolicy.fast_test()
    )
    var chunk = decode_commit_chunk(wal.read_chunk(Int64(0)))
    var k55 = _key(55)
    var count = 0
    var persisted_tag = -1
    for i in range(len(chunk.write_set)):
        if bytes_eq(chunk.write_set[i].key, k55):
            count += 1
            persisted_tag = Int(chunk.write_set[i].row[0])
    assert_equal(
        count, 1, "key 55 appears EXACTLY once in the durable chunk (loser dropped)"
    )
    assert_equal(
        persisted_tag,
        1,
        "the WINNER's value (tag 1) survives — NOT the loser's (tag 2)",
    )

    # A fresh recovery reads the WINNER's value at key 55.
    var ts_wal = CasManifestStore[_Slow](
        slow.clone(), prefix, RetryPolicy.fast_test()
    )
    var ts = TableStore[_Slow].open(ts_wal^)
    var txn = ts.begin()
    var got = ts.get(txn, _key(55))
    assert_true(Bool(got), "key 55 is visible after recovery")
    var got_v = got.value().copy()
    assert_equal(Int(got_v[0]), 1, "recovery reads the WINNER's value (tag 1)")
    ts.abort(txn^)


def main() raises:
    test_crash_atomicity_recovery_folds_all_winners_whole()
    print("  test_crash_atomicity_recovery_folds_all_winners_whole: PASS")
    test_crash_atomicity_crash_before_cas_persists_nothing()
    print("  test_crash_atomicity_crash_before_cas_persists_nothing: PASS")
    test_crash_atomicity_loser_never_in_durable_chunk()
    print("  test_crash_atomicity_loser_never_in_durable_chunk: PASS")
    print("ALL group-commit crash-atomicity tests PASSED")
