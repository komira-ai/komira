# =============================================================================
# src/komira_table_store/tests/test_table_store_fault_paths.mojo
#   The table store's fault handling, driven by a fault-injecting store double:
#   replay of a chunk read that fails once, the OCC scan's in-flight chunk
#   (sync and async), a failing head listing, every create-CAS failure shape of
#   the async commit (raised 412, raised transport error, transport ERR from
#   start and from poll, a 412 deferred to take, 412s past the attempt bound),
#   the group-commit appender's deferred 412, and a failed chunk read in
#   register_index's catch-up fold.
# =============================================================================
#
# THE DOUBLE: `_FaultStore` delegates every verb to a SharedInMemorySlowCasStore
# and reads its faults from marker objects under `zz_faults/` in the SAME shared
# backing, so a test arms a fault after the handle is open (the handle owns its
# store). A marker is [skip, count_lo, count_hi, mode]: the first `skip` calls
# pass, the next `count` calls fail with `mode`, then the marker is deleted.
#   get    (chunk objects only) -> raise the mode's message
#   list   -> raise the mode's message
#   start  -> 3: ERR 412 | 4: ERR transport | 5: raise 412 | 6: raise transport
#             | 7: READY without writing
#   poll   -> 4: ERR transport
#   take   -> 5: raise 412
#
# What each test proves (the planted mutant for each is in the PR body):
#   * replay retries a transient chunk read and fails on a fatal one.
#   * the OCC scan's failed chunk read is re-driven (sync and async), not
#     reported as an error or a conflict. The injected failure is deliberately
#     NOT torn-create wording: the OCC scans tag ANY chunk-read error RETRYABLE,
#     so a non-torn read failure is retried by design, not only the torn window.
#   * a non-retryable head-listing failure ends the sync commit with it.
#   * async create-CAS: a raised 412 re-runs and commits; a raised or ERR
#     transport failure from start or poll errors the op with its text; a 412
#     deferred to take re-runs and commits; 412s past the bound error the op
#     as retryable-exhausted after exactly 256 create-CAS starts.
#   * the appender maps a 412 deferred to take to a lost slot.
#   * register_index's catch-up fold retries a transient chunk read and
#     raises a fatal one without registering the lineage, so a later
#     register_index re-runs the fold (komira-ai/komira#1377).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.coalescing_window import APPEND_LOST_SLOT
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
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_table_store.table_store_codec import bytes_eq, encode_commit_chunk, WriteOp
from komira_table_store.table_store import (
    AsyncCommitOp,
    TableStore,
    Txn,
    commit_async_poll,
    commit_async_start,
    is_commit_retryable,
)
from komira_table_store.group_commit import TableStoreExactSlotAppender


comptime _MSG_TRUNCATED = 0
comptime _MSG_FATAL = 1
comptime _MSG_FLAKY = 2
comptime _MODE_ERR_412 = 3
comptime _MODE_ERR_TRANSPORT = 4
comptime _MODE_RAISE_412 = 5
comptime _MODE_RAISE_TRANSPORT = 6
comptime _MODE_FAKE_READY = 7


def _msg(mode: Int) -> String:
    if mode == _MSG_TRUNCATED:
        return String("truncated chunk body (injected)")
    if mode == _MSG_FATAL:
        return String("injected boom: fatal read")
    if mode == _MSG_FLAKY:
        return String("injected flaky read")
    if mode == _MODE_ERR_412 or mode == _MODE_RAISE_412:
        return String("HTTP 412 precondition failed (injected)")
    return String("injected transport failure")


def _marker(name: String) raises -> Path:
    return Path.parse(String("zz_faults/") + name)


struct _FaultStore(
    AsyncCasStore,
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: SharedInMemorySlowCasStore
    var _markers: SharedInMemoryConditionalStore

    def __init__(
        out self, var markers: SharedInMemoryConditionalStore, slow_ticks: Int
    ):
        self._inner = SharedInMemorySlowCasStore(
            inner=markers.clone(), slow_ticks=slow_ticks
        )
        self._markers = markers^

    def __init__(
        out self,
        var inner: SharedInMemorySlowCasStore,
        var markers: SharedInMemoryConditionalStore,
    ):
        self._inner = inner^
        self._markers = markers^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._markers.clone())

    def _fault(self, name: String) raises -> Int:
        """The armed mode for `name`, consuming one firing; -1 when none."""
        var p = _marker(name)
        var spec: List[UInt8]
        try:
            spec = self._markers.get(p)
        except e:
            _ = e
            return -1
        if Int(spec[0]) > 0:
            spec[0] = spec[0] - 1
            _ = self._markers.put(p, spec)
            return -1
        var count = Int(spec[1]) + 256 * Int(spec[2])
        var mode = Int(spec[3])
        count -= 1
        if count <= 0:
            self._markers.delete(p)
        else:
            spec[1] = UInt8(count & 0xFF)
            spec[2] = UInt8((count >> 8) & 0xFF)
            _ = self._markers.put(p, spec)
        return mode

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        var m = self._fault("list")
        if m >= 0:
            raise Error(_msg(m))
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if path.raw().endswith(".chunk"):
            var m = self._fault("get")
            if m >= 0:
                raise Error(_msg(m))
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)

    def read_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, path: Path, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._inner.read_start[S](path, reactor)

    def read_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._inner.read_poll[S](reactor)

    def read_take(mut self) raises -> CasReadResult:
        return self._inner.read_take()

    def cas_put_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self,
        path: Path,
        var bytes: List[UInt8],
        expected_etag: String,
        mut reactor: Reactor[S],
    ) raises -> CasOpProgress:
        var m = self._fault("start")
        if m == _MODE_ERR_412 or m == _MODE_ERR_TRANSPORT:
            _ = bytes^
            return CasOpProgress.error(_msg(m))
        if m == _MODE_RAISE_412 or m == _MODE_RAISE_TRANSPORT:
            _ = bytes^
            raise Error(_msg(m))
        if m == _MODE_FAKE_READY:
            _ = bytes^
            return CasOpProgress.ready()
        return self._inner.cas_put_start[S](path, bytes^, expected_etag, reactor)

    def cas_put_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        var m = self._fault("poll")
        if m >= 0:
            return CasOpProgress.error(_msg(m))
        return self._inner.cas_put_poll[S](reactor)

    def cas_put_take(mut self) raises -> ObjectMeta:
        var m = self._fault("take")
        if m >= 0:
            raise Error(_msg(m))
        return self._inner.cas_put_take()


comptime _PREFIX = "ts/fault"


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


def _arm(
    backing: SharedInMemoryConditionalStore,
    name: String,
    skip: Int,
    count: Int,
    mode: Int,
) raises:
    var spec = List[UInt8]()
    spec.append(UInt8(skip))
    spec.append(UInt8(count & 0xFF))
    spec.append(UInt8((count >> 8) & 0xFF))
    spec.append(UInt8(mode))
    _ = backing.put(_marker(name), spec)


def _armed(backing: SharedInMemoryConditionalStore, name: String) raises -> Bool:
    try:
        _ = backing.get(_marker(name))
    except e:
        _ = e
        return False
    return True


def _wal(
    backing: SharedInMemoryConditionalStore, slow_ticks: Int = 0
) -> CasManifestStore[_FaultStore]:
    return CasManifestStore[_FaultStore](
        store=_FaultStore(backing.clone(), slow_ticks),
        prefix=String(_PREFIX),
        retry=RetryPolicy.fast_test(),
    )


def _open(
    backing: SharedInMemoryConditionalStore, slow_ticks: Int = 0
) raises -> TableStore[_FaultStore]:
    return TableStore[_FaultStore].open(_wal(backing, slow_ticks))


def _commit_one(mut ts: TableStore[_FaultStore], k: String, v: String) raises -> Int64:
    var t = ts.begin()
    t.insert(_b(k), _b(v))
    return ts.commit(t^).commit_lsn


def _read(mut ts: TableStore[_FaultStore], k: String) raises -> String:
    var t = ts.begin()
    var got = ts.get(t, _b(k))
    if not got:
        return String("<none>")
    var out = String("")
    var v = got.value().copy()
    for i in range(len(v)):
        out += chr(Int(v[i]))
    return out


def _async_op(snapshot: Int64, k: String, v: String) raises -> AsyncCommitOp:
    var t = Txn(snapshot)
    t.insert(_b(k), _b(v))
    return AsyncCommitOp.from_txn(t^)


def test_replay_retries_transient_and_fails_fatal() raises:
    print("[faults] replay: a transient chunk read is retried, a fatal one raised")
    var backing = SharedInMemoryConditionalStore()
    var w = _open(backing)
    _ = _commit_one(w, "k", "v")
    # The open's head recovery reads chunk 0 once (skip it); replay reads it next.
    _arm(backing, "get", 1, 1, _MSG_TRUNCATED)
    var r = _open(backing)
    assert_false(_armed(backing, "get"), "the replay read hit the fault")
    assert_equal(_read(r, "k"), String("v"), "replay retried and folded the row")
    _arm(backing, "get", 1, 1, _MSG_FATAL)
    var err = String("")
    try:
        _ = _open(backing)
    except e:
        err = String(e)
    assert_true(err.find("injected boom: fatal read") >= 0, "fatal replay: " + err)


def test_sync_occ_scan_read_failure_is_redriven() raises:
    print("[faults] sync commit: a failed OCC-scan chunk read is re-driven")
    var backing = SharedInMemoryConditionalStore()
    var ts = _open(backing)
    _ = _commit_one(ts, "k1", "v1")
    var t = Txn(Int64(-1))
    t.insert(_b("k2"), _b("v2"))
    _arm(backing, "get", 0, 1, _MSG_FLAKY)
    var res = ts.commit(t^)
    assert_false(_armed(backing, "get"), "the OCC scan read hit the fault")
    assert_equal(res.commit_lsn, Int64(1), "the re-driven commit won slot 1")
    assert_equal(_read(ts, "k2"), String("v2"))


def test_sync_head_listing_failure_ends_commit() raises:
    print("[faults] sync commit: a fatal head-listing failure is raised")
    var backing = SharedInMemoryConditionalStore()
    var ts = _open(backing)
    var t = ts.begin()
    t.insert(_b("k"), _b("v"))
    _arm(backing, "list", 0, 1, _MSG_FATAL)
    var err = String("")
    try:
        _ = ts.commit(t^)
    except e:
        err = String(e)
    assert_true(err.find("injected boom: fatal read") >= 0, "listing failure: " + err)
    assert_equal(ts.wal_head_seq(), Int64(-1), "nothing was committed")


def test_async_occ_scan_read_failure_is_redriven() raises:
    print("[faults] async commit: a failed OCC-scan chunk read is re-driven")
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()
    var ts = _open(backing)
    _ = _commit_one(ts, "k1", "v1")
    var op = _async_op(Int64(-1), "k2", "v2")
    _arm(backing, "get", 0, 1, _MSG_FLAKY)
    assert_equal(commit_async_start[_FaultStore, NoopSink](ts, op, reactor), Int64(0))
    assert_false(_armed(backing, "get"), "the OCC scan read hit the fault")
    assert_true(op.is_done(), "re-driven, not errored: " + op.err_text())
    assert_equal(op.take_result().commit_lsn, Int64(1))


def _async_with_start_fault(mode: Int, count: Int = 1) raises -> AsyncCommitOp:
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()
    var ts = _open(backing)
    var op = _async_op(ts.begin().snapshot_lsn, "k", "v")
    _arm(backing, "start", 0, count, mode)
    _ = commit_async_start[_FaultStore, NoopSink](ts, op, reactor)
    return op^


def test_async_start_raised_412_reruns() raises:
    print("[faults] async start: a raised 412 re-runs the attempt and commits")
    var op = _async_with_start_fault(_MODE_RAISE_412)
    assert_true(op.is_done(), "committed after the raised 412: " + op.err_text())
    assert_equal(op.take_result().commit_lsn, Int64(0))


def test_async_start_raised_transport_errors() raises:
    print("[faults] async start: a raised transport failure errors the op")
    var op = _async_with_start_fault(_MODE_RAISE_TRANSPORT)
    assert_true(op.is_error(), "errored")
    assert_true(
        op.err_text().find("commit_async: create-CAS start: injected transport failure")
        >= 0,
        op.err_text(),
    )


def test_async_start_err_transport_errors() raises:
    print("[faults] async start: a transport ERR errors the op")
    var op = _async_with_start_fault(_MODE_ERR_TRANSPORT)
    assert_true(op.is_error(), "errored")
    assert_true(
        op.err_text().find("commit_async: create-CAS start: injected transport failure")
        >= 0,
        op.err_text(),
    )


def _left(backing: SharedInMemoryConditionalStore, name: String) raises -> Int:
    """The firings still armed on marker `name` (0 once it is consumed)."""
    var spec: List[UInt8]
    try:
        spec = backing.get(_marker(name))
    except e:
        _ = e
        return 0
    return Int(spec[1]) + 256 * Int(spec[2])


def test_async_412_past_the_bound_is_exhausted() raises:
    print("[faults] async start: 412 on every attempt ends as retryable-exhausted")
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()
    var ts = _open(backing)
    var op = _async_op(ts.begin().snapshot_lsn, "k", "v")
    _arm(backing, "start", 0, 300, _MODE_ERR_412)
    _ = commit_async_start[_FaultStore, NoopSink](ts, op, reactor)
    # Exactly 256 create-CAS starts ran before the bound ended the op: the
    # message alone names the constant, not the number of attempts made.
    assert_equal(_left(backing, "start"), 300 - 256, "256 attempts, not 255 or 257")
    assert_true(op.is_error(), "errored")
    assert_true(is_commit_retryable(op.err_text()), op.err_text())
    assert_true(op.err_text().find("commit_async exhausted 256") >= 0, op.err_text())


def test_async_412_deferred_to_take_reruns() raises:
    print("[faults] async: a 412 deferred to take re-runs and commits")
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()
    var ts = _open(backing)
    var op = _async_op(ts.begin().snapshot_lsn, "k", "v")
    _arm(backing, "start", 0, 1, _MODE_FAKE_READY)
    _arm(backing, "take", 0, 1, _MODE_RAISE_412)
    assert_equal(commit_async_start[_FaultStore, NoopSink](ts, op, reactor), Int64(0))
    assert_false(_armed(backing, "take"), "the take-side 412 fired")
    assert_true(op.is_done(), "committed after the deferred 412: " + op.err_text())
    assert_equal(op.take_result().commit_lsn, Int64(0))
    assert_equal(_read(ts, "k"), String("v"))


def test_async_poll_transport_err_errors() raises:
    print("[faults] async poll: a transport ERR errors the op")
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()
    var ts = _open(backing, slow_ticks=2)
    var op = _async_op(ts.begin().snapshot_lsn, "k", "v")
    var park = commit_async_start[_FaultStore, NoopSink](ts, op, reactor)
    assert_true(park != Int64(0), "the slow create-CAS parked")
    _arm(backing, "poll", 0, 1, _MODE_ERR_TRANSPORT)
    assert_equal(commit_async_poll[_FaultStore, NoopSink](ts, op, reactor), Int64(0))
    assert_true(op.is_error(), "errored")
    assert_true(
        op.err_text().find("commit_async: create-CAS poll: injected transport failure")
        >= 0,
        op.err_text(),
    )


def test_appender_take_412_is_lost_slot() raises:
    print("[faults] group appender: a 412 deferred to take is a lost slot")
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()
    var app = TableStoreExactSlotAppender[_FaultStore](_wal(backing))
    _arm(backing, "start", 0, 1, _MODE_FAKE_READY)
    _arm(backing, "take", 0, 1, _MODE_RAISE_412)
    var body = encode_commit_chunk(Int64(-1), List[WriteOp]())
    var prog = app.append_start[NoopSink](
        body^, Int64(0), Int64(0), Int64(0), Int64(0), reactor
    )
    assert_true(prog.is_ready(), "the faked create-CAS is READY")
    var out = app.append_take()
    assert_equal(Int(out.kind), Int(APPEND_LOST_SLOT), "a lost slot")


def _ik(lineage: Int, tail: String) -> List[UInt8]:
    """A key whose 4-byte big-endian prefix is `lineage` (the ordinal
    `TableStore._key_lineage_ord` routes on) followed by `tail`."""
    var out = List[UInt8]()
    for i in range(4):
        out.append(UInt8((lineage >> (8 * (3 - i))) & 0xFF))
    var sb = tail.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _index_rows(mut ts: TableStore[_FaultStore], lineage: Int) raises -> Int:
    var t = ts.begin()
    return len(
        ts.index_scan_visible(
            t, Int32(lineage), _ik(lineage, ""), _ik(lineage + 1, "")
        )
    )


def test_register_index_catch_up_read_failure() raises:
    print("[faults] register_index catch-up: transient read retried, fatal raised")
    var backing = SharedInMemoryConditionalStore()
    var ts = _open(backing)
    var t = ts.begin()
    t.insert(_ik(9, "a"), _b("ia"))
    _ = ts.commit(t^)
    # The catch-up fold's read of slot 0 is the next chunk get.
    _arm(backing, "get", 0, 1, _MSG_TRUNCATED)
    ts.register_index(Int32(9))
    assert_false(_armed(backing, "get"), "the catch-up read hit the fault")
    assert_equal(
        _index_rows(ts, 9), 1, "a transient catch-up read is retried, not a stop"
    )
    _arm(backing, "get", 0, 1, _MSG_FATAL)
    var err = String("")
    try:
        ts.register_index(Int32(5))
    except e:
        err = String(e)
    assert_true(err.find("injected boom: fatal read") >= 0, "fatal catch-up: " + err)
    assert_equal(len(ts._idx_lineage_ords), 1, "a failed catch-up registers nothing")
    ts.register_index(Int32(5))
    assert_equal(len(ts._idx_lineage_ords), 2, "a retried register completes")


def main() raises:
    test_replay_retries_transient_and_fails_fatal()
    test_sync_occ_scan_read_failure_is_redriven()
    test_sync_head_listing_failure_ends_commit()
    test_async_occ_scan_read_failure_is_redriven()
    test_async_start_raised_412_reruns()
    test_async_start_raised_transport_errors()
    test_async_start_err_transport_errors()
    test_async_412_past_the_bound_is_exhausted()
    test_async_412_deferred_to_take_reruns()
    test_async_poll_transport_err_errors()
    test_appender_take_412_is_lost_slot()
    test_register_index_catch_up_read_failure()
    print("ALL table store fault-path tests PASSED")
