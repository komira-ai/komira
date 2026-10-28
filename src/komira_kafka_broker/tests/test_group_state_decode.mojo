# =============================================================================
# tests/test_group_state_decode.mojo
#   decode_group_state_json is strict, and the coordinator never reads an
#   object that does not decode as an empty group.
#
#   What each test proves, and the defect it catches:
#   * a well-formed body decodes; a body without the optional fields reads
#     their documented defaults; a UTF-16 surrogate pair in a \u escape reads
#     as the one code point. A decoder that refuses valid text fails these.
#   * every proper prefix of a valid body, an empty body, whitespace, a body
#     that is not JSON, and text after the closing brace are errors. A decoder
#     that reads what it can finds an empty or partial group instead.
#   * a missing required field, a repeated key, a key it does not know, an
#     unknown group state, a number out of range or with a leading zero, a
#     bad or short escape, a raw control character, bytes that are not UTF-8,
#     and hex that is odd or not hex are each an error that names the reason.
#   * a lone surrogate in a \u escape is an error, not a process abort
#     (it was `chr(55296)` aborting the broker).
#   * the coordinator raises from join, sync, heartbeat, leave and load_state
#     over an object that does not decode, says the group's state is
#     unreadable, and leaves the stored bytes as they were: an unreadable
#     object is never a new group, and never reset to one.
#
#   No sleep and no clock reads.
# =============================================================================

from komira_kafka_broker.group_clock import ManualGroupClock
from komira_kafka_broker.group_coordinator import GroupCoordinator
from komira_kafka_broker.group_state import (
    DEFAULT_SESSION_TIMEOUT_MS,
    GroupMember,
    GroupState,
    GROUP_STATE_STABLE,
    decode_group_state_json,
    encode_group_state_json,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_kafka_server.wire import KafkaEncoder
from komira_kafka_server.wire.consumer_group import CONSUMER_PROTOCOL_VERSION

comptime Coordinator = GroupCoordinator[
    SharedInMemoryConditionalStore, ManualGroupClock
]


def _check(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _body(top: String, members: String) -> String:
    """A body with `top` as the scalar fields and `members` inside the array."""
    return String("{") + top + String('"members":[') + members + String("]}")


def _good_top() -> String:
    return String(
        '"generation_id":3,"leader":"m1","protocol":"range",'
    ) + String(
        '"protocol_type":"consumer","state":"Stable","rebalance_deadline":9,'
    ) + String('"session_timeout":7000,"round_opened":4,')


def _good_member() -> String:
    return String(
        '{"member_id":"m1","subscription":"0001","assignment":"ff",'
    ) + String('"join_generation":3,"last_active":5}')


def _head(s: String, n: Int) -> String:
    var b = _bytes(s)
    var out = List[UInt8]()
    for i in range(n):
        out.append(b[i])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _good() -> String:
    return _body(_good_top(), _good_member())


def _refused(body: String, reason: String) raises:
    """`body` must raise, and the message must hold `reason`."""
    var raised = False
    var msg = String("")
    try:
        _ = decode_group_state_json(_bytes(body), String("e"))
    except e:
        raised = True
        msg = String(e)
    _check(raised, "decode refuses: " + reason + " in " + body)
    _check(
        msg.find(reason) >= 0,
        "refusal names '" + reason + "', got: " + msg,
    )


def test_well_formed_body_decodes() raises:
    var st = decode_group_state_json(_bytes(_good()), String("etag-1"))
    _check(st.generation_id == Int32(3), "generation")
    _check(st.leader_member_id == String("m1"), "leader")
    _check(st.protocol == String("range"), "protocol")
    _check(st.state == String(GROUP_STATE_STABLE), "state")
    _check(st.rebalance_deadline_ms == Int64(9), "deadline")
    _check(st.session_timeout_ms == Int64(7000), "session timeout")
    _check(st.round_opened_ms == Int64(4), "round opened")
    _check(st.etag == String("etag-1"), "etag carried")
    _check(len(st.members) == 1, "one member")
    _check(len(st.members[0].subscription) == 2, "subscription hex")
    _check(st.members[0].assignment[0] == UInt8(0xFF), "assignment hex")
    _check(st.members[0].last_active_ms == Int64(5), "last_active")
    print("PASS test_well_formed_body_decodes")


def test_optional_fields_read_their_defaults() raises:
    var body = String(
        '{ "generation_id" : 2 , "leader" : "" , "protocol" : "range" ,'
        ' "state" : "Empty" , "members" : [ { "member_id" : "m" ,'
        ' "subscription" : "" , "assignment" : "" , "join_generation" : 2 } ] }\n'
    )
    var st = decode_group_state_json(_bytes(body), String("e"))
    _check(st.protocol_type == String("consumer"), "protocol_type default")
    _check(st.rebalance_deadline_ms == Int64(0), "deadline default")
    _check(st.session_timeout_ms == DEFAULT_SESSION_TIMEOUT_MS, "session default")
    _check(st.round_opened_ms == Int64(0), "round_opened default")
    _check(st.members[0].last_active_ms == Int64(0), "last_active default")
    print("PASS test_optional_fields_read_their_defaults")


def test_a_surrogate_pair_reads_as_one_code_point() raises:
    var body = String(
        '{"generation_id":1,"leader":"a\\ud83d\\ude00b","protocol":"range",'
        '"state":"Stable","members":[]}'
    )
    var st = decode_group_state_json(_bytes(body), String("e"))
    _check(st.leader_member_id == String("a") + chr(0x1F600) + String("b"), "emoji")
    print("PASS test_a_surrogate_pair_reads_as_one_code_point")


def test_encoder_output_always_decodes() raises:
    var hostile = String('q"\\') + chr(10) + chr(0) + chr(0x1F600) + String("é/")
    var members = List[GroupMember]()
    members.append(GroupMember(hostile.copy(), _bytes("xy"), List[UInt8](), Int32(2), Int64(3)))
    var st = GroupState(
        Int32(2), hostile.copy(), hostile.copy(), String("consumer"),
        String(GROUP_STATE_STABLE), Int64(1), members^, String(""),
    )
    var back = decode_group_state_json(encode_group_state_json(st), String("e"))
    _check(back.leader_member_id == hostile, "leader")
    _check(back.members[0].member_id == hostile, "member id")
    _check(len(back.members[0].subscription) == 2, "subscription")
    print("PASS test_encoder_output_always_decodes")


def test_every_proper_prefix_is_refused() raises:
    var full = _bytes(_good())
    for n in range(len(full)):
        var part = List[UInt8]()
        for k in range(n):
            part.append(full[k])
        var raised = False
        try:
            _ = decode_group_state_json(part, String("e"))
        except:
            raised = True
        _check(raised, "prefix of " + String(n) + " bytes is refused")
    print("PASS test_every_proper_prefix_is_refused")


def test_garbage_bodies_are_refused() raises:
    _refused(String(""), "truncated")
    _refused(String("   \n"), "truncated")
    _refused(String("not json"), "expected {")
    _refused(String("[]"), "expected {")
    _refused(String("{}"), "expected a string")
    _refused(_good() + String("x"), "text after the closing brace")
    _refused(_good() + String("{}"), "text after the closing brace")
    _refused(
        String('{"generation_id":1,"leader":"a\\'),
        "truncated",
    )
    print("PASS test_garbage_bodies_are_refused")


def test_missing_required_fields_are_refused() raises:
    var m = _good_member()
    _refused(
        _body(String('"leader":"m1","protocol":"range","state":"Stable",'), m),
        "missing generation_id",
    )
    _refused(
        _body(String('"generation_id":3,"protocol":"range","state":"Stable",'), m),
        "missing leader",
    )
    _refused(
        _body(String('"generation_id":3,"leader":"m1","state":"Stable",'), m),
        "missing protocol",
    )
    _refused(
        _body(String('"generation_id":3,"leader":"m1","protocol":"range",'), m),
        "missing state",
    )
    _refused(
        String('{"generation_id":3,"leader":"m1","protocol":"range","state":"Stable"}'),
        "missing members",
    )
    _refused(
        _body(_good_top(), String('{"subscription":"","assignment":"","join_generation":1}')),
        "without member_id",
    )
    _refused(
        _body(_good_top(), String('{"member_id":"m","assignment":"","join_generation":1}')),
        "without subscription",
    )
    _refused(
        _body(_good_top(), String('{"member_id":"m","subscription":"","join_generation":1}')),
        "without assignment",
    )
    _refused(
        _body(_good_top(), String('{"member_id":"m","subscription":"","assignment":""}')),
        "without join_generation",
    )
    print("PASS test_missing_required_fields_are_refused")


def test_malformed_fields_are_refused() raises:
    _refused(_good().replace('"leader":"m1",', '"leader":"m1","leader":"m2",'), "repeated")
    _refused(_good().replace('"leader":"m1",', '"leader":"m1","extra":1,'), "unknown field")
    _refused(_good().replace('"Stable"', '"Wedged"'), "unknown group state")
    _refused(_good().replace('"generation_id":3', '"generation_id":2147483648'), "32-bit")
    _refused(_good().replace('"generation_id":3', '"generation_id":03'), "leading zero")
    _refused(_good().replace('"generation_id":3', '"generation_id":-'), "expected an integer")
    _refused(_good().replace('"generation_id":3', '"generation_id":"3"'), "expected an integer")
    _refused(_good().replace('"session_timeout":7000', '"session_timeout":99999999999999999999'), "out of range")
    _refused(_good().replace('"leader":"m1"', '"leader":"m\\q"'), "unknown escape")
    _refused(_good().replace('"leader":"m1"', '"leader":"m\\u00"'), "malformed \\u")
    _refused(_good().replace('"leader":"m1"', '"leader":"m\\u00zz"'), "malformed \\u")
    _refused(_good().replace('"leader":"m1"', String('"leader":"m') + chr(1) + String('"')), "control character")
    _refused(_good().replace('"assignment":"ff"', '"assignment":"f"'), "odd length")
    _refused(_good().replace('"assignment":"ff"', '"assignment":"fg"'), "non-hex")
    _refused(_good().replace('"join_generation":3', '"join_generation":3000000000'), "32-bit")
    _refused(_good().replace('"members":[', '"members":[,'), "expected {")
    _refused(_good().replace('}]}', '},]}'), "expected {")
    print("PASS test_malformed_fields_are_refused")


def test_bytes_that_are_not_utf8_are_refused() raises:
    var body = _bytes(_good())
    var at = -1
    for i in range(len(body) - 1):
        if body[i] == UInt8(ord("m")) and body[i + 1] == UInt8(ord("1")):
            at = i
            break
    body[at] = UInt8(0xFF)
    var raised = False
    var msg = String("")
    try:
        _ = decode_group_state_json(body, String("e"))
    except e:
        raised = True
        msg = String(e)
    _check(raised, "invalid UTF-8 is refused")
    _check(msg.find("not valid UTF-8") >= 0, "names UTF-8, got: " + msg)
    print("PASS test_bytes_that_are_not_utf8_are_refused")


def test_lone_surrogates_are_errors_not_aborts() raises:
    _refused(_good().replace('"m1","protocol"', '"m\\ud800","protocol"'), "lone high surrogate")
    _refused(_good().replace('"m1","protocol"', '"m\\udfff","protocol"'), "lone low surrogate")
    _refused(_good().replace('"m1","protocol"', '"m\\ud800x","protocol"'), "lone high surrogate")
    _refused(_good().replace('"m1","protocol"', '"m\\ud800\\u0041","protocol"'), "not followed by a low")
    _refused(_good().replace('"m1","protocol"', '"m\\udc00\\ud800","protocol"'), "lone low surrogate")
    print("PASS test_lone_surrogates_are_errors_not_aborts")


# -- the coordinator over an object that does not decode ----------------------


def _sub() -> List[UInt8]:
    var enc = KafkaEncoder()
    enc.put_int16(CONSUMER_PROTOCOL_VERSION)
    enc.put_array_len(1)
    enc.put_string(String("t1"))
    enc.put_int32(Int32(-1))
    return enc.take_bytes()


def _names() -> List[String]:
    var p = List[String]()
    p.append(String("range"))
    return p^


def _raises_unreadable(var op_name: String, err: String, raised: Bool) raises:
    _check(raised, op_name + " raises over an unreadable object")
    _check(err.find("unreadable") >= 0, op_name + " names the unreadable state, got: " + err)


def test_coordinator_raises_and_leaves_an_unreadable_object_alone() raises:
    var bodies = List[String]()
    bodies.append(String(""))
    bodies.append(String("garbage"))
    bodies.append(_head(_good(), 40))
    bodies.append(String('{"generation_id":1,"leader":"a\\ud800b","protocol":"range","state":"Stable","members":[]}'))
    bodies.append(String('{"generation_id":1,"leader":"a","protocol":"range","state":"Stable"}'))
    for bi in range(len(bodies)):
        var raw = SharedInMemoryConditionalStore()
        var key = Path.parse(String("c/_meta/groups/g/state.json"))
        _ = raw.put(key, _bytes(bodies[bi]))
        var c = Coordinator(raw.clone(), String("c"), ManualGroupClock(), String(""))
        var tag = String(" (body ") + String(bi) + String(")")

        var raised = False
        var err = String("")
        try:
            _ = c.join_group(String("g"), String(""), String("cli"), _names(), _sub(), Int32(0))
        except e:
            raised = True
            err = String(e)
        _raises_unreadable(String("join") + tag, err, raised)

        raised = False
        err = String("")
        try:
            _ = c.heartbeat(String("g"), String("m"), Int32(1))
        except e:
            raised = True
            err = String(e)
        _raises_unreadable(String("heartbeat") + tag, err, raised)

        raised = False
        err = String("")
        try:
            _ = c.leave_group(String("g"), String("m"))
        except e:
            raised = True
            err = String(e)
        _raises_unreadable(String("leave") + tag, err, raised)

        raised = False
        err = String("")
        var ids = List[String]()
        ids.append(String("m"))
        var blobs = List[List[UInt8]]()
        blobs.append(List[UInt8]())
        try:
            _ = c.sync_group(String("g"), String("m"), Int32(1), ids, blobs)
        except e:
            raised = True
            err = String(e)
        _raises_unreadable(String("sync") + tag, err, raised)

        raised = False
        err = String("")
        try:
            _ = c.load_state(String("g"))
        except e:
            raised = True
            err = String(e)
        _raises_unreadable(String("load_state") + tag, err, raised)

        var after = raw.get(key)
        _check(len(after) == len(_bytes(bodies[bi])), "object length unchanged" + tag)
        for k in range(len(after)):
            _check(after[k] == _bytes(bodies[bi])[k], "object bytes unchanged" + tag)
    print("PASS test_coordinator_raises_and_leaves_an_unreadable_object_alone")


def _report(name: String, e: Error, mut failed: Int):
    print("FAIL " + name + ": " + String(e))
    failed += 1


def main() raises:
    var failed = 0
    try:
        test_well_formed_body_decodes()
    except e:
        _report(String("well_formed"), e, failed)
    try:
        test_optional_fields_read_their_defaults()
    except e:
        _report(String("optional_defaults"), e, failed)
    try:
        test_a_surrogate_pair_reads_as_one_code_point()
    except e:
        _report(String("surrogate_pair"), e, failed)
    try:
        test_encoder_output_always_decodes()
    except e:
        _report(String("encoder_output_decodes"), e, failed)
    try:
        test_every_proper_prefix_is_refused()
    except e:
        _report(String("prefixes_refused"), e, failed)
    try:
        test_garbage_bodies_are_refused()
    except e:
        _report(String("garbage_refused"), e, failed)
    try:
        test_missing_required_fields_are_refused()
    except e:
        _report(String("missing_fields"), e, failed)
    try:
        test_malformed_fields_are_refused()
    except e:
        _report(String("malformed_fields"), e, failed)
    try:
        test_bytes_that_are_not_utf8_are_refused()
    except e:
        _report(String("not_utf8"), e, failed)
    try:
        test_coordinator_raises_and_leaves_an_unreadable_object_alone()
    except e:
        _report(String("coordinator_unreadable"), e, failed)
    # Last: on a decoder that aborts on a surrogate escape this takes the
    # process down, so every other test has already reported.
    try:
        test_lone_surrogates_are_errors_not_aborts()
    except e:
        _report(String("lone_surrogates"), e, failed)
    if failed > 0:
        raise Error("test_group_state_decode: " + String(failed) + " FAILED")
    print("test_group_state_decode: ALL PASS")
