# =============================================================================
# komira_broker_coordinator/tests/test_cov_broker_coordinator_async.mojo
#   The parkable serve: `AsyncReassignOp` (read and write errors, the lost
#   write retry, the attempt bound), `BrokerHeartbeatSM` (one-step, error and
#   parked frames, the trace lines) and the suspendable dispatcher's
#   `make_frame` (routing, the 400 replies, the trace lines).
# =============================================================================
#
# The store is `_AsyncFaultStore`: the in-memory slow CAS store (each
# poll-shaped verb parks `slow_ticks` times) whose read_start, read_poll and
# cas_put_start consult fault rules kept in a shared in-memory store. A rule
# fails calls `lo..hi` (1-based) of a verb with an injected 412, an injected
# transport error, a RACE (a concurrent writer creates the object first, so
# the real store answers the write with its own 412), or a VANISH (the object
# is deleted and the write answered with a 412).
#
# The trace lines go to stdout; a test points fd 1 at a socket pair while
# the code under test runs and reads back what it printed.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.suspendable_handler import SuspendedFrame

from komira_broker import (
    Assignment,
    ClusterAssignmentStore,
    REBALANCE_INITIAL,
    assign_partitions,
)
from komira_broker_coordinator import (
    AsyncReassignOp,
    BrokerCoordSuspendableDispatcher,
    BrokerHeartbeatCoordinator,
    BrokerHeartbeatSM,
    json_response,
)
from komira_broker_coordinator.broker_heartbeat_handler import (
    NodeEndpointSnapshot,
    _CoalesceCacheState,
)
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
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
from komira_proto_codec import decode_proto, encode_proto

from komira_supervisor_proto.supervisor import (
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    HeartbeatResponse as PbHeartbeatResponse,
    JobPhase as PbJobPhase,
)
from komira_broker_proto.broker import NodeLoad as PbNodeLoad


comptime _MODE_412 = 1
comptime _MODE_TRANSPORT = 2
comptime _MODE_RACE = 3
comptime _MODE_VANISH = 4
comptime _TOPIC = "example-data"
comptime _CLUSTER = "cl-cov-async"
comptime _KEY = "cl-cov-async/_meta/cluster/example-data/assignment.bin"
comptime _NIL = "00000000-0000-0000-0000-000000000000"
comptime _Rt = BlockingRuntime[NoopSink]


# =============================================================================
# §1 — the fault-injecting poll-shaped store.
# =============================================================================
def _fault_msg(mode: Int) -> String:
    if mode == _MODE_412:
        return String("HTTP 412 precondition failed (injected)")
    return String("injected transport failure")


def _mk(name: String) raises -> Path:
    return Path.parse(String("faults/") + name)


def _u16(b: List[UInt8], at: Int) -> Int:
    return Int(b[at]) + 256 * Int(b[at + 1])


def _calls(m: SharedInMemoryConditionalStore, verb: String) raises -> Int:
    try:
        return _u16(m.get(_mk(String("n/") + verb)), 0)
    except e:
        _ = e
        return 0


def _arm(
    m: SharedInMemoryConditionalStore,
    verb: String,
    rule: Int,
    lo: Int,
    hi: Int,
    mode: Int,
) raises:
    var spec = List[UInt8]()
    spec.append(UInt8(lo & 0xFF))
    spec.append(UInt8((lo >> 8) & 0xFF))
    spec.append(UInt8(hi & 0xFF))
    spec.append(UInt8((hi >> 8) & 0xFF))
    spec.append(UInt8(mode))
    _ = m.put(_mk(String("rule/") + verb + String("/") + String(rule)), spec)


def _next_mode(m: SharedInMemoryConditionalStore, verb: String) raises -> Int:
    var n = _calls(m, verb) + 1
    var c = List[UInt8]()
    c.append(UInt8(n & 0xFF))
    c.append(UInt8((n >> 8) & 0xFF))
    _ = m.put(_mk(String("n/") + verb), c)
    for r in range(2):
        var spec: List[UInt8]
        try:
            spec = m.get(_mk(String("rule/") + verb + String("/") + String(r)))
        except e:
            _ = e
            continue
        if n >= _u16(spec, 0) and n <= _u16(spec, 2):
            return Int(spec[4])
    return -1


def _racer_body() raises -> List[UInt8]:
    var ids = List[String]()
    ids.append(String("9"))
    return assign_partitions(
        ids^, 6, Optional[Assignment](), REBALANCE_INITIAL
    ).encode_binary()


struct _AsyncFaultStore(
    AsyncCasStore,
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: SharedInMemorySlowCasStore
    var _m: SharedInMemoryConditionalStore

    def __init__(
        out self,
        var inner: SharedInMemorySlowCasStore,
        var markers: SharedInMemoryConditionalStore,
    ):
        self._inner = inner^
        self._m = markers^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._m.clone())

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
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
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)

    def read_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, path: Path, mut reactor: Reactor[S]) raises -> CasOpProgress:
        var mode = _next_mode(self._m, String("read_start"))
        if mode == _MODE_412 or mode == _MODE_TRANSPORT:
            return CasOpProgress.error(_fault_msg(mode))
        return self._inner.read_start[S](path, reactor)

    def read_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        var mode = _next_mode(self._m, String("read_poll"))
        if mode == _MODE_412 or mode == _MODE_TRANSPORT:
            return CasOpProgress.error(_fault_msg(mode))
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
        var mode = _next_mode(self._m, String("cas_put_start"))
        if mode == _MODE_412 or mode == _MODE_TRANSPORT:
            _ = bytes^
            return CasOpProgress.error(_fault_msg(mode))
        if mode == _MODE_RACE:
            _ = self._inner.put(path, _racer_body())
        if mode == _MODE_VANISH:
            # Another writer deleted the object: this write lost its etag.
            self._inner.delete(path)
            _ = bytes^
            return CasOpProgress.error(_fault_msg(_MODE_412))
        return self._inner.cas_put_start[S](path, bytes^, expected_etag, reactor)

    def cas_put_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._inner.cas_put_poll[S](reactor)

    def cas_put_take(mut self) raises -> ObjectMeta:
        return self._inner.cas_put_take()


comptime _Op = AsyncReassignOp[_AsyncFaultStore]
comptime _SM = BrokerHeartbeatSM[_AsyncFaultStore]
comptime _Disp = BrokerCoordSuspendableDispatcher[_AsyncFaultStore]


# =============================================================================
# §2 — builders, and the stdout capture.
# =============================================================================
def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _store(
    data: SharedInMemoryConditionalStore,
    faults: SharedInMemoryConditionalStore,
    slow_ticks: Int,
) -> _AsyncFaultStore:
    return _AsyncFaultStore(
        SharedInMemorySlowCasStore(inner=data.clone(), slow_ticks=slow_ticks),
        faults.clone(),
    )


def _ids1() -> List[String]:
    var ids = List[String]()
    ids.append(String("1"))
    return ids^


def _op(
    data: SharedInMemoryConditionalStore,
    faults: SharedInMemoryConditionalStore,
    slow_ticks: Int = 0,
) -> _Op:
    return _Op(_store(data, faults, slow_ticks), String(_KEY), _ids1(), 6)


def _stored(data: SharedInMemoryConditionalStore) raises -> Assignment:
    return Assignment.decode_binary(data.get(Path.parse(String(_KEY))))


def _endpoints() -> List[NodeEndpointSnapshot]:
    var out = List[NodeEndpointSnapshot]()
    out.append(
        NodeEndpointSnapshot(
            node_id=String("1"),
            advertised_host=String("broker-1.example.test"),
            advertised_port=Int32(9001),
        )
    )
    return out^


def _text(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1


@fieldwise_init
struct _Capture(Copyable, Movable):
    var saved: Int32
    var rd: Int32
    var wr: Int32


def _capture_begin() raises -> _Capture:
    """Point fd 1 at the write end of a fresh AF_UNIX socket pair."""
    var fds = SIMD[DType.int32, 2](-1, -1)
    # SAFETY: socketpair(2) writes two int32 into this local during the call.
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), UnsafePointer(to=fds).bitcast[UInt8]()
    )
    if rc < Int32(0):
        raise Error("test: socketpair() failed")
    var saved = external_call["dup", Int32](Int32(1))
    if saved < Int32(0):
        raise Error("test: dup(1) failed")
    _ = external_call["dup2", Int32](fds[1], Int32(1))
    return _Capture(saved, fds[0], fds[1])


def _capture_end(c: _Capture) raises -> String:
    """Restore fd 1, close every write end, and read what was printed."""
    _ = external_call["dup2", Int32](c.saved, Int32(1))
    _ = external_call["close", Int32](c.saved)
    _ = external_call["close", Int32](c.wr)
    var out = List[UInt8]()
    var buf = List[UInt8]()
    for _ in range(4096):
        buf.append(UInt8(0))
    while True:
        var n = external_call["recv", Int64](
            c.rd, buf.unsafe_ptr(), UInt64(4096), Int32(0)
        )
        if n <= Int64(0):
            break
        for i in range(Int(n)):
            out.append(buf[i])
    _ = external_call["close", Int32](c.rd)
    return _text(out)


# =============================================================================
# §3 — AsyncReassignOp.
# =============================================================================
def test_take_result_before_done_raises() raises:
    var op = _op(SharedInMemoryConditionalStore(), SharedInMemoryConditionalStore())
    var raised = String("")
    try:
        _ = op.take_result()
    except e:
        raised = String(e)
    assert_equal(raised, String("AsyncReassignOp.take_result: not done"))
    print("  test_take_result_before_done_raises: PASS")


def test_read_start_error_is_terminal() raises:
    var reactor = _new_reactor()
    var faults = SharedInMemoryConditionalStore()
    _arm(faults, String("read_start"), 0, 1, 1, _MODE_TRANSPORT)
    var op = _op(SharedInMemoryConditionalStore(), faults)
    assert_equal(op.start[NoopSink](reactor), Int64(0), "nothing to park on")
    assert_true(op.is_error(), "read error is terminal")
    assert_false(op.is_done(), "not done")
    assert_equal(
        op.err_text(), String("AsyncReassignOp read: injected transport failure")
    )
    assert_equal(op.poll[NoopSink](reactor), Int64(0), "poll after error: 0")
    assert_true(op.is_error(), "still an error")
    assert_equal(_calls(faults, String("cas_put_start")), 0, "no write")
    print("  test_read_start_error_is_terminal: PASS")


def test_read_poll_error_is_terminal() raises:
    var reactor = _new_reactor()
    var faults = SharedInMemoryConditionalStore()
    _arm(faults, String("read_poll"), 0, 1, 1, _MODE_TRANSPORT)
    var op = _op(SharedInMemoryConditionalStore(), faults, slow_ticks=1)
    assert_true(op.start[NoopSink](reactor) != Int64(0), "the read parks")
    assert_false(op.is_error() or op.is_done(), "in flight")
    assert_equal(op.poll[NoopSink](reactor), Int64(0), "error: nothing to park")
    assert_true(op.is_error(), "read_poll error is terminal")
    assert_equal(
        op.err_text(), String("AsyncReassignOp read: injected transport failure")
    )
    assert_equal(_calls(faults, String("cas_put_start")), 0, "no write")
    print("  test_read_poll_error_is_terminal: PASS")


def test_cas_start_transport_error_is_terminal() raises:
    var reactor = _new_reactor()
    var faults = SharedInMemoryConditionalStore()
    _arm(faults, String("cas_put_start"), 0, 1, 1, _MODE_TRANSPORT)
    var op = _op(SharedInMemoryConditionalStore(), faults)
    assert_equal(op.start[NoopSink](reactor), Int64(0), "finished in a burst")
    assert_true(op.is_error(), "a transport error is no lost CAS")
    assert_equal(
        op.err_text(), String("AsyncReassignOp CAS: injected transport failure")
    )
    assert_equal(_calls(faults, String("read_start")), 1, "no re-read")
    assert_equal(_calls(faults, String("cas_put_start")), 1, "no retry")
    print("  test_cas_start_transport_error_is_terminal: PASS")


def test_cas_start_lost_to_racer_retries() raises:
    """A concurrent writer creates the object first: the store's own 412 sends
    the op back to re-read the racer's body and write over it."""
    var reactor = _new_reactor()
    var data = SharedInMemoryConditionalStore()
    var faults = SharedInMemoryConditionalStore()
    _arm(faults, String("cas_put_start"), 0, 1, 1, _MODE_RACE)
    var op = _op(data, faults)
    assert_equal(op.start[NoopSink](reactor), Int64(0), "finished in a burst")
    assert_true(op.is_done(), "won on the second attempt")
    assert_equal(_calls(faults, String("read_start")), 2, "re-read once")
    assert_equal(_calls(faults, String("cas_put_start")), 2, "wrote twice")
    var a = op.take_result()
    var stored = _stored(data)
    for pid in range(6):
        assert_equal(a.owner_of(pid), String("1"), "result owner")
        assert_equal(stored.owner_of(pid), String("1"), "persisted owner")
    assert_equal(op.poll[NoopSink](reactor), Int64(0), "poll after done: 0")
    assert_true(op.is_done(), "still done")
    print("  test_cas_start_lost_to_racer_retries: PASS")


def test_retry_after_object_vanished_creates_it() raises:
    """The object is present on the first read (so the write carries its
    etag), then deleted and the write lost: the re-read finds it absent, so
    the retry must create it (no etag) rather than repeat the old etag."""
    var reactor = _new_reactor()
    var data = SharedInMemoryConditionalStore()
    _ = data.put(Path.parse(String(_KEY)), _racer_body())
    var faults = SharedInMemoryConditionalStore()
    _arm(faults, String("cas_put_start"), 0, 1, 1, _MODE_VANISH)
    var op = _op(data, faults)
    _ = op.start[NoopSink](reactor)
    assert_true(op.is_done(), "the retry created the object: " + op.err_text())
    assert_equal(_calls(faults, String("cas_put_start")), 2, "two writes")
    var stored = _stored(data)
    for pid in range(6):
        assert_equal(stored.owner_of(pid), String("1"), "persisted owner")
    print("  test_retry_after_object_vanished_creates_it: PASS")


def test_async_retry_bound_is_256_attempts() raises:
    var reactor = _new_reactor()
    var f_ok = SharedInMemoryConditionalStore()
    _arm(f_ok, String("cas_put_start"), 0, 1, 255, _MODE_412)
    var ok = _op(SharedInMemoryConditionalStore(), f_ok)
    _ = ok.start[NoopSink](reactor)
    assert_true(ok.is_done(), "won on the 256th attempt")
    assert_equal(_calls(f_ok, String("cas_put_start")), 256, "256 writes")

    var f_bad = SharedInMemoryConditionalStore()
    _arm(f_bad, String("cas_put_start"), 0, 1, 256, _MODE_412)
    var bad = _op(SharedInMemoryConditionalStore(), f_bad)
    _ = bad.start[NoopSink](reactor)
    assert_true(bad.is_error(), "256 lost writes give up")
    assert_equal(
        bad.err_text(),
        String(
            "AsyncReassignOp: CAS contention did not converge within 256"
            " attempts"
        ),
    )
    assert_equal(_calls(f_bad, String("cas_put_start")), 256, "no 257th write")
    assert_equal(_calls(f_bad, String("read_start")), 256, "no 257th read")
    print("  test_async_retry_bound_is_256_attempts: PASS")


def test_async_transport_on_last_attempt_wins() raises:
    """255 lost writes then a transport error: the transport error is
    reported, not the contention error."""
    var reactor = _new_reactor()
    var faults = SharedInMemoryConditionalStore()
    _arm(faults, String("cas_put_start"), 0, 1, 255, _MODE_412)
    _arm(faults, String("cas_put_start"), 1, 256, 256, _MODE_TRANSPORT)
    var op = _op(SharedInMemoryConditionalStore(), faults)
    _ = op.start[NoopSink](reactor)
    assert_equal(
        op.err_text(), String("AsyncReassignOp CAS: injected transport failure")
    )
    print("  test_async_transport_on_last_attempt_wins: PASS")


# =============================================================================
# §4 — BrokerHeartbeatSM.
# =============================================================================
def test_step_after_done_is_an_error() raises:
    var reactor = _new_reactor()
    var sm = _SM.one_step(json_response(Int32(200), String("{}")))
    var first = sm.step[NoopSink](reactor)
    assert_true(first.is_done(), "one step")
    assert_equal(first.take_response().status, Int32(200), "the response")
    var again = sm.step[NoopSink](reactor)
    assert_true(again.is_error(), "a second step is an error")
    assert_equal(again.err_text(), String("BrokerHeartbeatSM: step() after DONE"))
    print("  test_step_after_done_is_an_error: PASS")


def test_parkable_op_error_is_step_error_and_cache_untouched() raises:
    var reactor = _new_reactor()
    var faults = SharedInMemoryConditionalStore()
    _arm(faults, String("read_start"), 0, 1, 1, _MODE_TRANSPORT)
    var cache = ArcPointer[_CoalesceCacheState](_CoalesceCacheState())
    var sm = _SM.parkable(
        _op(SharedInMemoryConditionalStore(), faults),
        String("1"),
        _endpoints(),
        cache.copy(),
        _ids1(),
        6,
    )
    var r = sm.step[NoopSink](reactor)
    assert_true(r.is_error(), "the op's error is the step's error")
    assert_equal(
        r.err_text(), String("AsyncReassignOp read: injected transport failure")
    )
    assert_false(cache[].has_cache, "a failed reassign fills no cache")
    print("  test_parkable_op_error_is_step_error_and_cache_untouched: PASS")


def test_parkable_one_burst_traces_and_fills_cache() raises:
    var reactor = _new_reactor()
    var cache = ArcPointer[_CoalesceCacheState](_CoalesceCacheState())
    var sm = _SM.parkable(
        _op(SharedInMemoryConditionalStore(), SharedInMemoryConditionalStore()),
        String("1"),
        _endpoints(),
        cache.copy(),
        _ids1(),
        6,
        trace=True,
    )
    var cap = _capture_begin()
    var r = sm.step[NoopSink](reactor)
    var out = _capture_end(cap)
    assert_true(r.is_done(), "slow_ticks 0: done in one step")
    assert_equal(
        out, String("[coord-trace] SM.step START -> DONE/ERR (one burst)\n")
    )
    assert_true(cache[].has_cache, "the won CAS filled the cache")
    assert_equal(cache[].cached_effective_p, 6, "cache key: P")
    assert_equal(len(cache[].cached_membership), 1, "cache key: ids")
    assert_equal(cache[].cached_membership[0], String("1"), "cache key: id")
    var again = sm.step[NoopSink](reactor)
    assert_true(again.is_error(), "a finished parkable frame does not rerun")
    assert_equal(again.err_text(), String("BrokerHeartbeatSM: step() after DONE"))
    var http = r.take_response()
    assert_equal(http.status, Int32(200), "200")
    assert_equal(
        http.headers[String("content-type")], String("application/protobuf")
    )
    assert_equal(http.headers[String("content-length")], String(len(http.body)))
    var resp = decode_proto[PbHeartbeatResponse](http.body.copy())
    assert_equal(len(resp.assigned_partitions), 6, "node 1 owns all six")
    ref m = resp.broker_cluster.value()
    assert_equal(len(m.nodes), 1, "nodes from the snapshot")
    assert_equal(m.nodes[0].host, String("broker-1.example.test"), "host")
    assert_equal(m.nodes[0].port, UInt32(9001), "port")
    assert_equal(len(m.leaders), 6, "a leader per partition")
    assert_equal(m.leaders[5].leader_node_id, Int32(1), "leader parsed")
    print("  test_parkable_one_burst_traces_and_fills_cache: PASS")


def _drive_parked(trace: Bool) raises -> String:
    """Drive a parked frame (slow_ticks 2) to done, capturing stdout; return
    the captured text with each step's op_id appended as `<id>;`."""
    var reactor = _new_reactor()
    var cache = ArcPointer[_CoalesceCacheState](_CoalesceCacheState())
    var sm = _SM.parkable(
        _op(
            SharedInMemoryConditionalStore(),
            SharedInMemoryConditionalStore(),
            slow_ticks=2,
        ),
        String("1"),
        _endpoints(),
        cache.copy(),
        _ids1(),
        6,
        trace=trace,
    )
    var ids = String("")
    var cap = _capture_begin()
    var steps = 0
    var done = False
    while steps < 20 and not done:
        var r = sm.step[NoopSink](reactor)
        steps += 1
        if r.is_parked():
            ids += String(r.op_id()) + ";"
        else:
            done = r.is_done()
    var out = _capture_end(cap)
    assert_true(done, "the parked frame completes")
    assert_true(cache[].has_cache, "and fills the cache")
    return out + "|" + ids


def test_parked_frame_trace_lines() raises:
    var got = _drive_parked(True)
    var bar = got.find("|")
    var out = String(got[byte=0:bar])
    var ids = String(got[byte = bar + 1 :]).split(";")
    # Four parks: read x2, write x2; the last resume finishes.
    assert_equal(len(ids), 5, "four parks: " + got)
    var want = (
        String("[coord-trace] SM.step START -> PARK op_id=")
        + String(ids[0])
        + "\n"
    )
    for i in range(1, 4):
        want += (
            String("[coord-trace] SM.step RESUME -> RE-PARK op_id=")
            + String(ids[i])
            + "\n"
        )
    want += "[coord-trace] SM.step RESUME -> DONE/ERR\n"
    assert_equal(out, want, "the trace lines")
    var quiet = _drive_parked(False)
    assert_true(quiet.startswith("|"), "trace off prints nothing: " + quiet)
    print("  test_parked_frame_trace_lines: PASS")


# =============================================================================
# §5 — the suspendable dispatcher's make_frame.
# =============================================================================
def _disp(trace: Bool) raises -> _Disp:
    var store = ClusterAssignmentStore[_AsyncFaultStore](
        _store(
            SharedInMemoryConditionalStore(),
            SharedInMemoryConditionalStore(),
            0,
        ),
        String(_CLUSTER),
    )
    var coord = BrokerHeartbeatCoordinator[_AsyncFaultStore](
        store^, String(_CLUSTER), String(_TOPIC), 6
    )
    return _Disp(coord^, trace)


def _req(method: HttpMethod, path: String) -> HttpRequest:
    var req = HttpRequest()
    req.method = method
    req.path = path
    return req^


def _hb_req(job_id: String, node_id: Optional[String]) raises -> HttpRequest:
    var load = PbNodeLoad(UInt64(0), UInt32(0), Optional[UInt32]())
    var hb = PbSupervisorHeartbeat(
        job_id,
        PbJobPhase(PbJobPhase.JOB_PHASE_RUNNING),
        String("pod"),
        None,
        None,
        None,
        node_id,
        Optional[PbNodeLoad](load^),
        List[UInt32](),
        Optional[String](String("broker.example.test")),
        Optional[UInt32](UInt32(9092)),
    )
    var req = _req(HttpMethod.post(), String("/internal/heartbeat"))
    req.body = encode_proto[PbSupervisorHeartbeat](hb)
    return req^


def _run(
    mut d: _Disp, mut reactor: Reactor[NoopSink], var req: HttpRequest
) raises -> HttpResponse:
    var f = d.make_frame[_Rt](reactor, req^, Int64(7))
    for _ in range(20):
        var r = f.step[NoopSink](reactor)
        if r.is_done():
            return r.take_response()
        if r.is_error():
            raise Error(r.err_text())
    raise Error("test: frame did not finish")


def test_make_frame_routes_and_rejections() raises:
    var reactor = _new_reactor()
    var d = _disp(False)
    assert_false(d.trace_enabled(), "trace off")
    var a = _run(d, reactor, _req(HttpMethod.post(), String("/health")))
    assert_equal(a.status, Int32(405), "POST /health")
    var b = _run(d, reactor, _req(HttpMethod.get(), String("/internal/heartbeat")))
    assert_equal(b.status, Int32(405), "GET /internal/heartbeat")
    var c = _run(d, reactor, _req(HttpMethod.get(), String("/x")))
    assert_equal(c.status, Int32(404), "unknown path")
    var c2 = _run(d, reactor, _req(HttpMethod.post(), String("/healthz")))
    assert_equal(c2.status, Int32(404), "a longer path is no match")

    var bad = _req(HttpMethod.post(), String("/internal/heartbeat"))
    for _ in range(3):
        bad.body.append(UInt8(0xFF))
    var e = _run(d, reactor, bad^)
    assert_equal(e.status, Int32(400), "undecodable body")
    assert_true(
        _text(e.body).startswith('{"error":"bad_request","message":"'),
        _text(e.body),
    )
    var f = _run(d, reactor, _hb_req(String(_NIL), Optional[String]()))
    assert_equal(f.status, Int32(400), "no node_id")
    assert_true(_text(f.body).find("node_id required") >= 0, _text(f.body))
    var g = _run(d, reactor, _hb_req(String("job-3"), Optional[String](String("1"))))
    assert_equal(g.status, Int32(400), "node_id and job_id")
    assert_true(_text(g.body).find("cross-leg") >= 0, _text(g.body))
    var h = _run(d, reactor, _hb_req(String("job-3"), Optional[String]()))
    assert_true(
        _text(h.body).find("node_id required") >= 0,
        "node_id is checked before job_id",
    )
    assert_equal(
        d.coordinator().store_recompute_count(), 0, "no rejection reassigned"
    )
    var ok = _run(d, reactor, _hb_req(String(""), Optional[String](String("1"))))
    assert_equal(ok.status, Int32(200), "an empty job_id is served")
    assert_equal(d.coordinator().store_recompute_count(), 1, "one reassign")
    print("  test_make_frame_routes_and_rejections: PASS")


def test_make_frame_trace_lines() raises:
    var reactor = _new_reactor()
    var d = _disp(True)
    assert_true(d.trace_enabled(), "trace on")
    var cap = _capture_begin()
    var first = _run(
        d, reactor, _hb_req(String(_NIL), Optional[String](String("1")))
    )
    var second = _run(
        d, reactor, _hb_req(String(_NIL), Optional[String](String("1")))
    )
    var out = _capture_end(cap)
    assert_equal(first.status, Int32(200), "first served")
    assert_equal(second.status, Int32(200), "second served")
    assert_equal(
        out,
        String(
            "[coord-trace] make_frame: MEMBERSHIP-CHANGE node=1 effective_p=6"
            " n_live=1\n[coord-trace] SM.step START -> DONE/ERR (one burst)\n"
            "[coord-trace] make_frame: COALESCE-HIT node=1\n"
        ),
    )
    var q = _disp(False)
    var cap2 = _capture_begin()
    _ = _run(q, reactor, _hb_req(String(_NIL), Optional[String](String("1"))))
    _ = _run(q, reactor, _hb_req(String(_NIL), Optional[String](String("1"))))
    assert_equal(_capture_end(cap2), String(""), "trace off prints nothing")
    print("  test_make_frame_trace_lines: PASS")


def main() raises:
    print("test_cov_broker_coordinator_async")
    test_take_result_before_done_raises()
    test_read_start_error_is_terminal()
    test_read_poll_error_is_terminal()
    test_cas_start_transport_error_is_terminal()
    test_cas_start_lost_to_racer_retries()
    test_retry_after_object_vanished_creates_it()
    test_async_retry_bound_is_256_attempts()
    test_async_transport_on_last_attempt_wins()
    test_step_after_done_is_an_error()
    test_parkable_op_error_is_step_error_and_cache_untouched()
    test_parkable_one_burst_traces_and_fills_cache()
    test_parked_frame_trace_lines()
    test_make_frame_routes_and_rejections()
    test_make_frame_trace_lines()
    print("ALL test_cov_broker_coordinator_async tests PASS")
