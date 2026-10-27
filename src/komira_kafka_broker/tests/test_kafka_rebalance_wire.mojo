# =============================================================================
# tests/test_kafka_rebalance_wire.mojo
#   The consumer-group wire messages the coordinator's callers decode and encode:
#   JoinGroup, SyncGroup, Heartbeat and LeaveGroup round-trips, and the
#   ConsumerProtocol subscription and assignment blobs. A failure here is a
#   codec disagreeing with the byte layout the rebalance tests build by hand.
# =============================================================================

from komira_kafka_server.wire import KafkaEncoder, KafkaDecoder
from komira_kafka_server.wire.consumer_group import (
    JoinGroupProtocol,
    JoinGroupRequest,
    JoinGroupResponseMember,
    decode_join_group_request,
    encode_join_group_response,
    SyncGroupAssignment,
    SyncGroupRequest,
    decode_sync_group_request,
    encode_sync_group_response,
    HeartbeatRequest,
    decode_heartbeat_request,
    encode_heartbeat_response,
    LeaveGroupRequest,
    decode_leave_group_request,
    encode_leave_group_response,
    AssignedTopicPartitions,
    ConsumerSubscription,
    encode_consumer_assignment,
    decode_consumer_assignment,
    decode_consumer_subscription,
    CONSUMER_PROTOCOL_VERSION,
    ERROR_REBALANCE_IN_PROGRESS,
    ERROR_UNKNOWN_MEMBER_ID,
)


def _fail(msg: String) raises:
    raise Error("FAIL: " + msg)


def _check(cond: Bool, msg: String) raises:
    if not cond:
        _fail(msg)



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
# C) Wire encode/decode round-trips.
# =============================================================================


def test_join_group_wire_roundtrip() raises:
    # Build a JoinGroup v4 request, decode it, assert fields.
    var enc = KafkaEncoder()
    enc.put_string(String("g1"))  # group_id
    enc.put_int32(Int32(30000))  # session_timeout
    enc.put_int32(Int32(60000))  # rebalance_timeout (v1+)
    enc.put_string(String(""))  # member_id (first join)
    enc.put_string(String("consumer"))  # protocol_type
    enc.put_array_len(1)  # 1 protocol
    enc.put_string(String("range"))  # protocol name
    var sub_topics = List[String]()
    sub_topics.append(String("t1"))
    var sub = _subscription_blob(sub_topics)
    enc.put_bytes(Span(sub))  # protocol metadata
    var body = enc.take_bytes()

    var dec = KafkaDecoder(Span(body))
    var req = decode_join_group_request(dec, Int16(4))
    _check(req.group_id == String("g1"), "jg wire: group_id")
    _check(req.session_timeout_ms == Int32(30000), "jg wire: session")
    _check(req.rebalance_timeout_ms == Int32(60000), "jg wire: rebalance")
    _check(req.member_id.byte_length() == 0, "jg wire: empty member")
    _check(req.protocol_type == String("consumer"), "jg wire: ptype")
    _check(len(req.protocols) == 1, "jg wire: 1 protocol")
    _check(req.protocols[0].name == String("range"), "jg wire: range")
    # The subscription blob inside decodes to topic t1.
    var psub = decode_consumer_subscription(req.protocols[0].metadata)
    _check(len(psub.topics) == 1, "jg wire: sub 1 topic")
    _check(psub.topics[0] == String("t1"), "jg wire: sub t1")

    # Response encode -> decode (header v0 + throttle(v2+) + fields + members).
    var members = List[JoinGroupResponseMember]()
    members.append(JoinGroupResponseMember(String("m-1"), sub.copy()))
    var resp = encode_join_group_response(
        Int32(7),
        Int16(4),
        Int16(0),
        Int32(1),
        String("range"),
        String("m-1"),
        String("m-1"),
        members,
    )
    var rd = KafkaDecoder(Span(resp))
    _check(rd.get_int32() == Int32(7), "jg resp: correlation")
    _check(rd.get_int32() == Int32(0), "jg resp: throttle (v2+)")
    _check(rd.get_int16() == Int16(0), "jg resp: error")
    _check(rd.get_int32() == Int32(1), "jg resp: generation")
    _check(rd.get_string() == String("range"), "jg resp: protocol")
    _check(rd.get_string() == String("m-1"), "jg resp: leader")
    _check(rd.get_string() == String("m-1"), "jg resp: member_id")
    _check(rd.get_array_len() == 1, "jg resp: 1 member")
    _check(rd.get_string() == String("m-1"), "jg resp: member[0] id")
    var mblob = rd.get_bytes()
    _check(len(mblob) == len(sub), "jg resp: member[0] metadata len")
    print("PASS test_join_group_wire_roundtrip")


def test_sync_group_wire_roundtrip() raises:
    # SyncGroup v3 request: group, gen, member, group_instance_id(null),
    # assignments[1].
    var enc = KafkaEncoder()
    enc.put_string(String("g1"))
    enc.put_int32(Int32(1))  # generation
    enc.put_string(String("m-1"))  # member_id
    enc.put_nullable_string(Optional[String]())  # group_instance_id (v3 null)
    enc.put_array_len(1)
    enc.put_string(String("m-1"))
    var assigned = List[AssignedTopicPartitions]()
    var parts = List[Int32]()
    parts.append(Int32(0))
    parts.append(Int32(1))
    assigned.append(AssignedTopicPartitions(String("t1"), parts^))
    var ablob = encode_consumer_assignment(assigned)
    enc.put_bytes(Span(ablob))
    var body = enc.take_bytes()

    var dec = KafkaDecoder(Span(body))
    var req = decode_sync_group_request(dec, Int16(3))
    _check(req.group_id == String("g1"), "sg wire: group")
    _check(req.generation_id == Int32(1), "sg wire: gen")
    _check(req.member_id == String("m-1"), "sg wire: member")
    _check(len(req.assignments) == 1, "sg wire: 1 assignment")
    _check(req.assignments[0].member_id == String("m-1"), "sg wire: asg member")
    var adec = decode_consumer_assignment(req.assignments[0].assignment)
    _check(len(adec) == 1, "sg wire: asg 1 topic")
    _check(len(adec[0].partitions) == 2, "sg wire: asg 2 parts")

    # Response v3: throttle + error + assignment bytes.
    var resp = encode_sync_group_response(
        Int32(9), Int16(3), Int16(0), ablob.copy()
    )
    var rd = KafkaDecoder(Span(resp))
    _check(rd.get_int32() == Int32(9), "sg resp: correlation")
    _check(rd.get_int32() == Int32(0), "sg resp: throttle")
    _check(rd.get_int16() == Int16(0), "sg resp: error")
    var rab = rd.get_bytes()
    _check(len(rab) == len(ablob), "sg resp: assignment len")
    print("PASS test_sync_group_wire_roundtrip")


def test_heartbeat_wire_roundtrip() raises:
    var enc = KafkaEncoder()
    enc.put_string(String("g1"))
    enc.put_int32(Int32(3))
    enc.put_string(String("m-1"))
    var body = enc.take_bytes()
    var dec = KafkaDecoder(Span(body))
    var req = decode_heartbeat_request(dec)
    _check(req.group_id == String("g1"), "hb wire: group")
    _check(req.generation_id == Int32(3), "hb wire: gen")
    _check(req.member_id == String("m-1"), "hb wire: member")
    # Response v2 (throttle + error).
    var resp = encode_heartbeat_response(
        Int32(5), Int16(2), ERROR_REBALANCE_IN_PROGRESS
    )
    var rd = KafkaDecoder(Span(resp))
    _check(rd.get_int32() == Int32(5), "hb resp: correlation")
    _check(rd.get_int32() == Int32(0), "hb resp: throttle")
    _check(rd.get_int16() == ERROR_REBALANCE_IN_PROGRESS, "hb resp: error 27")
    print("PASS test_heartbeat_wire_roundtrip")


def test_leave_group_wire_roundtrip() raises:
    var enc = KafkaEncoder()
    enc.put_string(String("g1"))
    enc.put_string(String("m-1"))  # top-level member_id (v1/v2)
    var body = enc.take_bytes()
    var dec = KafkaDecoder(Span(body))
    var req = decode_leave_group_request(dec)
    _check(req.group_id == String("g1"), "lg wire: group")
    _check(req.member_id == String("m-1"), "lg wire: member")
    var resp = encode_leave_group_response(Int32(8), Int16(2), Int16(0))
    var rd = KafkaDecoder(Span(resp))
    _check(rd.get_int32() == Int32(8), "lg resp: correlation")
    _check(rd.get_int32() == Int32(0), "lg resp: throttle")
    _check(rd.get_int16() == Int16(0), "lg resp: error")
    print("PASS test_leave_group_wire_roundtrip")


def test_consumer_assignment_format() raises:
    # The MemberAssignment encode matches the ConsumerProtocol format: Version
    # INT16 + AssignedPartitions ARRAY{Topic, Partitions[]} + UserData null.
    var assigned = List[AssignedTopicPartitions]()
    var p1 = List[Int32]()
    p1.append(Int32(0))
    p1.append(Int32(2))
    assigned.append(AssignedTopicPartitions(String("ta"), p1^))
    var p2 = List[Int32]()
    p2.append(Int32(5))
    assigned.append(AssignedTopicPartitions(String("tb"), p2^))
    var blob = encode_consumer_assignment(assigned)

    # Decode raw to confirm the exact byte layout.
    var dec = KafkaDecoder(Span(blob))
    _check(dec.get_int16() == CONSUMER_PROTOCOL_VERSION, "asg fmt: version")
    _check(dec.get_array_len() == 2, "asg fmt: 2 topics")
    _check(dec.get_string() == String("ta"), "asg fmt: topic ta")
    _check(dec.get_array_len() == 2, "asg fmt: ta 2 parts")
    _check(dec.get_int32() == Int32(0), "asg fmt: ta p0")
    _check(dec.get_int32() == Int32(2), "asg fmt: ta p2")
    _check(dec.get_string() == String("tb"), "asg fmt: topic tb")
    _check(dec.get_array_len() == 1, "asg fmt: tb 1 part")
    _check(dec.get_int32() == Int32(5), "asg fmt: tb p5")
    _check(dec.get_int32() == Int32(-1), "asg fmt: userdata null")
    print("PASS test_consumer_assignment_format")



def main() raises:
    test_join_group_wire_roundtrip()
    test_sync_group_wire_roundtrip()
    test_heartbeat_wire_roundtrip()
    test_leave_group_wire_roundtrip()
    test_consumer_assignment_format()
    print("ALL PASS test_kafka_rebalance_wire")
