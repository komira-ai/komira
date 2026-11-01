# =============================================================================
# tests/test_kafka_rebalance_deadline_race.mojo
#   A member whose session is alive is carried through a rebalance deadline; a
#   member whose session expired is dropped.
#
# THE SCENARIO. A alone is Stable at generation 1 and owns all 6 partitions. B
#   joins, so the group is Preparing at generation 2 with members [A@1, B@2]. A
#   is alive and heartbeating; it rejoins at generation 2 on its next
#   REBALANCE_IN_PROGRESS heartbeat. If the rebalance deadline passes before that
#   rejoin lands, the window closes with A still at generation 1. A close that
#   kept only members at the current generation would drop A, make B the sole
#   leader, and let B's split assign all 6 partitions to B: a double assign, an
#   empty member, or a partial assignment.
#
# THE PROPERTY (session-aware close). A member with
#   now - last_active_ms < session_timeout is never dropped at the deadline: the
#   close promotes it to the current generation, with its prior subscription,
#   before electing the leader. A member is evicted only when its session has
#   expired. A heartbeat refreshes last_active_ms, so a heartbeating member that
#   has not rejoined stays alive.
#
# DETERMINISM. Each coordinator reads a ManualGroupClock that the test sets. B
#   opens the round with rebalance_timeout_ms of 0, so the deadline is the
#   current instant and the window closes on the first poll with A still at the
#   old generation. The coordinators share one store clone, the cross-broker
#   substrate. No sleep, no threads, no wall clock.
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
    GROUP_STATE_STABLE,
    DEFAULT_SESSION_TIMEOUT_MS,
)
from komira_kafka_broker.group_clock import ManualGroupClock
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.types import WritePrecondition

from komira_kafka_server.wire import KafkaEncoder
from komira_kafka_server.wire.consumer_group import (
    CONSUMER_PROTOCOL_VERSION,
    encode_consumer_assignment,
    decode_consumer_assignment,
    AssignedTopicPartitions,
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


# =============================================================================
# THE reproducer: deadline fires while a session-alive incumbent lags.
# =============================================================================


def test_alive_incumbent_not_dropped_on_deadline() raises:
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var cluster = String("test-cluster")
    var group = String("g1")

    var T0 = Int64(1_000_000)
    var SESSION = Int64(10000)  # 10s session window (generous vs. the race)

    var shared = SharedInMemoryConditionalStore()
    var coord = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock())
    # Pin the clock 50ms after the incumbent's last activity — A is well inside
    # its 10s session window when B's join fires the deadline.
    coord.clock.set(T0 + Int64(50))

    # Seed: A@1 Stable owns all 6, last_active = T0 (alive baseline).
    var members = List[GroupMember]()
    members.append(
        GroupMember(
            String("member-a"),
            _subscription_blob(topics),
            List[UInt8](),
            Int32(1),  # join_generation 1 (the OLD generation)
            T0,  # last_active = T0 (50ms before "now" => alive)
        )
    )
    var seed = GroupState(
        Int32(1),
        String("member-a"),
        String("range"),
        String("consumer"),
        String(GROUP_STATE_STABLE),
        T0,  # (deadline irrelevant in Stable)
        members^,
        String(""),
        SESSION,
    )
    _seed(shared, cluster, group, seed)

    # B joins and OPENS a new round. rebalance_timeout_ms == 0 makes the
    # deadline == now, so the poll closes the window on the DEADLINE on the first
    # poll WITH A STILL @gen1 (A's heartbeat-driven rejoin has not landed). This
    # is the deadline race, fixed in order.
    var rB = coord.join_group(
        group.copy(),
        String(""),  # mint B
        String("client-b"),
        pnames,
        _subscription_blob(topics),
        Int32(0),  # rebalance_timeout 0 => deadline fires immediately
        Int32(6000),  # session_timeout the consumer negotiates (6s)
    )
    _check(rB.error_code == Int16(0), "deadline-race: B error NONE")
    _check(
        rB.generation_id == Int32(2),
        "deadline-race: B at gen 2 (bumped once), got "
        + String(rB.generation_id),
    )

    # THE FIX: the persisted state still has BOTH members, both at gen 2 — A was
    # PROMOTED (carried forward), NOT dropped on the deadline.
    var st = _read(shared, cluster, group)
    _check(
        len(st.members) == 2,
        "deadline-race: BOTH members survive the deadline close (A not"
        " dropped), got " + String(len(st.members)),
    )
    var saw_a = False
    var saw_b = False
    var both_at_2 = True
    for i in range(len(st.members)):
        if st.members[i].member_id == String("member-a"):
            saw_a = True
        else:
            saw_b = True
        if st.members[i].join_generation != Int32(2):
            both_at_2 = False
    _check(saw_a, "deadline-race: incumbent member-a still present")
    _check(saw_b, "deadline-race: joiner B present")
    _check(both_at_2, "deadline-race: BOTH members re-anchored to gen 2")

    # The leader must be a MEMBER at gen 2 (so the consistent-leader invariant
    # holds: every member echoes the same persisted leader). The carried-over
    # incumbent A was the seeded leader@1 and is promoted to gen 2, so the
    # keep-leader-if-still-a-member rule keeps A as leader — a valid, stable
    # anchor that prevents cross-node leader flapping. Whoever the leader is,
    # its member list must include BOTH members (a 2-member split), NOT a
    # single-member view that would assign one member everything.
    var leader_is_member = False
    for i in range(len(st.members)):
        if st.members[i].member_id == rB.leader_id:
            leader_is_member = True
    _check(
        leader_is_member,
        "deadline-race: leader is a member at gen 2, got " + rB.leader_id,
    )
    if rB.member_id == rB.leader_id:
        _check(
            len(rB.members) == 2,
            "deadline-race: leader B sees BOTH members (2-member split), got "
            + String(len(rB.members)),
        )
    # The persisted leader must equal the seeded incumbent A (kept, since A is
    # still a member at the new generation) — the stable-anchor behavior.
    _check(
        rB.leader_id == String("member-a"),
        "deadline-race: incumbent A stays leader (stable anchor), got "
        + rB.leader_id,
    )
    print("PASS test_alive_incumbent_not_dropped_on_deadline")


def test_expired_incumbent_evicted_on_deadline() raises:
    # The COMPLEMENT: an incumbent whose session HAS expired (no heartbeat /
    # rejoin within session_timeout) IS evicted on the deadline close — so the
    # group does not carry a genuinely-dead member forever.
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var cluster = String("test-cluster")
    var group = String("g3")

    var T0 = Int64(2_000_000)
    var SESSION = Int64(10000)  # 10s

    var shared = SharedInMemoryConditionalStore()
    var coord = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock())
    coord.clock.set(T0)

    # Seed: dead member A@1 (Stable), last_active = T0 - 60s (LONG expired).
    var members = List[GroupMember]()
    members.append(
        GroupMember(
            String("dead-a"),
            _subscription_blob(topics),
            List[UInt8](),
            Int32(1),
            T0 - Int64(60000),  # 60s ago >> 10s session => EXPIRED
        )
    )
    var seed = GroupState(
        Int32(1),
        String("dead-a"),
        String("range"),
        String("consumer"),
        String(GROUP_STATE_STABLE),
        T0,
        members^,
        String(""),
        SESSION,
    )
    _seed(shared, cluster, group, seed)

    # Live member B joins, opens a round, deadline fires immediately.
    var rB = coord.join_group(
        group.copy(),
        String(""),
        String("client-b"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
        Int32(6000),
    )
    _check(rB.error_code == Int16(0), "evict: B error NONE")
    var st = _read(shared, cluster, group)
    # The dead incumbent was evicted; only B remains, at the new generation.
    _check(
        len(st.members) == 1,
        "evict: expired incumbent dropped, only B remains, got "
        + String(len(st.members)),
    )
    _check(st.members[0].member_id != String("dead-a"), "evict: A is gone")
    _check(
        st.members[0].join_generation == rB.generation_id,
        "evict: survivor at the new generation",
    )
    print("PASS test_expired_incumbent_evicted_on_deadline")


def test_heartbeat_refreshes_liveness_keeps_incumbent_alive() raises:
    # An incumbent that is mid-rebalance (the group is Preparing, so its
    # heartbeat returns REBALANCE_IN_PROGRESS) BUT keeps heartbeating must stay
    # SESSION-ALIVE: the heartbeat refreshes last_active_ms. We verify the
    # refresh lands in the persisted state.
    var topics = List[String]()
    topics.append(String("t1"))
    var cluster = String("test-cluster")
    var group = String("g4")

    var T0 = Int64(3_000_000)
    var SESSION = Int64(10000)

    var shared = SharedInMemoryConditionalStore()
    var coord = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock())
    coord.clock.set(T0)

    # Seed: A@1, Stable, last_active = T0 - 5s (still alive but aging).
    var members = List[GroupMember]()
    members.append(
        GroupMember(
            String("member-a"),
            _subscription_blob(topics),
            List[UInt8](),
            Int32(1),
            T0 - Int64(5000),
        )
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
    )
    _seed(shared, cluster, group, seed)

    # A heartbeats at the current generation while Stable -> NONE, AND its
    # last_active is refreshed to "now" (T0).
    var hb = coord.heartbeat(group.copy(), String("member-a"), Int32(1))
    _check(hb == Int16(0), "hb-refresh: NONE when stable + gen matches")
    var st = _read(shared, cluster, group)
    _check(len(st.members) == 1, "hb-refresh: still 1 member")
    _check(
        st.members[0].last_active_ms == T0,
        "hb-refresh: last_active refreshed to now (T0), got "
        + String(st.members[0].last_active_ms),
    )
    print("PASS test_heartbeat_refreshes_liveness_keeps_incumbent_alive")


# =============================================================================
# CROSS-BROKER convergence, as an explicit sequence of calls.
#
# The failure to rule out is a double assign (A=[0..5] AND B=[0..5]). TWO coordinators (one per "broker") drive the SAME
# group over the SAME shared store. We model a consumer client's loop: the
# member whose JoinGroup response says leader==self computes the RangeAssignor
# split over the members it was given and SyncGroups them; a follower SyncGroups
# empty + reads its assignment back. We assert the group converges to ONE
# consistent leader whose member list covers BOTH members (a disjoint 2-member
# split), NEVER two solo leaders that each self-assign everything.
# =============================================================================


@fieldwise_init
struct JoinResultLite(Copyable, Movable, Deinitable):
    var member_id: String
    var generation_id: Int32
    var leader_id: String
    var members: List[String]


def _join(
    mut coord: TestCoordinator,
    group: String,
    member_id_in: String,
    client_id: String,
    topics: List[String],
    pnames: List[String],
    session_ms: Int32,
) raises -> JoinResultLite:
    """A JoinGroup with rebalance_timeout == 0 so the poll closes on the deadline
    at once. Returns a
    lite snapshot of the JoinGroup response."""
    var jr = coord.join_group(
        group.copy(),
        member_id_in.copy(),
        client_id.copy(),
        pnames,
        _subscription_blob(topics),
        Int32(0),  # deadline fires immediately => no blocking poll
        session_ms,
    )
    var member_list = List[String]()
    for i in range(len(jr.members)):
        member_list.append(jr.members[i].member_id.copy())
    return JoinResultLite(
        jr.member_id.copy(),
        jr.generation_id,
        jr.leader_id.copy(),
        member_list^,
    )


def _leader_sync(
    mut coord: TestCoordinator,
    group: String,
    jr: JoinResultLite,
    topic: String,
    num_partitions: Int,
) raises -> Int16:
    """The leader computes the RangeAssignor split over its member list +
    SyncGroups all assignments. Returns the sync error code."""
    var member_ids = jr.members.copy()
    var n = len(member_ids)
    for i in range(1, n):
        var j = i
        while j > 0 and member_ids[j - 1] > member_ids[j]:
            var tmp = member_ids[j - 1].copy()
            member_ids[j - 1] = member_ids[j].copy()
            member_ids[j] = tmp^
            j -= 1
    var split = range_assign(member_ids, topic, num_partitions)
    var asg_ids = List[String]()
    var asg_blobs = List[List[UInt8]]()
    for mi in range(len(member_ids)):
        asg_ids.append(member_ids[mi].copy())
        var one = List[AssignedTopicPartitions]()
        one.append(split[mi].copy())
        asg_blobs.append(encode_consumer_assignment(one))
    var sync = coord.sync_group(
        group.copy(),
        jr.member_id.copy(),
        jr.generation_id,
        asg_ids,
        asg_blobs,
    )
    return sync[1]


def test_cross_broker_converges_no_double_assign() raises:
    # The sequence, deterministic (rebalance_timeout=0 => the window closes
    # on the deadline on every join, with NO real poll). A forms the group alone
    # (broker1), goes Stable owning all 6. B joins (broker2). A rejoins
    # (broker1). They must converge to ONE leader + a disjoint 2-member split —
    # NOT two solo leaders each owning all 6 (a double assign). We drive
    # the steps in a non-blocking order: a follower never SyncGroups before the
    # leader has made the group Stable.
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var cluster = String("test-cluster")
    var group = String("gx")
    var P = 6
    var SESSION = Int32(6000)

    var T0 = Int64(5_000_000)
    var shared = SharedInMemoryConditionalStore()
    var coordA = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock())  # broker1
    var coordB = TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock())  # broker2
    coordA.clock.set(T0)
    coordB.clock.set(T0)

    # 1) A forms the group alone, becomes leader@1, syncs -> Stable, owns all 6.
    var ja0 = _join(
        coordA, group, String(""), String("cliA"), topics, pnames, SESSION
    )
    var a_id = ja0.member_id.copy()
    _check(ja0.leader_id == a_id, "xbroker: A is leader@1")
    _check(_leader_sync(coordA, group, ja0, topics[0], P) == Int16(0),
        "xbroker: A leader sync@1 NONE")

    # 2) B joins broker2 -> opens gen 2, deadline fires immediately. The
    #    session-aware close PROMOTES the alive incumbent A (A's last_active is
    #    T0, now is T0). B's JoinResult must name a leader that is a member at
    #    gen 2 AND (if B is leader) list BOTH members.
    coordB.clock.set(T0)  # A is alive (now == A.last_active)
    var jb1 = _join(
        coordB, group, String(""), String("cliB"), topics, pnames, SESSION
    )
    var b_id = jb1.member_id.copy()
    _check(jb1.generation_id == Int32(2), "xbroker: B opened gen 2")

    # 3) A rejoins broker1 into the gen-2 round (heartbeat told it REBALANCE).
    #    A's JoinResult at gen 2 names the SAME leader B saw + lists both.
    var ja1 = _join(
        coordA, group, a_id.copy(), String("cliA"), topics, pnames, SESSION
    )
    _check(ja1.generation_id == Int32(2), "xbroker: A rejoined at gen 2")

    # 4) CONSISTENT LEADER: A and B must agree on ONE leader at gen 2. (This is
    #    the anti-double-assign invariant: exactly one of them computes + stores
    #    the split.)
    _check(
        ja1.leader_id == jb1.leader_id,
        "xbroker: A and B agree on the SAME leader at gen 2 (A="
        + ja1.leader_id + " B=" + jb1.leader_id + ")",
    )
    var leader_id = ja1.leader_id.copy()

    # 5) The leader (whichever it is) computes + stores the split. We let the
    #    member whose latest JoinResult named itself leader do the sync; its
    #    member list must cover BOTH members.
    if leader_id == a_id:
        _check(len(ja1.members) == 2, "xbroker: leader A sees both members")
        _check(
            _leader_sync(coordA, group, ja1, topics[0], P) == Int16(0),
            "xbroker: leader A sync@2 NONE",
        )
    else:
        _check(len(jb1.members) == 2, "xbroker: leader B sees both members")
        # B is the leader; re-fetch B's JoinResult at gen 2 (its first join may
        # have predated A's promotion). A non-blocking re-join refreshes it.
        var jb2 = _join(
            coordB, group, b_id.copy(), String("cliB"), topics, pnames, SESSION
        )
        _check(len(jb2.members) == 2, "xbroker: leader B (refetch) sees both")
        _check(
            _leader_sync(coordB, group, jb2, topics[0], P) == Int16(0),
            "xbroker: leader B sync@2 NONE",
        )

    # Read the converged stable state directly + assert ONE leader, 2 members,
    # disjoint assignments covering all P partitions (the authoritative check).
    var st = _read(shared, cluster, group)
    _check(
        st.state == String(GROUP_STATE_STABLE),
        "xbroker: converged to Stable, got " + st.state,
    )
    _check(
        len(st.members) == 2,
        "xbroker: exactly 2 members at convergence, got "
        + String(len(st.members)),
    )
    # The stored assignments must be disjoint + cover all P partitions (no
    # double-assign). Decode each member's stored assignment.
    var seen = List[Int]()
    for _ in range(P):
        seen.append(0)
    var total = 0
    for mi in range(len(st.members)):
        if len(st.members[mi].assignment) > 0:
            var dec = decode_consumer_assignment(st.members[mi].assignment)
            for ti in range(len(dec)):
                for pi in range(len(dec[ti].partitions)):
                    var p = Int(dec[ti].partitions[pi])
                    if p >= 0 and p < P:
                        seen[p] += 1
                        total += 1
    _check(
        total == P,
        "xbroker: assignments cover exactly P partitions (no double-assign),"
        " got " + String(total),
    )
    for p in range(P):
        _check(
            seen[p] == 1,
            "xbroker: partition " + String(p) + " owned by EXACTLY one member,"
            " got count " + String(seen[p]),
        )
    print("PASS test_cross_broker_converges_no_double_assign")


def main() raises:
    test_alive_incumbent_not_dropped_on_deadline()
    test_expired_incumbent_evicted_on_deadline()
    test_heartbeat_refreshes_liveness_keeps_incumbent_alive()
    test_cross_broker_converges_no_double_assign()
    print("ALL PASS test_kafka_rebalance_deadline_race")
