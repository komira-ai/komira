# =============================================================================
# tests/test_group_membership.mojo
#   reconcile_members and assignment_is_valid, called directly on a GroupState.
#
#   reconcile_members: a member at the current generation stays; an older member
#   is carried (re-anchored to the current generation, keeping its blobs and
#   last_active_ms) only when its session is alive and it was active within
#   GHOST_STALE_GRACE_MS of the round's open instant; a round_opened_ms of 0
#   skips the activity test; a member idle for exactly the session timeout is
#   expired.
#   assignment_is_valid: a clean disjoint cover passes; a reopened round, an
#   uncovered member, a slice for a member not at the generation, a partition
#   assigned twice, and a gap each fail.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_kafka_broker.group_membership import (
    assignment_is_valid,
    reconcile_members,
)
from komira_kafka_broker.group_state import (
    GroupMember,
    GroupState,
    GHOST_STALE_GRACE_MS,
    GROUP_STATE_COMPLETING,
    GROUP_STATE_PREPARING,
)
from komira_kafka_server.wire.consumer_group import (
    AssignedTopicPartitions,
    encode_consumer_assignment,
)

comptime NOW: Int64 = 100_000
comptime SESSION: Int64 = 10_000


def _member(id: String, gen: Int32, last_active: Int64) -> GroupMember:
    var sub = List[UInt8]()
    sub.append(UInt8(7))
    return GroupMember(id.copy(), sub^, List[UInt8](), gen, last_active)


def _state(
    var members: List[GroupMember], round_opened: Int64, var state: String
) -> GroupState:
    return GroupState(
        Int32(2),
        String(""),
        String("range"),
        String("consumer"),
        state^,
        Int64(0),
        members^,
        String("etag"),
        SESSION,
        round_opened,
    )


def _find(ms: List[GroupMember], id: String) -> Int:
    for i in range(len(ms)):
        if ms[i].member_id == id:
            return i
    return -1


def test_current_generation_member_is_kept_even_when_idle() raises:
    var ms = List[GroupMember]()
    ms.append(_member(String("a"), Int32(2), NOW - SESSION * 5))
    var out = reconcile_members(
        _state(ms^, NOW, String(GROUP_STATE_PREPARING)), Int32(2), NOW
    )
    assert_equal(len(out), 1)
    assert_equal(out[0].join_generation, Int32(2))


def test_older_alive_active_member_is_carried_forward() raises:
    var ms = List[GroupMember]()
    ms.append(_member(String("a"), Int32(1), NOW - 1000))
    var out = reconcile_members(
        _state(ms^, NOW, String(GROUP_STATE_PREPARING)), Int32(2), NOW
    )
    assert_equal(len(out), 1)
    assert_equal(out[0].join_generation, Int32(2))
    assert_equal(out[0].last_active_ms, NOW - 1000)
    assert_equal(len(out[0].subscription), 1)


def test_session_expired_member_is_dropped() raises:
    var ms = List[GroupMember]()
    # idle == the session timeout is expired; one less is alive.
    ms.append(_member(String("expired"), Int32(1), NOW - SESSION))
    ms.append(_member(String("alive"), Int32(1), NOW - SESSION + 1))
    var out = reconcile_members(
        _state(ms^, Int64(0), String(GROUP_STATE_PREPARING)), Int32(2), NOW
    )
    assert_equal(len(out), 1)
    assert_equal(out[0].member_id, String("alive"))


def test_ghost_silent_before_the_round_opened_is_dropped() raises:
    var opened = NOW - 500
    var ms = List[GroupMember]()
    # Session-alive in both cases; only the activity relative to the round
    # differs. The grace boundary is inclusive.
    ms.append(_member(String("ghost"), Int32(1), opened - GHOST_STALE_GRACE_MS - 1))
    ms.append(_member(String("edge"), Int32(1), opened - GHOST_STALE_GRACE_MS))
    ms.append(_member(String("lagging"), Int32(1), opened - 1))
    var out = reconcile_members(
        _state(ms^, opened, String(GROUP_STATE_PREPARING)), Int32(2), NOW
    )
    assert_equal(len(out), 2)
    assert_equal(_find(out, String("ghost")), -1)
    assert_true(_find(out, String("edge")) >= 0)
    assert_true(_find(out, String("lagging")) >= 0)


def test_no_round_open_stamp_keeps_the_session_only_rule() raises:
    var ms = List[GroupMember]()
    ms.append(_member(String("old"), Int32(1), NOW - SESSION + 1))
    var out = reconcile_members(
        _state(ms^, Int64(0), String(GROUP_STATE_PREPARING)), Int32(2), NOW
    )
    assert_equal(len(out), 1)


def _assignment(parts: List[Int32]) -> List[UInt8]:
    var a = List[AssignedTopicPartitions]()
    a.append(AssignedTopicPartitions(String("t"), parts.copy()))
    return encode_consumer_assignment(a)


def _two_members(state: String) -> GroupState:
    var ms = List[GroupMember]()
    ms.append(_member(String("a"), Int32(2), NOW))
    ms.append(_member(String("b"), Int32(2), NOW))
    return _state(ms^, NOW, state.copy())


def _ids(a: String, b: String) -> List[String]:
    var ids = List[String]()
    ids.append(a.copy())
    ids.append(b.copy())
    return ids^


def _parts(xs: List[Int]) -> List[Int32]:
    var out = List[Int32]()
    for x in xs:
        out.append(Int32(x))
    return out^


def _blobs(first: List[Int], second: List[Int]) -> List[List[UInt8]]:
    var out = List[List[UInt8]]()
    out.append(_assignment(_parts(first)))
    out.append(_assignment(_parts(second)))
    return out^


def test_clean_disjoint_cover_is_valid() raises:
    var st = _two_members(String(GROUP_STATE_COMPLETING))
    assert_true(
        assignment_is_valid(
            st, Int32(2), _ids("a", "b"), _blobs([0, 1, 2], [3, 4, 5])
        )
    )
    # More members than partitions: the trailing member holds none.
    assert_true(
        assignment_is_valid(st, Int32(2), _ids("a", "b"), _blobs([0, 1], []))
    )


def test_reopened_round_is_invalid() raises:
    var st = _two_members(String(GROUP_STATE_PREPARING))
    assert_false(
        assignment_is_valid(
            st, Int32(2), _ids("a", "b"), _blobs([0, 1, 2], [3, 4, 5])
        )
    )


def test_uncovered_member_is_invalid() raises:
    var st = _two_members(String(GROUP_STATE_COMPLETING))
    var ids = List[String]()
    ids.append(String("a"))
    var blobs = List[List[UInt8]]()
    blobs.append(_assignment(_parts([0, 1, 2, 3])))
    assert_false(assignment_is_valid(st, Int32(2), ids, blobs))


def test_slice_for_a_member_not_at_the_generation_is_invalid() raises:
    var ms = List[GroupMember]()
    ms.append(_member(String("a"), Int32(2), NOW))
    ms.append(_member(String("b"), Int32(2), NOW))
    ms.append(_member(String("ghost"), Int32(1), NOW))
    var st = _state(ms^, NOW, String(GROUP_STATE_COMPLETING))
    var ids = _ids("a", "ghost")
    ids.append(String("b"))
    var blobs = List[List[UInt8]]()
    blobs.append(_assignment(_parts([0, 1])))
    blobs.append(_assignment(_parts([2, 3])))
    blobs.append(_assignment(_parts([4, 5])))
    assert_false(assignment_is_valid(st, Int32(2), ids, blobs))
    # A member that is not in the state at all is not at the generation either.
    var ids2 = _ids("a", "b")
    ids2.append(String("stranger"))
    assert_false(assignment_is_valid(st, Int32(2), ids2, blobs))


def test_partition_assigned_twice_is_invalid() raises:
    var st = _two_members(String(GROUP_STATE_COMPLETING))
    assert_false(
        assignment_is_valid(
            st, Int32(2), _ids("a", "b"), _blobs([0, 1, 2], [2, 3])
        )
    )


def test_gap_in_the_cover_is_invalid() raises:
    var st = _two_members(String(GROUP_STATE_COMPLETING))
    assert_false(
        assignment_is_valid(
            st, Int32(2), _ids("a", "b"), _blobs([0, 1], [4, 5])
        )
    )


def main() raises:
    test_current_generation_member_is_kept_even_when_idle()
    test_older_alive_active_member_is_carried_forward()
    test_session_expired_member_is_dropped()
    test_ghost_silent_before_the_round_opened_is_dropped()
    test_no_round_open_stamp_keeps_the_session_only_rule()
    test_clean_disjoint_cover_is_valid()
    test_reopened_round_is_invalid()
    test_uncovered_member_is_invalid()
    test_slice_for_a_member_not_at_the_generation_is_invalid()
    test_partition_assigned_twice_is_invalid()
    test_gap_in_the_cover_is_invalid()
    print("test_group_membership: ALL PASS")
