# =============================================================================
# group_state.mojo: the persisted state of a consumer group.
# =============================================================================
#
# A group's membership lives in one object, <cluster>/_meta/groups/<id>/state.json.
# This module holds its in-memory model (GroupMember, GroupState), the group
# lifecycle state names, the timing constants the state carries, and the JSON
# encoder and decoder for the object. The JSON is hand-written: bytes in, bytes
# out, with the member blobs hex-encoded so the body stays text.
#
#   {"generation_id":N,"leader":"<id>","protocol":"range",
#    "protocol_type":"consumer","state":"Stable","rebalance_deadline":N,
#    "session_timeout":N,"round_opened":N,
#    "members":[{"member_id":"<id>","subscription":"<hex>","assignment":"<hex>",
#                "join_generation":N,"last_active":N}, ...]}
#
# No pointer type appears in any signature.
# =============================================================================



# Group lifecycle states (stored as a short string in state.json).
comptime GROUP_STATE_EMPTY: String = "Empty"
comptime GROUP_STATE_PREPARING: String = "PreparingRebalance"
comptime GROUP_STATE_COMPLETING: String = "CompletingRebalance"
comptime GROUP_STATE_STABLE: String = "Stable"

# The default session timeout (ms) when a JoinGroup does not negotiate one
# (e.g. the seed path / a request that sent session_timeout_ms <= 0). Kafka's
# stock default is 10s; we use 10s so a heartbeating member (stock heartbeat
# interval ~3s) always stays well inside the window.
comptime DEFAULT_SESSION_TIMEOUT_MS: Int64 = 10000

# The GHOST-REAP staleness grace (ms) — the max time a still-participating
# incumbent's last_active may lag the rebalance round's open instant. A member
# whose last_active predates round-open by MORE than this grace was SILENT at
# the round boundary (no recent heartbeat) and is treated as a ghost left
# behind by a consumer that reconnected under a new member_id; it is reaped at
# the session-aware close even when nominally inside the (longer) session
# window. Set to ~1.5x a stock heartbeat interval (heartbeat ~2s) so a genuine
# lagging incumbent that heartbeats right up to the round is always carried
# forward, while a ghost that has gone silent is dropped before it can inflate
# the leader's RangeAssignor split.
comptime GHOST_STALE_GRACE_MS: Int64 = 3000


# =============================================================================
# The in-memory model of state.json.
# =============================================================================


struct GroupMember(Copyable, Movable, Deinitable):
    """One member of a consumer group, as persisted in state.json.

    `subscription` is the raw ConsumerProtocolSubscription metadata blob the
    member sent in JoinGroup (the leader decodes it to compute assignments).
    `assignment` is the raw ConsumerProtocolAssignment blob the leader computed
    for this member (empty until SyncGroup stores it).
    `join_generation` records the generation at which this member last
    (re)joined — the join barrier waits until every member's join_generation
    equals the group's current generation.
    `last_active_ms` is the wall-clock (ms) of this member's last LIVENESS
    signal — refreshed on EVERY JoinGroup AND EVERY Heartbeat. A member is
    SESSION-ALIVE iff `now - last_active_ms < session_timeout_ms`. The rebalance
    deadline-close path keeps a session-alive incumbent that has not yet
    rejoined at the new generation (re-anchoring it to the current generation
    and carrying its prior subscription) instead of silently dropping it —
    a still-alive member is NEVER evicted on the rebalance deadline, only on
    genuine session expiry. This keeps a member alive across
    the rebalance deadline."""

    var member_id: String
    var subscription: List[UInt8]
    var assignment: List[UInt8]
    var join_generation: Int32
    var last_active_ms: Int64

    def __init__(
        out self,
        var member_id: String,
        var subscription: List[UInt8],
        var assignment: List[UInt8],
        join_generation: Int32,
        last_active_ms: Int64 = Int64(0),
    ):
        self.member_id = member_id^
        self.subscription = subscription^
        self.assignment = assignment^
        self.join_generation = join_generation
        self.last_active_ms = last_active_ms

    def copy(self) -> Self:
        return Self(
            self.member_id.copy(),
            self.subscription.copy(),
            self.assignment.copy(),
            self.join_generation,
            self.last_active_ms,
        )


struct GroupState(Movable, Deinitable):
    """The full persisted state of a consumer group (the state.json body)."""

    var generation_id: Int32
    var leader_member_id: String
    var protocol: String  # the chosen assignor name (e.g. "range")
    var protocol_type: String  # "consumer"
    var state: String  # one of GROUP_STATE_*
    var rebalance_deadline_ms: Int64
    # The session timeout (ms) the group's members negotiated — a member that
    # has not heartbeat-or-joined within this window is evicted; one still
    # within it is SESSION-ALIVE and is never dropped on the rebalance deadline.
    # Carried in state.json so every broker driving the group reads the same
    # session bound.
    var session_timeout_ms: Int64
    # The wall-clock (ms) at which the CURRENT rebalance round OPENED (the join
    # that bumped the generation / re-prepared a Stable group). Used to reap a
    # GHOST member: an old-generation member is only carried forward on the
    # session-aware close if it ACTIVELY re-confirmed (join or heartbeat) since
    # the round opened (last_active_ms >= round_opened_ms). A stale id whose
    # last_active predates the round (a consumer that reconnected under a NEW
    # member_id, leaving its OLD id behind, or a member that has gone silent) is
    # dropped even when nominally inside the session window — that is what keeps
    # a ghost from inflating the leader's split into an N-way over-split (the
    # "A flaps to [2,3], B never converges" convergence race). Stamped in
    # state.json so every broker reads the same round-open instant. Additive
    # trailing scalar (absent => 0, which keeps the legacy session-only rule).
    var round_opened_ms: Int64
    var members: List[GroupMember]
    # The etag from the store (empty when not yet persisted) — carried so a
    # read-modify-write CAS can supply the If-Match precondition.
    var etag: String

    def __init__(
        out self,
        generation_id: Int32,
        var leader_member_id: String,
        var protocol: String,
        var protocol_type: String,
        var state: String,
        rebalance_deadline_ms: Int64,
        var members: List[GroupMember],
        var etag: String,
        session_timeout_ms: Int64 = DEFAULT_SESSION_TIMEOUT_MS,
        round_opened_ms: Int64 = Int64(0),
    ):
        self.generation_id = generation_id
        self.leader_member_id = leader_member_id^
        self.protocol = protocol^
        self.protocol_type = protocol_type^
        self.state = state^
        self.rebalance_deadline_ms = rebalance_deadline_ms
        self.session_timeout_ms = session_timeout_ms
        self.round_opened_ms = round_opened_ms
        self.members = members^
        self.etag = etag^

    def member_index(self, member_id: String) -> Int:
        for i in range(len(self.members)):
            if self.members[i].member_id == member_id:
                return i
        return -1


# =============================================================================
# JSON encode and parse of state.json.
# =============================================================================
#
# Shape (members + their blobs hex-encoded so the JSON stays text-clean):
# {"generation_id":N,"leader":"<id>","protocol":"range",
#  "protocol_type":"consumer","state":"Stable","rebalance_deadline":N,
#  "members":[{"member_id":"<id>","subscription":"<hex>","assignment":"<hex>",
#              "join_generation":N}, ...]}


def _hex_encode(data: List[UInt8]) -> String:
    var digits = String("0123456789abcdef")
    var db = digits.as_bytes()
    var out = String("")
    for i in range(len(data)):
        var b = Int(data[i])
        out += chr(Int(db[(b >> 4) & 0xF]))
        out += chr(Int(db[b & 0xF]))
    return out^


def _hex_nibble(c: UInt8) -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c) - ord("a") + 10
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return Int(c) - ord("A") + 10
    return 0


def _hex_decode(s: String) -> List[UInt8]:
    var bs = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    var n = len(bs)
    while i + 1 < n:
        var hi = _hex_nibble(bs[i])
        var lo = _hex_nibble(bs[i + 1])
        out.append(UInt8((hi << 4) | lo))
        i += 2
    return out^


def encode_group_state_json(st: GroupState) -> List[UInt8]:
    """Serialize a GroupState to the state.json body bytes."""
    var s = String('{"generation_id":')
    s += String(st.generation_id)
    s += String(',"leader":"')
    s += st.leader_member_id
    s += String('","protocol":"')
    s += st.protocol
    s += String('","protocol_type":"')
    s += st.protocol_type
    s += String('","state":"')
    s += st.state
    s += String('","rebalance_deadline":')
    s += String(st.rebalance_deadline_ms)
    s += String(',"session_timeout":')
    s += String(st.session_timeout_ms)
    s += String(',"round_opened":')
    s += String(st.round_opened_ms)
    s += String(',"members":[')
    for i in range(len(st.members)):
        ref m = st.members[i]
        if i > 0:
            s += String(",")
        s += String('{"member_id":"')
        s += m.member_id
        s += String('","subscription":"')
        s += _hex_encode(m.subscription)
        s += String('","assignment":"')
        s += _hex_encode(m.assignment)
        s += String('","join_generation":')
        s += String(m.join_generation)
        s += String(',"last_active":')
        s += String(m.last_active_ms)
        s += String("}")
    s += String("]}")
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _find_key(s: String, key: String, start: Int) -> Int:
    var needle = String('"') + key + String('":')
    var idx = s.find(needle, start)
    if idx < 0:
        return -1
    return idx + len(needle.as_bytes())


def _parse_int64_at(s: String, pos: Int) -> Int64:
    var bs = s.as_bytes()
    var i = pos
    var n = len(bs)
    var neg = False
    if i < n and bs[i] == UInt8(ord("-")):
        neg = True
        i += 1
    var v = Int64(0)
    while i < n:
        var c = bs[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            break
        v = v * Int64(10) + Int64(Int(c) - ord("0"))
        i += 1
    return -v if neg else v


def _parse_string_at(s: String, pos: Int) -> String:
    """Parse a JSON string value at `pos` (must point at the opening `"`).
    Group ids / member ids / hex blobs contain no escape chars, so this is a
    plain quote-to-quote scan."""
    var bs = s.as_bytes()
    var i = pos
    var n = len(bs)
    if i >= n or bs[i] != UInt8(ord('"')):
        return String("")
    i += 1
    var start = i
    while i < n and bs[i] != UInt8(ord('"')):
        i += 1
    return String(StringSlice(unsafe_from_utf8=bs[start:i]))


def decode_group_state_json(
    body: List[UInt8], var etag: String
) raises -> GroupState:
    """Parse the state.json body bytes back to a GroupState (carrying `etag` so
    a later read-modify-write can CAS with If-Match). Tolerant of field order
    for the scalar fields; the members array is parsed positionally object by
    object."""
    var s = String(StringSlice(unsafe_from_utf8=Span(body)))
    var gen = Int32(0)
    var gp = _find_key(s, String("generation_id"), 0)
    if gp >= 0:
        gen = Int32(Int(_parse_int64_at(s, gp)))
    var leader = String("")
    var lp = _find_key(s, String("leader"), 0)
    if lp >= 0:
        leader = _parse_string_at(s, lp)
    var protocol = String("")
    var pp = _find_key(s, String("protocol"), 0)
    # Note: "protocol" is a prefix of "protocol_type" — but _find_key matches
    # `"protocol":` exactly (the closing quote+colon), so "protocol_type" (which
    # is `"protocol_type":`) does not collide.
    if pp >= 0:
        protocol = _parse_string_at(s, pp)
    var ptype = String("consumer")
    var ptp = _find_key(s, String("protocol_type"), 0)
    if ptp >= 0:
        ptype = _parse_string_at(s, ptp)
    var state = String(GROUP_STATE_EMPTY)
    var sp = _find_key(s, String("state"), 0)
    if sp >= 0:
        state = _parse_string_at(s, sp)
    var deadline = Int64(0)
    var dp = _find_key(s, String("rebalance_deadline"), 0)
    if dp >= 0:
        deadline = _parse_int64_at(s, dp)
    # `session_timeout` is an additive trailing scalar (absent in older
    # state.json) — default to DEFAULT_SESSION_TIMEOUT_MS when missing.
    var session_timeout = DEFAULT_SESSION_TIMEOUT_MS
    var stp = _find_key(s, String("session_timeout"), 0)
    if stp >= 0:
        session_timeout = _parse_int64_at(s, stp)
    # `round_opened` is an additive trailing scalar (absent in older
    # state.json) — default to 0, which keeps the legacy session-only carry rule
    # (no member is reaped on the round-open test when the field is missing).
    var round_opened = Int64(0)
    var rop = _find_key(s, String("round_opened"), 0)
    if rop >= 0:
        round_opened = _parse_int64_at(s, rop)

    # Parse the members array.
    var members = List[GroupMember]()
    var mstart = _find_key(s, String("members"), 0)
    if mstart >= 0:
        var cursor = mstart
        while True:
            var midp = _find_key(s, String("member_id"), cursor)
            if midp < 0:
                break
            var mid = _parse_string_at(s, midp)
            var subp = _find_key(s, String("subscription"), midp)
            var sub = List[UInt8]()
            if subp >= 0:
                sub = _hex_decode(_parse_string_at(s, subp))
            var asgp = _find_key(s, String("assignment"), midp)
            var asg = List[UInt8]()
            if asgp >= 0:
                asg = _hex_decode(_parse_string_at(s, asgp))
            var jgp = _find_key(s, String("join_generation"), midp)
            var jg = Int32(0)
            if jgp >= 0:
                jg = Int32(Int(_parse_int64_at(s, jgp)))
            # `last_active` is the per-member additive trailing scalar; parse it
            # after join_generation (still inside THIS member object — the next
            # member's member_id key is further along). Absent in older
            # state.json => 0 (treated as long-idle, but the deadline path stamps
            # it on the next join, and heartbeat refreshes it).
            var lap = _find_key(s, String("last_active"), jgp) if jgp >= 0 else -1
            var la = Int64(0)
            if lap >= 0:
                la = _parse_int64_at(s, lap)
            members.append(GroupMember(mid^, sub^, asg^, jg, la))
            # Advance past this member object's last fields so the next
            # _find_key("member_id") finds the NEXT member.
            var advance = lap if lap >= 0 else (jgp if jgp >= 0 else midp + 1)
            cursor = advance
    return GroupState(
        gen,
        leader^,
        protocol^,
        ptype^,
        state^,
        deadline,
        members^,
        etag^,
        session_timeout,
        round_opened,
    )


