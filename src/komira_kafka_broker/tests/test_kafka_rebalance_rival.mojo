# =============================================================================
# tests/test_kafka_rebalance_rival.mojo
#   A lost swap makes the coordinator re-read the stored group and decide
#   again; a rival write that lands first must survive.
#
#   The store is a RivalStore: the chosen conditional write does not land.
#   Before it fails with a 412, a rival coordinator's write lands through the
#   raw store: a member joining (opening a round on a Stable group, or joining
#   the open one), or a member's liveness stamp. The test then asserts what
#   only a retry that re-read the stored group and decided again can produce.
#
#   What each test proves, and the defect it catches:
#   * join, registering: a rival opens generation 2 first. The retry joins that
#     round at generation 2 (no second bump), and the rival is still a member.
#     A retry that replays its first decision bumps again or overwrites the
#     rival, or never lands.
#   * join, closing the window: a rival joins the round before the close. The
#     retry closes the round with the rival kept, and the leader's member list
#     names it.
#   * sync (leader): a rival stamps a member's liveness first. The retry stores
#     the assignments over the stamped object, and the stamp survives.
#   * sync (leader): a rival member leaves first (the generation moves). The
#     retry sees the new generation and answers REBALANCE_IN_PROGRESS; the
#     group is not moved to Stable and the leaver is gone.
#   * leave: a rival joins before the leave lands. The retry removes the leaver
#     from the group that holds the rival: the rival is kept, the generation
#     moves once.
#
#   Heartbeat has no retry loop (a lost swap is ignored), so it has no test
#   here; the faults test covers it.
#
#   No sleep and no clock reads: the manual clock moves only by the
#   coordinator's own waits.
# =============================================================================

from std.memory import ArcPointer

from komira_kafka_broker.group_clock import ManualGroupClock
from komira_kafka_broker.group_coordinator import (
    GroupCoordinator,
    JoinResult,
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
    ERROR_REBALANCE_IN_PROGRESS,
    encode_consumer_assignment,
)


def _check(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)


comptime _RIVAL_OPENS_ROUND = 1  # a join on a Stable group: gen + 1, Preparing
comptime _RIVAL_JOINS_ROUND = 2  # a join into the open round, same generation
comptime _RIVAL_STAMPS = 3  # a member's last_active becomes 777
comptime _RIVAL_LEAVES = 4  # the member "cli-2" leaves: gen + 1, Preparing

comptime _STAMP = Int64(777)


struct RivalPlan(Movable, Deinitable):
    var writes: Int  # conditional writes attempted since the last arm
    var fire_on: Int  # the write (1-based) the rival beats; 0 beats none
    var kind: Int
    var fired: Bool

    def __init__(out self):
        self.writes = 0
        self.fire_on = 0
        self.kind = 0
        self.fired = False

    def arm(mut self, fire_on: Int, kind: Int):
        self.writes = 0
        self.fire_on = fire_on
        self.kind = kind
        self.fired = False


def _rival_write(inner: SharedInMemoryConditionalStore, path: Path, kind: Int) raises:
    """The rival's write: read the stored group, change it, swap it back."""
    var meta = inner.head(path)
    var st = decode_group_state_json(inner.get(path), meta.etag.copy())
    if kind == _RIVAL_OPENS_ROUND:
        st.generation_id = st.generation_id + Int32(1)
        st.state = String(GROUP_STATE_PREPARING)
        st.rebalance_deadline_ms = Int64(0)
        st.members.append(
            GroupMember(
                String("rival"), List[UInt8](), List[UInt8](),
                st.generation_id, Int64(0),
            )
        )
    elif kind == _RIVAL_JOINS_ROUND:
        st.members.append(
            GroupMember(
                String("rival"), List[UInt8](), List[UInt8](),
                st.generation_id, Int64(0),
            )
        )
    elif kind == _RIVAL_STAMPS:
        for i in range(len(st.members)):
            st.members[i].last_active_ms = _STAMP
    else:
        var kept = List[GroupMember]()
        for i in range(len(st.members)):
            if st.members[i].member_id != String("cli-2"):
                kept.append(st.members[i].copy())
        st.members = kept^
        st.generation_id = st.generation_id + Int32(1)
        st.state = String(GROUP_STATE_PREPARING)
    _ = inner.compare_and_swap(path, encode_group_state_json(st), meta.etag)


struct RivalStore(CloneableConditionalWriteStore):
    var _inner: SharedInMemoryConditionalStore
    var _plan: ArcPointer[RivalPlan]

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var plan: ArcPointer[RivalPlan],
    ):
        self._inner = inner^
        self._plan = plan^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._plan.copy())

    def _beaten(self, path: Path) raises -> Bool:
        self._plan[].writes += 1
        if self._plan[].fire_on <= 0 or self._plan[].writes != self._plan[].fire_on:
            return False
        self._plan[].fired = True
        _rival_write(self._inner, path, self._plan[].kind)
        return True

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        if self._beaten(path):
            raise Error("RivalStore.conditional_put: precondition (412)")
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        if self._beaten(path):
            raise Error("RivalStore.compare_and_swap: precondition (412)")
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


comptime RivalCoordinator = GroupCoordinator[RivalStore, ManualGroupClock]


struct Rig(Movable, Deinitable):
    var coord: RivalCoordinator
    var plan: ArcPointer[RivalPlan]

    def __init__(
        out self,
        var coord: RivalCoordinator,
        var plan: ArcPointer[RivalPlan],
    ):
        self.coord = coord^
        self.plan = plan^


def _rig() raises -> Rig:
    var raw = SharedInMemoryConditionalStore()
    var plan = ArcPointer[RivalPlan](RivalPlan())
    var store = RivalStore(raw^, plan.copy())
    return Rig(
        RivalCoordinator(store^, String("c"), ManualGroupClock(), String("")),
        plan^,
    )


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


def _join(
    mut c: RivalCoordinator, member: String, client: String
) raises -> JoinResult:
    return c.join_group(String("g"), member, client, _names(), _sub(), Int32(0))


def _blob(partition: Int32) -> List[UInt8]:
    var assigned = List[AssignedTopicPartitions]()
    var parts = List[Int32]()
    parts.append(partition)
    assigned.append(AssignedTopicPartitions(String("t1"), parts^))
    return encode_consumer_assignment(assigned)


def _sync(
    mut c: RivalCoordinator, member: String, gen: Int32, ids: List[String]
) raises -> Tuple[List[UInt8], Int16]:
    var blobs = List[List[UInt8]]()
    for i in range(len(ids)):
        blobs.append(_blob(Int32(i)))
    return c.sync_group(String("g"), member, gen, ids, blobs)


def _state(mut c: RivalCoordinator) raises -> GroupState:
    var opt = c.load_state(String("g"))
    if not opt:
        raise Error("FAIL: no state for the group")
    return opt.take()


def _has(st: GroupState, member: String) -> Bool:
    return st.member_index(member) >= 0


def _stable_group_of_one(mut rig: Rig) raises -> JoinResult:
    var r = _join(rig.coord, String(""), String("cli"))
    var ids = List[String]()
    ids.append(r.member_id.copy())
    _check(_sync(rig.coord, r.member_id.copy(), r.generation_id, ids)[1] == Int16(0), "synced")
    _check(
        _state(rig.coord).state == String(GROUP_STATE_STABLE), "group is stable"
    )
    return r^


def _round_of_two(mut rig: Rig) raises -> JoinResult:
    """Members cli-1 (leader) and cli-2 in one CompletingRebalance round at
    generation 1. Returns cli-1's join result."""
    var a = _join(rig.coord, String(""), String("cli"))
    var b = _join(rig.coord, String(""), String("cli"))
    var st = _state(rig.coord)
    _check(a.member_id == String("cli-1"), "first member id")
    _check(b.member_id == String("cli-2"), "second member id")
    _check(len(st.members) == 2, "two members")
    _check(st.generation_id == Int32(1), "generation 1")
    _check(st.state == String(GROUP_STATE_COMPLETING), "completing")
    return a^


def test_join_registering_joins_the_round_a_rival_opened() raises:
    var rig = _rig()
    _ = _stable_group_of_one(rig)
    rig.plan[].arm(1, _RIVAL_OPENS_ROUND)
    var r = _join(rig.coord, String(""), String("late"))
    _check(rig.plan[].fired, "the rival landed first")
    _check(r.error_code == Int16(0), "join ok")
    _check(r.generation_id == Int32(2), "joined the rival's generation")
    var st = _state(rig.coord)
    _check(st.generation_id == Int32(2), "bumped once, not twice")
    _check(_has(st, String("rival")), "the rival is kept")
    _check(_has(st, r.member_id), "the joiner is stored")
    _check(len(st.members) == 3, "incumbent, rival and joiner")
    print("PASS test_join_registering_joins_the_round_a_rival_opened")


def test_join_close_keeps_a_member_that_joined_before_it() raises:
    var rig = _rig()
    # Write 1 registers the member, write 2 closes the window.
    rig.plan[].arm(2, _RIVAL_JOINS_ROUND)
    var r = _join(rig.coord, String(""), String("cli"))
    _check(rig.plan[].fired, "the rival landed first")
    _check(r.error_code == Int16(0), "join ok")
    _check(r.generation_id == Int32(1), "generation 1")
    var st = _state(rig.coord)
    _check(st.state == String(GROUP_STATE_COMPLETING), "round closed")
    _check(_has(st, String("rival")), "the rival is kept")
    _check(len(st.members) == 2, "joiner and rival")
    _check(len(r.members) == 2, "the leader's list names the rival")
    print("PASS test_join_close_keeps_a_member_that_joined_before_it")


def test_sync_stores_over_a_rivals_stamp_and_keeps_it() raises:
    var rig = _rig()
    var a = _round_of_two(rig)
    rig.plan[].arm(1, _RIVAL_STAMPS)
    var ids = List[String]()
    ids.append(String("cli-1"))
    ids.append(String("cli-2"))
    var out = _sync(rig.coord, a.member_id.copy(), a.generation_id, ids)
    _check(rig.plan[].fired, "the rival landed first")
    _check(out[1] == Int16(0), "sync ok")
    var st = _state(rig.coord)
    _check(st.state == String(GROUP_STATE_STABLE), "stable")
    _check(st.members[0].last_active_ms == _STAMP, "the stamp survives")
    _check(st.members[1].last_active_ms == _STAMP, "the stamp survives")
    _check(len(st.members[0].assignment) > 0, "assignment stored")
    _check(len(st.members[1].assignment) > 0, "assignment stored")
    print("PASS test_sync_stores_over_a_rivals_stamp_and_keeps_it")


def test_sync_sees_a_rival_leave_and_does_not_go_stable() raises:
    var rig = _rig()
    var a = _round_of_two(rig)
    rig.plan[].arm(1, _RIVAL_LEAVES)
    var ids = List[String]()
    ids.append(String("cli-1"))
    ids.append(String("cli-2"))
    var out = _sync(rig.coord, a.member_id.copy(), a.generation_id, ids)
    _check(rig.plan[].fired, "the rival landed first")
    _check(out[1] == ERROR_REBALANCE_IN_PROGRESS, "told to rejoin")
    var st = _state(rig.coord)
    _check(st.state == String(GROUP_STATE_PREPARING), "not moved to stable")
    _check(st.generation_id == Int32(2), "the leave's generation stands")
    _check(not _has(st, String("cli-2")), "the leaver stays gone")
    print("PASS test_sync_sees_a_rival_leave_and_does_not_go_stable")


def test_leave_removes_its_member_from_the_group_a_rival_changed() raises:
    var rig = _rig()
    var a = _round_of_two(rig)
    rig.plan[].arm(1, _RIVAL_JOINS_ROUND)
    _check(
        rig.coord.leave_group(String("g"), a.member_id.copy()) == Int16(0),
        "leave ok",
    )
    _check(rig.plan[].fired, "the rival landed first")
    var st = _state(rig.coord)
    _check(not _has(st, String("cli-1")), "the leaver is gone")
    _check(_has(st, String("cli-2")), "the other member is kept")
    _check(_has(st, String("rival")), "the rival is kept")
    _check(len(st.members) == 2, "two members remain")
    _check(st.generation_id == Int32(2), "generation moved once")
    _check(st.state == String(GROUP_STATE_PREPARING), "preparing")
    print("PASS test_leave_removes_its_member_from_the_group_a_rival_changed")


def main() raises:
    var failed = 0
    try:
        test_join_registering_joins_the_round_a_rival_opened()
    except e:
        print("FAIL join_registering: " + String(e))
        failed += 1
    try:
        test_join_close_keeps_a_member_that_joined_before_it()
    except e:
        print("FAIL join_close: " + String(e))
        failed += 1
    try:
        test_sync_stores_over_a_rivals_stamp_and_keeps_it()
    except e:
        print("FAIL sync_stamp: " + String(e))
        failed += 1
    try:
        test_sync_sees_a_rival_leave_and_does_not_go_stable()
    except e:
        print("FAIL sync_leave: " + String(e))
        failed += 1
    try:
        test_leave_removes_its_member_from_the_group_a_rival_changed()
    except e:
        print("FAIL leave: " + String(e))
        failed += 1
    if failed > 0:
        raise Error("test_kafka_rebalance_rival: " + String(failed) + " FAILED")
    print("test_kafka_rebalance_rival: ALL PASS")
