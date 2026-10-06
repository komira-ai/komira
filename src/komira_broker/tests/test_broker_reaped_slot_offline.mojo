# =============================================================================
# tests/test_broker_reaped_slot_offline.mojo
#   The broker's side of the reaped-slot guard (komira-ai/komira#486;
#   komira_objectstore/manifest_slot_guard.mojo).
# =============================================================================
#
# Each test names the defect it catches and the mutant that turns it red:
#   1 `classify_append_error`: `slot_reaped` is a lost slot in both modes, and
#     `log_start_unread` is terminal even when its cause spells `412`
#     ............................... the classifier maps slot_reaped to APPEND_ERR
#   2 ESCALATING appender (the parkable op): a win the store reports below
#     `_LOG_START` ends in ERR slot_reaped, classified LOST_SLOT; the re-drive
#     lands at the live tail
#   3 IDEMPOTENT-SINGLETON appender: the same refusal comes back on the ERR
#     channel (not a raise that escapes the spine); the re-drive commits once.
#     Any other append_idempotent failure still raises.
#   4 `recover_last_committed_seq` never reads below `_LOG_START`, where a
#     refused win carrying the producer's identity was left behind
#     ............................... the floor removed (a false DUPLICATE)
# All run on the in-memory stores; no network.
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_broker.broker_coalescing_produce import (
    BROKER_APPEND_MODE_ESCALATING,
    BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON,
    BrokerBatchAppender,
    _EosResultCell,
)
from komira_broker.broker_core import BrokerCore
from komira_broker.manifest_body import encode_manifest_body

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    LogStart,
    RetryPolicy,
    encode_log_start,
    log_start_key,
)
from komira_objectstore.coalescing_window import APPEND_ERR, APPEND_LOST_SLOT
from komira_objectstore.manifest_slot_guard import (
    is_slot_reaped,
    log_start_unread_error,
    slot_reaped_error,
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
comptime _RPC = Int64(10)


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _body(tag: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(16):
        out.append(UInt8((i * 7 + tag) & 0xFF))
    return out^


# -----------------------------------------------------------------------------
# A parking store whose create of `trigger` is followed, before the create
# returns, by `_LOG_START` moving past it: to the guard this is a win in a slot
# below the log start, exactly what a win in a reaped slot looks like.
# -----------------------------------------------------------------------------
struct _LogStartPassesWin(
    AsyncCasStore, ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    var inner: _Slow
    var trigger: String
    var ls_key: String

    def __init__(out self, var inner: _Slow, var trigger: String, var ls_key: String):
        self.inner = inner^
        self.trigger = trigger^
        self.ls_key = ls_key^

    def _pass(self) raises:
        _ = self.inner.put(
            Path.parse(self.ls_key),
            encode_log_start(LogStart(_RPC, Int64(1), String(""))),
        )

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        var meta = self.inner.conditional_put(path, bytes, precond)
        if path.raw() == self.trigger:
            self._pass()
        return meta^

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
        var prog = self.inner.cas_put_start[S](path, bytes^, expected_etag, reactor)
        if path.raw() == self.trigger and prog.is_ready():
            self._pass()
        return prog^

    def cas_put_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self.inner.cas_put_poll[S](reactor)

    def cas_put_take(mut self) raises -> ObjectMeta:
        return self.inner.cas_put_take()


def _guarded_wal(prefix: String) raises -> CasManifestStore[_LogStartPassesWin]:
    """A partition WAL (opted in, as the produce factory does) over a store that
    moves `_LOG_START` past slot 0 as soon as slot 0 is won."""
    var wal = CasManifestStore[_LogStartPassesWin](
        store=_LogStartPassesWin(
            _Slow(slow_ticks=0),
            prefix + "/manifest/00000000000000000000.chunk",
            log_start_key(prefix).raw(),
        ),
        prefix=prefix.copy(),
        retry=RetryPolicy.fast_test(),
    )
    wal.enable_reaped_slot_guard()
    return wal^


# =============================================================================
# 1. classify_append_error, both modes.
# =============================================================================
def test_classify_append_error() raises:
    print("[broker reaped-slot] 1. classify_append_error")
    var reaped = String(slot_reaped_error(String("append")))
    var unread = String(
        log_start_unread_error(
            String("append"), String("GET failed status=412 precondition If-Match")
        )
    )
    for mode in range(2):
        var cell = ArcPointer[_EosResultCell](_EosResultCell())
        var appender = BrokerBatchAppender[_Slow](
            CasManifestStore[_Slow](_Slow(slow_ticks=0), String("c/p")),
            UInt8(mode),
            cell,
        )
        assert_equal(
            appender.classify_append_error(reaped),
            APPEND_LOST_SLOT,
            "slot_reaped is a lost slot (re-read + re-append), mode " + String(mode),
        )
        assert_equal(
            appender.classify_append_error(unread),
            APPEND_ERR,
            "log_start_unread is terminal even when its cause spells 412",
        )
        var bare = appender.classify_append_error(String("precondition (412)"))
        if UInt8(mode) == BROKER_APPEND_MODE_ESCALATING:
            assert_equal(bare, APPEND_LOST_SLOT, "escalating: a 412 is a lost slot")
        else:
            assert_equal(bare, APPEND_ERR, "singleton: unchanged, terminal")
    print("  PASS")


# =============================================================================
# 2. ESCALATING: the parkable op refuses the win below `_LOG_START` on its ERR
#    channel; the classifier routes it to the spine's lost-slot loop; the
#    re-drive (authoritative head, LIST from the log start) lands at slot 1.
# =============================================================================
def test_escalating_refusal_is_lost_slot_then_lands() raises:
    print("[broker reaped-slot] 2. escalating: ERR slot_reaped -> LOST_SLOT")
    var reactor = _new_reactor()
    var cell = ArcPointer[_EosResultCell](_EosResultCell())
    var appender = BrokerBatchAppender[_LogStartPassesWin](
        _guarded_wal(String("c/esc")), BROKER_APPEND_MODE_ESCALATING, cell
    )
    var p = appender.append_start[NoopSink](
        _body(1), _RPC, Int64(0), Int64(0), Int64(0), reactor
    )
    assert_true(p.is_error(), "the win below _LOG_START is not READY")
    assert_true(is_slot_reaped(p.err_text()), p.err_text())
    assert_equal(
        appender.classify_append_error(p.err_text()), APPEND_LOST_SLOT, "lost slot"
    )
    var p2 = appender.append_start[NoopSink](
        _body(1), _RPC, Int64(0), Int64(0), Int64(0), reactor
    )
    assert_true(p2.is_ready(), "the re-drive completes")
    var won = appender.append_take()
    assert_true(won.is_won(), "and is committed")
    assert_equal(won.result.chunk_seq, Int64(1), "at slot 1, the live tail")
    assert_equal(won.result.base_offset, _RPC, "at the log-start offset")
    print("  PASS")


# =============================================================================
# 3. IDEMPOTENT-SINGLETON: append_idempotent raised slot_reaped (sentinel
#    released). The appender returns it on the ERR channel; the re-drive
#    commits. Mutant: the raise escapes (append_start raises).
# =============================================================================
def test_eos_refusal_is_err_channel_then_commits() raises:
    print("[broker reaped-slot] 3. EOS: slot_reaped on the ERR channel")
    var reactor = _new_reactor()
    var cell = ArcPointer[_EosResultCell](_EosResultCell())
    var appender = BrokerBatchAppender[_LogStartPassesWin](
        _guarded_wal(String("c/eos")),
        BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON,
        cell,
        Int64(5),  # producer_id
        Int64(0),
        Int64(0),  # first_seq
        Int64(9),  # last_seq
        Int64(0),
        Int64(0),
        Int64(0),
    )
    var body = encode_manifest_body(
        String("seg/eos"), _RPC, UInt32(0), Int64(100), Int64(1), Int64(5),
        Int64(0), Int64(0), Int64(9),
    )
    var p = appender.append_start[NoopSink](
        body.copy(), _RPC, Int64(0), Int64(0), Int64(0), reactor
    )
    assert_true(p.is_error() and is_slot_reaped(p.err_text()), p.err_text())
    assert_equal(
        appender.classify_append_error(p.err_text()), APPEND_LOST_SLOT, "lost slot"
    )
    var p2 = appender.append_start[NoopSink](
        body.copy(), _RPC, Int64(0), Int64(0), Int64(0), reactor
    )
    assert_true(p2.is_ready(), "the re-drive completes")
    var won = appender.append_take()
    assert_true(won.is_won(), "committed: " + won.err)
    assert_equal(won.result.chunk_seq, Int64(1), "once, at slot 1")

    # Any other append_idempotent failure is still raised.
    var raised = False
    try:
        _ = appender.append_start[NoopSink](
            body.copy(), Int64(-1), Int64(0), Int64(0), Int64(0), reactor
        )
    except e:
        raised = String(e).find("negative record_count") >= 0
    assert_true(raised, "a non-slot_reaped failure is raised as before")
    print("  PASS")


# =============================================================================
# 4. The dedupe recovery scan is floored at `_LOG_START`. A stale writer's
#    refused win at slot 1 (below log_start 2) carries producer P's identity
#    with last_seq 99; P has nothing in the live range. Mutant: the floor
#    removed -> 99 (a false DUPLICATE for P's next batch).
# =============================================================================
def _mb(producer_id: Int64, last_seq: Int64) -> List[UInt8]:
    return encode_manifest_body(
        String("seg/k"), _RPC, UInt32(0), Int64(100), Int64(1), producer_id,
        Int64(0), last_seq - _RPC + Int64(1), last_seq,
    )


def test_recover_last_committed_seq_is_floored() raises:
    print("[broker reaped-slot] 4. recover_last_committed_seq floor")
    var store = _Store()
    var prefix = String("c/_meta/topics/t/0")
    var m = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix.copy(), retry=RetryPolicy.fast_test()
    )
    m.enable_reaped_slot_guard()
    var p = Int64(41)
    var q = Int64(42)
    _ = m.append(_mb(p, Int64(9)), _RPC)  # 0: P
    _ = m.append(_mb(q, Int64(9)), _RPC)  # 1: Q
    _ = m.append(_mb(q, Int64(19)), _RPC)  # 2: Q
    _ = m.append(_mb(q, Int64(29)), _RPC)  # 3: Q
    for s in range(2):
        m.schedule_for_delete_at(Int64(s), Int64(1))
    var ls = m.read_log_start()
    _ = m.advance_log_start(Int64(2), Int64(20), ls.etag)
    m.reap(Int64(0))
    m.reap(Int64(1))
    var stale = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix.copy(), retry=RetryPolicy.fast_test()
    )
    stale.enable_reaped_slot_guard()
    var refused = False
    try:
        _ = stale.try_append_at_seq(Int64(1), Int64(10), _mb(p, Int64(99)), _RPC)
    except e:
        refused = is_slot_reaped(String(e))
    assert_true(refused, "PRECONDITION: the stale win at slot 1 was refused")

    var broker = BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=CasManifestStore[_Store](
            store=store.clone(), prefix=prefix.copy(), retry=RetryPolicy.fast_test()
        ),
        cluster=String("c"),
        topic=String("t"),
        partition=Int64(0),
        broker_id=String("b"),
    )
    assert_equal(
        broker.recover_last_committed_seq(p, authoritative=True),
        Int64(-1),
        "P has no committed chunk at or above log_start (the slot-1 chunk was"
        " never acknowledged)",
    )
    assert_equal(
        broker.recover_last_committed_seq(q, authoritative=True),
        Int64(29),
        "Q's live tail is still found",
    )
    print("  PASS")


def main() raises:
    test_classify_append_error()
    test_escalating_refusal_is_lost_slot_then_lands()
    test_eos_refusal_is_err_channel_then_commits()
    test_recover_last_committed_seq_is_floored()
    print("ALL broker reaped-slot tests PASSED")
