# =============================================================================
# komira_broker_coordinator/tests/test_cov_broker_coordinator_handler.mojo
#   The synchronous heartbeat handler (`BrokerHeartbeatCoordinator`): node-id
#   parsing, the coalesce gate's membership comparison, the effective
#   partition count, the registry refresh, the compare-and-swap retry loop
#   (a lost write, a transport error, the attempt bound) and the eager
#   prelude of the parkable serve.
# =============================================================================
#
# The store is `_FaultStore`: a `CloneableConditionalWriteStore` over a shared
# in-memory store whose conditional writes consult fault rules kept in a
# second shared in-memory store (so every clone, and the test, sees the same
# rules and call counter). A rule fails calls `lo..hi` (1-based) of a verb
# with an injected 412, an injected transport error, or a RACE: a concurrent
# writer creates the object first, so the real store answers the write with
# its own 412.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_broker import (
    Assignment,
    ClusterAssignmentStore,
    REBALANCE_INITIAL,
    assign_partitions,
)
from komira_broker_coordinator import (
    BrokerHeartbeatCoordinator,
    DEFAULT_ADVERTISED_HOST,
    DEFAULT_ADVERTISED_PORT,
)
from komira_broker_coordinator.broker_heartbeat_handler import (
    _id_lists_equal,
    _parse_node_id,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import (
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

from komira_supervisor_proto.supervisor import (
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    HeartbeatResponse as PbHeartbeatResponse,
    JobPhase as PbJobPhase,
)
from komira_broker_proto.broker import NodeLoad as PbNodeLoad


# =============================================================================
# §1 — the fault-injecting store.
# =============================================================================
comptime _MODE_412 = 1
comptime _MODE_TRANSPORT = 2
comptime _MODE_RACE = 3
comptime _TOPIC = "example-data"
comptime _CLUSTER = "cl-cov"


def _fault_msg(mode: Int) -> String:
    if mode == _MODE_412:
        return String("HTTP 412 precondition failed (injected)")
    return String('injected "transport"\nfailure')


def _mk(name: String) raises -> Path:
    return Path.parse(String("faults/") + name)


def _u16(b: List[UInt8], at: Int) -> Int:
    return Int(b[at]) + 256 * Int(b[at + 1])


def _calls(m: SharedInMemoryConditionalStore, verb: String) raises -> Int:
    """How many times `verb` was called (0 when never)."""
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
    """Fail calls `lo..hi` (1-based, inclusive) of `verb` with `mode`."""
    var spec = List[UInt8]()
    spec.append(UInt8(lo & 0xFF))
    spec.append(UInt8((lo >> 8) & 0xFF))
    spec.append(UInt8(hi & 0xFF))
    spec.append(UInt8((hi >> 8) & 0xFF))
    spec.append(UInt8(mode))
    _ = m.put(_mk(String("rule/") + verb + String("/") + String(rule)), spec)


def _next_mode(m: SharedInMemoryConditionalStore, verb: String) raises -> Int:
    """Count one call of `verb`; the mode of the first rule whose window
    holds it, or -1."""
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
    """A valid assignment a concurrent coordinator wrote: node 9 owns all."""
    var ids = List[String]()
    ids.append(String("9"))
    return assign_partitions(
        ids^, 6, Optional[Assignment](), REBALANCE_INITIAL
    ).encode_binary()


struct _FaultStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: SharedInMemoryConditionalStore
    var _m: SharedInMemoryConditionalStore

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var markers: SharedInMemoryConditionalStore,
    ):
        self._inner = inner^
        self._m = markers^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._m.clone())

    def _write_fault(self, path: Path) raises:
        var mode = _next_mode(self._m, String("put"))
        if mode == _MODE_412 or mode == _MODE_TRANSPORT:
            raise Error(_fault_msg(mode))
        if mode == _MODE_RACE:
            _ = self._inner.put(path, _racer_body())

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._write_fault(path)
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._write_fault(path)
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


# =============================================================================
# §2 — builders.
# =============================================================================
@fieldwise_init
struct _Rig(Movable):
    var coord: BrokerHeartbeatCoordinator[_FaultStore]
    var data: SharedInMemoryConditionalStore
    var faults: SharedInMemoryConditionalStore


def _rig(p: Int = 6, stale_us: Int64 = Int64(15_000_000)) raises -> _Rig:
    var data = SharedInMemoryConditionalStore()
    var faults = SharedInMemoryConditionalStore()
    var store = ClusterAssignmentStore[_FaultStore](
        _FaultStore(data.clone(), faults.clone()), String(_CLUSTER)
    )
    var coord = BrokerHeartbeatCoordinator[_FaultStore](
        store^, String(_CLUSTER), String(_TOPIC), p, stale_threshold_us=stale_us
    )
    return _Rig(coord^, data^, faults^)


def _hb(
    node_id: String,
    reported_total: Optional[UInt32] = None,
    host: Optional[String] = None,
    port: Optional[UInt32] = None,
    var owned: List[UInt32] = List[UInt32](),
) -> PbSupervisorHeartbeat:
    var load = PbNodeLoad(UInt64(5), UInt32(len(owned)), reported_total)
    return PbSupervisorHeartbeat(
        String("00000000-0000-0000-0000-000000000000"),
        PbJobPhase(PbJobPhase.JOB_PHASE_RUNNING),
        String("broker-node-") + node_id,
        None,
        None,
        None,
        Optional[String](String(node_id)),
        Optional[PbNodeLoad](load^),
        owned^,
        host,
        port,
    )


def _hb_without_node() -> PbSupervisorHeartbeat:
    return PbSupervisorHeartbeat(
        String("00000000-0000-0000-0000-000000000000"),
        PbJobPhase(PbJobPhase.JOB_PHASE_RUNNING),
        String("job-pod"),
        None,
        None,
        None,
        Optional[String](),
        Optional[PbNodeLoad](),
        List[UInt32](),
        Optional[String](),
        Optional[UInt32](),
    )


def _stored(data: SharedInMemoryConditionalStore) raises -> Assignment:
    var key = String(_CLUSTER) + "/_meta/cluster/" + _TOPIC + "/assignment.bin"
    return Assignment.decode_binary(data.get(Path.parse(key)))


def _leader_ids(resp: PbHeartbeatResponse) -> List[Int32]:
    var out = List[Int32]()
    ref m = resp.broker_cluster.value()
    for i in range(len(m.leaders)):
        out.append(m.leaders[i].leader_node_id)
    return out^


# =============================================================================
# §3 — node-id parsing and the membership comparison (pure functions).
# =============================================================================
def test_parse_node_id_table() raises:
    """Digits parse; empty, a lone '-', and any byte outside '0'..'9' (the
    neighbours '/' and ':' included) give -1. A signed id ("-12") is not
    pinned: komira-ai/komira#1503 asks what a negative id should give."""
    assert_equal(_parse_node_id(String("")), Int32(-1), "empty")
    assert_equal(_parse_node_id(String("-")), Int32(-1), "lone minus")
    assert_equal(_parse_node_id(String("0")), Int32(0), "zero (lower bound)")
    assert_equal(_parse_node_id(String("9")), Int32(9), "nine (upper bound)")
    assert_equal(_parse_node_id(String("42")), Int32(42), "two digits")
    assert_equal(_parse_node_id(String("907")), Int32(907), "three digits")
    assert_equal(_parse_node_id(String("/")), Int32(-1), "'/' is below '0'")
    assert_equal(_parse_node_id(String(":")), Int32(-1), "':' is above '9'")
    assert_equal(_parse_node_id(String("1/")), Int32(-1), "trailing '/'")
    assert_equal(_parse_node_id(String("1:")), Int32(-1), "trailing ':'")
    assert_equal(_parse_node_id(String("a1")), Int32(-1), "leading letter")
    assert_equal(_parse_node_id(String("--1")), Int32(-1), "double minus")
    assert_equal(_parse_node_id(String("+1")), Int32(-1), "plus sign")
    assert_equal(_parse_node_id(String("1-")), Int32(-1), "minus not first")
    assert_equal(
        _parse_node_id(String("2147483647")), Int32(2147483647), "Int32 max"
    )
    print("  test_parse_node_id_table: PASS")


def _strs(a: String, b: String = String(""), n: Int = 1) -> List[String]:
    var out = List[String]()
    out.append(a)
    if n > 1:
        out.append(b)
    return out^


def test_id_lists_equal() raises:
    """Equal only with the same length and the same element at each index."""
    assert_true(_id_lists_equal(List[String](), List[String]()), "both empty")
    assert_true(
        _id_lists_equal(_strs("a", "b", 2), _strs("a", "b", 2)), "same pair"
    )
    assert_false(
        _id_lists_equal(_strs("a"), List[String]()), "longer vs empty"
    )
    assert_false(
        _id_lists_equal(_strs("a"), _strs("a", "b", 2)), "prefix is not equal"
    )
    assert_false(
        _id_lists_equal(_strs("a", "b", 2), _strs("a", "c", 2)),
        "last element differs",
    )
    assert_false(
        _id_lists_equal(_strs("x", "b", 2), _strs("a", "b", 2)),
        "first element differs",
    )
    assert_false(
        _id_lists_equal(_strs("a", "b", 2), _strs("b", "a", 2)), "order"
    )
    print("  test_id_lists_equal: PASS")


# =============================================================================
# §4 — the coalesce gate and the registry.
# =============================================================================
def test_same_size_membership_swap_recomputes() raises:
    """Node 1 goes stale in the same heartbeat node 3 joins: the live set has
    the same size but different ids, so the cached assignment is not reused
    and node 1 leads no partition afterwards."""
    var r = _rig(6, Int64(15_000_000))
    var t0 = Int64(1_000_000_000)
    _ = r.coord.handle_broker_heartbeat(_hb(String("1")), t0)
    _ = r.coord.handle_broker_heartbeat(_hb(String("2")), t0 + 10_000_000)
    assert_equal(r.coord.store_recompute_count(), 2, "two joins, two passes")
    # A steady heartbeat of node 2 inside the window is a coalesce hit.
    _ = r.coord.handle_broker_heartbeat(_hb(String("2")), t0 + 12_000_000)
    assert_equal(r.coord.store_recompute_count(), 2, "steady: no pass")

    var resp = r.coord.handle_broker_heartbeat(_hb(String("3")), t0 + 20_000_000)
    assert_equal(r.coord.store_recompute_count(), 3, "swap {1,2}->{2,3}: pass")
    assert_equal(resp.cluster.value().node_count, UInt32(2), "two live nodes")
    ref nodes = resp.broker_cluster.value().nodes
    assert_equal(len(nodes), 2, "the routing map lists the live nodes only")
    assert_equal(nodes[0].node_id, Int32(2), "node 2 kept")
    assert_equal(nodes[1].node_id, Int32(3), "node 3 joined")
    var leaders = _leader_ids(resp)
    assert_equal(len(leaders), 6, "one leader per partition")
    var stored = _stored(r.data)
    ref m = resp.broker_cluster.value()
    for i in range(6):
        assert_true(
            leaders[i] == Int32(2) or leaders[i] == Int32(3),
            "partition " + String(i) + " led by a live node",
        )
        assert_equal(
            m.leaders[i].partition_id, UInt32(i), "leader " + String(i) + " pid"
        )
        assert_equal(
            String(leaders[i]), stored.owner_of(i), "leader is the stored owner"
        )
    assert_equal(len(resp.assigned_partitions), 3, "node 3 gets half")
    # One lease generation per assigned pid, equal to the persisted one.
    assert_equal(
        len(resp.assigned_generations), len(resp.assigned_partitions), "gens"
    )
    for i in range(len(resp.assigned_partitions)):
        var pid = Int(resp.assigned_partitions[i])
        assert_equal(stored.owner_of(pid), String("3"), "node 3 owns it")
        assert_equal(
            resp.assigned_generations[i],
            stored.generation_of(pid),
            "generation of pid " + String(pid),
        )
        assert_true(
            resp.assigned_generations[i] >= Int64(2),
            "a pid node 3 took over is past generation 1",
        )
    print("  test_same_size_membership_swap_recomputes: PASS")


def test_reported_partition_total_grows_p() raises:
    """A reported live partition total equal to the configured count changes
    nothing; a larger one is a membership change that grows P."""
    var r = _rig(6)
    var t = Int64(2_000_000_000)
    var a = r.coord.handle_broker_heartbeat(
        _hb(String("1"), Optional[UInt32](UInt32(6))), t
    )
    assert_equal(a.cluster.value().total_partitions, UInt32(6), "P = 6")
    _ = r.coord.handle_broker_heartbeat(
        _hb(String("1"), Optional[UInt32](UInt32(6))), t + 1
    )
    assert_equal(r.coord.store_recompute_count(), 1, "same P: coalesce hit")

    var b = r.coord.handle_broker_heartbeat(
        _hb(String("1"), Optional[UInt32](UInt32(9))), t + 2
    )
    assert_equal(r.coord.store_recompute_count(), 2, "P 6 -> 9 recomputes")
    assert_equal(b.cluster.value().total_partitions, UInt32(9), "P = 9")
    assert_equal(len(b.assigned_partitions), 9, "the lone node gets all 9")
    assert_equal(len(_leader_ids(b)), 9, "nine leaders")
    assert_equal(_stored(r.data).num_partitions, 9, "persisted with P = 9")
    print("  test_reported_partition_total_grows_p: PASS")


def test_stale_cutoff_is_inclusive() raises:
    """A node whose last heartbeat is exactly `threshold` old is live (kept
    by the prune, counted, and its reported P counts); one microsecond later
    it is stale and leaves the routing map."""
    var r = _rig(6, Int64(15_000_000))
    var t0 = Int64(7_000_000_000)
    _ = r.coord.handle_broker_heartbeat(
        _hb(String("1"), Optional[UInt32](UInt32(9))), t0
    )
    var at = r.coord.handle_broker_heartbeat(_hb(String("2")), t0 + 15_000_000)
    assert_equal(at.cluster.value().node_count, UInt32(2), "1 live at cutoff")
    assert_equal(at.cluster.value().total_partitions, UInt32(9), "its P counts")
    assert_equal(r.coord.live_node_count(t0 + 15_000_000), 2, "counted live")
    assert_equal(r.coord.live_node_count(t0 + 15_000_001), 1, "then stale")
    # Node 2 now reports P = 9 itself, so P does not depend on node 1.
    var past = r.coord.handle_broker_heartbeat(
        _hb(String("2"), Optional[UInt32](UInt32(9))), t0 + 15_000_001
    )
    assert_equal(past.cluster.value().node_count, UInt32(1), "1 pruned")
    assert_equal(len(past.assigned_partitions), 9, "node 2 owns all nine")
    assert_equal(len(past.broker_cluster.value().nodes), 1, "map pruned")
    print("  test_stale_cutoff_is_inclusive: PASS")


def test_reregister_refreshes_fields() raises:
    """A second heartbeat of a known node refreshes its liveness clock and its
    advertised endpoint; an omitted endpoint takes the defaults."""
    var r = _rig(4, Int64(15_000_000))
    var t0 = Int64(3_000_000_000)
    var first = r.coord.handle_broker_heartbeat(_hb(String("5")), t0)
    ref n0 = first.broker_cluster.value().nodes[0]
    assert_equal(n0.host, DEFAULT_ADVERTISED_HOST, "default host")
    assert_equal(n0.port, UInt32(Int(DEFAULT_ADVERTISED_PORT)), "default port")

    var second = r.coord.handle_broker_heartbeat(
        _hb(
            String("5"),
            host=Optional[String](String("broker-5.example.test")),
            port=Optional[UInt32](UInt32(19093)),
        ),
        t0 + 10_000_000,
    )
    ref n1 = second.broker_cluster.value().nodes[0]
    assert_equal(n1.host, String("broker-5.example.test"), "host refreshed")
    assert_equal(n1.port, UInt32(19093), "port refreshed")
    assert_equal(len(second.broker_cluster.value().nodes), 1, "no duplicate")

    # 20 s after the FIRST heartbeat but 10 s after the second: live only if
    # the second heartbeat refreshed the clock.
    _ = r.coord.handle_broker_heartbeat(_hb(String("5")), t0 + 20_000_000)
    assert_equal(r.coord.store_recompute_count(), 1, "still one member")
    assert_equal(r.coord.live_node_count(t0 + 20_000_000), 1, "node 5 live")
    print("  test_reregister_refreshes_fields: PASS")


# =============================================================================
# §5 — the compare-and-swap retry loop of `reassign`.
# =============================================================================
def test_lost_cas_to_racer_rereads_and_retries() raises:
    """A concurrent writer creates the object between the read and the write:
    the store's own 412 sends the loop back to re-read the racer's body and
    write over it with If-Match. The won write refreshes the cache, so the
    next steady heartbeat writes nothing."""
    var r = _rig(6)
    _arm(r.faults, String("put"), 0, 1, 1, _MODE_RACE)
    var t = Int64(4_000_000_000)
    var resp = r.coord.handle_broker_heartbeat(_hb(String("1")), t)
    assert_equal(_calls(r.faults, String("put")), 2, "lost once, then won")
    assert_equal(len(resp.assigned_partitions), 6, "node 1 owns all six")
    var stored = _stored(r.data)
    for pid in range(6):
        assert_equal(stored.owner_of(pid), String("1"), "persisted owner")
    assert_equal(r.coord.store_recompute_count(), 1, "one recompute")
    _ = r.coord.handle_broker_heartbeat(_hb(String("1")), t + 1)
    assert_equal(_calls(r.faults, String("put")), 2, "steady: no write")
    print("  test_lost_cas_to_racer_rereads_and_retries: PASS")


def test_transport_error_propagates_without_retry() raises:
    """A write error that is no precondition failure is raised at once (one
    write), and leaves the cache empty: the next heartbeat recomputes."""
    var r = _rig(6)
    _arm(r.faults, String("put"), 0, 1, 1, _MODE_TRANSPORT)
    var t = Int64(5_000_000_000)
    var raised = String("")
    try:
        _ = r.coord.handle_broker_heartbeat(_hb(String("1")), t)
    except e:
        raised = String(e)
    assert_equal(raised, _fault_msg(_MODE_TRANSPORT), "the store's error")
    assert_equal(_calls(r.faults, String("put")), 1, "no retry")
    _ = r.coord.handle_broker_heartbeat(_hb(String("1")), t + 1)
    assert_equal(r.coord.store_recompute_count(), 2, "cache was not filled")
    assert_equal(_calls(r.faults, String("put")), 2, "second heartbeat wrote")
    print("  test_transport_error_propagates_without_retry: PASS")


def test_retry_bound_is_256_attempts() raises:
    """255 lost writes then a win succeed; 256 lost writes raise the
    contention error after exactly 256 writes."""
    var ok = _rig(6)
    _arm(ok.faults, String("put"), 0, 1, 255, _MODE_412)
    var resp = ok.coord.handle_broker_heartbeat(_hb(String("1")), Int64(1))
    assert_equal(_calls(ok.faults, String("put")), 256, "won on the 256th")
    assert_equal(len(resp.assigned_partitions), 6, "assigned after retries")

    var bad = _rig(6)
    _arm(bad.faults, String("put"), 0, 1, 256, _MODE_412)
    var raised = String("")
    try:
        _ = bad.coord.reassign(Int64(1))
    except e:
        raised = String(e)
    assert_equal(
        raised,
        String(
            "BrokerHeartbeatCoordinator.reassign: CAS contention did not"
            " converge within 256 attempts (topic=example-data)"
        ),
        "the contention error",
    )
    assert_equal(_calls(bad.faults, String("put")), 256, "256 writes, no more")
    print("  test_retry_bound_is_256_attempts: PASS")


def test_transport_error_on_last_attempt_wins_over_contention() raises:
    """255 lost writes then a transport error: the transport error is what
    is raised, not the contention error."""
    var r = _rig(6)
    _arm(r.faults, String("put"), 0, 1, 255, _MODE_412)
    _arm(r.faults, String("put"), 1, 256, 256, _MODE_TRANSPORT)
    var raised = String("")
    try:
        _ = r.coord.reassign(Int64(1))
    except e:
        raised = String(e)
    assert_equal(raised, _fault_msg(_MODE_TRANSPORT), "transport reported")
    print("  test_transport_error_on_last_attempt_wins_over_contention: PASS")


# =============================================================================
# §6 — the eager prelude of the parkable serve, and the accessors.
# =============================================================================
def test_prepare_async_heartbeat() raises:
    """No node_id raises; a first heartbeat is a parked prelude carrying the
    pure-pass inputs (the reported P included) and bumps the recompute
    count; once the shared cache is filled the prelude is a cached hit."""
    var r = _rig(6)
    var raised = String("")
    try:
        _ = r.coord.prepare_async_heartbeat(_hb_without_node(), Int64(1))
    except e:
        raised = String(e)
    assert_true(raised.find("node_id absent") >= 0, "absent node_id raises")

    var owned = List[UInt32]()
    owned.append(UInt32(0))
    owned.append(UInt32(1))
    var t = Int64(6_000_000_000)
    var p = r.coord.prepare_async_heartbeat(
        _hb(
            String("7"),
            Optional[UInt32](UInt32(8)),
            Optional[String](String("broker-7.example.test")),
            Optional[UInt32](UInt32(9097)),
            owned^,
        ),
        t,
    )
    assert_true(p.parked, "membership change parks")
    assert_equal(p.node_id, String("7"), "node id carried")
    assert_equal(p.effective_p, 8, "reported P carried")
    assert_equal(len(p.sorted_ids), 1, "one live id")
    assert_equal(p.sorted_ids[0], String("7"), "the live id")
    assert_false(Bool(p.cached_assignment), "no cached assignment")
    assert_equal(len(p.endpoints), 1, "one endpoint")
    assert_equal(
        p.endpoints[0].advertised_host, String("broker-7.example.test")
    )
    assert_equal(p.endpoints[0].advertised_port, Int32(9097))
    assert_equal(r.coord.store_recompute_count(), 1, "parked prelude counts")

    # The synchronous reassign fills the same (shared) cache.
    _ = r.coord.reassign(t)
    var hit = r.coord.prepare_async_heartbeat(
        _hb(String("7"), Optional[UInt32](UInt32(8))), t + 1
    )
    assert_false(hit.parked, "same membership: cached hit")
    assert_equal(hit.cached_assignment.value().num_partitions, 8, "cached P")
    assert_equal(hit.effective_p, 0, "a hit carries no pass inputs")
    assert_equal(len(hit.sorted_ids), 0, "a hit carries no ids")
    assert_equal(len(hit.endpoints), 1, "endpoints still carried")
    assert_equal(r.coord.store_recompute_count(), 2, "reassign counted, hit not")
    print("  test_prepare_async_heartbeat: PASS")


def test_store_accessors() raises:
    var r = _rig(6)
    var key = String(_CLUSTER) + "/_meta/cluster/" + _TOPIC + "/assignment.bin"
    assert_equal(r.coord.store_mut().key_for(String(_TOPIC)), key, "store key")
    assert_equal(r.coord.assignment_key(), key, "assignment key")
    assert_equal(r.coord.cluster(), String(_CLUSTER), "cluster")
    assert_equal(r.coord.topic(), String(_TOPIC), "topic")
    assert_equal(r.coord.num_partitions(), 6, "configured P")
    print("  test_store_accessors: PASS")


def main() raises:
    print("test_cov_broker_coordinator_handler")
    test_parse_node_id_table()
    test_id_lists_equal()
    test_same_size_membership_swap_recomputes()
    test_reported_partition_total_grows_p()
    test_reregister_refreshes_fields()
    test_stale_cutoff_is_inclusive()
    test_lost_cas_to_racer_rereads_and_retries()
    test_transport_error_propagates_without_retry()
    test_retry_bound_is_256_attempts()
    test_transport_error_on_last_attempt_wins_over_contention()
    test_prepare_async_heartbeat()
    test_store_accessors()
    print("ALL test_cov_broker_coordinator_handler tests PASS")
