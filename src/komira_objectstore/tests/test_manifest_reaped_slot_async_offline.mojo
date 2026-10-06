# =============================================================================
# tests/test_manifest_reaped_slot_async_offline.mojo
#   The reaped-slot guard in the poll-shaped `AsyncManifestAppendOp`
#   (komira-ai/komira#486; manifest_slot_guard.mojo). The synchronous paths are
#   in test_manifest_reaped_slot_guard_offline.mojo.
# =============================================================================
#
# On a guarded manifest the op takes the create as soon as it completes and
# reads `_LOG_START` as its OWN parkable phase, before any `_HEAD` or cache
# update (the reactor is never blocked on the check). Each test names
# the defect it catches and the mutant that turns it red:
#   6  parked check; a reaped win ends in ERR slot_reaped and never moves
#      `_HEAD`; a live win commits; a lost slot is still the 412 ERR
#      ............................... the `_HEAD`/cache update before the check
#   9  the parkable read raises -> ERR log_start_unread ..... fail open
#   13 every other guarded phase: absent / undecodable `_LOG_START`, a parked
#      read that raises or ERRs, a 412 or a failure at the create's take,
#      `take` before the check, and `apply_async_append_win`'s own guard
# All run on the in-memory stores; no network.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_objectstore.cas_manifest import (
    AsyncManifestAppendOp,
    CasManifestStore,
    RetryPolicy,
    head_key,
    is_not_found,
    is_precondition,
    log_start_key,
)
from komira_objectstore.manifest_slot_guard import (
    is_log_start_unread,
    is_slot_reaped,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.store import (
    AsyncCasStore,
    CasOpProgress,
    CasReadResult,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


comptime _Store = SharedInMemoryConditionalStore
comptime _Slow = SharedInMemorySlowCasStore
comptime _RPC = Int64(10)  # records per chunk, every test


def _body(tag: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(16):
        out.append(UInt8((i * 7 + tag) & 0xFF))
    return out^


def _mk[
    S: ConditionalWriteStore
](var store: S, prefix: String, guard: Bool = True) -> CasManifestStore[S]:
    var m = CasManifestStore[S](
        store=store^, prefix=prefix.copy(), retry=RetryPolicy.fast_test()
    )
    if guard:
        m.enable_reaped_slot_guard()
    return m^


def _retire[
    S: ConditionalWriteStore
](mut m: CasManifestStore[S], first: Int64, new_log_start_seq: Int64) raises:
    """RetentionPass + ReapWorker, in their order: tombstone, advance
    `_LOG_START` to `(new_log_start_seq, new_log_start_seq * _RPC)`, reap."""
    var s = first
    while s < new_log_start_seq:
        m.schedule_for_delete_at(s, Int64(1))
        s += Int64(1)
    var ls = m.read_log_start()
    _ = m.advance_log_start(new_log_start_seq, new_log_start_seq * _RPC, ls.etag)
    s = first
    while s < new_log_start_seq:
        m.reap(s)
        s += Int64(1)


def _durable_head_seq(store: _Store, prefix: String) raises -> Int64:
    var r = _mk(store.clone(), prefix, guard=False)
    return r.read_durable_head().chunk_seq


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _durable_head_seq_slow(store: _Slow, prefix: String) raises -> Int64:
    var r = _mk(store.clone(), prefix, guard=False)
    return r.read_durable_head().chunk_seq


# =============================================================================
# 6. The poll-shaped op. With a parking store the `_LOG_START` read is its
#    own parked phase: after the create completes the op parks again, and
#    `_HEAD` is untouched until the check passes. A win at a reaped slot ends
#    in a `slot_reaped` ERR (the live channel the spine classifies) and never
#    moves `_HEAD`; `take` then raises it. A win at the tail commits.
#    Mutant: the `_HEAD` advance / cache update before the check.
# =============================================================================
def test_async_op_reaped_slot() raises:
    print("[reaped-slot] 6. AsyncManifestAppendOp: parked check, reaped refused")
    var reactor = _new_reactor()
    var store = _Slow(slow_ticks=1)
    var prefix = String("rs/async")
    var wal = _mk(store.clone(), prefix)
    for i in range(5):
        _ = wal.append(_body(i), _RPC)  # durable _HEAD stays at 0
    _retire(wal, Int64(0), Int64(3))

    var op = AsyncManifestAppendOp[_Slow]()
    var p = op.start[NoopSink](wal, Int64(1), Int64(10), _body(8), _RPC, reactor)
    assert_true(p.is_pending(), "the create parks")
    p = op.poll[NoopSink](wal, reactor)
    assert_true(p.is_pending(), "the create completed; the _LOG_START read parks")
    assert_equal(
        _durable_head_seq_slow(store, prefix),
        Int64(0),
        "while the check is parked, _HEAD is untouched",
    )
    p = op.poll[NoopSink](wal, reactor)
    assert_true(p.is_error(), "the reaped win ends in ERR, not READY")
    assert_true(is_slot_reaped(p.err_text()), p.err_text())
    assert_equal(
        _durable_head_seq_slow(store, prefix),
        Int64(0),
        "the refused win never advanced _HEAD to slot 1",
    )
    assert_equal(
        wal.read_head().chunk_seq,
        Int64(0),
        "the refusal invalidated the head cache (it held chunk 4): read_head"
        " now returns the durable _HEAD",
    )
    var raised = False
    try:
        _ = op.take(wal)
    except e:
        raised = is_slot_reaped(String(e))
    assert_true(raised, "take after the refusal raises slot_reaped")

    var op2 = AsyncManifestAppendOp[_Slow]()
    var p2 = op2.start[NoopSink](wal, Int64(5), Int64(50), _body(9), _RPC, reactor)
    while p2.is_pending():
        p2 = op2.poll[NoopSink](wal, reactor)
    assert_true(p2.is_ready(), "the create at the tail and its check complete")
    var res2 = op2.take(wal)
    assert_true(Bool(res2), "a win at the tail is committed")
    assert_equal(res2.value().chunk_seq, Int64(5), "at slot 5")
    assert_equal(_durable_head_seq_slow(store, prefix), Int64(5), "_HEAD advanced")

    # A lost slot through the parked path is still the 412 ERR (no check runs).
    var op3 = AsyncManifestAppendOp[_Slow]()
    var p3 = op3.start[NoopSink](wal, Int64(5), Int64(60), _body(10), _RPC, reactor)
    while p3.is_pending():
        p3 = op3.poll[NoopSink](wal, reactor)
    assert_true(p3.is_error() and is_precondition(p3.err_text()), p3.err_text())
    print("  PASS")


# =============================================================================
# 9. Fail closed, async: the parkable `_LOG_START` read raises. FAIL CLOSED: ERR
#    log_start_unread, no `_HEAD`, and `take` raises it. Mutant: fail open.
# =============================================================================
def test_async_log_start_read_failure_fails_closed() raises:
    print("[reaped-slot async] 9. the parkable read raises -> no ack")

    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=0, raise_on_read_start=True)
    var aprefix = String("rs/f5a")
    var wal = _mk(slow.clone(), aprefix)
    var op = AsyncManifestAppendOp[_Slow]()
    var p = op.start[NoopSink](wal, Int64(0), Int64(0), _body(5), _RPC, reactor)
    assert_true(p.is_error(), "the check's read failed: ERR, not READY")
    assert_true(is_log_start_unread(p.err_text()), p.err_text())
    var head_absent = False
    try:
        _ = slow.inner_ref().head(head_key(aprefix))
    except e:
        head_absent = is_not_found(String(e))
    assert_true(head_absent, "the unacked win never created _HEAD")
    var raised2 = False
    try:
        _ = op.take(wal)
    except e:
        raised2 = is_log_start_unread(String(e))
    assert_true(raised2, "take after the refusal raises log_start_unread")
    print("  PASS")


# -----------------------------------------------------------------------------
# A parking AsyncCasStore that faults one step: MODE 1 `read_poll` raises,
# MODE 2 `read_poll` returns ERR, MODE 3 `cas_put_take` raises a 412, MODE 4
# `cas_put_take` raises another error. Everything else delegates.
# -----------------------------------------------------------------------------
struct _AsyncFault(AsyncCasStore, ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    var inner: _Slow
    var mode: Int

    def __init__(out self, var inner: _Slow, mode: Int):
        self.inner = inner^
        self.mode = mode

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)

    def read_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, path: Path, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self.inner.read_start[S](path, reactor)

    def read_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        if self.mode == 1:
            raise Error("simulated read_poll transport failure")
        if self.mode == 2:
            return CasOpProgress.error(String("simulated read_poll ERR"))
        return self.inner.read_poll[S](reactor)

    def read_take(mut self) raises -> CasReadResult:
        return self.inner.read_take()

    def cas_put_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self,
        path: Path,
        var bytes: List[UInt8],
        expected_etag: String,
        mut reactor: Reactor[S],
    ) raises -> CasOpProgress:
        return self.inner.cas_put_start[S](path, bytes^, expected_etag, reactor)

    def cas_put_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self.inner.cas_put_poll[S](reactor)

    def cas_put_take(mut self) raises -> ObjectMeta:
        if self.mode == 3:
            raise Error("precondition failed (412): If-None-Match")
        if self.mode == 4:
            raise Error("simulated cas_put_take failure")
        return self.inner.cas_put_take()


def _drive[
    S: ConditionalWriteStore & AsyncCasStore
](
    mut op: AsyncManifestAppendOp[S],
    mut wal: CasManifestStore[S],
    seq: Int64,
    mut reactor: Reactor[NoopSink],
) raises -> CasOpProgress:
    """Start a create at `seq` and poll it until it stops parking."""
    var p = op.start[NoopSink](wal, seq, seq * _RPC, _body(Int(seq)), _RPC, reactor)
    while p.is_pending():
        p = op.poll[NoopSink](wal, reactor)
    return p^


# =============================================================================
# 13. The op's remaining phases (each branch of the guarded state machine).
# =============================================================================
def test_async_op_phase_branches() raises:
    print("[reaped-slot] 13. AsyncManifestAppendOp: every guarded phase")
    var reactor = _new_reactor()

    # Absent `_LOG_START` (never truncated) reads as 0: the win commits.
    var wal = _mk(_Slow(slow_ticks=0), String("rs/b-absent"))
    var op = AsyncManifestAppendOp[_Slow]()
    var p = _drive(op, wal, Int64(0), reactor)
    assert_true(p.is_ready(), "absent _LOG_START: live win")
    assert_true(Bool(op.take(wal)), "committed")

    # An undecodable `_LOG_START` body fails closed, async and sync.
    var bad = _Slow(slow_ticks=0)
    var bprefix = String("rs/b-corrupt")
    var bw = _mk(bad.clone(), bprefix)
    var short = List[UInt8]()
    for _ in range(3):
        short.append(UInt8(1))
    _ = bad.put(log_start_key(bprefix), short)  # a 3-byte body: undecodable
    var op_b = AsyncManifestAppendOp[_Slow]()
    p = _drive(op_b, bw, Int64(0), reactor)
    assert_true(p.is_error() and is_log_start_unread(p.err_text()), p.err_text())
    # Sync: a WARM writer (no `_LOG_START` read before its create) hits the
    # undecodable body in its post-win read and fails closed.
    var sstore = _Store()
    var sprefix = String("rs/b-corrupt-sync")
    var sw = _mk(sstore.clone(), sprefix)
    _ = sw.append(_body(0), _RPC)
    _ = sw.append(_body(1), _RPC)
    _ = sstore.put(log_start_key(sprefix), short)
    var sync_unread = False
    try:
        _ = sw.append(_body(2), _RPC)
    except e:
        sync_unread = is_log_start_unread(String(e))
    assert_true(sync_unread, "sync: an undecodable _LOG_START fails closed")

    # MODE 1/2: the parked read raises / returns ERR -> log_start_unread.
    for mode in range(1, 3):
        var fw = _mk(
            _AsyncFault(_Slow(slow_ticks=1), mode), String("rs/b-rp") + String(mode)
        )
        var opf = AsyncManifestAppendOp[_AsyncFault]()
        var pf = _drive(opf, fw, Int64(0), reactor)
        assert_true(
            pf.is_error() and is_log_start_unread(pf.err_text()),
            "mode " + String(mode) + ": " + pf.err_text(),
        )

    # MODE 3: a 412 at the create's take -> READY, then take returns None.
    var w3 = _mk(_AsyncFault(_Slow(slow_ticks=0), 3), String("rs/b-412"))
    var op3 = AsyncManifestAppendOp[_AsyncFault]()
    var p3 = _drive(op3, w3, Int64(0), reactor)
    assert_true(p3.is_ready(), "a deferred 412 completes the op")
    assert_false(Bool(op3.take(w3)), "and take reports the lost slot")

    # MODE 4: another failure at the create's take propagates.
    var w4 = _mk(_AsyncFault(_Slow(slow_ticks=0), 4), String("rs/b-take"))
    var op4 = AsyncManifestAppendOp[_AsyncFault]()
    var raised4 = False
    try:
        _ = _drive(op4, w4, Int64(0), reactor)
    except e:
        raised4 = String(e).find("simulated cas_put_take failure") >= 0
    assert_true(raised4, "a non-412 take failure is raised, not swallowed")

    # `take` before the create and its check completed is refused.
    var ws = _mk(_Slow(slow_ticks=2), String("rs/b-early"))
    var ope = AsyncManifestAppendOp[_Slow]()
    var pe = ope.start[NoopSink](ws, Int64(0), Int64(0), _body(3), _RPC, reactor)
    assert_true(pe.is_pending(), "parked")
    var early = False
    try:
        _ = ope.take(ws)
    except e:
        early = String(e).find("have not completed") >= 0
    assert_true(early, "a guarded op is not takeable before its check")
    var idle = AsyncManifestAppendOp[_Slow]()
    assert_true(idle.poll[NoopSink](ws, reactor).is_error(), "poll when idle: ERR")
    var idle_take = False
    try:
        _ = idle.take(ws)
    except e:
        idle_take = String(e).find("no create-CAS in flight") >= 0
    assert_true(idle_take, "take when idle raises")

    # `apply_async_append_win`'s own guard (a direct caller cannot bypass it).
    var dstore = _Store()
    var dprefix = String("rs/b-apply")
    var g = _mk(dstore.clone(), dprefix)
    for i in range(3):
        _ = g.append(_body(i), _RPC)
    _retire(g, Int64(0), Int64(2))
    var need = False
    try:
        g.apply_async_append_win(Int64(3), Int64(30), _RPC, String("e"))
    except e:
        need = String(e).find("needs the _LOG_START read") >= 0
    assert_true(need, "guarded: no log-start value, no advance")
    var reaped = False
    try:
        g.apply_async_append_win(Int64(1), Int64(10), _RPC, String("e"), Int64(2))
    except e:
        reaped = is_slot_reaped(String(e))
    assert_true(reaped, "guarded: a win below the given log start is refused")
    assert_equal(
        g.read_head().chunk_seq,
        Int64(0),
        "the refusal invalidated the head cache (it held chunk 2)",
    )
    g.apply_async_append_win(Int64(3), Int64(30), _RPC, String("e"), Int64(2))
    assert_equal(_durable_head_seq(dstore, dprefix), Int64(3), "a live win advances")
    var u = _mk(dstore.clone(), String("rs/b-apply-u"), guard=False)
    u.apply_async_append_win(Int64(0), Int64(0), _RPC, String("e"))
    print("  PASS")


def main() raises:
    test_async_op_reaped_slot()
    test_async_log_start_read_failure_fails_closed()
    test_async_op_phase_branches()
    print("ALL reaped-slot async guard tests PASSED")
