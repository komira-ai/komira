# =============================================================================
# test_resource_messaging_numbers.mojo
# =============================================================================
#
# THE MESSAGING TYPES OF `kci.resource.v1`, FIELD BY FIELD, AS WIRE BYTES:
# the field template of test_resource_field_numbers.mojo for `Queue`,
# `Topic` and `Subscription` (that file is past the size a Mojo source should
# stay under, so the three are pinned here; it still pins their body arms
# 15, 21 and 28 by the field each fills, and `Access` SEND 5 and RECEIVE 6).
#
# For each message:
#   1. WIRE BYTES BY NAME. A byte stream written by hand, field by field,
#      with the number the proto declares and a value no other field holds,
#      is decoded and every field read back BY NAME. This catches two
#      fields of one wire type swapping numbers.
#   2. BINARY ROUND TRIP. The decoded message re-encodes to the hand-written
#      records (zero values aside, `_same`). This catches a field moved to a
#      number nothing else uses, and a changed wire type.
#   3. JSON ROUND TRIP. Its proto3 JSON carries the camelCase names an
#      author writes (`ackDeadline`, `deadLetter`, `maxDeliveries`, `topic`,
#      `queue`), decodes back to the same message, and re-encodes to the same
#      binary bytes.
#   4. ABSENT IS UNSET. An empty record decodes with every field absent:
#      `max_deliveries` has presence (an explicit 0 is present, and refused
#      when the graph is validated, never here), and `ack_deadline` and both
#      `Ref`s are absent messages.
#   5. AS ITS ARM. As `Resource.body` 15 (`queue`), 21 (`topic`) and 28
#      (`subscription`), each fills its own field, at its position in
#      declaration order (6th, 10th and 17th; the census of every arm is in
#      test_resource_compute_numbers.mojo).
# The bytes are a LITERAL restatement of the proto, deliberately.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from kci_resource_proto.resource import (
    Access,
    Queue,
    Resource,
    Retention,
    Subscription,
    Topic,
    Uses,
)


# ---- a hand-written wire stream (as in test_resource_field_numbers) -------------

comptime _VARINT = 0
comptime _LEN = 2


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _uint(mut b: List[UInt8], field: Int, v: UInt64):
    _varint(b, UInt64((field << 3) | _VARINT))
    _varint(b, v)


def _str(mut b: List[UInt8], field: Int, s: String):
    _varint(b, UInt64((field << 3) | _LEN))
    _varint(b, UInt64(s.byte_length()))
    for c in s.as_bytes():
        b.append(c)


def _msg(mut b: List[UInt8], field: Int, m: List[UInt8]):
    _varint(b, UInt64((field << 3) | _LEN))
    _varint(b, UInt64(len(m)))
    for i in range(len(m)):
        b.append(m[i])


def _ref(resource: String) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, resource)
    return b^


def _hex(b: List[UInt8]) -> String:
    var digits = String("0123456789abcdef")
    var out = String("")
    for i in range(len(b)):
        var v = Int(b[i])
        out += String(digits[byte = v >> 4 : (v >> 4) + 1])
        out += String(digits[byte = v & 15 : (v & 15) + 1])
    return out^


def _read_varint(b: List[UInt8], mut pos: Int, mut ok: Bool) -> UInt64:
    var v: UInt64 = 0
    var shift = 0
    while pos < len(b) and shift < 64:
        var c = b[pos]
        pos += 1
        v |= UInt64(c & 0x7F) << UInt64(shift)
        if c < 0x80:
            return v
        shift += 7
    ok = False
    return 0


def _canon(b: List[UInt8], mut out: List[UInt8]) -> Bool:
    """`b` with every zero-valued record dropped, recursively, and its records
    sorted stably by field number. False when `b` does not parse as a
    message (varint and length-delimited records only: no messaging field is
    fixed-width)."""
    var fields = List[Int]()
    var records = List[List[UInt8]]()
    var pos = 0
    var ok = True
    while pos < len(b):
        var tag = _read_varint(b, pos, ok)
        if not ok or (tag >> 3) == 0:
            return False
        var rec = List[UInt8]()
        if Int(tag & 7) == _VARINT:
            var v = _read_varint(b, pos, ok)
            if not ok:
                return False
            if v == 0:
                continue
            _varint(rec, tag)
            _varint(rec, v)
        elif Int(tag & 7) == _LEN:
            var n = Int(_read_varint(b, pos, ok))
            if not ok or pos + n > len(b):
                return False
            var content = List[UInt8]()
            for k in range(n):
                content.append(b[pos + k])
            pos += n
            var inner = List[UInt8]()
            if not _canon(content, inner):
                inner = content^
            if len(inner) == 0:
                continue
            _varint(rec, tag)
            _varint(rec, UInt64(len(inner)))
            for k in range(len(inner)):
                rec.append(inner[k])
        else:
            return False
        var j = len(fields)
        fields.append(Int(tag >> 3))
        records.append(rec^)
        while j > 0 and fields[j - 1] > fields[j]:
            var f = fields[j]
            fields[j] = fields[j - 1]
            fields[j - 1] = f
            var r = records[j].copy()
            records[j] = records[j - 1].copy()
            records[j - 1] = r^
            j -= 1
    for k in range(len(records)):
        for x in range(len(records[k])):
            out.append(records[k][x])
    return True


def _same(got: List[UInt8], want: List[UInt8], what: String) raises:
    var cg = List[UInt8]()
    var cw = List[UInt8]()
    assert_true(_canon(got, cg), what + ": the encoding does not parse")
    assert_true(_canon(want, cw), what + ": the hand-written bytes do not parse")
    assert_equal(
        _hex(cg),
        _hex(cw),
        what + ": re-encoding the decoded message does not give the hand-written records back",
    )


def _bytes_equal(a: List[UInt8], b: List[UInt8], what: String) raises:
    assert_equal(_hex(a), _hex(b), what)


# ---- queue -----------------------------------------------------------------------


def _queue() -> List[UInt8]:
    """Queue { ack_deadline: 45s, dead_letter: "dlq", max_deliveries: 7 }."""
    var deadline = List[UInt8]()
    _uint(deadline, 1, 45)  # Duration.seconds
    var b = List[UInt8]()
    _msg(b, 1, deadline)
    _msg(b, 2, _ref("dlq"))
    _uint(b, 3, 7)
    return b^


def test_queue() raises:
    """Queue: 1 ack_deadline (a Duration), 2 dead_letter (a Ref), 3
    max_deliveries (presence); by name, binary, JSON, absent = unset; as the
    `queue` arm 15 (the sixth) of a Resource with retention 3."""
    var b = _queue()
    var q = decode_proto[Queue](b.copy())
    assert_equal(Int(q.ack_deadline.value().seconds), 45, "field 1 is `ack_deadline`")
    assert_equal(q.dead_letter.value().resource, "dlq", "field 2 is `dead_letter`")
    assert_equal(Int(q.max_deliveries.value()), 7, "field 3 is `max_deliveries`")
    _same(encode_proto(q), b, "Queue")

    var text = encode_json(q)
    for key in ['"ackDeadline":"45s"', '"deadLetter":{"resource":"dlq"', '"maxDeliveries":7']:
        assert_true(String(key) in text, String("Queue JSON carries ") + String(key) + ": " + text)
    var back = decode_json[Queue](text)
    assert_equal(back.dead_letter.value().resource, "dlq", "JSON: dead_letter")
    _bytes_equal(encode_proto(back), encode_proto(q), "Queue: JSON round trip, binary bytes")

    # Presence: an explicit 0 is a value; nothing written is absent.
    var zero = List[UInt8]()
    _uint(zero, 3, 0)
    var qz = decode_proto[Queue](zero.copy())
    assert_true(Bool(qz.max_deliveries), "an explicit max_deliveries of 0 is present")
    assert_equal(Int(qz.max_deliveries.value()), 0)
    var none = decode_proto[Queue](List[UInt8]())
    assert_true(not Bool(none.max_deliveries), "an unwritten max_deliveries is absent")
    assert_true(not Bool(none.ack_deadline), "an unwritten ack_deadline is absent")
    assert_true(not Bool(none.dead_letter), "an unwritten dead_letter is absent")
    var from_json = decode_json[Queue](String("{}"))
    assert_true(not Bool(from_json.max_deliveries), "JSON {}: max_deliveries absent")

    var r = List[UInt8]()
    _str(r, 1, "work")
    _uint(r, 3, UInt64(Retention.KEEP))
    _msg(r, 15, b)
    var rr = decode_proto[Resource](r.copy())
    assert_true(Bool(rr.queue), "body 15 is `queue`")
    assert_equal(rr._oneof0_case, 6, "the queue is the sixth arm")
    assert_equal(rr.retention.value, Retention.KEEP)
    assert_equal(Int(rr.queue.value().max_deliveries.value()), 7)
    _same(encode_proto(rr), r, "Resource with a queue")
    print("  test_queue: PASS")


# ---- topic -----------------------------------------------------------------------


def test_topic() raises:
    """Topic declares no field: any record in it is unknown and dropped. As
    the `topic` arm 21 (the tenth), its empty record is kept."""
    var probe = List[UInt8]()
    _uint(probe, 1, 9)
    _str(probe, 2, "x")
    _bytes_equal(encode_proto(decode_proto[Topic](probe.copy())), List[UInt8](), "Topic has no field")
    assert_equal(encode_json(decode_proto[Topic](List[UInt8]())), "{}", "Topic JSON")

    var r = List[UInt8]()
    _str(r, 1, "events")
    _msg(r, 21, List[UInt8]())
    var rr = decode_proto[Resource](r.copy())
    assert_true(Bool(rr.topic), "body 21 is `topic`")
    assert_equal(rr._oneof0_case, 10, "the topic is the tenth arm")
    var again = encode_proto(rr)
    # `_same` drops an empty record as a zero value; the arm's tag (21,
    # length-delimited: 0xAA 0x01) and its zero length must be there.
    assert_true(_hex(again).find("aa0100") >= 0, "the empty topic arm re-encodes: " + _hex(again))
    var text = encode_json(rr)
    assert_true('"topic":{}' in text, "Resource JSON carries the empty topic: " + text)
    assert_true(Bool(decode_json[Resource](text).topic), "JSON round trip keeps the topic arm")
    print("  test_topic: PASS")


# ---- subscription ----------------------------------------------------------------


def test_subscription() raises:
    """Subscription: 1 topic, 2 queue (each a Ref); by name, binary, JSON,
    absent = unset; as the `subscription` arm 28 (the seventeenth)."""
    var b = List[UInt8]()
    _msg(b, 1, _ref("events"))
    _msg(b, 2, _ref("work"))
    var s = decode_proto[Subscription](b.copy())
    assert_equal(s.topic.value().resource, "events", "field 1 is `topic`")
    assert_equal(s.queue.value().resource, "work", "field 2 is `queue`")
    _same(encode_proto(s), b, "Subscription")

    var text = encode_json(s)
    for key in ['"topic":{"resource":"events"', '"queue":{"resource":"work"']:
        assert_true(String(key) in text, String("Subscription JSON carries ") + String(key) + ": " + text)
    _bytes_equal(
        encode_proto(decode_json[Subscription](text)), encode_proto(s), "Subscription: JSON round trip"
    )
    var none = decode_proto[Subscription](List[UInt8]())
    assert_true(not Bool(none.topic) and not Bool(none.queue), "absent Refs are unset")

    var r = List[UInt8]()
    _str(r, 1, "fan")
    _msg(r, 28, b)
    var rr = decode_proto[Resource](r.copy())
    assert_true(Bool(rr.subscription), "body 28 is `subscription`")
    assert_equal(rr._oneof0_case, 17, "the subscription is the seventeenth arm")
    assert_equal(rr.subscription.value().queue.value().resource, "work")
    _same(encode_proto(rr), r, "Resource with a subscription")
    print("  test_subscription: PASS")


# ---- the two messaging verbs ----------------------------------------------------------


def test_send_and_receive() raises:
    """`Access` SEND 5 and RECEIVE 6 on a Uses line: by wire bytes, by name,
    and in JSON."""
    var names = ["SEND", "RECEIVE"]
    for i in range(2):
        var u = List[UInt8]()
        _msg(u, 1, _ref("work"))
        _uint(u, 2, UInt64(5 + i))
        var d = decode_proto[Uses](u.copy())
        assert_equal(d.access.json_name(), String(names[i]), String("Access ") + String(5 + i))
        assert_equal(d.access.value, Access.SEND if i == 0 else Access.RECEIVE)
        _same(encode_proto(d), u, String("Uses ") + String(names[i]))
        var text = encode_json(d)
        assert_true(
            (String('"access":"') + String(names[i]) + String('"')) in text, "JSON by name: " + text
        )
    print("  test_send_and_receive: PASS")


def main() raises:
    print("test_resource_messaging_numbers: queue, topic, subscription")
    test_queue()
    test_topic()
    test_subscription()
    test_send_and_receive()
    print("ALL kci.resource.v1 MESSAGING FIELD-NUMBER TESTS PASSED")
