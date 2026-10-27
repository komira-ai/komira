# =============================================================================
# tests/test_kafka_rebalance.mojo
#   The consumer-group coordinator over the in-memory store, on a manual clock.
#
#   A) The range assignor: contiguous, balanced, deterministic; more members
#      than partitions.
#   B) The state machine: JoinGroup member-id mint and reuse and generation bump;
#      Empty -> Preparing -> Completing -> Stable; SyncGroup leader-stores and
#      follower-reads; LeaveGroup -> Preparing + generation bump; Heartbeat ->
#      REBALANCE_IN_PROGRESS during a rebalance and NONE when Stable; the
#      two-member 4-partition split (2+2), then one leaves and the other gets
#      all 4; a join into an open round keeps its generation; the join decision
#      is the same under a CAS retry; the state.json round trip.
#
#   Two tests cover the join barrier on the clock: a sole member's window closes
#   without a wait, and a join with a live window waits on the manual clock until
#   it reaches the deadline.
#
#   The coordinator reads and waits on a ManualGroupClock. Every join passes
#   rebalance_timeout_ms of 0, so its window is closed from the start.
#   The wire round trips are in test_kafka_rebalance_wire.
# =============================================================================

from komira_kafka_broker.group_assignor import (
    range_assign,
    pick_protocol_name,
)
from komira_kafka_broker.group_coordinator import GroupCoordinator
from komira_kafka_broker.group_state import (
    GroupState,
    GroupMember,
    encode_group_state_json,
    decode_group_state_json,
    GROUP_STATE_EMPTY,
    GROUP_STATE_PREPARING,
    GROUP_STATE_COMPLETING,
    GROUP_STATE_STABLE,
)
from komira_kafka_broker.group_clock import ManualGroupClock
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.types import WritePrecondition

from komira_kafka_server.wire import KafkaEncoder
from komira_kafka_server.wire.consumer_group import (
    AssignedTopicPartitions,
    encode_consumer_assignment,
    decode_consumer_assignment,
    CONSUMER_PROTOCOL_VERSION,
    ERROR_ILLEGAL_GENERATION,
    ERROR_REBALANCE_IN_PROGRESS,
    ERROR_UNKNOWN_MEMBER_ID,
)


comptime TestCoordinator = GroupCoordinator[
    SharedInMemoryConditionalStore, ManualGroupClock
]


def _fail(msg: String) raises:
    raise Error("FAIL: " + msg)


def _check(cond: Bool, msg: String) raises:
    if not cond:
        _fail(msg)


def _new_coordinator() raises -> TestCoordinator:
    return TestCoordinator(
        SharedInMemoryConditionalStore(),
        String("test-cluster"),
        ManualGroupClock(),
    )


def _state(
    mut c: TestCoordinator, group: String
) raises -> GroupState:
    """Load the persisted GroupState, raising if absent (test helper:
    `.take()` cannot be called on an Optional rvalue)."""
    var opt = c.load_state(group)
    if not opt:
        raise Error("FAIL: no state for group " + group)
    return opt.take()


# A subscription blob for `topics` (Version INT16 + Topics ARRAY(STRING) +
# UserData null) — what a consumer puts in JoinGroup.Protocols[].Metadata.
def _subscription_blob(topics: List[String]) -> List[UInt8]:
    var enc = KafkaEncoder()
    enc.put_int16(CONSUMER_PROTOCOL_VERSION)
    enc.put_array_len(len(topics))
    for i in range(len(topics)):
        enc.put_string(topics[i])
    enc.put_int32(Int32(-1))  # UserData null
    return enc.take_bytes()


# =============================================================================
# A) The RangeAssignor.
# =============================================================================


def test_range_assign_even() raises:
    # 4 partitions across 2 members -> 2 + 2, contiguous.
    var members = List[String]()
    members.append(String("m-a"))
    members.append(String("m-b"))
    var asg = range_assign(members, String("t1"), 4)
    _check(len(asg) == 2, "range even: 2 members")
    _check(len(asg[0].partitions) == 2, "range even: m-a 2 parts")
    _check(len(asg[1].partitions) == 2, "range even: m-b 2 parts")
    _check(asg[0].partitions[0] == Int32(0), "range even: m-a p0")
    _check(asg[0].partitions[1] == Int32(1), "range even: m-a p1")
    _check(asg[1].partitions[0] == Int32(2), "range even: m-b p2")
    _check(asg[1].partitions[1] == Int32(3), "range even: m-b p3")
    print("PASS test_range_assign_even")


def test_range_assign_uneven() raises:
    # 5 partitions across 2 members -> 3 + 2 (first member gets the extra).
    var members = List[String]()
    members.append(String("a"))
    members.append(String("b"))
    var asg = range_assign(members, String("t1"), 5)
    _check(len(asg[0].partitions) == 3, "range uneven: a 3")
    _check(len(asg[1].partitions) == 2, "range uneven: b 2")
    _check(asg[0].partitions[0] == Int32(0), "uneven a p0")
    _check(asg[0].partitions[2] == Int32(2), "uneven a p2")
    _check(asg[1].partitions[0] == Int32(3), "uneven b p3")
    _check(asg[1].partitions[1] == Int32(4), "uneven b p4")
    print("PASS test_range_assign_uneven")


def test_range_assign_more_members_than_partitions() raises:
    # 2 partitions across 3 members -> 1, 1, 0 (trailing member gets none).
    var members = List[String]()
    members.append(String("a"))
    members.append(String("b"))
    members.append(String("c"))
    var asg = range_assign(members, String("t1"), 2)
    _check(len(asg) == 3, "M>P: 3 members present")
    _check(len(asg[0].partitions) == 1, "M>P: a 1")
    _check(len(asg[1].partitions) == 1, "M>P: b 1")
    _check(len(asg[2].partitions) == 0, "M>P: c 0")
    print("PASS test_range_assign_more_members_than_partitions")


def test_range_assign_single_member_all() raises:
    var members = List[String]()
    members.append(String("only"))
    var asg = range_assign(members, String("t1"), 4)
    _check(len(asg) == 1, "single: 1 member")
    _check(len(asg[0].partitions) == 4, "single: all 4")
    _check(asg[0].partitions[3] == Int32(3), "single: p3")
    print("PASS test_range_assign_single_member_all")


# =============================================================================
# B) The state machine over the store.
# =============================================================================


def test_join_mints_member_id_and_first_generation() raises:
    var c = _new_coordinator()
    var topics = List[String]()
    topics.append(String("t1"))
    var sub = _subscription_blob(topics)
    var pnames = List[String]()
    pnames.append(String("range"))
    var r = c.join_group(
        String("g1"),
        String(""),  # empty member_id -> mint
        String("client-x"),
        pnames,
        sub,
        Int32(0),  # rebalance_timeout 0 -> window closes immediately
    )
    _check(r.member_id.byte_length() > 0, "join: minted non-empty member_id")
    _check(r.member_id.find("client-x") >= 0, "join: member_id carries client")
    _check(r.generation_id == Int32(1), "join: first generation 1")
    _check(r.leader_id == r.member_id, "join: sole member is leader")
    _check(r.error_code == Int16(0), "join: error NONE")
    # Leader gets itself in the member list.
    _check(len(r.members) == 1, "join: leader sees 1 member")
    print("PASS test_join_mints_member_id_and_first_generation")


def test_state_transitions_to_completing_after_join() raises:
    var c = _new_coordinator()
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var r = c.join_group(
        String("g1"),
        String(""),
        String("cli"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    # After the JoinGroup returns, the group should be CompletingRebalance
    # (awaiting the leader's SyncGroup).
    var st = _state(c, String("g1"))
    _check(
        st.state == String(GROUP_STATE_COMPLETING),
        "state: Completing after join, got " + st.state,
    )
    _check(st.generation_id == Int32(1), "state: gen 1")
    _check(st.leader_member_id == r.member_id, "state: leader recorded")
    print("PASS test_state_transitions_to_completing_after_join")


def test_sync_leader_stores_then_member_reads() raises:
    var c = _new_coordinator()
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var r = c.join_group(
        String("g1"),
        String(""),
        String("cli"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    # Leader computes a RangeAssignor assignment for itself (all 4 partitions of
    # t1) and submits it via SyncGroup.
    var assigned = List[AssignedTopicPartitions]()
    var parts = List[Int32]()
    parts.append(Int32(0))
    parts.append(Int32(1))
    parts.append(Int32(2))
    parts.append(Int32(3))
    assigned.append(AssignedTopicPartitions(String("t1"), parts^))
    var blob = encode_consumer_assignment(assigned)
    var asg_ids = List[String]()
    asg_ids.append(r.member_id.copy())
    var asg_blobs = List[List[UInt8]]()
    asg_blobs.append(blob.copy())

    var out = c.sync_group(
        String("g1"),
        r.member_id.copy(),
        r.generation_id,
        asg_ids,
        asg_blobs,
    )
    _check(out[1] == Int16(0), "sync: leader error NONE")
    # The returned assignment blob decodes to all 4 partitions of t1.
    var decoded = decode_consumer_assignment(out[0])
    _check(len(decoded) == 1, "sync: 1 topic in assignment")
    _check(decoded[0].topic == String("t1"), "sync: topic t1")
    _check(len(decoded[0].partitions) == 4, "sync: 4 partitions")
    # Group is now Stable.
    var st = _state(c, String("g1"))
    _check(st.state == String(GROUP_STATE_STABLE), "sync: group Stable")
    print("PASS test_sync_leader_stores_then_member_reads")


def test_heartbeat_none_when_stable_then_illegal_generation() raises:
    var c = _new_coordinator()
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var r = c.join_group(
        String("g1"),
        String(""),
        String("cli"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    # Sync to Stable.
    var assigned = List[AssignedTopicPartitions]()
    var parts = List[Int32]()
    parts.append(Int32(0))
    assigned.append(AssignedTopicPartitions(String("t1"), parts^))
    var asg_ids = List[String]()
    asg_ids.append(r.member_id.copy())
    var asg_blobs = List[List[UInt8]]()
    asg_blobs.append(encode_consumer_assignment(assigned))
    _ = c.sync_group(
        String("g1"), r.member_id.copy(), r.generation_id, asg_ids, asg_blobs
    )
    # Heartbeat with the right generation -> NONE.
    var hb = c.heartbeat(String("g1"), r.member_id.copy(), r.generation_id)
    _check(hb == Int16(0), "heartbeat: NONE when stable")
    # Heartbeat with a stale (wrong) generation on a Stable group ->
    # ILLEGAL_GENERATION.
    var hb_stale = c.heartbeat(
        String("g1"), r.member_id.copy(), r.generation_id - Int32(1)
    )
    _check(
        hb_stale == ERROR_ILLEGAL_GENERATION,
        "heartbeat: stale gen -> illegal generation",
    )
    print("PASS test_heartbeat_none_when_stable_then_illegal_generation")


def test_heartbeat_codes_and_liveness_stamp() raises:
    # A heartbeat in a CompletingRebalance group at its generation answers NONE
    # (the states are covered in test_kafka_rebalance_heartbeat), a member or
    # group the store does not know answers UNKNOWN_MEMBER_ID, and a heartbeat
    # stamps the member's last_active_ms with the clock's now.
    var c = _new_coordinator()
    c.clock.set(Int64(1000))
    var r = _join_with_window(c, String(""), String("cli"), Int32(0))
    _check(
        c.heartbeat(String("g1"), r.member_id.copy(), r.generation_id)
        == Int16(0),
        "hb: Completing at its generation -> none",
    )
    _check(
        c.heartbeat(String("g1"), String("nobody"), r.generation_id)
        == ERROR_UNKNOWN_MEMBER_ID,
        "hb: unknown member",
    )
    _check(
        c.heartbeat(String("no-such-group"), r.member_id.copy(), Int32(1))
        == ERROR_UNKNOWN_MEMBER_ID,
        "hb: unknown group",
    )
    _check(
        _state(c, String("g1")).members[0].last_active_ms == Int64(1000),
        "hb: join stamped the clock",
    )
    c.clock.set(Int64(7500))
    _ = c.heartbeat(String("g1"), r.member_id.copy(), r.generation_id)
    var st = _state(c, String("g1"))
    _check(
        st.members[0].last_active_ms == Int64(7500),
        "hb: heartbeat stamped the clock",
    )
    _check(
        st.state == String(GROUP_STATE_COMPLETING),
        "hb: a heartbeat changes no state",
    )
    print("PASS test_heartbeat_codes_and_liveness_stamp")


def test_leave_bumps_generation_and_preparing() raises:
    var c = _new_coordinator()
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    # Two members join. The FIRST join opens a round at gen 1 (Empty->Preparing,
    # bump-ONCE). The SECOND join lands while that round is still in flight (the
    # leader has not synced to Stable), so under bump-once-per-round it JOINS
    # gen 1 rather than leapfrogging to gen 2 — both members co-exist at one
    # generation. (Re-bumping on every join would be the leapfrog bug.)
    var r1 = c.join_group(
        String("g1"),
        String(""),
        String("cli1"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    var r2 = c.join_group(
        String("g1"),
        String(""),
        String("cli2"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    _check(
        r2.generation_id == r1.generation_id,
        "second join joins the in-flight round at the SAME generation"
        " (bump-once-per-round; no leapfrog)",
    )
    _check(len(_state(c, String("g1")).members) == 2, "both members co-exist")
    var gen_before = _state(c, String("g1")).generation_id
    # r1 leaves -> generation bumps, state PreparingRebalance (one member left).
    var err = c.leave_group(String("g1"), r1.member_id.copy())
    _check(err == Int16(0), "leave: error NONE")
    var st = _state(c, String("g1"))
    _check(st.generation_id > gen_before, "leave: generation bumped")
    _check(
        st.state == String(GROUP_STATE_PREPARING),
        "leave: state Preparing, got " + st.state,
    )
    _check(len(st.members) == 1, "leave: 1 member remains")
    _check(st.members[0].member_id == r2.member_id, "leave: r2 remains")
    # The leave bumped the generation: a heartbeat from the remaining member
    # at the generation it joined is ILLEGAL_GENERATION, and one at the new
    # generation sees the rebalance.
    var hb = c.heartbeat(String("g1"), r2.member_id.copy(), r2.generation_id)
    _check(hb == Int16(22), "leave: remaining member at its old generation")
    hb = c.heartbeat(String("g1"), r2.member_id.copy(), st.generation_id)
    _check(
        hb == ERROR_REBALANCE_IN_PROGRESS,
        "leave: remaining member sees rebalance",
    )
    print("PASS test_leave_bumps_generation_and_preparing")


def test_leave_last_member_goes_empty() raises:
    var c = _new_coordinator()
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var r = c.join_group(
        String("g1"),
        String(""),
        String("cli"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    var err = c.leave_group(String("g1"), r.member_id.copy())
    _check(err == Int16(0), "leave-last: error NONE")
    var st = _state(c, String("g1"))
    _check(st.state == String(GROUP_STATE_EMPTY), "leave-last: Empty")
    _check(len(st.members) == 0, "leave-last: no members")
    print("PASS test_leave_last_member_goes_empty")


struct JoinResultLite(Movable, Deinitable):
    var member_id: String
    var generation_id: Int32

    def __init__(out self, var member_id: String, generation_id: Int32):
        self.member_id = member_id^
        self.generation_id = generation_id


def _join_with_window(
    mut c: TestCoordinator,
    member_id: String,
    client: String,
    rebalance_timeout_ms: Int32,
) raises -> JoinResultLite:
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var r = c.join_group(
        String("g1"),
        member_id,
        client,
        pnames,
        _subscription_blob(topics),
        rebalance_timeout_ms,
    )
    return JoinResultLite(r.member_id.copy(), r.generation_id)


def test_sole_member_join_closes_without_waiting() raises:
    # A one-member group has every member at the current generation on the
    # first poll, so the window closes early: the join never waits, whatever
    # the rebalance timeout. The clock is neither slept on nor moved.
    var c = _new_coordinator()
    c.clock.set(Int64(1_000_000))
    var r = _join_with_window(c, String(""), String("cli"), Int32(60000))
    _check(r.generation_id == Int32(1), "early close: generation 1")
    _check(c.clock.sleep_calls == 0, "early close: no wait on the clock")
    _check(c.clock.now == Int64(1_000_000), "early close: clock unmoved")
    print("PASS test_sole_member_join_closes_without_waiting")


def test_join_waits_for_the_deadline_on_the_manual_clock() raises:
    # A is Stable at generation 1. B joins with a 5000 ms rebalance window
    # while A has not rejoined, so the barrier cannot close early and the join
    # polls, waiting on the clock between polls. The manual clock's sleep moves
    # it by the requested wait, so the poll reaches the deadline and the join
    # returns: it never reads the wall clock and never spins on a frozen one.
    # A's session is alive at the deadline (idle 5000 ms < the 10000 ms
    # default), so the close carries A into generation 2 with B.
    var c = _new_coordinator()
    var t0 = Int64(1_000_000)
    c.clock.set(t0)
    var a = _join_with_window(c, String(""), String("cli-a"), Int32(0))
    var assigned = List[AssignedTopicPartitions]()
    var parts = List[Int32]()
    parts.append(Int32(0))
    assigned.append(AssignedTopicPartitions(String("t1"), parts^))
    var ids = List[String]()
    ids.append(a.member_id.copy())
    var blobs = List[List[UInt8]]()
    blobs.append(encode_consumer_assignment(assigned))
    _ = c.sync_group(String("g1"), a.member_id.copy(), a.generation_id, ids, blobs)
    _check(
        _state(c, String("g1")).state == String(GROUP_STATE_STABLE),
        "deadline wait: A Stable",
    )
    var calls_before = c.clock.sleep_calls

    var b = _join_with_window(c, String(""), String("cli-b"), Int32(5000))
    var st = _state(c, String("g1"))
    _check(st.generation_id == Int32(2), "deadline wait: generation 2")
    _check(
        c.clock.now >= st.rebalance_deadline_ms,
        "deadline wait: the clock reached the deadline",
    )
    _check(
        c.clock.sleep_calls > calls_before,
        "deadline wait: the join waited on the clock",
    )
    _check(len(st.members) == 2, "deadline wait: both members carried")
    for i in range(len(st.members)):
        _check(
            st.members[i].join_generation == Int32(2),
            "deadline wait: member at generation 2 " + st.members[i].member_id,
        )
    _check(
        st.state == String(GROUP_STATE_COMPLETING),
        "deadline wait: Completing after the close",
    )
    _ = b^
    print("PASS test_join_waits_for_the_deadline_on_the_manual_clock")


def test_two_member_split_then_one_leaves_gets_all() raises:
    # The KEYSTONE state-machine test: two members of g1 subscribed to a
    # 4-partition topic split 2+2 (via the leader's RangeAssignor), each member
    # reads its own assignment from SyncGroup; then one leaves and the other,
    # on rejoin+sync, gets all 4 partitions back.
    var c = _new_coordinator()
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))

    # Member 1 joins.
    var r1 = c.join_group(
        String("g1"),
        String(""),
        String("cli1"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    # Member 2 joins (generation bumps; group re-prepares).
    var r2 = c.join_group(
        String("g1"),
        String(""),
        String("cli2"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    # Member 1 rejoins to catch up to the current generation (mirrors a real
    # consumer getting REBALANCE_IN_PROGRESS on its heartbeat and rejoining).
    var r1b = c.join_group(
        String("g1"),
        r1.member_id.copy(),
        String("cli1"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    var r2b = c.join_group(
        String("g1"),
        r2.member_id.copy(),
        String("cli2"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    # The two should now agree on a single generation + leader.
    _check(
        r1b.generation_id == r2b.generation_id
        or r2b.generation_id > r1b.generation_id,
        "split: generations converge (monotone)",
    )
    # Identify the leader (the one whose JoinResult carried the member list).
    var leader_id = r2b.leader_id.copy()
    var current_gen = r2b.generation_id
    # The leader computes the RangeAssignor split over the (sorted) members.
    var st = _state(c, String("g1"))
    var member_ids = List[String]()
    for i in range(len(st.members)):
        member_ids.append(st.members[i].member_id.copy())
    # Sort ascending (the assignor requires it).
    var n = len(member_ids)
    for i in range(1, n):
        var j = i
        while j > 0 and member_ids[j - 1] > member_ids[j]:
            var tmp = member_ids[j - 1].copy()
            member_ids[j - 1] = member_ids[j].copy()
            member_ids[j] = tmp^
            j -= 1
    var split = range_assign(member_ids, String("t1"), 4)
    _check(len(split) == 2, "split: 2 members assigned")
    _check(len(split[0].partitions) == 2, "split: first gets 2")
    _check(len(split[1].partitions) == 2, "split: second gets 2")
    # No double-assignment: the 4 partitions are disjoint + cover 0..3.
    var seen = List[Bool]()
    for _ in range(4):
        seen.append(False)
    for mi in range(len(split)):
        for pi in range(len(split[mi].partitions)):
            var p = Int(split[mi].partitions[pi])
            _check(not seen[p], "split: partition " + String(p) + " unique")
            seen[p] = True
    for p in range(4):
        _check(seen[p], "split: partition " + String(p) + " covered")

    # The leader submits both assignments via SyncGroup.
    var asg_ids = List[String]()
    var asg_blobs = List[List[UInt8]]()
    for mi in range(len(member_ids)):
        asg_ids.append(member_ids[mi].copy())
        var one = List[AssignedTopicPartitions]()
        one.append(split[mi].copy())
        asg_blobs.append(encode_consumer_assignment(one))
    var sync_leader = c.sync_group(
        String("g1"), leader_id.copy(), current_gen, asg_ids, asg_blobs
    )
    _check(sync_leader[1] == Int16(0), "split: leader sync NONE")

    # Each member's stored assignment covers exactly 2 partitions; combined = 4.
    var total = 0
    for mi in range(len(member_ids)):
        var st2 = _state(c, String("g1"))
        var idx = st2.member_index(member_ids[mi])
        var dec = decode_consumer_assignment(st2.members[idx].assignment)
        if len(dec) > 0:
            total += len(dec[0].partitions)
    _check(total == 4, "split: combined assignment covers 4 partitions")

    # Now member with id == member_ids[1] leaves; the other rejoins + syncs and
    # gets all 4 back.
    var leaver = member_ids[1].copy()
    var stayer = member_ids[0].copy()
    _ = c.leave_group(String("g1"), leaver)
    var rejoin = c.join_group(
        String("g1"),
        stayer.copy(),
        String("cli-stay"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    var solo_ids = List[String]()
    solo_ids.append(stayer.copy())
    var solo = range_assign(solo_ids, String("t1"), 4)
    var solo_blobs = List[List[UInt8]]()
    var one2 = List[AssignedTopicPartitions]()
    one2.append(solo[0].copy())
    solo_blobs.append(encode_consumer_assignment(one2))
    var sync2 = c.sync_group(
        String("g1"),
        stayer.copy(),
        rejoin.generation_id,
        solo_ids,
        solo_blobs,
    )
    _check(sync2[1] == Int16(0), "split: solo sync NONE")
    var final_dec = decode_consumer_assignment(sync2[0])
    _check(len(final_dec) == 1, "split: solo 1 topic")
    _check(
        len(final_dec[0].partitions) == 4,
        "split: stayer gets all 4 back",
    )
    print("PASS test_two_member_split_then_one_leaves_gets_all")


# =============================================================================
# B') The bump-once-per-round barrier.
#
# These are the deterministic, no-thread tests for the
# generation-LEAPFROG case: if EVERY JoinGroup bumped the generation +
# re-prepared even when the group was ALREADY PreparingRebalance, so two
# members joining at different brokers within one rebalance window could never
# co-exist at one generation — the all-members barrier would never be satisfied and the
# 2nd member would get NO partitions. Instead, a join that lands while the group is
# already Preparing joins AT THE CURRENT generation (no bump, no deadline reset),
# so the members converge onto ONE generation.
#
# We model "another broker already opened the rebalance round" by pre-seeding
# the SHARED state.json directly (the test holds a clone of the same store the
# coordinator drives — exactly the cross-broker shared-store model) with a member
# already at gen G in PreparingRebalance and a FAR-FUTURE deadline (so the
# window stays open). A second member's JoinGroup then (i) must NOT bump the
# generation, (ii) registers at gen G, (iii) closes the window early on the
# all-rejoined barrier (both members at gen G), with NO real sleep.
# =============================================================================


def _state_key(cluster: String, group: String) -> String:
    return cluster + String("/_meta/groups/") + group + String("/state.json")


def _seed_state(
    mut store: SharedInMemoryConditionalStore,
    cluster: String,
    group: String,
    st: GroupState,
) raises:
    """Write `st` into the shared store as the group's state.json (models a peer
    broker having already persisted the in-flight rebalance round)."""
    var path = Path.parse(_state_key(cluster, group))
    var body = encode_group_state_json(st)
    _ = store.conditional_put(
        path, body^, WritePrecondition.if_none_match_star()
    )


def _read_state(
    mut store: SharedInMemoryConditionalStore, cluster: String, group: String
) raises -> GroupState:
    var path = Path.parse(_state_key(cluster, group))
    var meta = store.head(path)
    var body = store.get(path)
    return decode_group_state_json(body^, meta.etag.copy())


def test_no_generation_leapfrog_when_already_preparing() raises:
    # A peer broker has already opened a rebalance round at gen 7 with member A
    # registered (PreparingRebalance, far-future deadline). Member B joins via
    # the coordinator. The fix: B must join AT gen 7 (no leapfrog to gen 8) and
    # the window closes early on the all-rejoined barrier (A@7 + B@7).
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var cluster = String("test-cluster")
    var group = String("g1")

    var shared = SharedInMemoryConditionalStore()
    var coord = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock())

    # Pre-seed: gen 7, Preparing, far-future deadline, one member A @ gen 7.
    # Leader left EMPTY so the coordinator deterministically elects the min
    # member_id at the generation (exercises the election path).
    var members = List[GroupMember]()
    members.append(
        GroupMember(
            String("member-a"),
            _subscription_blob(topics),
            List[UInt8](),
            Int32(7),
        )
    )
    var seed = GroupState(
        Int32(7),
        String(""),  # leader unset => elect min at gen 7
        String("range"),
        String("consumer"),
        String(GROUP_STATE_PREPARING),
        Int64(1) << Int64(62),  # deadline far in the future => window stays open
        members^,
        String(""),
    )
    _seed_state(shared, cluster, group, seed)

    # Member B joins (empty member_id -> mint). With a LARGE rebalance_timeout B
    # would block forever IF the barrier never closed; the fix makes B join at
    # gen 7 so A@7 + B@7 satisfies all-rejoined immediately (no real sleep).
    var rB = coord.join_group(
        group.copy(),
        String(""),  # mint
        String("client-b"),
        pnames,
        _subscription_blob(topics),
        Int32(300000),  # 5min — proves the early-close fires, NOT the deadline
    )
    # (i) NO leapfrog: B's generation is still 7, not 8.
    _check(
        rB.generation_id == Int32(7),
        "no-leapfrog: B joins at gen 7 (no bump), got "
        + String(rB.generation_id),
    )
    _check(rB.error_code == Int16(0), "no-leapfrog: B error NONE")

    # (ii) the persisted state has BOTH members at gen 7 (co-exist at one gen).
    var st = _read_state(shared, cluster, group)
    _check(st.generation_id == Int32(7), "no-leapfrog: state gen still 7")
    _check(len(st.members) == 2, "no-leapfrog: 2 members co-exist")
    var both_at_7 = True
    for i in range(len(st.members)):
        if st.members[i].join_generation != Int32(7):
            both_at_7 = False
    _check(both_at_7, "no-leapfrog: both members at gen 7")

    # (iii) deterministic leader = lexicographically-smallest member at gen 7.
    var min_id = st.members[0].member_id.copy()
    for i in range(1, len(st.members)):
        if st.members[i].member_id < min_id:
            min_id = st.members[i].member_id.copy()
    _check(
        rB.leader_id == min_id,
        "no-leapfrog: leader is the min member_id at gen 7, got "
        + rB.leader_id,
    )
    # The leader is whichever member_id sorts first at gen 7; the OTHER member
    # is a follower (empty member list). Either way both co-exist at gen 7.
    print("PASS test_no_generation_leapfrog_when_already_preparing")


def _seeded_preparing_round(
    mut shared: SharedInMemoryConditionalStore,
    cluster: String,
    group: String,
    topics: List[String],
) raises:
    """(Re)seed the group at gen 3, PreparingRebalance, far-future deadline,
    members A + B both already at gen 3 (a fully-formed in-flight round). Models
    a peer broker's persisted state.json that a CAS-loser would RE-LOAD."""
    var path = Path.parse(_state_key(cluster, group))
    var members = List[GroupMember]()
    members.append(
        GroupMember(
            String("aaa-member"),
            _subscription_blob(topics),
            List[UInt8](),
            Int32(3),
        )
    )
    members.append(
        GroupMember(
            String("bbb-member"),
            _subscription_blob(topics),
            List[UInt8](),
            Int32(3),
        )
    )
    var seed = GroupState(
        Int32(3),
        String("aaa-member"),
        String("range"),
        String("consumer"),
        String(GROUP_STATE_PREPARING),
        Int64(1) << Int64(62),
        members^,
        String(""),
    )
    var body = encode_group_state_json(seed)
    # Overwrite whatever is there (create-if-absent first, else If-Match the
    # current etag) so each "re-load" starts from the IDENTICAL Preparing state.
    try:
        _ = shared.conditional_put(
            path, body.copy(), WritePrecondition.if_none_match_star()
        )
    except:
        var meta = shared.head(path)
        _ = shared.conditional_put(
            path, body.copy(), WritePrecondition.if_match(meta.etag.copy())
        )


def test_join_decision_idempotent_under_cas_retry() raises:
    # The bump-vs-join decision is a PURE function of the loaded `state`:
    # "state == PreparingRebalance => join at the CURRENT generation (no bump)".
    # It is therefore idempotent under CAS-retry — a CAS-loser that re-LOADS the
    # SAME Preparing state and re-DECIDES reaches the SAME no-bump outcome, with
    # the SAME deterministic leader, no matter who won the prior CAS.
    #
    # We model two deciders observing the IDENTICAL in-flight Preparing round by
    # re-seeding that exact state.json before each decide (the close advances the
    # round to Completing after a join, so a fresh re-seed is how we re-present
    # the "same loaded state" a CAS-loser would re-read).
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var cluster = String("test-cluster")
    var group = String("g2")

    var shared = SharedInMemoryConditionalStore()
    var coord = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock())

    # --- decider #1: re-load the Preparing@3 round, rejoin aaa-member. ---
    _seeded_preparing_round(shared, cluster, group, topics)
    var r1 = coord.join_group(
        group.copy(),
        String("aaa-member"),
        String("cli-a"),
        pnames,
        _subscription_blob(topics),
        Int32(300000),  # 5min — proves early-close (all@3), NOT the deadline
    )
    _check(
        r1.generation_id == Int32(3),
        "cas-idempotent: decider #1 keeps gen 3 (no bump), got "
        + String(r1.generation_id),
    )

    # --- decider #2: a CAS-loser re-LOADS the SAME Preparing@3 state and
    # re-DECIDES. The decision reads only `state`, so it ALSO keeps gen 3. ---
    _seeded_preparing_round(shared, cluster, group, topics)
    var r2 = coord.join_group(
        group.copy(),
        String("aaa-member"),
        String("cli-a"),
        pnames,
        _subscription_blob(topics),
        Int32(300000),
    )
    _check(
        r2.generation_id == Int32(3),
        "cas-idempotent: decider #2 (re-load + re-decide) STILL keeps gen 3"
        " — no double-bump, got " + String(r2.generation_id),
    )
    # The two re-decides agree on generation AND on the deterministic leader.
    _check(
        r1.generation_id == r2.generation_id,
        "cas-idempotent: re-decides agree on generation",
    )
    _check(
        r1.leader_id == r2.leader_id,
        "cas-idempotent: re-decides agree on leader",
    )
    _check(
        r2.leader_id == String("aaa-member"),
        "cas-idempotent: leader is the min member_id at gen 3, got "
        + r2.leader_id,
    )
    # And exactly the seeded members co-exist (the rejoin refreshed, not dup'd).
    var st = _read_state(shared, cluster, group)
    _check(
        len(st.members) == 2,
        "cas-idempotent: still exactly 2 members (rejoin refreshed, no dup)",
    )
    print("PASS test_join_decision_idempotent_under_cas_retry")


def test_state_json_roundtrip() raises:
    # The state.json encode/parse round-trips (incl. members + hex blobs).
    var c = _new_coordinator()
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    _ = c.join_group(
        String("grp"),
        String(""),
        String("cc"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    var st = _state(c, String("grp"))
    var body = encode_group_state_json(st)
    var rt = decode_group_state_json(body, String('"etag-99"'))
    _check(rt.generation_id == st.generation_id, "json: gen")
    _check(rt.leader_member_id == st.leader_member_id, "json: leader")
    _check(rt.protocol == st.protocol, "json: protocol")
    _check(rt.state == st.state, "json: state")
    _check(len(rt.members) == len(st.members), "json: member count")
    _check(
        rt.members[0].member_id == st.members[0].member_id, "json: member id"
    )
    # Subscription blob bytes survive the hex round-trip.
    _check(
        len(rt.members[0].subscription) == len(st.members[0].subscription),
        "json: subscription len",
    )
    _check(rt.etag == String('"etag-99"'), "json: etag carried")
    print("PASS test_state_json_roundtrip")


def main() raises:
    # A) RangeAssignor
    test_range_assign_even()
    test_range_assign_uneven()
    test_range_assign_more_members_than_partitions()
    test_range_assign_single_member_all()
    # B) state machine
    test_join_mints_member_id_and_first_generation()
    test_state_transitions_to_completing_after_join()
    test_sync_leader_stores_then_member_reads()
    test_heartbeat_none_when_stable_then_illegal_generation()
    test_heartbeat_codes_and_liveness_stamp()
    test_leave_bumps_generation_and_preparing()
    test_leave_last_member_goes_empty()
    test_sole_member_join_closes_without_waiting()
    test_join_waits_for_the_deadline_on_the_manual_clock()
    test_two_member_split_then_one_leaves_gets_all()
    test_no_generation_leapfrog_when_already_preparing()
    test_join_decision_idempotent_under_cas_retry()
    test_state_json_roundtrip()
    print("ALL PASS test_kafka_rebalance")
