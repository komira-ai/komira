# =============================================================================
# tests/test_kafka_rebalance_convergence_race.mojo
#   A stale member id never inflates the leader's split: two members converge to
#   a disjoint cover of all partitions.
#
# THE PROPERTY. The leader computes the range split over the member list in its
#   JoinGroup response, then SyncGroups the result. When a consumer reconnects
#   under a new member id, its old id stays in state.json. If a round carried
#   that stale id forward as long as it was nominally inside the session window,
#   the leader's view would hold an extra member: 6 partitions over 3 ids is
#   [0,1] / [2,3] / [4,5], the real member that sorts to the middle gets the
#   wrong subset, the stale id's slice is assigned to nobody, and the group
#   stays on that subset.
#
# WHAT STOPS IT, two defenses, each tested here:
#   (1) Ghost reap at reconcile: state.json carries round_opened_ms, the instant
#       the current round opened. An older-generation member is carried forward
#       at the close only if it was active (join or heartbeat refreshing
#       last_active_ms) within GHOST_STALE_GRACE_MS of that instant. A stale id
#       whose last_active predates the round is reaped, even inside the session
#       window.
#   (2) Valid-cover completion at sync_group: a leader's SyncGroup is rejected
#       (REBALANCE_IN_PROGRESS) if its assignment gives a partition to a member
#       that is not at the current generation, assigns a partition twice, or
#       leaves a gap in 0..max. The leader then rejoins and splits again over
#       the member set without the stale id.
#
# DETERMINISM. Each coordinator reads a ManualGroupClock that the test sets, and
#   the coordinators share one store (the cross-broker substrate). The test
#   orders every call explicitly: no threads, no sleep, no wall clock.
# =============================================================================

from komira_kafka_broker.group_assignor import (
    range_assign,
)
from komira_kafka_broker.group_coordinator import (
    GroupCoordinator,
)
from komira_kafka_broker.group_state import (
    GroupState,
    GroupMember,
    encode_group_state_json,
    decode_group_state_json,
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
    ERROR_REBALANCE_IN_PROGRESS,
    CONSUMER_PROTOCOL_VERSION,
    AssignedTopicPartitions,
    encode_consumer_assignment,
    decode_consumer_assignment,
)


comptime TestCoordinator = GroupCoordinator[
    SharedInMemoryConditionalStore, ManualGroupClock
]


def _fail(msg: String) raises:
    raise Error("FAIL: " + msg)


def _check(cond: Bool, msg: String) raises:
    if not cond:
        _fail(msg)


def _subscription_blob(topics: List[String]) -> List[UInt8]:
    var enc = KafkaEncoder()
    enc.put_int16(CONSUMER_PROTOCOL_VERSION)
    enc.put_array_len(len(topics))
    for i in range(len(topics)):
        enc.put_string(topics[i])
    enc.put_int32(Int32(-1))  # UserData null
    return enc.take_bytes()


def _state_key(cluster: String, group: String) -> String:
    return cluster + String("/_meta/groups/") + group + String("/state.json")


def _seed(
    mut store: SharedInMemoryConditionalStore,
    cluster: String,
    group: String,
    st: GroupState,
) raises:
    var path = Path.parse(_state_key(cluster, group))
    var body = encode_group_state_json(st)
    _ = store.conditional_put(
        path, body^, WritePrecondition.if_none_match_star()
    )


def _read(
    mut store: SharedInMemoryConditionalStore, cluster: String, group: String
) raises -> GroupState:
    var path = Path.parse(_state_key(cluster, group))
    var meta = store.head(path)
    var body = store.get(path)
    return decode_group_state_json(body^, meta.etag.copy())


# A leader's SyncGroup over an EXPLICIT member-id view (which may include a
# ghost). Mirrors a real client leader: sort ascending, RangeAssignor
# split, submit per-member assignment blobs.
def _leader_sync_over(
    mut coord: TestCoordinator,
    group: String,
    leader_id: String,
    generation: Int32,
    member_ids_in: List[String],
    topic: String,
    n_parts: Int,
) raises -> Int16:
    var ids = List[String]()
    for i in range(len(member_ids_in)):
        ids.append(member_ids_in[i].copy())
    var n = len(ids)
    for i in range(1, n):
        var j = i
        while j > 0 and ids[j - 1] > ids[j]:
            var tmp = ids[j - 1].copy()
            ids[j - 1] = ids[j].copy()
            ids[j] = tmp^
            j -= 1
    var split = range_assign(ids, topic, n_parts)
    var asg_ids = List[String]()
    var asg_blobs = List[List[UInt8]]()
    for mi in range(len(ids)):
        asg_ids.append(ids[mi].copy())
        var one = List[AssignedTopicPartitions]()
        one.append(split[mi].copy())  # positionally aligned to ids
        asg_blobs.append(encode_consumer_assignment(one))
    var out = coord.sync_group(
        group, leader_id.copy(), generation, asg_ids, asg_blobs
    )
    return out[1]


# Assert exactly 2 members are at the current generation and the stored
# assignments are a disjoint full cover of all n_parts.
def _assert_two_member_full_cover(
    mut store: SharedInMemoryConditionalStore,
    cluster: String,
    group: String,
    n_parts: Int,
    label: String,
) raises:
    var st = _read(store, cluster, group)
    var gen = st.generation_id
    var n_at_gen = 0
    for i in range(len(st.members)):
        if st.members[i].join_generation == gen:
            n_at_gen += 1
    _check(
        n_at_gen == 2,
        label + ": expected exactly 2 members at the current generation "
        + String(gen) + ", got " + String(n_at_gen),
    )
    var seen = List[Int]()
    for _ in range(n_parts):
        seen.append(0)
    for i in range(len(st.members)):
        if st.members[i].join_generation != gen:
            continue
        _check(
            len(st.members[i].assignment) > 0,
            label + ": member " + st.members[i].member_id
            + " at the current generation has an EMPTY assignment",
        )
        var dec = decode_consumer_assignment(st.members[i].assignment)
        for ti in range(len(dec)):
            for pi in range(len(dec[ti].partitions)):
                var p = Int(dec[ti].partitions[pi])
                _check(
                    p >= 0 and p < n_parts,
                    label + ": partition " + String(p) + " out of range",
                )
                seen[p] += 1
    for p in range(n_parts):
        _check(
            seen[p] == 1,
            label + ": partition " + String(p) + " owned by EXACTLY one"
            " member, got count " + String(seen[p]),
        )


# =============================================================================
# REPRODUCER 1 — a stale GHOST id (left behind by a consumer that reconnected
# under a new member_id) must be REAPED at reconcile so it cannot inflate the
# leader's split. Drives the ghost through the real join/reconcile path.
# =============================================================================


def test_ghost_member_reaped_at_reconcile() raises:
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var cluster = String("test-cluster")
    var group = String("g-ghost")
    var n_parts = 6

    var T0 = Int64(7_000_000)
    var SESSION = Int64(10000)  # 10s session window (generous)

    var shared = SharedInMemoryConditionalStore()
    var coord = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock(), String("n1"))

    # Seed a Stable@1 group whose membership carries a STALE GHOST id
    # ("real-a-old") left behind by the real consumer when it reconnected under
    # a new id. The ghost's last_active is T0 - 8s: still inside the 10s session
    # window (so the OLD session-only rule would PROMOTE it forward), but it has
    # NOT re-confirmed in a long while. The live consumer "real-b" is the other
    # member. round_opened_ms = 0 in the seed (legacy stamp); the join below
    # opens a NEW round and stamps round_opened_ms = now, AFTER the ghost's
    # last_active -> the ghost fails the re-confirm test and is reaped.
    var members = List[GroupMember]()
    members.append(
        GroupMember(String("real-a-old"), _subscription_blob(topics),
                    List[UInt8](), Int32(1), T0 - Int64(8000))  # stale, alive
    )
    members.append(
        GroupMember(String("real-b"), _subscription_blob(topics),
                    List[UInt8](), Int32(1), T0 - Int64(50))  # fresh
    )
    var seed = GroupState(
        Int32(1),
        String("real-a-old"),
        String("range"),
        String("consumer"),
        String(GROUP_STATE_STABLE),
        T0,
        members^,
        String(""),
        SESSION,
        Int64(0),  # legacy: no round-open stamp yet
    )
    _seed(shared, cluster, group, seed)

    # The live consumer "real-b" rejoins (its heartbeat saw a stale generation).
    # This OPENS gen 2 (Stable -> new round) and stamps round_opened_ms = now.
    # rebalance_timeout 0 => the deadline fires immediately; the close-time reconcile
    # runs with the ghost still @gen1. The ghost's last_active (T0-8s) predates
    # round_opened_ms (T0) -> REAPED. real-b is fresh and at the new gen.
    coord.clock.set(T0)
    var rB = coord.join_group(
        group.copy(),
        String("real-b"),
        String("client-b"),
        pnames,
        _subscription_blob(topics),
        Int32(0),  # deadline fires immediately
        Int32(6000),
    )
    _check(rB.error_code == Int16(0), "ghost: B rejoin error NONE")
    _check(rB.generation_id == Int32(2), "ghost: B opened gen 2, got "
        + String(rB.generation_id))

    # THE KEYSTONE: the stale ghost id is GONE — only the live consumer remains
    # at the new generation. A reconcile that only checked the session would have promoted it to gen 2 (it
    # was session-alive), giving a 2-id view where the real split would be wrong.
    var st = _read(shared, cluster, group)
    var saw_ghost = False
    var n_at_2 = 0
    for i in range(len(st.members)):
        if st.members[i].member_id == String("real-a-old"):
            saw_ghost = True
        if st.members[i].join_generation == Int32(2):
            n_at_2 += 1
    _check(
        not saw_ghost,
        "ghost: the stale id real-a-old must be REAPED (not promoted forward)",
    )
    _check(
        n_at_2 == 1,
        "ghost: exactly the live consumer remains at gen 2, got "
        + String(n_at_2),
    )
    _ = n_parts
    print("PASS test_ghost_member_reaped_at_reconcile")


def test_alive_lagging_incumbent_still_carried_forward() raises:
    # POSITIVE CONTROL for the ghost reap: a GENUINE lagging incumbent that keeps
    # HEARTBEATING into the current round (its last_active is refreshed AFTER the
    # round opened) must STILL be carried forward — the reap must not drop a real
    # participating member. This is the deadline-race promotion behavior the
    # ghost reap must preserve.
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var cluster = String("test-cluster")
    var group = String("g-lag")

    var T0 = Int64(8_000_000)
    var SESSION = Int64(10000)

    var shared = SharedInMemoryConditionalStore()
    var coord = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock(), String("n1"))

    # Seed Stable@1: incumbent A@1 (will lag) + nothing else. A is alive.
    var members = List[GroupMember]()
    members.append(
        GroupMember(String("member-a"), _subscription_blob(topics),
                    List[UInt8](), Int32(1), T0 - Int64(50))
    )
    var seed = GroupState(
        Int32(1),
        String("member-a"),
        String("range"),
        String("consumer"),
        String(GROUP_STATE_STABLE),
        T0,
        members^,
        String(""),
        SESSION,
        Int64(0),
    )
    _seed(shared, cluster, group, seed)

    # B joins -> opens gen 2 at now=T0+100 (round_opened_ms = T0+100). The
    # deadline fires immediately. A is at gen 1 and its last_active (T0-50)
    # PRE-dates round_opened... BUT A keeps heartbeating: we refresh A's liveness
    # via a heartbeat AT/AFTER the round opens so it is re-confirmed. We model
    # that by heartbeating A right after B opens the round, then re-driving the
    # reconcile via A's own rejoin. The clean way: B opens the round, A heartbeats
    # (refreshing last_active to now >= round_opened), then a re-trigger of
    # reconcile (any join) carries A forward.
    coord.clock.set(T0 + Int64(100))
    var rB = coord.join_group(
        group.copy(), String(""), String("client-b"), pnames,
        _subscription_blob(topics), Int32(0), Int32(6000),
    )
    _check(rB.error_code == Int16(0), "lag: B join NONE")
    # A heartbeats AFTER the round opened -> last_active refreshed to now, which
    # is >= round_opened_ms. A is now a re-confirmed lagging incumbent.
    coord.clock.set(T0 + Int64(150))
    _ = coord.heartbeat(group.copy(), String("member-a"), Int32(1))
    # A rejoins into the open round (re-trigger reconcile). A is re-confirmed, so
    # it is carried forward, NOT reaped.
    coord.clock.set(T0 + Int64(200))
    var rA = coord.join_group(
        group.copy(), String("member-a"), String("client-a"), pnames,
        _subscription_blob(topics), Int32(0), Int32(6000),
    )
    _check(rA.error_code == Int16(0), "lag: A rejoin NONE")

    var st = _read(shared, cluster, group)
    var saw_a = False
    var saw_b = False
    var gen = st.generation_id
    for i in range(len(st.members)):
        if st.members[i].join_generation != gen:
            continue
        if st.members[i].member_id == String("member-a"):
            saw_a = True
        else:
            saw_b = True
    _check(saw_a, "lag: the re-confirmed lagging incumbent A is carried forward")
    _check(saw_b, "lag: the joiner B is present")
    print("PASS test_alive_lagging_incumbent_still_carried_forward")


# =============================================================================
# REPRODUCER 2 — a leader's SyncGroup that hands a slice to a member NOT at the
# current generation (a ghost slice) must be REJECTED (defense-in-depth, in case
# the ghost survives the reconcile on some interleaving).
# =============================================================================


def test_ghost_slice_syncgroup_is_rejected() raises:
    var topics = List[String]()
    topics.append(String("t1"))
    var cluster = String("test-cluster")
    var group = String("g-slice")
    var topic = String("t1")
    var n_parts = 6

    var T0 = Int64(9_000_000)
    var SESSION = Int64(6000)

    var shared = SharedInMemoryConditionalStore()
    var node1 = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock(), String("n1"))
    node1.clock.set(T0)

    # Two REAL members at gen 5 (current) + a ghost id at an OLDER gen 4 (stale).
    # The leader's split (computed before the ghost aged out) hands [0,1] to the
    # ghost. The ghost is NOT at the current generation -> its slice is dead.
    var members = List[GroupMember]()
    members.append(
        GroupMember(String("ghost-old"), _subscription_blob(topics),
                    List[UInt8](), Int32(4), T0 - Int64(100))  # OLDER gen
    )
    members.append(
        GroupMember(String("real-a"), _subscription_blob(topics),
                    List[UInt8](), Int32(5), T0)
    )
    members.append(
        GroupMember(String("real-b"), _subscription_blob(topics),
                    List[UInt8](), Int32(5), T0)
    )
    var seed = GroupState(
        Int32(5),
        String("real-a"),
        String("range"),
        String("consumer"),
        String(GROUP_STATE_COMPLETING),
        Int64(1) << Int64(62),
        members^,
        String(""),
        SESSION,
        T0 - Int64(200),  # round opened before now
    )
    _seed(shared, cluster, group, seed)

    # The leader submits a 3-way split that includes the ghost (NOT at gen 5).
    var over_ids = List[String]()
    over_ids.append(String("ghost-old"))
    over_ids.append(String("real-a"))
    over_ids.append(String("real-b"))
    var rc = _leader_sync_over(
        node1, group.copy(), String("real-a"), Int32(5), over_ids,
        topic.copy(), n_parts,
    )
    _check(
        rc == ERROR_REBALANCE_IN_PROGRESS,
        "ghost-slice: a SyncGroup handing a slice to a member NOT at the current"
        " generation must be REJECTED, got rc=" + String(rc),
    )
    var st = _read(shared, cluster, group)
    _check(
        st.state != String(GROUP_STATE_STABLE),
        "ghost-slice: the over-split must NOT land Stable",
    )
    print("PASS test_ghost_slice_syncgroup_is_rejected")


def test_gap_cover_syncgroup_is_rejected() raises:
    # A gap in the cover: the leader over-split 6 partitions
    # across 3 ids where the MIDDLE id is a GHOST promoted into the current
    # generation, so the real members got [0,1] and [4,5] and [2,3] was DROPPED
    # (A|B = {0,1,4,5}, a gap at 2,3). Even though both real members ARE at the
    # current generation and the assignment is disjoint, the union has a GAP and
    # those partitions are never consumed. The gap-free cover guard must reject
    # this so the leader rejoins and re-runs the assignor over the de-ghosted
    # set. We drive the post-reap leader view directly: real-a -> [0,1],
    # real-b -> [4,5] (the ghost's [2,3] is simply absent from what the live
    # members submit), reproducing the dropped-middle gap.
    var topics = List[String]()
    topics.append(String("t1"))
    var cluster = String("test-cluster")
    var group = String("g-gap")
    var topic = String("t1")

    var T0 = Int64(14_000_000)
    var SESSION = Int64(6000)

    var shared = SharedInMemoryConditionalStore()
    var node1 = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock(), String("n1"))
    node1.clock.set(T0)

    var members = List[GroupMember]()
    members.append(
        GroupMember(String("real-a"), _subscription_blob(topics),
                    List[UInt8](), Int32(7), T0)
    )
    members.append(
        GroupMember(String("real-b"), _subscription_blob(topics),
                    List[UInt8](), Int32(7), T0)
    )
    var seed = GroupState(
        Int32(7),
        String("real-a"),
        String("range"),
        String("consumer"),
        String(GROUP_STATE_COMPLETING),
        Int64(1) << Int64(62),
        members^,
        String(""),
        SESSION,
        T0 - Int64(200),
    )
    _seed(shared, cluster, group, seed)

    # real-a -> [0,1], real-b -> [4,5]; [2,3] dropped (the ghost's dead slice).
    var asg_ids = List[String]()
    var asg_blobs = List[List[UInt8]]()
    var pa = List[Int32]()
    pa.append(Int32(0)); pa.append(Int32(1))
    var oa = List[AssignedTopicPartitions]()
    oa.append(AssignedTopicPartitions(topic.copy(), pa^))
    asg_ids.append(String("real-a"))
    asg_blobs.append(encode_consumer_assignment(oa))
    var pb = List[Int32]()
    pb.append(Int32(4)); pb.append(Int32(5))  # 2,3 dropped
    var ob = List[AssignedTopicPartitions]()
    ob.append(AssignedTopicPartitions(topic.copy(), pb^))
    asg_ids.append(String("real-b"))
    asg_blobs.append(encode_consumer_assignment(ob))

    var out = node1.sync_group(
        group.copy(), String("real-a"), Int32(7), asg_ids, asg_blobs
    )
    _check(
        out[1] == ERROR_REBALANCE_IN_PROGRESS,
        "gap-cover: a SyncGroup whose union has a GAP (partitions 2,3 dropped on"
        " the floor) must be REJECTED, got rc=" + String(out[1]),
    )
    var st = _read(shared, cluster, group)
    _check(
        st.state != String(GROUP_STATE_STABLE),
        "gap-cover: a gap-cover split must NOT land Stable",
    )
    print("PASS test_gap_cover_syncgroup_is_rejected")


def test_double_assign_syncgroup_is_rejected() raises:
    # A leader split that DOUBLE-ASSIGNS a partition (two members claim the same
    # partition) must be rejected — a direct guard against the double-consume
    # data-correctness mode.
    var topics = List[String]()
    topics.append(String("t1"))
    var cluster = String("test-cluster")
    var group = String("g-dbl")
    var topic = String("t1")

    var T0 = Int64(11_000_000)
    var SESSION = Int64(6000)

    var shared = SharedInMemoryConditionalStore()
    var node1 = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock(), String("n1"))
    node1.clock.set(T0)

    var members = List[GroupMember]()
    members.append(
        GroupMember(String("aaa"), _subscription_blob(topics),
                    List[UInt8](), Int32(3), T0)
    )
    members.append(
        GroupMember(String("bbb"), _subscription_blob(topics),
                    List[UInt8](), Int32(3), T0)
    )
    var seed = GroupState(
        Int32(3),
        String("aaa"),
        String("range"),
        String("consumer"),
        String(GROUP_STATE_COMPLETING),
        Int64(1) << Int64(62),
        members^,
        String(""),
        SESSION,
        T0 - Int64(200),
    )
    _seed(shared, cluster, group, seed)

    # Both members get partition 2 (double-assign).
    var asg_ids = List[String]()
    var asg_blobs = List[List[UInt8]]()
    var pa = List[Int32]()
    pa.append(Int32(0)); pa.append(Int32(1)); pa.append(Int32(2))
    var oa = List[AssignedTopicPartitions]()
    oa.append(AssignedTopicPartitions(topic.copy(), pa^))
    asg_ids.append(String("aaa"))
    asg_blobs.append(encode_consumer_assignment(oa))
    var pb = List[Int32]()
    pb.append(Int32(2)); pb.append(Int32(3)); pb.append(Int32(4))  # 2 dup
    var ob = List[AssignedTopicPartitions]()
    ob.append(AssignedTopicPartitions(topic.copy(), pb^))
    asg_ids.append(String("bbb"))
    asg_blobs.append(encode_consumer_assignment(ob))

    var out = node1.sync_group(
        group.copy(), String("aaa"), Int32(3), asg_ids, asg_blobs
    )
    _check(
        out[1] == ERROR_REBALANCE_IN_PROGRESS,
        "double-assign: a SyncGroup that double-assigns partition 2 must be"
        " REJECTED, got rc=" + String(out[1]),
    )
    var st = _read(shared, cluster, group)
    _check(
        st.state != String(GROUP_STATE_STABLE),
        "double-assign: a double-assign split must NOT land Stable",
    )
    print("PASS test_double_assign_syncgroup_is_rejected")


# =============================================================================
# POSITIVE CONTROLS — the new guards must NOT over-reject the happy paths.
# =============================================================================


def test_correct_two_member_split_still_completes() raises:
    var topics = List[String]()
    topics.append(String("t1"))
    var cluster = String("test-cluster")
    var group = String("g-ok")
    var topic = String("t1")
    var n_parts = 6

    var T0 = Int64(12_000_000)
    var SESSION = Int64(6000)

    var shared = SharedInMemoryConditionalStore()
    var node1 = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock(), String("n1"))
    node1.clock.set(T0)

    var members = List[GroupMember]()
    members.append(
        GroupMember(String("m-aaa"), _subscription_blob(topics),
                    List[UInt8](), Int32(4), T0)
    )
    members.append(
        GroupMember(String("m-bbb"), _subscription_blob(topics),
                    List[UInt8](), Int32(4), T0)
    )
    var seed = GroupState(
        Int32(4),
        String("m-aaa"),
        String("range"),
        String("consumer"),
        String(GROUP_STATE_COMPLETING),
        Int64(1) << Int64(62),
        members^,
        String(""),
        SESSION,
        T0 - Int64(200),
    )
    _seed(shared, cluster, group, seed)

    var ids = List[String]()
    ids.append(String("m-aaa"))
    ids.append(String("m-bbb"))
    var rc = _leader_sync_over(
        node1, group.copy(), String("m-aaa"), Int32(4), ids,
        topic.copy(), n_parts,
    )
    _check(
        rc == Int16(0),
        "ok: a correct disjoint 2-member split must COMPLETE (NONE), got rc="
        + String(rc),
    )
    var st = _read(shared, cluster, group)
    _check(
        st.state == String(GROUP_STATE_STABLE),
        "ok: group Stable after the correct split, got " + st.state,
    )
    _assert_two_member_full_cover(shared, cluster, group, n_parts, "ok-cover")
    print("PASS test_correct_two_member_split_still_completes")


def test_single_member_full_cover_still_completes() raises:
    var topics = List[String]()
    topics.append(String("t1"))
    var cluster = String("test-cluster")
    var group = String("g-solo")
    var topic = String("t1")
    var n_parts = 6

    var T0 = Int64(13_000_000)
    var SESSION = Int64(6000)

    var shared = SharedInMemoryConditionalStore()
    var node1 = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock(), String("n1"))
    node1.clock.set(T0)

    var members = List[GroupMember]()
    members.append(
        GroupMember(String("solo"), _subscription_blob(topics),
                    List[UInt8](), Int32(1), T0)
    )
    var seed = GroupState(
        Int32(1),
        String("solo"),
        String("range"),
        String("consumer"),
        String(GROUP_STATE_COMPLETING),
        Int64(1) << Int64(62),
        members^,
        String(""),
        SESSION,
        T0 - Int64(200),
    )
    _seed(shared, cluster, group, seed)

    var ids = List[String]()
    ids.append(String("solo"))
    var rc = _leader_sync_over(
        node1, group.copy(), String("solo"), Int32(1), ids,
        topic.copy(), n_parts,
    )
    _check(
        rc == Int16(0),
        "solo: sole-member full-cover sync must COMPLETE, got rc=" + String(rc),
    )
    var st = _read(shared, cluster, group)
    _check(
        st.state == String(GROUP_STATE_STABLE),
        "solo: sole-member group Stable, got " + st.state,
    )
    var dec = decode_consumer_assignment(st.members[0].assignment)
    _check(len(dec) == 1 and len(dec[0].partitions) == n_parts,
        "solo: sole member owns all 6")
    print("PASS test_single_member_full_cover_still_completes")


def main() raises:
    test_ghost_member_reaped_at_reconcile()
    test_alive_lagging_incumbent_still_carried_forward()
    test_ghost_slice_syncgroup_is_rejected()
    test_gap_cover_syncgroup_is_rejected()
    test_double_assign_syncgroup_is_rejected()
    test_correct_two_member_split_still_completes()
    test_single_member_full_cover_still_completes()
    print("ALL PASS test_kafka_rebalance_convergence_race")
