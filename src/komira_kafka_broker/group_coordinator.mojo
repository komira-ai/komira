# =============================================================================
# group_coordinator.mojo: the consumer-group rebalance state machine over a
#                         conditional-write object store.
# =============================================================================
#
# JoinGroup, SyncGroup, Heartbeat and LeaveGroup for subscribe()-style
# consumers: a topic's partitions are spread over the members of a group, and
# redistributed when membership changes.
#
# The model is stateless over the store. No process holds a long-poll join
# barrier. A group's membership lives at
#   <cluster>/_meta/groups/<group_id>/state.json
# and is compare-and-swapped (If-Match) over the same ConditionalWriteStore the
# data plane and the offset store use. A JoinGroup registers the member with a
# CAS and then polls the stored state until the rebalance window closes; a
# SyncGroup stores the leader's assignment with a CAS and lets followers poll it
# back. The CAS is what serializes two brokers driving the same group.
#
# States (the `state` field of state.json):
#   Empty               no members.
#   PreparingRebalance  a member joined or left; the generation was bumped;
#                       JoinGroups are being collected within the window.
#   CompletingRebalance the window closed; members have their JoinGroup
#                       response; the leader's SyncGroup is awaited.
#   Stable              assignments are stored; members are consuming.
# Transitions:
#   Empty --JoinGroup--> PreparingRebalance (generation 1)
#   Stable --JoinGroup (new round)--> PreparingRebalance (generation + 1)
#   Stable --LeaveGroup--> PreparingRebalance (generation + 1)
#   PreparingRebalance --window closed--> CompletingRebalance
#   CompletingRebalance --leader SyncGroup--> Stable
#
# The state, the member reconciliation, the assignor and the clock are in
# group_state, group_membership, group_assignor and group_clock. This module
# holds the store traffic: load, CAS, and the four handlers.
#
# Time is read and waited on through the coordinator's GroupClock, so a test
# passes a ManualGroupClock and no test waits in real time.
#
# Session expiry happens only when a round closes (reconcile_members drops an
# expired older-generation member then). No handler sweeps a silent member out
# of a Stable group, and none starts a rebalance for it.
#
# No pointer type appears in any signature; the store is owned by value and
# used through its typed API (conditional_put, compare_and_swap, get, head).
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from komira_kafka_server.wire.consumer_group import (
    JoinGroupResponseMember,
    ERROR_ILLEGAL_GENERATION,
    ERROR_REBALANCE_IN_PROGRESS,
    ERROR_UNKNOWN_MEMBER_ID,
)

from .group_assignor import pick_protocol_name
from .group_clock import GroupClock
from .group_membership import assignment_is_valid, reconcile_members
from .store_support import group_path_segment, is_lost_cas, is_not_found
from .group_state import (
    GroupMember,
    GroupState,
    GROUP_STATE_EMPTY,
    GROUP_STATE_PREPARING,
    GROUP_STATE_COMPLETING,
    GROUP_STATE_STABLE,
    DEFAULT_SESSION_TIMEOUT_MS,
    encode_group_state_json,
    decode_group_state_json,
)

# The poll interval (ms) of the join and sync barriers, and a cap on poll
# iterations so a wedged store cannot hang a handler. The deadline is the
# request's rebalance_timeout_ms; these bound the polling. The product is a
# 40 second ceiling on one wait: a rebalance_timeout_ms above it closes the
# JoinGroup wait at the ceiling, and a SyncGroup follower whose leader has not
# synced by then is answered REBALANCE_IN_PROGRESS.
comptime JOIN_POLL_INTERVAL_MS: Int64 = 20
comptime JOIN_POLL_MAX_ITERS: Int = 2000


struct JoinResult(Movable, Deinitable):
    """The outcome of a JoinGroup: this member's id + the group generation +
    the leader id + (for the leader only) the full member list with each
    member's subscription blob. Followers get an empty `members`."""

    var member_id: String
    var generation_id: Int32
    var leader_id: String
    var protocol_name: String
    var members: List[JoinGroupResponseMember]
    var error_code: Int16

    def __init__(
        out self,
        var member_id: String,
        generation_id: Int32,
        var leader_id: String,
        var protocol_name: String,
        var members: List[JoinGroupResponseMember],
        error_code: Int16,
    ):
        self.member_id = member_id^
        self.generation_id = generation_id
        self.leader_id = leader_id^
        self.protocol_name = protocol_name^
        self.members = members^
        self.error_code = error_code


struct GroupCoordinator[
    Storage: CloneableConditionalWriteStore, Clock: GroupClock
](Movable, Deinitable):
    """The consumer-group rebalance state machine over a conditional-write store.

    Owns a handle to the same store type the data plane and the offset store
    use (a `CloneableConditionalWriteStore`), so the group tree lives beside
    the segment and manifest tree. state.json is read-modify-write CAS'd with
    If-Match (compare_and_swap); the first writer of an absent state.json
    creates it with If-None-Match (conditional_put). On a 412 the writer
    re-reads and retries, which is how two brokers driving one group
    serialize.

    `clock` is the GroupClock every timestamp and every wait goes through. It
    is a public field so a test with a ManualGroupClock can set or advance it
    between calls.
    """

    var _store: Self.Storage
    var _cluster: String
    # Mints member-id suffixes, unique within this process.
    var _member_seq: Int64
    # A token unique to this broker (e.g. its node id), folded into every
    # minted member id. Without it two brokers minting their first joiner would
    # both produce `<client_id>-1`, the shared state.json would hold one member
    # instead of two, and no split would happen. Empty on a single broker.
    var _node_token: String
    var clock: Self.Clock

    def __init__(
        out self,
        var store: Self.Storage,
        var cluster: String,
        var clock: Self.Clock,
        var node_token: String = String(""),
    ):
        self._store = store^
        self._cluster = cluster^
        self._member_seq = Int64(0)
        self._node_token = node_token^
        self.clock = clock^

    def _now(mut self) -> Int64:
        return self.clock.now_ms()

    # -- key + member-id helpers ---------------------------------------------

    def _state_key(self, group_id: String) raises -> String:
        """`<cluster>/_meta/groups/<group>/state.json`, with the group id
        encoded as the offset store encodes it. An empty id has no key."""
        if group_id.byte_length() == 0:
            raise Error("group_coordinator: empty group id")
        return (
            self._cluster
            + String("/_meta/groups/")
            + group_path_segment(group_id)
            + String("/state.json")
        )

    def _mint_member_id(mut self, client_id: String) -> String:
        """Assign a fresh member_id for a first-join member. Shape:
        `<client_id>-<node_token>-<seq>` — the node token makes the id GLOBALLY
        unique across brokers (two brokers minting their first joiner produce
        DISTINCT ids), and the per-process seq makes it unique within a broker.
        Without the node token, broker-1 and broker-2 both mint `<client_id>-1`
        and collide in the shared state.json -> the cross-node group never
        splits. The token is omitted on the single-broker / offline path (no
        cross-broker collision is possible there)."""
        self._member_seq += Int64(1)
        var cid = client_id.copy()
        if cid.byte_length() == 0:
            cid = String("consumer")
        var out = cid + String("-")
        if self._node_token.byte_length() > 0:
            out += self._node_token + String("-")
        out += String(self._member_seq)
        return out^

    # -- load (read state.json; None if absent) ------------------------------

    def _load(mut self, group_id: String) raises -> Optional[GroupState]:
        var path = Path.parse(self._state_key(group_id))
        try:
            var meta = self._store.head(path)
            var body = self._store.get(path)
            return Optional(decode_group_state_json(body^, meta.etag.copy()))
        except e:
            var msg = String(e)
            if is_not_found(msg):
                return Optional[GroupState]()
            raise Error(msg)

    # -- CAS-store: create-if-absent (etag empty) or If-Match -----------------

    def _cas_store(mut self, group_id: String, st: GroupState) raises -> String:
        """Persist `st` with the right precondition: If-None-Match create when
        the in-memory etag is empty (the state was absent), else If-Match on the
        carried etag. Returns the new etag. Raises (412) on a lost CAS — the
        caller re-reads + retries."""
        var path = Path.parse(self._state_key(group_id))
        var body = encode_group_state_json(st)
        if st.etag.byte_length() == 0:
            var meta = self._store.conditional_put(
                path, body^, WritePrecondition.if_none_match_star()
            )
            return meta.etag.copy()
        var meta = self._store.compare_and_swap(path, body^, st.etag)
        return meta.etag.copy()

    # -- JoinGroup -----------------------------------------------------------

    def join_group(
        mut self,
        group_id: String,
        member_id_in: String,
        client_id: String,
        protocol_names: List[String],
        subscription: List[UInt8],
        rebalance_timeout_ms: Int32,
        session_timeout_ms: Int32 = Int32(0),
    ) raises -> JoinResult:
        """CAS-register the member into the group (minting a member_id when
        empty), move the group to PreparingRebalance + bump the generation, then
        POLL the persisted state until the rebalance window closes. Respond with
        the leader's full member list (leader only) or an empty list (follower).

        The CAS-register loop re-reads + retries on a lost CAS (412), so two
        brokers registering members into the SAME group serialize.
        """
        var protocol = pick_protocol_name(protocol_names)
        # --- phase 1: CAS-register the member (retry on lost CAS) ------------
        var my_member_id = String("")
        var my_generation = Int32(0)
        var registered = False
        for _attempt in range(256):
            var loaded = self._load(group_id)
            var member_id = member_id_in.copy()
            var st: GroupState
            if loaded:
                st = loaded.take()
                # Decide the member_id (mint if empty/first-join).
                if member_id.byte_length() == 0:
                    member_id = self._mint_member_id(client_id)
                # BUMP-ONCE-PER-ROUND (the cross-broker-idempotent decision).
                # The "is this a NEW rebalance round (bump the generation) or am I
                # joining an IN-FLIGHT round (keep the generation)" choice is a
                # pure function of the LOADED `state` field — so it is identical
                # for whichever broker wins the CAS and for any CAS-loser that
                # re-loads + re-decides:
                #   * state == PreparingRebalance OR CompletingRebalance -> a
                #     round is already open (the leader has NOT yet synced to
                #     Stable); JOIN AT THE CURRENT generation (no bump). If the
                #     round had already advanced to Completing, drop it BACK to
                #     Preparing so this late (re)joiner is collected into THIS
                #     round's member set before the leader's SyncGroup lands —
                #     that is what stops an incumbent's heartbeat-driven rejoin
                #     from LEAPFROGGING into a fresh generation.
                #   * else (Stable / Empty) -> this join OPENS a new round: bump
                #     generation_id + 1, go Preparing, reset the rebalance
                #     deadline.
                # So members joining at
                # different brokers within one rebalance window now converge onto
                # ONE generation (the all-known-members barrier below becomes
                # satisfiable) instead of each re-bumping past the other forever.
                var round_open = st.state == String(
                    GROUP_STATE_PREPARING
                ) or st.state == String(GROUP_STATE_COMPLETING)
                var new_gen: Int32
                if round_open:
                    # Join the in-flight round at the current generation. Do NOT
                    # re-bump and do NOT reset the deadline (let the window the
                    # round-opener set elapse / fill). Re-open Completing back to
                    # Preparing so a fresh member is collected before SyncGroup.
                    new_gen = st.generation_id
                    st.state = String(GROUP_STATE_PREPARING)
                else:
                    new_gen = st.generation_id + Int32(1)
                    st.generation_id = new_gen
                    st.state = String(GROUP_STATE_PREPARING)
                    st.rebalance_deadline_ms = self._now() + Int64(
                        Int(rebalance_timeout_ms)
                    )
                    # Stamp this round's open instant — the ghost-reap baseline.
                    # Any old-gen member whose last_active predates this instant
                    # has NOT re-confirmed into this round and will be reaped on
                    # the session-aware close (see reconcile_members).
                    st.round_opened_ms = self._now()
                st.protocol = protocol.copy()
                # Negotiate the session timeout: keep the larger of the carried
                # value and what this join requests (a member only sets it on a
                # real join; a 0/negative request keeps the existing bound). This
                # is a liveness signal, NOT the rebalance window.
                if session_timeout_ms > Int32(0):
                    var req_session = Int64(Int(session_timeout_ms))
                    if req_session > st.session_timeout_ms:
                        st.session_timeout_ms = req_session
                var now_ms = self._now()
                # Insert / refresh this member at the current-round generation +
                # stamp its liveness (this join IS a liveness signal).
                var idx = st.member_index(member_id)
                if idx >= 0:
                    st.members[idx].subscription = subscription.copy()
                    st.members[idx].join_generation = new_gen
                    st.members[idx].last_active_ms = now_ms
                else:
                    st.members.append(
                        GroupMember(
                            member_id.copy(),
                            subscription.copy(),
                            List[UInt8](),
                            new_gen,
                            now_ms,
                        )
                    )
                my_member_id = member_id.copy()
                my_generation = new_gen
            else:
                # First member of a brand-new group.
                if member_id.byte_length() == 0:
                    member_id = self._mint_member_id(client_id)
                var now_ms = self._now()
                var members = List[GroupMember]()
                members.append(
                    GroupMember(
                        member_id.copy(),
                        subscription.copy(),
                        List[UInt8](),
                        Int32(1),
                        now_ms,
                    )
                )
                var session = (
                    Int64(Int(session_timeout_ms)) if session_timeout_ms
                    > Int32(0) else DEFAULT_SESSION_TIMEOUT_MS
                )
                st = GroupState(
                    Int32(1),
                    member_id.copy(),  # provisional leader
                    protocol.copy(),
                    String("consumer"),
                    String(GROUP_STATE_PREPARING),
                    now_ms + Int64(Int(rebalance_timeout_ms)),
                    members^,
                    String(""),  # empty etag => create-if-absent
                    session,
                    now_ms,  # round_opened_ms — this join opens the first round
                )
                my_member_id = member_id.copy()
                my_generation = Int32(1)
            try:
                _ = self._cas_store(group_id, st)
                registered = True
                break
            except e:
                var msg = String(e)
                if is_lost_cas(msg):
                    continue  # lost CAS — re-read + retry
                raise Error(msg)
        if not registered:
            # Every swap lost: the member was never stored.
            return JoinResult(
                member_id_in.copy(),
                Int32(0),
                String(""),
                protocol^,
                List[JoinGroupResponseMember](),
                ERROR_REBALANCE_IN_PROGRESS,
            )

        # --- phase 2: poll until the rebalance window closes -----------------
        # The window closes when now >= rebalance_deadline. (In the
        # single-process test, the deadline is the only barrier; a real
        # multi-broker fleet would ALSO close early once every known member's
        # join_generation == current generation, but the deadline is the
        # backstop. We honor the deadline for correctness + simplicity.)
        # The window closes EARLY once every member recorded in state.json has
        # rejoined at the CURRENT generation (join_generation == generation_id)
        # — that is the genuine all-members-rejoined barrier. The deadline is
        # the backstop for a member that never rejoins. A single subscribe()
        # consumer satisfies the early-close on the first poll (it is the only
        # member, already at the current generation), so JoinGroup returns
        # immediately rather than waiting the full rebalance_timeout.
        for _poll in range(JOIN_POLL_MAX_ITERS):
            var loaded = self._load(group_id)
            if not loaded:
                break  # group vanished (all left) — bail with what we have
            var st = loaded.take()
            var window_closed = self._now() >= st.rebalance_deadline_ms
            var all_rejoined = len(st.members) > 0
            for i in range(len(st.members)):
                if st.members[i].join_generation != st.generation_id:
                    all_rejoined = False
                    break
            if window_closed or all_rejoined:
                break
            self.clock.sleep_ms(JOIN_POLL_INTERVAL_MS)

        # --- phase 3: read final state, elect leader, transition, respond ----
        var final = self._load(group_id)
        if not final:
            # Group was torn down mid-join.
            return JoinResult(
                my_member_id^,
                my_generation,
                String(""),
                protocol^,
                List[JoinGroupResponseMember](),
                ERROR_UNKNOWN_MEMBER_ID,
            )
        var fst = final.take()
        var current_gen = fst.generation_id

        # Move the group to CompletingRebalance (awaiting the leader's SyncGroup)
        # and PERSIST a SINGLE leader for this generation. CAS-retry.
        #
        # CONSISTENT-LEADER (so two brokers never double-assign). The leader
        # MUST be identical for every member of generation `current_gen` — only
        # then does exactly ONE member compute + SyncGroup-store the assignment
        # (two leaders => two overlapping assignments => double-assign). We make
        # the leader a deterministic, persist-ONCE-per-generation value:
        #   * leader = lexicographically-smallest member_id that has joined at
        #     `current_gen` (the assignor's sort order — deterministic);
        #   * once written into state.json for a generation it is NOT recomputed
        #     while the generation is unchanged (so a member whose snapshot was
        #     momentarily missing a peer cannot elect a different leader).
        # Every JoinGroup response then ECHOES the persisted leader read back
        # from the final state — so all members agree.
        var closed = False
        for _attempt in range(256):
            var loaded = self._load(group_id)
            if not loaded:
                closed = True
                break
            var st = loaded.take()
            if st.generation_id != current_gen:
                closed = True
                break  # a newer rebalance superseded us — leave it alone

            # SESSION-AWARE WINDOW CLOSE (a still-alive incumbent is never dropped on the deadline). The
            # window may have closed on the DEADLINE while a still-ALIVE
            # incumbent has not yet rejoined at `current_gen` (its
            # join_generation lags because its heartbeat-driven rejoin had not
            # landed when the deadline fired). Real Kafka never drops a
            # session-alive member on the rebalance deadline — it carries the
            # member with its prior subscription into the new generation and
            # only EVICTS a member on genuine session expiry. We reconcile the
            # member set here, BEFORE electing the leader / building the member
            # list, so the assignor sees the EXACT set of live members:
            #   * a member at an OLDER generation that is SESSION-ALIVE
            #     (now - last_active_ms < session_timeout) is PROMOTED to
            #     `current_gen` (re-anchor join_generation; keep its
            #     subscription + last_active_ms) — carried forward, never
            #     dropped on the deadline;
            #   * a member at an OLDER generation that is SESSION-EXPIRED is
            #     EVICTED — this reaps a ghost from a prior round whose client
            #     died / left without a clean LeaveGroup (a lingering ghost would
            #     otherwise inflate the member count and skew the split).
            # A member already at `current_gen` is kept as-is — we do NOT
            # session-evict a current-generation member, because liveness for a
            # freshly-(re)joined member is established by the join itself and the
            # best-effort heartbeat refresh can lose a CAS race; the conservative
            # rule (only expire OLDER-generation members) avoids dropping a
            # member that just rejoined but whose heartbeat refresh has not yet
            # landed. This is a pure function of the loaded state + the session
            # clock, so it is idempotent under CAS-retry and identical across
            # brokers.
            st.members = reconcile_members(st, current_gen, self._now())

            # If a leader is already persisted AND it is a member at this
            # generation, keep it; else (re)elect the min member_id at this gen.
            var keep_leader = False
            if st.leader_member_id.byte_length() > 0:
                var li = st.member_index(st.leader_member_id)
                if (
                    li >= 0
                    and st.members[li].join_generation == current_gen
                ):
                    keep_leader = True
            if not keep_leader:
                var elect = String("")
                for i in range(len(st.members)):
                    if st.members[i].join_generation == current_gen:
                        if (
                            elect.byte_length() == 0
                            or st.members[i].member_id < elect
                        ):
                            elect = st.members[i].member_id.copy()
                st.leader_member_id = elect^
            # Only ADVANCE to Completing from Preparing; if another joiner has
            # already re-opened a fresh round we leave the state alone.
            if st.state == String(GROUP_STATE_PREPARING):
                st.state = String(GROUP_STATE_COMPLETING)
            try:
                _ = self._cas_store(group_id, st)
                closed = True
                break
            except e:
                var msg = String(e)
                if is_lost_cas(msg):
                    continue
                raise Error(msg)
        if not closed:
            # Every swap lost: the round was not moved to CompletingRebalance.
            return JoinResult(
                my_member_id^,
                current_gen,
                String(""),
                protocol^,
                List[JoinGroupResponseMember](),
                ERROR_REBALANCE_IN_PROGRESS,
            )

        # Re-read the final state so the response echoes the PERSISTED leader +
        # the full member set at this generation (consistent across all members).
        var after = self._load(group_id)
        var leader_id = String("")
        var resp_members = List[JoinGroupResponseMember]()
        var resp_gen = current_gen
        if after:
            var ast = after.take()
            if ast.generation_id == current_gen:
                leader_id = ast.leader_member_id.copy()
                resp_gen = ast.generation_id
                # Leader gets the full member list (member_id + subscription
                # blob) at this generation; followers get an empty list.
                if my_member_id == leader_id:
                    for i in range(len(ast.members)):
                        if ast.members[i].join_generation == current_gen:
                            resp_members.append(
                                JoinGroupResponseMember(
                                    ast.members[i].member_id.copy(),
                                    ast.members[i].subscription.copy(),
                                )
                            )
        return JoinResult(
            my_member_id^,
            resp_gen,
            leader_id^,
            protocol^,
            resp_members^,
            Int16(0),
        )

    # -- SyncGroup -----------------------------------------------------------

    def sync_group(
        mut self,
        group_id: String,
        member_id: String,
        generation_id: Int32,
        leader_assignments_member_ids: List[String],
        leader_assignments_blobs: List[List[UInt8]],
    ) raises -> Tuple[List[UInt8], Int16]:
        """If THIS member is the group's leader and sent assignments, CAS-store
        every member's assignment blob into state.json + transition to Stable.
        Assignments sent by any other member are ignored, as Kafka ignores them.
        Then (leader or follower) poll until Stable and return THIS member's
        stored assignment blob.

        Returns (assignment_blob, error_code).
        """
        # --- phase 1 (leader): store assignments + go Stable -----------------
        var has_assignments = len(leader_assignments_member_ids) > 0
        if has_assignments:
            var stored = False
            for _attempt in range(256):
                var loaded = self._load(group_id)
                if not loaded:
                    return (List[UInt8](), ERROR_UNKNOWN_MEMBER_ID)
                var st = loaded.take()
                if st.generation_id != generation_id:
                    # A newer rebalance started — tell the leader to rejoin.
                    return (List[UInt8](), ERROR_REBALANCE_IN_PROGRESS)
                if st.leader_member_id != member_id:
                    # Not the leader: its assignments are ignored; it waits for
                    # the leader's like a follower.
                    stored = True
                    break
                if not assignment_is_valid(
                    st,
                    generation_id,
                    leader_assignments_member_ids,
                    leader_assignments_blobs,
                ):
                    return (List[UInt8](), ERROR_REBALANCE_IN_PROGRESS)
                # Write each assignment into the matching member.
                for ai in range(len(leader_assignments_member_ids)):
                    var mid = leader_assignments_member_ids[ai]
                    var idx = st.member_index(mid)
                    if idx >= 0:
                        st.members[idx].assignment = leader_assignments_blobs[
                            ai
                        ].copy()
                st.state = String(GROUP_STATE_STABLE)
                try:
                    _ = self._cas_store(group_id, st)
                    stored = True
                    break
                except e:
                    var msg = String(e)
                    if is_lost_cas(msg):
                        continue
                    raise Error(msg)
            if not stored:
                return (List[UInt8](), ERROR_REBALANCE_IN_PROGRESS)

        # --- phase 2: poll until Stable, then read this member's assignment --
        for _poll in range(JOIN_POLL_MAX_ITERS):
            var loaded = self._load(group_id)
            if not loaded:
                return (List[UInt8](), ERROR_UNKNOWN_MEMBER_ID)
            var st = loaded.take()
            if st.generation_id != generation_id:
                return (List[UInt8](), ERROR_REBALANCE_IN_PROGRESS)
            if st.state == String(GROUP_STATE_STABLE):
                var idx = st.member_index(member_id)
                if idx >= 0:
                    return (st.members[idx].assignment.copy(), Int16(0))
                return (List[UInt8](), ERROR_UNKNOWN_MEMBER_ID)
            self.clock.sleep_ms(JOIN_POLL_INTERVAL_MS)
        # Timed out waiting for the leader's SyncGroup.
        return (List[UInt8](), ERROR_REBALANCE_IN_PROGRESS)

    # -- Heartbeat -----------------------------------------------------------

    def heartbeat(
        mut self,
        group_id: String,
        member_id: String,
        generation_id: Int32,
    ) raises -> Int16:
        """Return NONE(0) when the group is Stable + the member's generation
        matches. Return REBALANCE_IN_PROGRESS(27) when a rebalance is underway
        (the group is not Stable) so the member rejoins. UNKNOWN_MEMBER_ID(25)
        if the member is not in the group. ILLEGAL_GENERATION(22) if the group
        is Stable and the generation is not the group's, older or newer.

        A heartbeat is ALSO a LIVENESS signal — it refreshes the member's
        `last_active_ms` via a best-effort CAS so a still-alive incumbent that
        has not yet rejoined at the new generation (it is mid-rebalance, about
        to rejoin) is NOT mistaken for session-expired and dropped on the
        rebalance deadline. The refresh touches ONLY last_active_ms (never
        generation / state / membership), so it is idempotent and safe under a
        concurrent rebalance; a lost CAS is simply ignored (the next heartbeat
        re-stamps)."""
        var loaded = self._load(group_id)
        if not loaded:
            return ERROR_UNKNOWN_MEMBER_ID
        var st = loaded.take()
        var midx = st.member_index(member_id)
        if midx < 0:
            return ERROR_UNKNOWN_MEMBER_ID

        # Compute the response code FIRST (semantics unchanged).
        var code = Int16(0)
        if st.state != String(GROUP_STATE_STABLE):
            # A rebalance is in progress (Preparing / Completing). Tell the
            # member to rejoin.
            code = ERROR_REBALANCE_IN_PROGRESS
        elif generation_id != st.generation_id:
            # Stable but the member is on another generation: it must rejoin.
            code = ERROR_ILLEGAL_GENERATION

        # Best-effort liveness refresh (only when the etag is concrete — a freshly
        # decoded state always carries one). Stamp last_active_ms + re-store via
        # If-Match; ignore a lost CAS (the next heartbeat re-stamps). This is what
        # keeps a heartbeating-but-not-yet-rejoined incumbent session-alive.
        if st.etag.byte_length() > 0:
            st.members[midx].last_active_ms = self._now()
            try:
                _ = self._cas_store(group_id, st)
            except e:
                var msg = String(e)
                if not is_lost_cas(msg):
                    raise Error(msg)
                # lost CAS — fine, liveness will be re-stamped next heartbeat.
        return code

    # -- LeaveGroup ----------------------------------------------------------

    def leave_group(
        mut self, group_id: String, member_id: String
    ) raises -> Int16:
        """Remove the member, bump the generation, and move the group to
        PreparingRebalance (so the remaining members rebalance on their next
        heartbeat -> rejoin). If the member was the last one, the group goes
        Empty. CAS-retry on a lost write; after 256 lost swaps the answer is
        REBALANCE_IN_PROGRESS and the member is still stored.

        The leave does not reset `rebalance_deadline_ms`: a group that was
        Stable keeps the deadline of its last round, so the next join into the
        Preparing round finds its window already closed."""
        for _attempt in range(256):
            var loaded = self._load(group_id)
            if not loaded:
                return ERROR_UNKNOWN_MEMBER_ID
            var st = loaded.take()
            var idx = st.member_index(member_id)
            if idx < 0:
                return ERROR_UNKNOWN_MEMBER_ID
            # Remove the member.
            var kept = List[GroupMember]()
            for i in range(len(st.members)):
                if i != idx:
                    kept.append(st.members[i].copy())
            st.members = kept^
            st.generation_id = st.generation_id + Int32(1)
            if len(st.members) == 0:
                st.state = String(GROUP_STATE_EMPTY)
                st.leader_member_id = String("")
            else:
                st.state = String(GROUP_STATE_PREPARING)
            try:
                _ = self._cas_store(group_id, st)
                return Int16(0)
            except e:
                var msg = String(e)
                if is_lost_cas(msg):
                    continue
                raise Error(msg)
        return ERROR_REBALANCE_IN_PROGRESS

    # -- introspection (for unit tests) --------------------------------------

    def load_state(mut self, group_id: String) raises -> Optional[GroupState]:
        """Read the persisted GroupState (test helper)."""
        return self._load(group_id)
