# =============================================================================
# tests/test_kafka_rebalance_heartbeat.mojo
#   Heartbeat answers as Apache Kafka's handleHeartbeat does, in every group
#   state, over a state.json written straight into the store.
#
#   Unknown group or member: UNKNOWN_MEMBER_ID (25). A generation that is not
#   the group's, older or newer, in a PreparingRebalance, CompletingRebalance
#   or Stable group: ILLEGAL_GENERATION (22). At the group's generation:
#   PreparingRebalance answers REBALANCE_IN_PROGRESS (27), CompletingRebalance
#   and Stable answer NONE (0). An Empty group has no member to know.
#
#   What it catches: a coordinator that answers 27 for every non-Stable state
#   fails the CompletingRebalance row and the PreparingRebalance wrong-
#   generation rows; one that checks the generation only when Stable fails the
#   same rows; one that answers a stranger with anything but 25 fails the
#   unknown-member rows. A last test checks that the liveness stamp the
#   heartbeat writes changes neither the answer nor the group's state.
#
#   No sleep and no clock reads.
# =============================================================================

from komira_kafka_broker.group_clock import ManualGroupClock
from komira_kafka_broker.group_coordinator import GroupCoordinator
from komira_kafka_broker.group_state import (
    GroupMember,
    GroupState,
    GROUP_STATE_COMPLETING,
    GROUP_STATE_EMPTY,
    GROUP_STATE_PREPARING,
    GROUP_STATE_STABLE,
    encode_group_state_json,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.types import WritePrecondition
from komira_kafka_server.wire.consumer_group import (
    ERROR_ILLEGAL_GENERATION,
    ERROR_REBALANCE_IN_PROGRESS,
    ERROR_UNKNOWN_MEMBER_ID,
)

comptime Coordinator = GroupCoordinator[
    SharedInMemoryConditionalStore, ManualGroupClock
]

comptime _GEN = Int32(5)


def _check(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)


def _coordinator(state: String, with_member: Bool) raises -> Coordinator:
    var raw = SharedInMemoryConditionalStore()
    var members = List[GroupMember]()
    if with_member:
        members.append(
            GroupMember(
                String("m1"), List[UInt8](), List[UInt8](), _GEN, Int64(0)
            )
        )
    var st = GroupState(
        _GEN,
        String("m1") if with_member else String(""),
        String("range"),
        String("consumer"),
        state.copy(),
        Int64(0),
        members^,
        String(""),
    )
    _ = raw.conditional_put(
        Path.parse(String("c/_meta/groups/g/state.json")),
        encode_group_state_json(st),
        WritePrecondition.if_none_match_star(),
    )
    return Coordinator(raw^, String("c"), ManualGroupClock(), String(""))


def _row(
    state: String, member: String, gen: Int32, want: Int16, what: String
) raises:
    var c = _coordinator(state, True)
    var got = c.heartbeat(String("g"), member.copy(), gen)
    _check(
        got == want,
        state + " " + what + ": want " + String(want) + ", got " + String(got),
    )


def test_preparing_rebalance() raises:
    var s = String(GROUP_STATE_PREPARING)
    _row(s, String("m1"), _GEN, ERROR_REBALANCE_IN_PROGRESS, "right generation")
    _row(s, String("m1"), _GEN - Int32(1), ERROR_ILLEGAL_GENERATION, "older generation")
    _row(s, String("m1"), _GEN + Int32(1), ERROR_ILLEGAL_GENERATION, "newer generation")
    _row(s, String("nobody"), _GEN, ERROR_UNKNOWN_MEMBER_ID, "unknown member")
    print("PASS test_preparing_rebalance")


def test_completing_rebalance() raises:
    var s = String(GROUP_STATE_COMPLETING)
    _row(s, String("m1"), _GEN, Int16(0), "right generation")
    _row(s, String("m1"), _GEN - Int32(1), ERROR_ILLEGAL_GENERATION, "older generation")
    _row(s, String("m1"), _GEN + Int32(1), ERROR_ILLEGAL_GENERATION, "newer generation")
    _row(s, String("nobody"), _GEN, ERROR_UNKNOWN_MEMBER_ID, "unknown member")
    print("PASS test_completing_rebalance")


def test_stable() raises:
    var s = String(GROUP_STATE_STABLE)
    _row(s, String("m1"), _GEN, Int16(0), "right generation")
    _row(s, String("m1"), _GEN - Int32(1), ERROR_ILLEGAL_GENERATION, "older generation")
    _row(s, String("m1"), _GEN + Int32(1), ERROR_ILLEGAL_GENERATION, "newer generation")
    _row(s, String("nobody"), _GEN, ERROR_UNKNOWN_MEMBER_ID, "unknown member")
    print("PASS test_stable")


def test_empty_group_and_absent_group() raises:
    var c = _coordinator(String(GROUP_STATE_EMPTY), False)
    _check(
        c.heartbeat(String("g"), String("m1"), _GEN) == ERROR_UNKNOWN_MEMBER_ID,
        "an Empty group knows no member",
    )
    _check(
        c.heartbeat(String("absent"), String("m1"), _GEN)
        == ERROR_UNKNOWN_MEMBER_ID,
        "an absent group knows no member",
    )
    print("PASS test_empty_group_and_absent_group")


def test_the_answer_is_not_changed_by_the_liveness_stamp() raises:
    # Two heartbeats in a row on a CompletingRebalance group: the first stamps
    # the member, the second reads the stamped object; both answer NONE.
    var c = _coordinator(String(GROUP_STATE_COMPLETING), True)
    _check(c.heartbeat(String("g"), String("m1"), _GEN) == Int16(0), "first")
    _check(c.heartbeat(String("g"), String("m1"), _GEN) == Int16(0), "second")
    var loaded = c.load_state(String("g"))
    var st = loaded.take()
    _check(st.state == String(GROUP_STATE_COMPLETING), "state untouched")
    _check(st.generation_id == _GEN, "generation untouched")
    print("PASS test_the_answer_is_not_changed_by_the_liveness_stamp")


def main() raises:
    var failed = 0
    try:
        test_preparing_rebalance()
    except e:
        print("FAIL preparing: " + String(e))
        failed += 1
    try:
        test_completing_rebalance()
    except e:
        print("FAIL completing: " + String(e))
        failed += 1
    try:
        test_stable()
    except e:
        print("FAIL stable: " + String(e))
        failed += 1
    try:
        test_empty_group_and_absent_group()
    except e:
        print("FAIL empty_absent: " + String(e))
        failed += 1
    try:
        test_the_answer_is_not_changed_by_the_liveness_stamp()
    except e:
        print("FAIL stamp: " + String(e))
        failed += 1
    if failed > 0:
        raise Error(
            "test_kafka_rebalance_heartbeat: " + String(failed) + " FAILED"
        )
    print("test_kafka_rebalance_heartbeat: ALL PASS")
