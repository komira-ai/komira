# =============================================================================
# src/komira_table_store/tests/test_table_store_guard_paths.mojo
#   The table store's refusals and less-travelled paths over the in-memory
#   store: closed-txn guards, the async op's state guards, index registration,
#   the v3 (explicit DML-LSN) index-shard commit and its replay, the scan
#   overlay's bounds, and the lease-epoch guard of the async path.
# =============================================================================
#
# What each test proves:
#   * a closed txn refuses insert, update, delete, commit and from_txn.
#   * take_result on a running op is refused; commit_async_poll on an op with
#     no create-CAS in flight errors it; on a finished op it changes nothing.
#   * register_index folds rows committed before it, a re-register keeps one
#     index, and a scan of an unregistered lineage is refused.
#   * commit_index_shard is refused unless enabled and for a negative DML-LSN;
#     enabled, it writes a v3 chunk whose rows are visible at the DML-LSN and
#     not one below, on the writing handle and on a handle that replays the
#     WAL (a snapshot above the tail ends the fold at the first missing slot).
#   * the scan overlay drops buffered keys below lo, at or above hi, and
#     buffered tombstones.
#   * the async commit path refuses a non-zero writer-lease epoch (either one).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)

from komira_table_store.table_store_codec import bytes_eq, decode_commit_chunk
from komira_table_store.table_store import (
    AsyncCommitOp,
    TableStore,
    Txn,
    commit_async_poll,
    commit_async_start,
)


comptime _Store = SharedInMemorySlowCasStore


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _ik(ord: Int, s: String) -> List[UInt8]:
    """A key with a 4-byte big-endian lineage ordinal prefix."""
    var out = List[UInt8]()
    out.append(UInt8((ord >> 24) & 0xFF))
    out.append(UInt8((ord >> 16) & 0xFF))
    out.append(UInt8((ord >> 8) & 0xFF))
    out.append(UInt8(ord & 0xFF))
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _open(backing: SharedInMemoryConditionalStore, prefix: String) raises -> TableStore[_Store]:
    var slow = SharedInMemorySlowCasStore(inner=backing.clone(), slow_ticks=0)
    var wal = CasManifestStore[_Store](
        store=slow^, prefix=prefix, retry=RetryPolicy.fast_test()
    )
    return TableStore[_Store].open(wal^)


def test_closed_txn_guards() raises:
    print("[guards] a closed txn refuses insert/update/delete/commit/from_txn")
    var ts = _open(SharedInMemoryConditionalStore(), "g/closed")
    var t = ts.begin()
    t.is_open = False
    var e1 = String("")
    try:
        t.insert(_b("k"), _b("v"))
    except e:
        e1 = String(e)
    assert_true(e1.find("Txn.insert: transaction is not open") >= 0, e1)
    var e2 = String("")
    try:
        t.update(_b("k"), _b("v"))
    except e:
        e2 = String(e)
    assert_true(e2.find("Txn.update: transaction is not open") >= 0, e2)
    var e3 = String("")
    try:
        t.delete(_b("k"))
    except e:
        e3 = String(e)
    assert_true(e3.find("Txn.delete: transaction is not open") >= 0, e3)
    assert_equal(len(t.write_set), 0, "nothing was buffered")
    var e4 = String("")
    try:
        _ = ts.commit(t^)
    except e:
        e4 = String(e)
    assert_true(e4.find("TableStore.commit: transaction is not open") >= 0, e4)
    var t2 = ts.begin()
    t2.is_open = False
    var e5 = String("")
    try:
        _ = AsyncCommitOp.from_txn(t2^)
    except e:
        e5 = String(e)
    assert_true(e5.find("AsyncCommitOp.from_txn: transaction is not open") >= 0, e5)


def test_async_op_state_guards() raises:
    print("[guards] take_result before done; poll with nothing in flight / after done")
    var reactor = _new_reactor()
    var ts = _open(SharedInMemoryConditionalStore(), "g/aco")
    var t = ts.begin()
    t.insert(_b("k"), _b("v"))
    var op = AsyncCommitOp.from_txn(t^)
    var e1 = String("")
    try:
        _ = op.take_result()
    except e:
        e1 = String(e)
    assert_true(e1.find("AsyncCommitOp.take_result: not done") >= 0, e1)
    assert_equal(commit_async_poll[_Store, NoopSink](ts, op, reactor), Int64(0))
    assert_true(op.is_error(), "a poll with no create-CAS in flight errors the op")
    assert_true(op.err_text().find("no create-CAS in flight") >= 0, op.err_text())

    # A finished (read-only) op: a stray poll leaves it DONE.
    var ro = AsyncCommitOp.from_txn(ts.begin())
    assert_equal(commit_async_start[_Store, NoopSink](ts, ro, reactor), Int64(0))
    assert_true(ro.is_done(), "read-only op is DONE")
    assert_equal(commit_async_poll[_Store, NoopSink](ts, ro, reactor), Int64(0))
    assert_true(ro.is_done() and not ro.is_error(), "a stray poll keeps DONE")
    assert_false(ro.take_result().did_append, "still the read-only result")

    # A committed op: a stray poll keeps the won result.
    var t3 = ts.begin()
    t3.insert(_b("k3"), _b("v3"))
    var won = AsyncCommitOp.from_txn(t3^)
    assert_equal(commit_async_start[_Store, NoopSink](ts, won, reactor), Int64(0))
    assert_true(won.is_done(), "the commit finished in one burst")
    var lsn = won.take_result().commit_lsn
    assert_equal(commit_async_poll[_Store, NoopSink](ts, won, reactor), Int64(0))
    assert_true(won.is_done() and not won.is_error(), "stray poll keeps DONE")
    assert_equal(won.take_result().commit_lsn, lsn, "stray poll keeps the LSN")


def test_register_index_catch_up_and_idempotent() raises:
    print("[guards] register_index: catch-up fold, re-register no-op, unknown refused")
    var backing = SharedInMemoryConditionalStore()
    var ts = _open(backing, "g/idx")
    var t = ts.begin()
    t.insert(_ik(9, "a"), _b("ia"))
    t.insert(_ik(1, "h"), _b("hv"))
    _ = ts.commit(t^)
    ts.register_index(Int32(9))
    ts.register_index(Int32(9))
    assert_equal(len(ts._idx_lineage_ords), 1, "a re-register keeps one index")
    var r = ts.begin()
    var rows = ts.index_scan_visible(r, Int32(9), _ik(9, ""), _ik(10, ""))
    assert_equal(len(rows), 1, "the catch-up fold found the earlier index row")
    assert_true(bytes_eq(rows[0].row, _b("ia")), "index row value")
    var err = String("")
    try:
        _ = ts.index_scan_visible(r, Int32(4), _ik(4, ""), _ik(5, ""))
    except e:
        err = String(e)
    assert_true(
        err.find("lineage ordinal 4 is not a registered index") >= 0,
        "an unregistered lineage scan is refused: " + err,
    )


def test_commit_index_shard_v3() raises:
    print("[guards] commit_index_shard: gated, dml_lsn >= 0, v3 rows at the DML-LSN")
    var backing = SharedInMemoryConditionalStore()
    var ts = _open(backing, "g/v3")
    var t0 = ts.begin()
    t0.insert(_b("k"), _b("v"))
    var e0 = String("")
    try:
        _ = ts.commit_index_shard(t0^, Int64(7))
    except e:
        e0 = String(e)
    assert_true(e0.find("DISABLED by default") >= 0, "the gate is shut: " + e0)
    var t1 = ts.begin()
    t1.insert(_b("k"), _b("v"))
    var e1 = String("")
    try:
        _ = ts.commit_index_shard(t1^, Int64(-1), True)
    except e:
        e1 = String(e)
    assert_true(e1.find("dml_lsn must be >= 0") >= 0, "negative DML-LSN: " + e1)

    var t2 = ts.begin()
    t2.insert(_b("k"), _b("v"))
    var res = ts.commit_index_shard(t2^, Int64(7), True)
    assert_equal(res.commit_lsn, Int64(0), "the WAL slot is 0")
    var body = ts.wal_mut().read_chunk(Int64(0))
    assert_equal(Int(body[3]), 0x33, "the chunk is v3")
    assert_equal(decode_commit_chunk(body).stamp_lsn, Int64(7), "stamp 7")

    assert_false(Bool(ts.get(Txn(Int64(6)), _b("k"))), "live: invisible at 6")
    var at7 = ts.get(Txn(Int64(7)), _b("k"))
    assert_true(Bool(at7) and bytes_eq(at7.value(), _b("v")), "live: visible at 7")

    var replayed = _open(backing, "g/v3")
    assert_false(Bool(replayed.get(Txn(Int64(6)), _b("k"))), "replay: invisible at 6")
    var r7 = replayed.get(Txn(Int64(7)), _b("k"))
    assert_true(Bool(r7) and bytes_eq(r7.value(), _b("v")), "replay: visible at 7")
    assert_equal(replayed.folded_seq(), Int64(0), "the fold stopped at the tail")


def test_scan_overlay_bounds() raises:
    print("[guards] scan overlay drops buffered keys out of range and tombstones")
    var ts = _open(SharedInMemoryConditionalStore(), "g/scan")
    var t0 = ts.begin()
    t0.insert(_b("b"), _b("b0"))
    t0.insert(_b("d"), _b("d0"))
    _ = ts.commit(t0^)
    var t = ts.begin()
    t.insert(_b("a"), _b("a1"))
    t.insert(_b("z"), _b("z1"))
    t.insert(_b("y"), _b("y1"))
    t.delete(_b("b"))
    t.delete(_b("c"))
    t.insert(_b("c2"), _b("c21"))
    var rows = ts.scan(t, _b("b"), _b("y"))
    assert_equal(len(rows), 2, "only c2 and d are in [b, y)")
    assert_true(bytes_eq(rows[0].key, _b("c2")) and bytes_eq(rows[0].row, _b("c21")))
    assert_true(bytes_eq(rows[1].key, _b("d")) and bytes_eq(rows[1].row, _b("d0")))
    var from_rows = ts.scan_from(t, _b("x"))
    assert_equal(len(from_rows), 2, "scan_from x: y and z")
    assert_true(bytes_eq(from_rows[0].key, _b("y")) and bytes_eq(from_rows[1].key, _b("z")))
    ts.abort(t^)


def test_async_refuses_nonzero_lease_epoch() raises:
    print("[guards] the async path refuses a non-zero writer or current epoch")
    var reactor = _new_reactor()
    for which in range(2):
        var ts = _open(SharedInMemoryConditionalStore(), "g/epoch")
        if which == 0:
            ts.enable_writer_lease_fastpath(Int64(1), Int64(0))
        else:
            ts.enable_writer_lease_fastpath(Int64(0), Int64(1))
        var t = ts.begin()
        t.insert(_b("k"), _b("v"))
        var op = AsyncCommitOp.from_txn(t^)
        assert_equal(commit_async_start[_Store, NoopSink](ts, op, reactor), Int64(0))
        assert_true(op.is_error(), "epoch case " + String(which) + " errors")
        assert_true(
            op.err_text().find("non-zero writer-lease epochs are not supported") >= 0,
            op.err_text(),
        )


def main() raises:
    test_closed_txn_guards()
    test_async_op_state_guards()
    test_register_index_catch_up_and_idempotent()
    test_commit_index_shard_v3()
    test_scan_overlay_bounds()
    test_async_refuses_nonzero_lease_epoch()
    print("ALL table store guard-path tests PASSED")
