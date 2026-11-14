# =============================================================================
# group_state.mojo: the persisted state of a consumer group.
# =============================================================================
#
# A group's membership lives in one object, <cluster>/_meta/groups/<id>/state.json.
# This module holds its in-memory model (GroupMember, GroupState), the group
# lifecycle state names, the timing constants the state carries, and the JSON
# encoder and decoder for the object. The JSON is hand-written: bytes in, bytes
# out, with the member blobs hex-encoded so the body stays text. Strings that
# come from the wire (member ids, the leader, protocol names) are JSON-escaped on
# the way out and unescaped on the way in, so a quote, a backslash or a control
# character in an id cannot end the string it sits in.
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
    SESSION-ALIVE iff `now - last_active_ms < session_timeout_ms`. When a round
    closes, a session-alive incumbent that has not yet rejoined at the new
    generation is kept (re-anchored to the current generation, carrying its
    prior subscription) instead of being dropped on the rebalance deadline; an
    older-generation member whose session has expired is dropped. The check
    runs only when a round closes: nothing sweeps a member out of a Stable
    group."""

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
    # The session timeout (ms) the group's members negotiated. When a round
    # closes, an older-generation member that has not heartbeat-or-joined within
    # this window is dropped; one still within it is SESSION-ALIVE and is kept.
    # Nothing evicts a member outside a closing round. Carried in state.json so
    # every broker driving the group reads the same session bound.
    var session_timeout_ms: Int64
    # The wall-clock (ms) at which the CURRENT rebalance round OPENED (the join
    # that bumped the generation / re-prepared a Stable group). Used to reap a
    # GHOST member: an old-generation member is only carried forward on the
    # session-aware close if it was active (join or heartbeat) no earlier than
    # GHOST_STALE_GRACE_MS before the round opened
    # (last_active_ms >= round_opened_ms - GHOST_STALE_GRACE_MS). A stale id
    # whose last_active predates that (a consumer that reconnected under a NEW
    # member_id, leaving its OLD id behind, or a member that has gone silent) is
    # dropped even when nominally inside the session window, so a ghost cannot
    # widen the leader's split. Stamped in state.json so every broker reads the
    # same round-open instant. A state.json without the field reads as 0, and 0
    # skips the round-open test (only the session test applies).
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
# The shape is the one in the header: members and their blobs are hex-encoded so
# the JSON stays text-clean.


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
    """The value of one hex digit, or -1 if `c` is not one."""
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c) - ord("a") + 10
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return Int(c) - ord("A") + 10
    return -1


def _json_escape(s: String) -> String:
    """`s` as the inside of a JSON string: `"` and `\\` get a backslash and a
    control character below 0x20 becomes `\\u00XX`."""
    var digit_chars = String("0123456789abcdef")
    var digits = digit_chars.as_bytes()
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        var c = bs[i]
        if c == UInt8(ord('"')) or c == UInt8(ord("\\")):
            out.append(UInt8(ord("\\")))
            out.append(c)
        elif c < UInt8(0x20):
            out.extend(String("\\u00").as_bytes())
            out.append(digits[Int(c >> 4)])
            out.append(digits[Int(c & 0xF)])
        else:
            out.append(c)
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def encode_group_state_json(st: GroupState) -> List[UInt8]:
    """Serialize a GroupState to the state.json body bytes."""
    var s = String('{"generation_id":')
    s += String(st.generation_id)
    s += String(',"leader":"')
    s += _json_escape(st.leader_member_id)
    s += String('","protocol":"')
    s += _json_escape(st.protocol)
    s += String('","protocol_type":"')
    s += _json_escape(st.protocol_type)
    s += String('","state":"')
    s += _json_escape(st.state)
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
        s += _json_escape(m.member_id)
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

def _hex4(bs: Span[UInt8, _], at: Int) -> Int:
    """The value of the four hex digits at `at`, or -1 if they are not there."""
    if at + 4 > len(bs):
        return -1
    var v = 0
    for k in range(4):
        var c = bs[at + k]
        var is_hex = (
            (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or (c >= UInt8(ord("a")) and c <= UInt8(ord("f")))
            or (c >= UInt8(ord("A")) and c <= UInt8(ord("F")))
        )
        if not is_hex:
            return -1
        v = (v << 4) | _hex_nibble(c)
    return v



# -- strict decoding -----------------------------------------------------------
#
# The decoder reads the body as the JSON the encoder writes, token by token. It
# raises, naming the byte offset, on anything else: an empty or truncated body,
# text after the closing brace, a missing or repeated key, a key it does not
# know, a number that is not an integer in range, a string with a raw control
# character or an unknown or malformed escape (a lone UTF-16 surrogate included),
# bytes that are not UTF-8, hex that is odd or not hex, and a group state that
# is not one of the four names. Required: generation_id, leader, protocol,
# state, members, and in each member member_id, subscription, assignment and
# join_generation. Optional, with the default named: protocol_type ("consumer"),
# rebalance_deadline (0), session_timeout (DEFAULT_SESSION_TIMEOUT_MS) and
# round_opened (0) at the top, last_active (0) in a member.


struct _Reader(Movable):
    var bs: List[UInt8]
    var i: Int

    def __init__(out self, var bs: List[UInt8]):
        self.bs = bs^
        self.i = 0

    def err(self, what: String) -> Error:
        return Error(
            String("state.json: ") + what + String(" at byte ") + String(self.i)
        )

    def peek(self) -> Int:
        if self.i >= len(self.bs):
            return -1
        return Int(self.bs[self.i])

    def skip_ws(mut self):
        while self.i < len(self.bs):
            var c = self.bs[self.i]
            if (
                c == UInt8(0x20)
                or c == UInt8(0x09)
                or c == UInt8(0x0A)
                or c == UInt8(0x0D)
            ):
                self.i += 1
            else:
                break

    def expect(mut self, c: String) raises:
        self.skip_ws()
        if self.peek() != ord(c):
            if self.peek() < 0:
                raise self.err(String("truncated, expected ") + c)
            raise self.err(String("expected ") + c)
        self.i += 1

    def read_string(mut self) raises -> String:
        self.skip_ws()
        if self.peek() < 0:
            raise self.err(String("truncated, expected a string"))
        if self.peek() != ord('"'):
            raise self.err(String("expected a string"))
        self.i += 1
        var out = List[UInt8]()
        while True:
            if self.i >= len(self.bs):
                raise self.err(String("truncated inside a string"))
            var c = self.bs[self.i]
            if c == UInt8(ord('"')):
                self.i += 1
                break
            if c < UInt8(0x20):
                raise self.err(String("control character inside a string"))
            if c != UInt8(ord("\\")):
                out.append(c)
                self.i += 1
                continue
            self.i += 1
            if self.i >= len(self.bs):
                raise self.err(String("truncated escape"))
            var e = self.bs[self.i]
            self.i += 1
            if e == UInt8(ord("n")):
                out.append(UInt8(10))
            elif e == UInt8(ord("t")):
                out.append(UInt8(9))
            elif e == UInt8(ord("r")):
                out.append(UInt8(13))
            elif e == UInt8(ord("b")):
                out.append(UInt8(8))
            elif e == UInt8(ord("f")):
                out.append(UInt8(12))
            elif (
                e == UInt8(ord('"'))
                or e == UInt8(ord("\\"))
                or e == UInt8(ord("/"))
            ):
                out.append(e)
            elif e == UInt8(ord("u")):
                var code = _hex4(self.bs, self.i)
                if code < 0:
                    raise self.err(String("malformed \\u escape"))
                self.i += 4
                if code >= 0xDC00 and code <= 0xDFFF:
                    raise self.err(String("lone low surrogate in \\u escape"))
                if code >= 0xD800 and code <= 0xDBFF:
                    if (
                        self.i + 1 >= len(self.bs)
                        or self.bs[self.i] != UInt8(ord("\\"))
                        or self.bs[self.i + 1] != UInt8(ord("u"))
                    ):
                        raise self.err(
                            String("lone high surrogate in \\u escape")
                        )
                    var low = _hex4(self.bs, self.i + 2)
                    if low < 0xDC00 or low > 0xDFFF:
                        raise self.err(
                            String("high surrogate not followed by a low one")
                        )
                    self.i += 6
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                if code < 0x80:
                    out.append(UInt8(code))
                else:
                    out.extend(chr(code).as_bytes())
            else:
                raise self.err(String("unknown escape"))
        try:
            return String(StringSlice(from_utf8=Span(out)))
        except:
            raise self.err(String("string is not valid UTF-8"))

    def read_int(mut self) raises -> Int64:
        self.skip_ws()
        var neg = False
        if self.peek() == ord("-"):
            neg = True
            self.i += 1
        var start = self.i
        var v = Int64(0)
        var limit = Int64(9223372036854775807)
        while self.i < len(self.bs):
            var c = self.bs[self.i]
            if c < UInt8(ord("0")) or c > UInt8(ord("9")):
                break
            var d = Int64(Int(c) - ord("0"))
            if v > (limit - d) // Int64(10):
                raise self.err(String("integer out of range"))
            v = v * Int64(10) + d
            self.i += 1
        if self.i == start:
            raise self.err(String("expected an integer"))
        if self.bs[start] == UInt8(ord("0")) and self.i - start > 1:
            raise self.err(String("integer with a leading zero"))
        return -v if neg else v

    def read_int32(mut self) raises -> Int32:
        var v = self.read_int()
        if v < Int64(-2147483648) or v > Int64(2147483647):
            raise self.err(String("integer out of the 32-bit range"))
        return Int32(Int(v))

    def read_hex(mut self) raises -> List[UInt8]:
        var s = self.read_string()
        var bs = s.as_bytes()
        if len(bs) % 2 != 0:
            raise self.err(String("hex string of odd length"))
        var out = List[UInt8]()
        var k = 0
        while k < len(bs):
            var hi = _hex_nibble(bs[k])
            var lo = _hex_nibble(bs[k + 1])
            if hi < 0 or lo < 0:
                raise self.err(String("hex string with a non-hex digit"))
            out.append(UInt8((hi << 4) | lo))
            k += 2
        return out^

    def after_value(mut self, close: String) raises -> Bool:
        """After a value inside an object or array: True for a comma (another
        entry follows), False for the closing character."""
        self.skip_ws()
        var c = self.peek()
        if c < 0:
            raise self.err(String("truncated, expected , or ") + close)
        if c == ord(","):
            self.i += 1
            return True
        if c == ord(close):
            self.i += 1
            return False
        raise self.err(String("expected , or ") + close)


def _read_member(mut r: _Reader) raises -> GroupMember:
    r.expect(String("{"))
    var mid = String("")
    var sub = List[UInt8]()
    var asg = List[UInt8]()
    var jg = Int32(0)
    var la = Int64(0)
    var seen_mid = False
    var seen_sub = False
    var seen_asg = False
    var seen_jg = False
    var seen_la = False
    while True:
        var key = r.read_string()
        r.expect(String(":"))
        if key == String("member_id"):
            if seen_mid:
                raise r.err(String("member_id repeated"))
            seen_mid = True
            mid = r.read_string()
        elif key == String("subscription"):
            if seen_sub:
                raise r.err(String("subscription repeated"))
            seen_sub = True
            sub = r.read_hex()
        elif key == String("assignment"):
            if seen_asg:
                raise r.err(String("assignment repeated"))
            seen_asg = True
            asg = r.read_hex()
        elif key == String("join_generation"):
            if seen_jg:
                raise r.err(String("join_generation repeated"))
            seen_jg = True
            jg = r.read_int32()
        elif key == String("last_active"):
            if seen_la:
                raise r.err(String("last_active repeated"))
            seen_la = True
            la = r.read_int()
        else:
            raise r.err(String("unknown member field ") + key)
        if not r.after_value(String("}")):
            break
    if not seen_mid:
        raise r.err(String("member without member_id"))
    if not seen_sub:
        raise r.err(String("member without subscription"))
    if not seen_asg:
        raise r.err(String("member without assignment"))
    if not seen_jg:
        raise r.err(String("member without join_generation"))
    return GroupMember(mid^, sub^, asg^, jg, la)


def decode_group_state_json(
    body: List[UInt8], var etag: String
) raises -> GroupState:
    """Parse the state.json body bytes back to a GroupState (carrying `etag` so
    a later read-modify-write can CAS with If-Match). Strict: raises an Error
    naming the problem and the byte offset for a body that is empty, truncated,
    not the JSON `encode_group_state_json` writes, or missing a required field
    (see the block above). Never aborts the process, whatever the bytes."""
    var r = _Reader(body.copy())
    r.expect(String("{"))
    var gen = Int32(0)
    var leader = String("")
    var protocol = String("")
    var ptype = String("consumer")
    var state = String("")
    var deadline = Int64(0)
    var session_timeout = DEFAULT_SESSION_TIMEOUT_MS
    var round_opened = Int64(0)
    var members = List[GroupMember]()
    var seen_gen = False
    var seen_leader = False
    var seen_protocol = False
    var seen_state = False
    var seen_members = False
    var seen_ptype = False
    var seen_deadline = False
    var seen_session = False
    var seen_round = False
    while True:
        var key = r.read_string()
        r.expect(String(":"))
        if key == String("generation_id"):
            if seen_gen:
                raise r.err(String("generation_id repeated"))
            seen_gen = True
            gen = r.read_int32()
        elif key == String("leader"):
            if seen_leader:
                raise r.err(String("leader repeated"))
            seen_leader = True
            leader = r.read_string()
        elif key == String("protocol"):
            if seen_protocol:
                raise r.err(String("protocol repeated"))
            seen_protocol = True
            protocol = r.read_string()
        elif key == String("protocol_type"):
            if seen_ptype:
                raise r.err(String("protocol_type repeated"))
            seen_ptype = True
            ptype = r.read_string()
        elif key == String("state"):
            if seen_state:
                raise r.err(String("state repeated"))
            seen_state = True
            state = r.read_string()
            if (
                state != String(GROUP_STATE_EMPTY)
                and state != String(GROUP_STATE_PREPARING)
                and state != String(GROUP_STATE_COMPLETING)
                and state != String(GROUP_STATE_STABLE)
            ):
                raise r.err(String("unknown group state ") + state)
        elif key == String("rebalance_deadline"):
            if seen_deadline:
                raise r.err(String("rebalance_deadline repeated"))
            seen_deadline = True
            deadline = r.read_int()
        elif key == String("session_timeout"):
            if seen_session:
                raise r.err(String("session_timeout repeated"))
            seen_session = True
            session_timeout = r.read_int()
        elif key == String("round_opened"):
            if seen_round:
                raise r.err(String("round_opened repeated"))
            seen_round = True
            round_opened = r.read_int()
        elif key == String("members"):
            if seen_members:
                raise r.err(String("members repeated"))
            seen_members = True
            r.expect(String("["))
            r.skip_ws()
            if r.peek() == ord("]"):
                r.i += 1
            else:
                while True:
                    members.append(_read_member(r))
                    if not r.after_value(String("]")):
                        break
        else:
            raise r.err(String("unknown field ") + key)
        if not r.after_value(String("}")):
            break
    r.skip_ws()
    if r.i != len(r.bs):
        raise r.err(String("text after the closing brace"))
    if not seen_gen:
        raise r.err(String("missing generation_id"))
    if not seen_leader:
        raise r.err(String("missing leader"))
    if not seen_protocol:
        raise r.err(String("missing protocol"))
    if not seen_state:
        raise r.err(String("missing state"))
    if not seen_members:
        raise r.err(String("missing members"))
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
