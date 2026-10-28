# =============================================================================
# tests/test_kafka_rebalance_leapfrog_race.mojo
#   A leader's SyncGroup cannot complete a round with a stale member set: a
#   member that joined the same generation is never left with an empty
#   assignment.
#
# THE INTERLEAVING (two broker nodes over one shared state.json):
#   1. Member A joins, the window closes, A is elected leader at generation G and
#      the group goes CompletingRebalance, with the member list A saw = [A].
#   2. Before A's SyncGroup lands, member B joins at the other node. B loads
#      Completing@G, sees a round is open, joins at G without a bump, and
#      reopens the round Completing -> Preparing with members [A@G, B@G].
#   3. A's SyncGroup@G lands. A guard on the generation alone passes (B is at G),
#      so A's assignment, which names only A, would flip the group to Stable@G
#      with B's assignment empty, and B would get no partition.
#
# THE PROPERTY. A leader's SyncGroup may complete a round only for the current
#   member set. If the round was reopened (the state is back to Preparing), or a
#   member at the current generation is not covered by the leader's assignment
#   list, the leader is told to rejoin (REBALANCE_IN_PROGRESS). It rejoins,
#   sees the full member set and splits again, so both members converge to one
#   generation with a disjoint cover of all 6 partitions.
#
# DETERMINISM. Two coordinators, each on its own ManualGroupClock, share one
#   store, and the test injects the peer's registration at the exact phase
#   boundary. No threads, no sleep, no wall clock.
# =============================================================================

from komira_kafka_broker.group_assignor import (
    range_assign,
)
from komira_kafka_broker.group_coordinator import (
    GroupCoordinator,
)
from komira_kafka_broker.group_state import (
    GroupState,
    decode_group_state_json,
    GROUP_STATE_COMPLETING,
    GROUP_STATE_STABLE,
)
from komira_kafka_broker.group_clock import ManualGroupClock
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path

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


def _read(
    mut store: SharedInMemoryConditionalStore, cluster: String, group: String
) raises -> GroupState:
    var path = Path.parse(_state_key(cluster, group))
    var meta = store.head(path)
    var body = store.get(path)
    return decode_group_state_json(body^, meta.etag.copy())


def _coord_on(
    shared: SharedInMemoryConditionalStore, cluster: String, node: String
) raises -> TestCoordinator:
    """A coordinator bound to the SHARED store under a node token (so two
    coordinators mint globally-unique member ids exactly like two brokers)."""
    return TestCoordinator(shared.clone(), cluster.copy(), ManualGroupClock(), node.copy())


# Run a leader's SyncGroup for the members CURRENTLY at `generation`, using the
# RangeAssignor (mirrors a real consumer-group leader's SyncGroup).
def _leader_sync_range(
    mut coord: TestCoordinator,
    group: String,
    leader_id: String,
    generation: Int32,
    member_ids_in: List[String],
    topic: String,
    n_parts: Int,
) raises -> Int16:
    # Sort the leader's member view ascending (the assignor order).
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
    var out = coord.sync_group(group, leader_id.copy(), generation, asg_ids, asg_blobs)
    return out[1]


# Assert every member at the current generation has a non-empty assignment and
# the union covers all n_parts exactly once (disjoint + complete).
def _assert_disjoint_full_cover(
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
        n_at_gen >= 2,
        label
        + ": expected >=2 members at the current generation "
        + String(gen)
        + ", got "
        + String(n_at_gen),
    )
    var seen = List[Bool]()
    for _ in range(n_parts):
        seen.append(False)
    var total = 0
    for i in range(len(st.members)):
        if st.members[i].join_generation != gen:
            continue
        _check(
            len(st.members[i].assignment) > 0,
            label
            + ": member "
            + st.members[i].member_id
            + " at the current generation has an EMPTY assignment (got no"
            " partitions)",
        )
        var dec = decode_consumer_assignment(st.members[i].assignment)
        for ti in range(len(dec)):
            for pi in range(len(dec[ti].partitions)):
                var p = Int(dec[ti].partitions[pi])
                _check(
                    p >= 0 and p < n_parts,
                    label + ": partition " + String(p) + " out of range",
                )
                _check(
                    not seen[p],
                    label
                    + ": partition "
                    + String(p)
                    + " double-assigned across members",
                )
                seen[p] = True
                total += 1
    _check(
        total == n_parts,
        label
        + ": combined assignment covers "
        + String(total)
        + " of "
        + String(n_parts)
        + " partitions",
    )


# =============================================================================
# THE REPRODUCER — a stale leader SyncGroup must not complete a re-opened round
# to Stable with a member left unassigned.
# =============================================================================


def test_stale_leader_syncgroup_does_not_strand_a_member() raises:
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var cluster = String("test-cluster")
    var group = String("g-leap")
    var topic = String("t1")
    var n_parts = 6

    var shared = SharedInMemoryConditionalStore()
    var node1 = _coord_on(shared, cluster, String("n1"))
    var node2 = _coord_on(shared, cluster, String("n2"))
    var t0 = Int64(1_000_000)
    node1.clock.set(t0)
    node2.clock.set(t0)

    # --- step 1: member A joins at node-1 (brand-new group). The window closes
    # on the deadline (rebalance_timeout 0) -> the close elects A leader@gen1 and
    # goes Completing with the member list the leader saw = [A]. ---
    var rA = node1.join_group(
        group.copy(),
        String(""),  # mint A
        String("client-a"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    _check(rA.error_code == Int16(0), "race: A join error NONE")
    var a_id = rA.member_id.copy()
    var gen = rA.generation_id
    var st1 = _read(shared, cluster, group)
    _check(
        st1.state == String(GROUP_STATE_COMPLETING),
        "race: group Completing after A's join, got " + st1.state,
    )
    _check(rA.leader_id == a_id, "race: A is the leader of gen " + String(gen))

    # --- step 2: BEFORE A's SyncGroup lands, member B joins at node-2. B loads
    # Completing@gen, sees a round is open, JOINS at the SAME generation (no
    # bump, per the bump-once fix) and RE-OPENS the round Completing->Preparing
    # with members = [A@gen, B@gen]. ---
    var rB = node2.join_group(
        group.copy(),
        String(""),  # mint B
        String("client-b"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    _check(rB.error_code == Int16(0), "race: B join error NONE")
    var b_id = rB.member_id.copy()
    _check(
        rB.generation_id == gen,
        "race: B joins AT gen " + String(gen) + " (no bump), got "
        + String(rB.generation_id),
    )
    var st2 = _read(shared, cluster, group)
    _check(
        len(st2.members) == 2,
        "race: both A and B recorded at gen " + String(gen),
    )

    # --- step 3: A's STALE SyncGroup@gen lands now. The leader A computed its
    # assignment from the [A]-only view it saw at step 1 (it never saw B). It
    # SyncGroups ONLY A's assignment (A = all 6). With the generation match as the only
    # guard (still `gen`), it would clobber the re-opened
    # round to Stable@gen with B unassigned. ---
    var a_only = List[String]()
    a_only.append(a_id.copy())
    var a_sync_rc = _leader_sync_range(
        node1, group.copy(), a_id.copy(), gen, a_only, topic.copy(), n_parts
    )

    # THE KEYSTONE: the stale SyncGroup MUST be rejected (the leader is told to
    # rejoin) rather than completing the round with B stranded. After the fix,
    # the leader rejoins, sees [A, B], and re-runs the assignor over BOTH.
    _check(
        a_sync_rc == ERROR_REBALANCE_IN_PROGRESS,
        "race: a STALE leader SyncGroup (member set changed under it) must be"
        " REJECTED with REBALANCE_IN_PROGRESS, got rc=" + String(a_sync_rc),
    )

    # The group must NOT be Stable with B stranded. (Either still mid-rebalance,
    # or Stable only once B is covered — the cover assertion below enforces it.)
    var st3 = _read(shared, cluster, group)
    if st3.state == String(GROUP_STATE_STABLE):
        # If it DID go Stable, every member must be covered (no strand).
        _assert_disjoint_full_cover(
            shared, cluster, group, n_parts, "race-premature-stable"
        )

    # --- step 4: the leader rejoins (it got REBALANCE_IN_PROGRESS) and now
    # re-runs the assignor over the FULL member set [A, B]; the round completes
    # to a disjoint full cover. We drive that recovery explicitly. ---
    var rA2 = node1.join_group(
        group.copy(),
        a_id.copy(),
        String("client-a"),
        pnames,
        _subscription_blob(topics),
        Int32(0),
    )
    _check(rA2.error_code == Int16(0), "race: A rejoin error NONE")
    var cur = _read(shared, cluster, group)
    var leader_now = cur.leader_member_id.copy()
    var both = List[String]()
    for i in range(len(cur.members)):
        if cur.members[i].join_generation == cur.generation_id:
            both.append(cur.members[i].member_id.copy())
    # Whoever the leader is at the current generation completes the round.
    if leader_now == a_id:
        _ = _leader_sync_range(
            node1, group.copy(), leader_now.copy(), cur.generation_id,
            both, topic.copy(), n_parts,
        )
    else:
        _ = _leader_sync_range(
            node2, group.copy(), leader_now.copy(), cur.generation_id,
            both, topic.copy(), n_parts,
        )

    # CONVERGENCE: both members co-exist at ONE generation with a disjoint full
    # cover of all 6 partitions — neither is stranded.
    _assert_disjoint_full_cover(
        shared, cluster, group, n_parts, "race-converge"
    )
    _ = b_id
    print("PASS test_stale_leader_syncgroup_does_not_strand_a_member")


def test_full_coverage_leader_syncgroup_completes_normally() raises:
    # POSITIVE CONTROL: the membership-aware SyncGroup guard must NOT over-reject.
    # A leader whose assignment list covers EVERY member at the generation
    # completes the round to Stable normally (the common 2-member case). This is
    # the guard's "don't break the happy path" companion to the strand reproducer.
    var topics = List[String]()
    topics.append(String("t1"))
    var pnames = List[String]()
    pnames.append(String("range"))
    var cluster = String("test-cluster")
    var group = String("g-ok")
    var topic = String("t1")
    var n_parts = 6

    var shared = SharedInMemoryConditionalStore()
    var node1 = _coord_on(shared, cluster, String("n1"))
    var node2 = _coord_on(shared, cluster, String("n2"))
    node1.clock.set(Int64(1_000_000))
    node2.clock.set(Int64(1_000_000))

    # A then B join; A rejoins to catch up to the current generation. The result
    # is a fully-formed 2-member round at one generation (both recorded).
    var rA = node1.join_group(
        group.copy(), String(""), String("client-a"), pnames,
        _subscription_blob(topics), Int32(0),
    )
    var a_id = rA.member_id.copy()
    var rB = node2.join_group(
        group.copy(), String(""), String("client-b"), pnames,
        _subscription_blob(topics), Int32(0),
    )
    var b_id = rB.member_id.copy()
    # A rejoins so it is at the current generation too (mirrors the heartbeat
    # REBALANCE_IN_PROGRESS rejoin).
    var rA2 = node1.join_group(
        group.copy(), a_id.copy(), String("client-a"), pnames,
        _subscription_blob(topics), Int32(0),
    )
    _check(rA2.error_code == Int16(0), "ok: A rejoin error NONE")

    var cur = _read(shared, cluster, group)
    var gen = cur.generation_id
    var leader_now = cur.leader_member_id.copy()
    var all_ids = List[String]()
    for i in range(len(cur.members)):
        if cur.members[i].join_generation == gen:
            all_ids.append(cur.members[i].member_id.copy())
    _check(len(all_ids) == 2, "ok: both members at the generation")

    # The leader SyncGroups the FULL set -> NONE, group goes Stable, disjoint
    # full cover. (Not REBALANCE_IN_PROGRESS — the guard must allow this.)
    var rc: Int16
    if leader_now == a_id:
        rc = _leader_sync_range(
            node1, group.copy(), leader_now.copy(), gen, all_ids,
            topic.copy(), n_parts,
        )
    else:
        rc = _leader_sync_range(
            node2, group.copy(), leader_now.copy(), gen, all_ids,
            topic.copy(), n_parts,
        )
    _check(
        rc == Int16(0),
        "ok: a full-coverage leader SyncGroup must COMPLETE (NONE), got rc="
        + String(rc),
    )
    var st = _read(shared, cluster, group)
    _check(
        st.state == String(GROUP_STATE_STABLE),
        "ok: group Stable after full-coverage sync, got " + st.state,
    )
    _assert_disjoint_full_cover(shared, cluster, group, n_parts, "ok-cover")
    _ = b_id
    print("PASS test_full_coverage_leader_syncgroup_completes_normally")


def main() raises:
    test_stale_leader_syncgroup_does_not_strand_a_member()
    test_full_coverage_leader_syncgroup_completes_normally()
    print("ALL PASS test_kafka_rebalance_leapfrog_race")
