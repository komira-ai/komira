# =============================================================================
# group_membership.mojo: which members a rebalance carries, and whether a
#                        leader's assignment is valid for them.
# =============================================================================
#
# Two pure decisions the coordinator makes from a loaded GroupState, kept apart
# from the store traffic so each is the same on whichever broker evaluates it
# and on every CAS retry:
#
#   * reconcile_members: when a JoinGroup round closes, which members of older
#     generations are carried into the new one and which are dropped.
#   * assignment_is_valid: whether the assignment a leader submits in SyncGroup
#     is a clean cover of the members at the current generation.
#
# No pointer type appears in any signature.
# =============================================================================

from komira_kafka_server.wire.consumer_group import decode_consumer_assignment

from .group_state import (
    GroupMember,
    GroupState,
    GROUP_STATE_PREPARING,
    GHOST_STALE_GRACE_MS,
)


def reconcile_members(
    st: GroupState, current_gen: Int32, now_ms: Int64
) -> List[GroupMember]:
    """The member set a round closing at `current_gen` carries forward.

    A member already at `current_gen` is kept as it is: a member that just
    rejoined is alive by that join, and its heartbeat refresh may not have been
    stored yet. A member at an older generation is carried forward (re-anchored
    to `current_gen`, keeping its subscription and last_active_ms) only when
      * it is session-alive: `now_ms - last_active_ms < session_timeout_ms`, and
      * it was still active when the round opened: its last_active_ms is no
        more than GHOST_STALE_GRACE_MS before `round_opened_ms`. A
        round_opened_ms of 0 (a state with no round-open stamp) skips this
        test.
    Any other older-generation member is dropped: it is a session-expired
    member, or a stale id left by a consumer that reconnected under a new
    member id. Keeping such an id would widen the leader's split by one member
    that no live consumer holds.
    """
    var reconciled = List[GroupMember]()
    for i in range(len(st.members)):
        if st.members[i].join_generation == current_gen:
            reconciled.append(st.members[i].copy())
        else:
            var idle = now_ms - st.members[i].last_active_ms
            var alive = idle < st.session_timeout_ms
            var reconfirmed = (
                st.round_opened_ms <= Int64(0)
                or st.members[i].last_active_ms
                >= st.round_opened_ms - GHOST_STALE_GRACE_MS
            )
            if alive and reconfirmed:
                var m = st.members[i].copy()
                m.join_generation = current_gen
                reconciled.append(m^)
    return reconciled^


def assignment_is_valid(
    st: GroupState,
    generation_id: Int32,
    assignment_member_ids: List[String],
    assignment_blobs: List[List[UInt8]],
) raises -> Bool:
    """Whether a leader's SyncGroup assignment may complete the round.

    False (the leader must rejoin) when any of these holds:
      * the round was reopened: the state is back to PreparingRebalance after
        the leader's JoinGroup response moved it to Completing;
      * a member at `generation_id` is not named in the assignment (it joined
        the generation after the leader computed its split);
      * a partition is assigned to a member that is not at `generation_id`;
      * a partition is assigned to more than one member;
      * the assigned partitions are not the contiguous range 0..max (a
        partition fell out of the split).
    """
    if st.state == String(GROUP_STATE_PREPARING):
        return False
    for mi in range(len(st.members)):
        if st.members[mi].join_generation != generation_id:
            continue
        var covered = False
        for ai in range(len(assignment_member_ids)):
            if assignment_member_ids[ai] == st.members[mi].member_id:
                covered = True
                break
        if not covered:
            return False

    var seen_parts = List[Int32]()
    var max_part = Int32(-1)
    for ai in range(len(assignment_member_ids)):
        var amidx = st.member_index(assignment_member_ids[ai])
        var assignee_current = (
            amidx >= 0 and st.members[amidx].join_generation == generation_id
        )
        var dec = decode_consumer_assignment(assignment_blobs[ai])
        var has_parts = False
        for ti in range(len(dec)):
            for pi in range(len(dec[ti].partitions)):
                has_parts = True
                var p = dec[ti].partitions[pi]
                for si in range(len(seen_parts)):
                    if seen_parts[si] == p:
                        return False
                seen_parts.append(p)
                if p > max_part:
                    max_part = p
        if has_parts and not assignee_current:
            return False
    if max_part >= Int32(0):
        var present = List[Bool]()
        for _ in range(Int(max_part) + 1):
            present.append(False)
        for si in range(len(seen_parts)):
            var sp = Int(seen_parts[si])
            if sp >= 0 and sp <= Int(max_part):
                present[sp] = True
        for k in range(Int(max_part) + 1):
            if not present[k]:
                return False
    return True
