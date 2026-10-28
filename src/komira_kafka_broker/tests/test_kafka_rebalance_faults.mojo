# =============================================================================
# tests/test_kafka_rebalance_faults.mojo
#   The consumer-group coordinator under store faults and hostile input, on a
#   manual clock.
#
#   The store under the coordinator is a FaultStore: a shared in-memory store
#   whose conditional writes can be made to fail a chosen number of times, in
#   three spellings (an in-tree 412, a cloud 412, a non-412 transport failure
#   that names a key holding "412"), and whose reads can fail with a 403 that
#   names a key holding "404". The failure plan is shared through an ArcPointer,
#   so the test arms it after the coordinator has taken the store.
#
#   What each test proves, and the defect it catches:
#   * state.json text: ids and protocol names holding a quote, a backslash or a
#     control character round-trip through encode and decode, and a client id
#     or protocol name written to forge "state" or "leader" does not change the
#     decoded group. A writer that does not escape fails the first two.
#   * a 403 whose key names "404" is not an absent group: join, heartbeat and
#     leave raise, and nothing is created. A substring test for "404" makes the
#     join create the group over a store that cannot be read.
#   * the state key encodes "/" and "%" in a group id as the offset store does,
#     so one group cannot name another's subtree, and an empty id is refused.
#   * a lost swap is retried, not surfaced: join (create, window close, and a
#     join on a Stable group, which still bumps the generation once), sync,
#     leave and heartbeat each finish after one injected 412. Exhausted retries
#     are an error (REBALANCE_IN_PROGRESS) for join and sync, never a success
#     for a member that was not stored.
#   * a write failure that is not a 412, whose key spells "412", "precondition"
#     or "If-Match", raises rather than retrying.
#   * heartbeat on a Stable group answers ILLEGAL_GENERATION for a generation
#     that is not the group's, older or newer.
#   * SyncGroup and LeaveGroup error codes: unknown group, unknown member, a
#     stale generation, a follower that waits out the poll cap, and a
#     non-leader's assignments being ignored.
#   * a join with an unknown non-empty member id registers it.
#
#   No test sleeps or reads a clock: the manual clock moves only by the
#   coordinator's own waits, and the poll cap is checked by counting them.
# =============================================================================

from std.memory import ArcPointer

from komira_kafka_broker.group_clock import ManualGroupClock
from komira_kafka_broker.group_coordinator import (
    GroupCoordinator,
    JoinResult,
    JOIN_POLL_MAX_ITERS,
)
from komira_kafka_broker.group_state import (
    GroupMember,
    GroupState,
    GROUP_STATE_COMPLETING,
    GROUP_STATE_PREPARING,
    GROUP_STATE_STABLE,
    decode_group_state_json,
    encode_group_state_json,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_kafka_server.wire import KafkaEncoder
from komira_kafka_server.wire.consumer_group import (
    AssignedTopicPartitions,
    CONSUMER_PROTOCOL_VERSION,
    ERROR_ILLEGAL_GENERATION,
    ERROR_REBALANCE_IN_PROGRESS,
    ERROR_UNKNOWN_MEMBER_ID,
    decode_consumer_assignment,
    encode_consumer_assignment,
)


def _check(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)


# =============================================================================
# The fault store.
# =============================================================================

# How a failing write reads.
comptime _KIND_LOST_CAS_LOCAL: Int = 0  # the in-tree stores' 412
comptime _KIND_LOST_CAS_CLOUD: Int = 1  # the cloud stores' 412
comptime _KIND_TRANSPORT: Int = 2  # a 503 that is not a lost swap


struct FaultPlan(Movable, Deinitable):
    var writes: Int  # conditional writes attempted since the last arm
    var fail_from: Int  # first write (1-based) to fail; 0 fails none
    var fail_count: Int  # how many writes fail from there; -1 fails all
    var kind: Int
    var fail_reads: Bool  # head and get raise a 403 naming the key

    def __init__(out self):
        self.writes = 0
        self.fail_from = 0
        self.fail_count = 0
        self.kind = _KIND_LOST_CAS_LOCAL
        self.fail_reads = False

    def arm(mut self, fail_from: Int, fail_count: Int, kind: Int):
        self.writes = 0
        self.fail_from = fail_from
        self.fail_count = fail_count
        self.kind = kind

    def should_fail(mut self) -> Bool:
        self.writes += 1
        if self.fail_from <= 0 or self.writes < self.fail_from:
            return False
        if self.fail_count < 0:
            return True
        return self.writes < self.fail_from + self.fail_count


def _write_error(kind: Int, verb: String, key: String) -> String:
    if kind == _KIND_LOST_CAS_LOCAL:
        return (
            String("FaultStore.") + verb
            + String(": precondition (412) — injected key=") + key
        )
    if kind == _KIND_LOST_CAS_CLOUD:
        return (
            String("StoreError[PRECONDITION] ") + verb
            + String(" s3://b/") + key + String(" status=412")
        )
    return (
        String("StoreError[TRANSPORT] ") + verb + String(" s3://b/") + key
        + String(" status=503 connection reset")
    )


struct FaultStore(CloneableConditionalWriteStore):
    var _inner: SharedInMemoryConditionalStore
    var _plan: ArcPointer[FaultPlan]

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var plan: ArcPointer[FaultPlan],
    ):
        self._inner = inner^
        self._plan = plan^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._plan.copy())

    def _read_gate(self, verb: String, path: Path) raises:
        if self._plan[].fail_reads:
            raise Error(
                String("StoreError[PERMISSION_DENIED] ") + verb
                + String(" s3://b/") + path.raw() + String(" status=403 denied")
            )

    def head(self, path: Path) raises -> ObjectMeta:
        self._read_gate(String("head"), path)
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        if self._plan[].should_fail():
            raise Error(
                _write_error(
                    self._plan[].kind, String("conditional_put"), path.raw()
                )
            )
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        if self._plan[].should_fail():
            raise Error(
                _write_error(
                    self._plan[].kind, String("compare_and_swap"), path.raw()
                )
            )
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._read_gate(String("get"), path)
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


comptime FaultCoordinator = GroupCoordinator[FaultStore, ManualGroupClock]
comptime PlainCoordinator = GroupCoordinator[
    SharedInMemoryConditionalStore, ManualGroupClock
]


struct Rig(Movable, Deinitable):
    var coord: FaultCoordinator
    var plan: ArcPointer[FaultPlan]
    var raw: SharedInMemoryConditionalStore

    def __init__(
        out self,
        var coord: FaultCoordinator,
        var plan: ArcPointer[FaultPlan],
        var raw: SharedInMemoryConditionalStore,
    ):
        self.coord = coord^
        self.plan = plan^
        self.raw = raw^


def _rig() raises -> Rig:
    var raw = SharedInMemoryConditionalStore()
    var plan = ArcPointer[FaultPlan](FaultPlan())
    var store = FaultStore(raw.clone(), plan.copy())
    return Rig(
        FaultCoordinator(
            store^, String("c"), ManualGroupClock(), String("")
        ),
        plan^,
        raw^,
    )


def _exists(rig: Rig, key: String) -> Bool:
    try:
        _ = rig.raw.head(Path.parse(key))
        return True
    except:
        return False


# =============================================================================
# Request builders.
# =============================================================================


def _sub() -> List[UInt8]:
    var enc = KafkaEncoder()
    enc.put_int16(CONSUMER_PROTOCOL_VERSION)
    enc.put_array_len(1)
    enc.put_string(String("t1"))
    enc.put_int32(Int32(-1))
    return enc.take_bytes()


def _names() -> List[String]:
    var p = List[String]()
    p.append(String("range"))
    return p^


def _blob(parts: List[Int32]) -> List[UInt8]:
    var assigned = List[AssignedTopicPartitions]()
    assigned.append(AssignedTopicPartitions(String("t1"), parts.copy()))
    return encode_consumer_assignment(assigned)


def _parts(first: Int32, last: Int32) -> List[Int32]:
    var out = List[Int32]()
    var p = first
    while p <= last:
        out.append(p)
        p += Int32(1)
    return out^


def _join(
    mut c: FaultCoordinator, group: String, member: String, client: String
) raises -> JoinResult:
    return c.join_group(group, member, client, _names(), _sub(), Int32(0))


def _sync_alone(
    mut c: FaultCoordinator, group: String, r: JoinResult
) raises -> Tuple[List[UInt8], Int16]:
    var ids = List[String]()
    ids.append(r.member_id.copy())
    var blobs = List[List[UInt8]]()
    blobs.append(_blob(_parts(Int32(0), Int32(3))))
    return c.sync_group(group, r.member_id.copy(), r.generation_id, ids, blobs)


def _state(mut c: FaultCoordinator, group: String) raises -> GroupState:
    var opt = c.load_state(group)
    if not opt:
        raise Error("FAIL: no state for group " + group)
    return opt.take()


# =============================================================================
# state.json text.
# =============================================================================


def test_state_json_roundtrips_ids_with_quotes_backslashes_and_controls() raises:
    var hostile = (
        String('q"uote\\back') + chr(10) + String("nl") + chr(9)
        + String("tab") + chr(1) + String("ctl é")
    )
    var members = List[GroupMember]()
    members.append(GroupMember(hostile.copy(), _sub(), List[UInt8](), Int32(3), Int64(9)))
    members.append(GroupMember(String("plain"), List[UInt8](), List[UInt8](), Int32(3), Int64(8)))
    var st = GroupState(
        Int32(3),
        hostile.copy(),
        String('r","state":"Stable'),
        String("consumer"),
        String("PreparingRebalance"),
        Int64(55),
        members^,
        String(""),
    )
    var back = decode_group_state_json(encode_group_state_json(st), String("e"))
    _check(back.leader_member_id == hostile, "leader survives")
    _check(back.protocol == String('r","state":"Stable'), "protocol survives")
    _check(back.state == String("PreparingRebalance"), "state is not forged")
    _check(len(back.members) == 2, "two members")
    _check(back.members[0].member_id == hostile, "member id survives")
    _check(back.members[1].member_id == String("plain"), "second member")
    _check(back.members[1].last_active_ms == Int64(8), "second member fields")
    print("PASS test_state_json_roundtrips_ids_with_quotes_backslashes_and_controls")


def test_client_id_cannot_forge_the_group_state() raises:
    var rig = _rig()
    var client = String('x","state":"Stable","leader":"evil')
    var r = _join(rig.coord, String("g"), String(""), client)
    _check(r.error_code == Int16(0), "join ok")
    _check(r.member_id == client + String("-1"), "member id minted from client")
    var st = _state(rig.coord, String("g"))
    _check(st.state == String(GROUP_STATE_COMPLETING), "state is not forged")
    _check(st.leader_member_id == r.member_id, "leader is the member")
    _check(len(st.members) == 1, "one member")
    _check(st.members[0].member_id == r.member_id, "member id intact")
    _check(
        rig.coord.heartbeat(String("g"), r.member_id.copy(), r.generation_id)
        == Int16(0),
        "the member is found again",
    )
    print("PASS test_client_id_cannot_forge_the_group_state")


def test_protocol_name_cannot_forge_the_group_state() raises:
    var rig = _rig()
    var names = List[String]()
    names.append(String('r","state":"Stable","leader":"evil'))
    var r = rig.coord.join_group(
        String("g"), String(""), String("cli"), names, _sub(), Int32(0)
    )
    var st = _state(rig.coord, String("g"))
    _check(st.state == String(GROUP_STATE_COMPLETING), "state is not forged")
    _check(st.leader_member_id == r.member_id, "leader is the member")
    _check(st.protocol == names[0], "protocol stored as offered")
    print("PASS test_protocol_name_cannot_forge_the_group_state")


# =============================================================================
# Store read errors and the state key.
# =============================================================================


def test_a_403_naming_404_is_not_an_absent_group() raises:
    var rig = _rig()
    var g = String("g404")
    # An existing group, then reads that fail with a 403 naming the key.
    var r = _join(rig.coord, g, String(""), String("cli"))
    rig.plan[].fail_reads = True
    var raised = False
    try:
        _ = _join(rig.coord, g, String(""), String("cli"))
    except:
        raised = True
    _check(raised, "join raises on an unreadable group")
    raised = False
    try:
        _ = rig.coord.heartbeat(g, r.member_id.copy(), r.generation_id)
    except:
        raised = True
    _check(raised, "heartbeat raises on an unreadable group")
    raised = False
    try:
        _ = rig.coord.leave_group(g, r.member_id.copy())
    except:
        raised = True
    _check(raised, "leave raises on an unreadable group")
    rig.plan[].fail_reads = False
    _check(len(_state(rig.coord, g).members) == 1, "the group is untouched")

    # A group never created: the first join over unreadable state raises and
    # creates nothing.
    rig.plan[].fail_reads = True
    raised = False
    try:
        _ = _join(rig.coord, String("h404"), String(""), String("cli"))
    except:
        raised = True
    _check(raised, "first join raises on an unreadable key")
    _check(
        not _exists(rig, String("c/_meta/groups/h404/state.json")),
        "nothing was created",
    )
    print("PASS test_a_403_naming_404_is_not_an_absent_group")


def test_state_key_encodes_the_group_id() raises:
    var rig = _rig()
    _ = _join(rig.coord, String("a/b"), String(""), String("cli"))
    _ = _join(rig.coord, String("p%q"), String(""), String("cli"))
    _check(
        _exists(rig, String("c/_meta/groups/a%2Fb/state.json")),
        "slash is encoded",
    )
    _check(
        _exists(rig, String("c/_meta/groups/p%25q/state.json")),
        "percent is encoded",
    )
    _check(
        not _exists(rig, String("c/_meta/groups/a/b/state.json")),
        "no nested key",
    )
    var refused = False
    try:
        _ = _join(rig.coord, String(""), String(""), String("cli"))
    except:
        refused = True
    _check(refused, "an empty group id is refused")
    _check(
        not _exists(rig, String("c/_meta/groups//state.json")),
        "no empty-id key",
    )
    print("PASS test_state_key_encodes_the_group_id")


# =============================================================================
# Lost swaps.
# =============================================================================


def test_first_join_survives_a_lost_create() raises:
    var rig = _rig()
    rig.plan[].arm(1, 1, _KIND_LOST_CAS_LOCAL)
    var r = _join(rig.coord, String("g"), String(""), String("cli"))
    _check(r.error_code == Int16(0), "join ok")
    _check(r.generation_id == Int32(1), "generation 1")
    var st = _state(rig.coord, String("g"))
    _check(len(st.members) == 1, "member stored")
    _check(st.state == String(GROUP_STATE_COMPLETING), "window closed")
    print("PASS test_first_join_survives_a_lost_create")


def test_window_close_survives_a_lost_swap() raises:
    var rig = _rig()
    # Write 1 registers the member; write 2 closes the window.
    rig.plan[].arm(2, 1, _KIND_LOST_CAS_CLOUD)
    var r = _join(rig.coord, String("g"), String(""), String("cli"))
    _check(r.error_code == Int16(0), "join ok")
    _check(r.leader_id == r.member_id, "leader named")
    _check(len(r.members) == 1, "leader gets the member list")
    _check(
        _state(rig.coord, String("g")).state == String(GROUP_STATE_COMPLETING),
        "state advanced",
    )
    print("PASS test_window_close_survives_a_lost_swap")


def test_join_on_a_stable_group_bumps_once_under_a_lost_swap() raises:
    var rig = _rig()
    var r = _join(rig.coord, String("g"), String(""), String("cli"))
    _check(_sync_alone(rig.coord, String("g"), r)[1] == Int16(0), "synced")
    _check(
        _state(rig.coord, String("g")).state == String(GROUP_STATE_STABLE),
        "stable",
    )
    rig.plan[].arm(1, 2, _KIND_LOST_CAS_LOCAL)
    var r2 = _join(rig.coord, String("g"), r.member_id.copy(), String("cli"))
    _check(r2.error_code == Int16(0), "rejoin ok")
    _check(r2.generation_id == Int32(2), "bumped once, not per retry")
    _check(_state(rig.coord, String("g")).generation_id == Int32(2), "stored once")
    print("PASS test_join_on_a_stable_group_bumps_once_under_a_lost_swap")


def test_join_whose_every_swap_is_lost_is_an_error() raises:
    var rig = _rig()
    rig.plan[].arm(1, -1, _KIND_LOST_CAS_LOCAL)
    var r = _join(rig.coord, String("g"), String(""), String("cli"))
    _check(
        r.error_code == ERROR_REBALANCE_IN_PROGRESS,
        "an unregistered member is not told success",
    )
    _check(
        not _exists(rig, String("c/_meta/groups/g/state.json")),
        "nothing stored",
    )
    print("PASS test_join_whose_every_swap_is_lost_is_an_error")


def test_window_close_whose_every_swap_is_lost_is_an_error() raises:
    var rig = _rig()
    rig.plan[].arm(2, -1, _KIND_LOST_CAS_LOCAL)
    var r = _join(rig.coord, String("g"), String(""), String("cli"))
    _check(
        r.error_code == ERROR_REBALANCE_IN_PROGRESS,
        "a round that never closed is not reported closed",
    )
    print("PASS test_window_close_whose_every_swap_is_lost_is_an_error")


def test_sync_survives_a_lost_swap_and_reports_exhaustion() raises:
    var rig = _rig()
    var r = _join(rig.coord, String("g"), String(""), String("cli"))
    rig.plan[].arm(1, 1, _KIND_LOST_CAS_CLOUD)
    var out = _sync_alone(rig.coord, String("g"), r)
    _check(out[1] == Int16(0), "sync ok after one lost swap")
    _check(len(decode_consumer_assignment(out[0])[0].partitions) == 4, "assignment")

    var rig2 = _rig()
    var r2 = _join(rig2.coord, String("g"), String(""), String("cli"))
    rig2.plan[].arm(1, -1, _KIND_LOST_CAS_LOCAL)
    var out2 = _sync_alone(rig2.coord, String("g"), r2)
    _check(out2[1] == ERROR_REBALANCE_IN_PROGRESS, "exhausted sync is an error")
    _check(
        _state(rig2.coord, String("g")).state == String(GROUP_STATE_COMPLETING),
        "never stable",
    )
    print("PASS test_sync_survives_a_lost_swap_and_reports_exhaustion")


def test_leave_survives_a_lost_swap_and_reports_exhaustion() raises:
    var rig = _rig()
    var r = _join(rig.coord, String("g"), String(""), String("cli"))
    rig.plan[].arm(1, 2, _KIND_LOST_CAS_LOCAL)
    _check(
        rig.coord.leave_group(String("g"), r.member_id.copy()) == Int16(0),
        "leave ok after lost swaps",
    )
    _check(_state(rig.coord, String("g")).generation_id == Int32(2), "bumped once")

    var rig2 = _rig()
    var r2 = _join(rig2.coord, String("g"), String(""), String("cli"))
    rig2.plan[].arm(1, -1, _KIND_LOST_CAS_LOCAL)
    _check(
        rig2.coord.leave_group(String("g"), r2.member_id.copy())
        == ERROR_REBALANCE_IN_PROGRESS,
        "exhausted leave is an error",
    )
    _check(
        len(_state(rig2.coord, String("g")).members) == 1,
        "member still stored",
    )
    print("PASS test_leave_survives_a_lost_swap_and_reports_exhaustion")


def test_heartbeat_ignores_a_lost_swap_and_raises_on_other_failures() raises:
    var rig = _rig()
    rig.coord.clock.set(Int64(1000))
    var r = _join(rig.coord, String("g"), String(""), String("cli"))
    rig.coord.clock.set(Int64(5000))
    rig.plan[].arm(1, 1, _KIND_LOST_CAS_LOCAL)
    var code = rig.coord.heartbeat(String("g"), r.member_id.copy(), r.generation_id)
    _check(code == Int16(0), "the answer is unchanged")
    _check(
        _state(rig.coord, String("g")).members[0].last_active_ms == Int64(1000),
        "the lost swap stamped nothing",
    )
    rig.plan[].arm(1, 1, _KIND_TRANSPORT)
    var raised = False
    try:
        _ = rig.coord.heartbeat(String("g"), r.member_id.copy(), r.generation_id)
    except:
        raised = True
    _check(raised, "a transport failure is raised")
    print("PASS test_heartbeat_ignores_a_lost_swap_and_raises_on_other_failures")


def test_a_write_failure_naming_412_is_not_a_lost_swap() raises:
    # Each group id spells a marker; the failure is a 503 and must surface.
    var groups = List[String]()
    groups.append(String("g412"))
    groups.append(String("precondition"))
    groups.append(String("If-Match"))
    groups.append(String("If-None-Match"))
    for i in range(len(groups)):
        var rig = _rig()
        rig.plan[].arm(1, -1, _KIND_TRANSPORT)
        var raised = False
        try:
            _ = _join(rig.coord, groups[i], String(""), String("cli"))
        except:
            raised = True
        _check(raised, "join raises for group " + groups[i])
        _check(rig.plan[].writes == 1, "no retry for group " + groups[i])
    print("PASS test_a_write_failure_naming_412_is_not_a_lost_swap")


# =============================================================================
# Error codes.
# =============================================================================


def test_heartbeat_on_a_stable_group_with_a_wrong_generation() raises:
    var rig = _rig()
    var r = _join(rig.coord, String("g"), String(""), String("cli"))
    _ = _sync_alone(rig.coord, String("g"), r)
    _check(
        rig.coord.heartbeat(String("g"), r.member_id.copy(), r.generation_id)
        == Int16(0),
        "right generation",
    )
    _check(
        rig.coord.heartbeat(String("g"), r.member_id.copy(), r.generation_id - Int32(1))
        == ERROR_ILLEGAL_GENERATION,
        "older generation",
    )
    _check(
        rig.coord.heartbeat(String("g"), r.member_id.copy(), r.generation_id + Int32(1))
        == ERROR_ILLEGAL_GENERATION,
        "newer generation",
    )
    print("PASS test_heartbeat_on_a_stable_group_with_a_wrong_generation")


def test_sync_error_codes() raises:
    var rig = _rig()
    var none = List[String]()
    var noblobs = List[List[UInt8]]()
    _check(
        rig.coord.sync_group(String("nope"), String("m"), Int32(1), none, noblobs)[1]
        == ERROR_UNKNOWN_MEMBER_ID,
        "unknown group, follower",
    )
    var ids = List[String]()
    ids.append(String("m"))
    var blobs = List[List[UInt8]]()
    blobs.append(_blob(_parts(Int32(0), Int32(0))))
    _check(
        rig.coord.sync_group(String("nope"), String("m"), Int32(1), ids, blobs)[1]
        == ERROR_UNKNOWN_MEMBER_ID,
        "unknown group, leader",
    )
    var r = _join(rig.coord, String("g"), String(""), String("cli"))
    # A stale generation from the leader.
    var ids2 = List[String]()
    ids2.append(r.member_id.copy())
    var blobs2 = List[List[UInt8]]()
    blobs2.append(_blob(_parts(Int32(0), Int32(3))))
    _check(
        rig.coord.sync_group(
            String("g"), r.member_id.copy(), r.generation_id + Int32(1), ids2, blobs2
        )[1]
        == ERROR_REBALANCE_IN_PROGRESS,
        "leader, stale generation",
    )
    # A follower's poll sees a different generation.
    _check(
        rig.coord.sync_group(
            String("g"), r.member_id.copy(), r.generation_id + Int32(1), none, noblobs
        )[1]
        == ERROR_REBALANCE_IN_PROGRESS,
        "follower, stale generation",
    )
    # A follower waiting on a leader that never syncs ends at the poll cap.
    var before = rig.coord.clock.sleep_calls
    _check(
        rig.coord.sync_group(
            String("g"), r.member_id.copy(), r.generation_id, none, noblobs
        )[1]
        == ERROR_REBALANCE_IN_PROGRESS,
        "follower, no leader sync",
    )
    _check(
        rig.coord.clock.sleep_calls - before == JOIN_POLL_MAX_ITERS,
        "the wait is capped at the poll limit",
    )
    # Stable, but the caller is not a member.
    _ = _sync_alone(rig.coord, String("g"), r)
    _check(
        rig.coord.sync_group(
            String("g"), String("ghost"), r.generation_id, none, noblobs
        )[1]
        == ERROR_UNKNOWN_MEMBER_ID,
        "stable, unknown member",
    )
    print("PASS test_sync_error_codes")


def test_leave_error_codes() raises:
    var rig = _rig()
    _check(
        rig.coord.leave_group(String("nope"), String("m")) == ERROR_UNKNOWN_MEMBER_ID,
        "unknown group",
    )
    var r = _join(rig.coord, String("g"), String(""), String("cli"))
    _check(
        rig.coord.leave_group(String("g"), String("ghost")) == ERROR_UNKNOWN_MEMBER_ID,
        "unknown member",
    )
    _check(len(_state(rig.coord, String("g")).members) == 1, "group untouched")
    _check(r.error_code == Int16(0), "joined")
    print("PASS test_leave_error_codes")


def test_only_the_leaders_assignments_are_stored() raises:
    var c = PlainCoordinator(
        SharedInMemoryConditionalStore(), String("c"), ManualGroupClock()
    )
    var a = c.join_group(
        String("g"), String(""), String("ca"), _names(), _sub(), Int32(0)
    )
    var b = c.join_group(
        String("g"), String(""), String("cb"), _names(), _sub(), Int32(0)
    )
    _check(a.member_id == String("ca-1"), "first member id")
    _check(b.member_id == String("cb-2"), "second member id")
    _check(b.leader_id == a.member_id, "the smallest id leads")
    var ids = List[String]()
    ids.append(a.member_id.copy())
    ids.append(b.member_id.copy())
    var blobs = List[List[UInt8]]()
    blobs.append(_blob(_parts(Int32(0), Int32(1))))
    blobs.append(_blob(_parts(Int32(2), Int32(3))))
    # The follower sends a complete assignment: it is not stored.
    var from_follower = c.sync_group(
        String("g"), b.member_id.copy(), b.generation_id, ids, blobs
    )
    _check(
        from_follower[1] == ERROR_REBALANCE_IN_PROGRESS,
        "a follower's assignment completes nothing",
    )
    var opt = c.load_state(String("g"))
    _check(Bool(opt), "state present")
    var st = opt.take()
    _check(st.state == String(GROUP_STATE_COMPLETING), "still awaiting the leader")
    # The leader's is.
    var from_leader = c.sync_group(
        String("g"), a.member_id.copy(), a.generation_id, ids, blobs
    )
    _check(from_leader[1] == Int16(0), "leader sync ok")
    var none = List[String]()
    var noblobs = List[List[UInt8]]()
    var mine = c.sync_group(
        String("g"), b.member_id.copy(), b.generation_id, none, noblobs
    )
    _check(mine[1] == Int16(0), "follower reads")
    var got = decode_consumer_assignment(mine[0])
    _check(got[0].partitions[0] == Int32(2), "follower holds 2 and 3")
    print("PASS test_only_the_leaders_assignments_are_stored")


def test_join_with_an_unknown_member_id_registers_it() raises:
    var rig = _rig()
    var r = _join(rig.coord, String("g"), String(""), String("cli"))
    _ = _sync_alone(rig.coord, String("g"), r)
    var r2 = _join(rig.coord, String("g"), String("expired-id"), String("cli"))
    _check(r2.error_code == Int16(0), "accepted")
    _check(r2.member_id == String("expired-id"), "kept the id it offered")
    _check(
        _state(rig.coord, String("g")).member_index(String("expired-id")) >= 0,
        "registered",
    )
    print("PASS test_join_with_an_unknown_member_id_registers_it")


def _report(name: String, e: Error, mut failed: Int):
    print("FAIL " + name + ": " + String(e))
    failed += 1


def main() raises:
    var failed = 0
    try:
        test_state_json_roundtrips_ids_with_quotes_backslashes_and_controls()
    except e:
        _report(String("state_json_roundtrips_ids"), e, failed)
    try:
        test_client_id_cannot_forge_the_group_state()
    except e:
        _report(String("client_id_cannot_forge"), e, failed)
    try:
        test_protocol_name_cannot_forge_the_group_state()
    except e:
        _report(String("protocol_name_cannot_forge"), e, failed)
    try:
        test_a_403_naming_404_is_not_an_absent_group()
    except e:
        _report(String("403_naming_404"), e, failed)
    try:
        test_state_key_encodes_the_group_id()
    except e:
        _report(String("state_key_encodes"), e, failed)
    try:
        test_first_join_survives_a_lost_create()
    except e:
        _report(String("first_join_lost_create"), e, failed)
    try:
        test_window_close_survives_a_lost_swap()
    except e:
        _report(String("window_close_lost_swap"), e, failed)
    try:
        test_join_on_a_stable_group_bumps_once_under_a_lost_swap()
    except e:
        _report(String("join_stable_bumps_once"), e, failed)
    try:
        test_join_whose_every_swap_is_lost_is_an_error()
    except e:
        _report(String("join_every_swap_lost"), e, failed)
    try:
        test_window_close_whose_every_swap_is_lost_is_an_error()
    except e:
        _report(String("close_every_swap_lost"), e, failed)
    try:
        test_sync_survives_a_lost_swap_and_reports_exhaustion()
    except e:
        _report(String("sync_lost_swap"), e, failed)
    try:
        test_leave_survives_a_lost_swap_and_reports_exhaustion()
    except e:
        _report(String("leave_lost_swap"), e, failed)
    try:
        test_heartbeat_ignores_a_lost_swap_and_raises_on_other_failures()
    except e:
        _report(String("heartbeat_lost_swap"), e, failed)
    try:
        test_a_write_failure_naming_412_is_not_a_lost_swap()
    except e:
        _report(String("write_failure_naming_412"), e, failed)
    try:
        test_heartbeat_on_a_stable_group_with_a_wrong_generation()
    except e:
        _report(String("heartbeat_wrong_generation"), e, failed)
    try:
        test_sync_error_codes()
    except e:
        _report(String("sync_error_codes"), e, failed)
    try:
        test_leave_error_codes()
    except e:
        _report(String("leave_error_codes"), e, failed)
    try:
        test_only_the_leaders_assignments_are_stored()
    except e:
        _report(String("only_leaders_assignments"), e, failed)
    try:
        test_join_with_an_unknown_member_id_registers_it()
    except e:
        _report(String("unknown_member_registers"), e, failed)
    if failed > 0:
        raise Error("test_kafka_rebalance_faults: " + String(failed) + " FAILED")
    print("test_kafka_rebalance_faults: ALL PASS")
