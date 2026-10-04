# =============================================================================
# src/komira_table_store/tests/test_table_store_async_commit_park_e2e.mojo
#   PARK-PROOF for the table store parkable AsyncCommitOp (P2) — THE
#   GATE: while connection A's commit is PARKED on its in-flight create-CAS,
#   connection B executes AND completes its own work; A's commit still lands
#   durably + atomically after the park.
# =============================================================================
#
# The acceptance test for the parkable commit. It drives the `commit_async_*`
# poll-shaped commit driver (table_store) over a CONTROLLABLE-SLOW in-mem
# `AsyncCasStore` (SharedInMemorySlowCasStore, slow_ticks > 0) on a REAL reactor
# (kqueue/epoll, so register_timer FIRES), proving the GATE assertions:
#
#   (1) PARK — A's commit `commit_async_start` PARKS on its create-CAS round-trip
#       (it returns a BIASED op_id >= OP_ID_ALLOC_BASE and is NOT done). The
#       serve thread is NOT blocked: the round-trip is in flight on the reactor.
#       RED on a blocking commit (which would run inline to completion, never
#       parking, blocking the serve thread); GREEN here.
#   (2) OVERLAP — WHILE A's commit is parked (op in flight, NOT committed), B
#       executes AND COMPLETES its own commit (B is a DIFFERENT handle on the
#       SAME shared store). B's wall-clock progress overlaps A's commit-in-flight
#       window — IMPOSSIBLE if the commit blocked the serve thread. This is the
#       multiplexing property the foundation reserves the bucket-2 demux for.
#   (3) DURABLE + ATOMIC — after A's parked create-CAS completes (the reactor
#       fires the timer, `commit_async_poll` finalizes), A's commit LANDS: A's
#       write is readable at a fresh snapshot, A's commit_lsn is a valid won
#       slot, and the two commits did NOT corrupt each other (both rows visible,
#       gapless LSNs). Durability is UNCHANGED — the commit waited for the CAS to
#       land before acking.
#
# This is the DRIVER-LEVEL proof — the same sanctioned shape the broker
# coordinator's `tests/objectstore/test_broker_coord_parkable_serve.mojo` uses
# (it proves the park property via the driver's admit/drive over a slow store on
# a real reactor, NOT through real sockets). The op the commit parks on is a
# reactor timer (SharedInMemorySlowCasStore yields CAS_OP_PENDING via
# register_timer), which fires through the SAME demux a real S3 socket-read
# completion does.
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

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)

from komira_table_store.table_store_codec import bytes_eq
from komira_table_store.table_store import (
    AsyncCommitOp,
    TableStore,
    commit_async_poll,
    commit_async_start,
)


comptime _Store = SharedInMemorySlowCasStore


# =============================================================================
# Helpers.
# =============================================================================


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _store_handle(
    var inner: SharedInMemoryConditionalStore, slow_ticks: Int
) raises -> TableStore[_Store]:
    """A TableStore handle over a slow AsyncCasStore sharing `inner`'s map."""
    var slow = SharedInMemorySlowCasStore(inner=inner^, slow_ticks=slow_ticks)
    var wal = CasManifestStore[_Store](
        store=slow^, prefix=String("pg/park"), retry=RetryPolicy.fast_test()
    )
    return TableStore[_Store].open(wal^)


def _drive_op_to_done(
    mut store: TableStore[_Store],
    mut op: AsyncCommitOp,
    mut reactor: Reactor[NoopSink],
    first_op_id: Int64,
) raises:
    """Drive a parked commit op to completion: fire the reactor for its biased
    op_id + re-enter `commit_async_poll` until DONE/ERR. Bounded loop."""
    var park_id = first_op_id
    var rounds = 0
    while not (op.is_done() or op.is_error()):
        rounds += 1
        if rounds > 1000:
            raise Error("park-proof: op did not converge in 1000 reactor rounds")
        # Block on the reactor until the parked timer op_id fires.
        var completions = reactor.poll_completions(Int32(50_000))
        var fired = False
        for i in range(len(completions)):
            if completions[i].op_id == park_id:
                fired = True
        if not fired:
            continue
        park_id = commit_async_poll[_Store, NoopSink](store, op, reactor)


# =============================================================================
# THE GATE — B completes while A's commit is parked; A still lands.
# =============================================================================
def test_commit_parks_and_other_conn_completes() raises:
    print("[park-proof] A's commit PARKS; B completes during the park; A lands")
    var reactor = _new_reactor()

    # ONE shared backend; two TableStore handles (conn A + conn B) — the
    # production share-nothing shape (each pgwire conn owns a TableStore handle
    # over ONE shared object store).
    var backing = SharedInMemoryConditionalStore()
    # slow_ticks=2 => each create-CAS yields PENDING twice before completing, so
    # A's commit genuinely PARKS on the reactor (does not complete inline).
    var conn_a = _store_handle(backing.clone(), slow_ticks=2)
    # Conn B uses slow_ticks=0 so its OWN commit completes synchronously the same
    # window A is parked — the cleanest proof that B is NOT blocked behind A.
    var conn_b = _store_handle(backing.clone(), slow_ticks=0)

    # ── A: a write txn whose COMMIT parks on the create-CAS. ─────────────────
    var ta = conn_a.begin()
    ta.insert(_b("alice"), _b("from-A"))
    var op_a = AsyncCommitOp.from_txn(ta^)
    var park_a = commit_async_start[_Store, NoopSink](conn_a, op_a, reactor)

    # GATE (1) — PARK: A's commit returned a BIASED op_id and is NOT done. The
    # create-CAS round-trip is IN FLIGHT on the reactor; the serve thread is free.
    assert_true(
        park_a >= OP_ID_ALLOC_BASE,
        "A's commit PARKED on a biased reactor op_id (>= OP_ID_ALLOC_BASE) — it"
        " did NOT run inline to completion blocking the serve thread",
    )
    assert_false(
        op_a.is_done() or op_a.is_error(),
        "A's commit is IN FLIGHT (parked), not yet committed",
    )

    # ── GATE (2) — OVERLAP: while A is parked, B executes AND COMPLETES a write
    # commit. B's commit completes synchronously (slow_ticks=0 => no park) WHILE
    # A's create-CAS is still in flight — impossible if A's commit blocked the
    # serve thread. ─────────────────────────────────────────────────────────
    var tb = conn_b.begin()
    tb.insert(_b("bob"), _b("from-B"))
    var op_b = AsyncCommitOp.from_txn(tb^)
    var park_b = commit_async_start[_Store, NoopSink](conn_b, op_b, reactor)
    assert_equal(
        park_b,
        Int64(0),
        "B's commit (slow_ticks=0) completed in ONE synchronous burst (no park)"
        " WHILE A is still parked — B is NOT blocked behind A's in-flight CAS",
    )
    assert_true(op_b.is_done(), "B's commit DONE during A's parked window")
    var res_b = op_b.take_result()
    assert_true(res_b.did_append, "B's commit appended a chunk")
    assert_true(
        res_b.commit_lsn >= Int64(0), "B won a valid commit slot during A's park"
    )

    # A is STILL parked (B completing did not advance A).
    assert_false(
        op_a.is_done() or op_a.is_error(),
        "A is STILL parked after B completed — the two are independent",
    )

    # ── GATE (3) — DURABLE + ATOMIC: drive A's parked create-CAS to completion;
    # assert A's commit LANDS and both rows are visible (no corruption). ──────
    _drive_op_to_done(conn_a, op_a, reactor, park_a)
    assert_true(
        op_a.is_done(),
        "A's commit completed after the park (DONE, not errored): "
        + op_a.err_text(),
    )
    var res_a = op_a.take_result()
    assert_true(res_a.did_append, "A's commit appended a chunk (durable)")
    assert_true(res_a.commit_lsn >= Int64(0), "A won a valid commit slot")

    # Both commits landed at DISTINCT slots (gapless, no overwrite).
    assert_true(
        res_a.commit_lsn != res_b.commit_lsn,
        "A and B won DISTINCT commit slots — the create-CAS arbitrated them"
        " (no torn/overwritten slot)",
    )

    # Read both rows back at a FRESH snapshot on a FRESH disjoint handle — proves
    # both commits are DURABLE on the shared backend (not just local cache).
    var verifier = _store_handle(backing.clone(), slow_ticks=0)
    var tv = verifier.begin()
    var got_a = verifier.get(tv, _b("alice"))
    var got_b = verifier.get(tv, _b("bob"))
    assert_true(Bool(got_a), "A's row ('alice') is durably visible after the park")
    assert_true(
        bytes_eq(got_a.value(), _b("from-A")), "A's row value is byte-correct"
    )
    assert_true(Bool(got_b), "B's row ('bob') is durably visible")
    assert_true(
        bytes_eq(got_b.value(), _b("from-B")), "B's row value is byte-correct"
    )
    verifier.abort(tv^)
    print("  test_commit_parks_and_other_conn_completes: PASS")


# =============================================================================
# slow_ticks=0 degenerate path: a commit with no artificial delay completes in
# ONE synchronous burst (no park) — the parkable driver's fast path is correct.
# =============================================================================
def test_zero_slow_ticks_commit_completes_in_one_step() raises:
    print("[park-proof] slow_ticks=0 commit completes in ONE step (no park)")
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()
    var conn = _store_handle(backing.clone(), slow_ticks=0)

    var t = conn.begin()
    t.insert(_b("k1"), _b("v1"))
    var op = AsyncCommitOp.from_txn(t^)
    var park = commit_async_start[_Store, NoopSink](conn, op, reactor)
    assert_equal(
        park, Int64(0), "slow_ticks=0 commit completed in one burst (no park)"
    )
    assert_true(op.is_done(), "commit DONE in one step")
    var res = op.take_result()
    assert_true(res.did_append, "the commit appended a chunk")

    # Durable read-back on a fresh handle.
    var verifier = _store_handle(backing.clone(), slow_ticks=0)
    var tv = verifier.begin()
    var got = verifier.get(tv, _b("k1"))
    assert_true(Bool(got), "the row is durably visible")
    assert_true(bytes_eq(got.value(), _b("v1")), "the row value is byte-correct")
    verifier.abort(tv^)
    print("  test_zero_slow_ticks_commit_completes_in_one_step: PASS")


# =============================================================================
# Read-only / empty txn finishes immediately (no append, no LSN, no park).
# =============================================================================
def test_empty_txn_commit_is_read_only_no_park() raises:
    print("[park-proof] empty txn commit is read-only (no append, no park)")
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()
    var conn = _store_handle(backing.clone(), slow_ticks=2)

    var t = conn.begin()  # no writes buffered
    var op = AsyncCommitOp.from_txn(t^)
    var park = commit_async_start[_Store, NoopSink](conn, op, reactor)
    assert_equal(park, Int64(0), "an empty txn commit never parks")
    assert_true(op.is_done(), "empty txn commit DONE immediately")
    var res = op.take_result()
    assert_false(res.did_append, "empty txn: no chunk appended (read-only)")
    assert_equal(res.commit_lsn, Int64(-1), "empty txn: no LSN (-1)")
    print("  test_empty_txn_commit_is_read_only_no_park: PASS")


def main() raises:
    test_commit_parks_and_other_conn_completes()
    test_zero_slow_ticks_commit_completes_in_one_step()
    test_empty_txn_commit_is_read_only_no_park()
    print("ALL table store async-commit park-proof tests PASSED")
