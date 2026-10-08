# =============================================================================
# test_resource_trigger_numbers.mojo
# =============================================================================
#
# THE TRIGGERS OF `kci.resource.v1`, AS WIRE BYTES: the `schedule` arm 22
# and the `event_trigger` arm 31. The field template of
# test_resource_field_numbers.mojo, in a file of its own (that file is past
# the size a Mojo source should stay under).
#
# 1. KEPT, BY BYTES ONLY. Nothing is read by name: `Resource` 22 holding a
#    schedule with every field and `Resource` 31 holding an event trigger
#    with every field survive decode then encode. Every failure is collected,
#    so one run names every number that is missing.
# 2. SCHEDULE. 1 cron, 2 timezone, 3 target (a `Ref`); by name, binary,
#    JSON (`cron`, `timezone`, `target`), absent = unset; 4 is not a field;
#    as `Resource.body` 22, the eleventh arm, under the JSON name
#    `schedule`.
# 3. EVENTTRIGGER. 1 source (a `Ref`), 2 event (a `SourceEvent`), 3 target
#    (a `Ref`); by name, binary, JSON (`source`, `event` by its value name,
#    `target`), absent = unset; 4 is not a field; as `Resource.body` 31, the
#    twentieth arm, under the JSON name `eventTrigger`.
# 4. SOURCEEVENT. 0 SOURCE_EVENT_UNSET, 1 OBJECT_CREATED, 2 OBJECT_DELETED,
#    in both directions; 3 is held (a message published to a topic) and
#    renders as its bare number.
# The census of every arm's oneof position is in
# test_resource_compute_numbers.mojo.
# The bytes are a LITERAL restatement of the proto, deliberately: deriving
# them from the generated code would agree with it by construction.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from kci_resource_proto.resource import EventTrigger, Resource, Schedule, SourceEvent


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
    sorted stably by field number (this codec writes zero values and writes
    plain fields before oneof fields; neither is the catalog's business).
    False when `b` does not parse as a message (varint and length-delimited
    records only: no field here is fixed-width)."""
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


def _kept(got: List[UInt8], want: List[UInt8]) -> Bool:
    var cg = List[UInt8]()
    var cw = List[UInt8]()
    if not _canon(got, cg) or not _canon(want, cw):
        return False
    return _hex(cg) == _hex(cw)


def _same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_true(
        _kept(got, want),
        what + ": re-encoding the decoded message does not give the hand-written records back\n  want "
        + _hex(want) + "\n  got  " + _hex(got),
    )


def _bytes_equal(a: List[UInt8], b: List[UInt8], what: String) raises:
    assert_equal(_hex(a), _hex(b), what)




# ---- the messages, as bytes ------------------------------------------------------------


def _schedule() -> List[UInt8]:
    """Schedule { 1 cron, 2 timezone, 3 target }."""
    var b = List[UInt8]()
    _str(b, 1, "30 2 * * 1-5")
    _str(b, 2, "Europe/Paris")
    _msg(b, 3, _ref("nightly"))
    return b^


def _event_trigger() -> List[UInt8]:
    """EventTrigger { 1 source, 2 event (OBJECT_DELETED), 3 target }."""
    var b = List[UInt8]()
    _msg(b, 1, _ref("uploads"))
    _uint(b, 2, 2)
    _msg(b, 3, _ref("thumbs"))
    return b^


def _resource(id: String, arm: Int, body: List[UInt8]) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, id)
    _msg(b, arm, body)
    return b^


# ---- 1. kept, by bytes only -------------------------------------------------------


def test_added_trigger_numbers_are_kept() raises:
    """Catches: `Resource` 22 or 31 undeclared, renumbered or of another
    wire type, and any field of `Schedule` or `EventTrigger` undeclared or
    of another wire type (each is dropped or misread on re-encode). Collects
    every failure, so the red run against the earlier schema names all of
    them."""
    var bad = List[String]()
    var s = _resource("nightly-at-2", 22, _schedule())
    if not _kept(encode_proto(decode_proto[Resource](s.copy())), s):
        bad.append("Resource 22 (Schedule 1 cron, 2 timezone, 3 target)")
    var e = _resource("on-upload", 31, _event_trigger())
    if not _kept(encode_proto(decode_proto[Resource](e.copy())), e):
        bad.append("Resource 31 (EventTrigger 1 source, 2 event, 3 target)")
    var names = String("")
    for i in range(len(bad)):
        names += String("\n  ") + bad[i]
    assert_equal(len(bad), 0, String("not kept as P9 declares them:") + names)
    print("  test_added_trigger_numbers_are_kept: PASS")


# ---- 2. Schedule ------------------------------------------------------------------


def test_schedule() raises:
    """Catches: `cron` and `timezone` (two strings) swapped or at another
    number (each is read back by name), `target` at another number or wire
    type, a JSON name other than the proto3 one, an unwritten target read as
    present, a field declared at 4, and the arm at another number or
    position."""
    var b = _schedule()
    var s = decode_proto[Schedule](b.copy())
    assert_equal(s.cron, "30 2 * * 1-5", "field 1 is `cron`")
    assert_equal(s.timezone, "Europe/Paris", "field 2 is `timezone`")
    assert_equal(s.target.value().resource, "nightly", "field 3 is `target`")
    _same(encode_proto(s), b, "Schedule")

    var text = encode_json(s)
    for want in ['"cron":"30 2 * * 1-5"', '"timezone":"Europe/Paris"', '"target":{"resource":"nightly"}']:
        assert_true(String(want) in text, String(want) + " in Schedule JSON: " + text)
    _bytes_equal(encode_proto(decode_json[Schedule](text)), encode_proto(s), "Schedule: JSON round trip")

    var none = decode_proto[Schedule](List[UInt8]())
    assert_equal(none.cron, "", "absent: no cron")
    assert_equal(none.timezone, "", "absent: no timezone (UTC)")
    assert_true(not Bool(none.target), "absent: no target")

    var probe = _schedule()
    _str(probe, 4, "not-a-field")
    _same(encode_proto(decode_proto[Schedule](probe.copy())), _schedule(), "Schedule has no field 4")

    var rr = decode_proto[Resource](_resource("nightly-at-2", 22, _schedule()))
    assert_true(Bool(rr.schedule), "body 22 is `schedule`")
    assert_equal(rr._oneof0_case, 11, "the schedule is the eleventh arm")
    var rt = encode_json(rr)
    assert_true('"schedule":{' in rt, "Resource JSON names the arm schedule: " + rt)
    _bytes_equal(encode_proto(decode_json[Resource](rt)), encode_proto(rr), "Resource with a schedule: JSON round trip")
    print("  test_schedule: PASS")


# ---- 3. EventTrigger ----------------------------------------------------------------


def test_event_trigger() raises:
    """Catches: `source` and `target` (two `Ref`s) swapped or at another
    number (each is read back by name), `event` at another number or wire
    type, a JSON name other than the proto3 one (the event by its value
    name), an unwritten source or target read as present, a field declared
    at 4, and the arm at another number or position."""
    var b = _event_trigger()
    var e = decode_proto[EventTrigger](b.copy())
    assert_equal(e.source.value().resource, "uploads", "field 1 is `source`")
    assert_equal(e.event.value, SourceEvent.OBJECT_DELETED, "field 2 is `event`")
    assert_equal(e.target.value().resource, "thumbs", "field 3 is `target`")
    _same(encode_proto(e), b, "EventTrigger")

    var text = encode_json(e)
    for want in ['"source":{"resource":"uploads"}', '"event":"OBJECT_DELETED"', '"target":{"resource":"thumbs"}']:
        assert_true(String(want) in text, String(want) + " in EventTrigger JSON: " + text)
    _bytes_equal(encode_proto(decode_json[EventTrigger](text)), encode_proto(e), "EventTrigger: JSON round trip")
    var authored = decode_json[EventTrigger](
        String('{"source":{"resource":"b"},"event":"OBJECT_CREATED","target":{"resource":"s"}}')
    )
    assert_equal(authored.event.value, SourceEvent.OBJECT_CREATED, "JSON by name: event")

    var none = decode_proto[EventTrigger](List[UInt8]())
    assert_true(not Bool(none.source), "absent: no source")
    assert_equal(none.event.value, SourceEvent.SOURCE_EVENT_UNSET, "absent: the unset event")
    assert_true(not Bool(none.target), "absent: no target")

    var probe = _event_trigger()
    _str(probe, 4, "not-a-field")
    _same(encode_proto(decode_proto[EventTrigger](probe.copy())), _event_trigger(), "EventTrigger has no field 4")

    var rr = decode_proto[Resource](_resource("on-upload", 31, _event_trigger()))
    assert_true(Bool(rr.event_trigger), "body 31 is `event_trigger`")
    assert_equal(rr._oneof0_case, 20, "the event trigger is the twentieth arm")
    var rt = encode_json(rr)
    assert_true('"eventTrigger":{' in rt, "Resource JSON names the arm eventTrigger: " + rt)
    _bytes_equal(encode_proto(decode_json[Resource](rt)), encode_proto(rr), "Resource with an event trigger: JSON round trip")
    print("  test_event_trigger: PASS")


# ---- 4. SourceEvent -----------------------------------------------------------------


def test_source_event_ordinals() raises:
    """Catches: an event renumbered or renamed (the number is what is
    stored), and the held 3 (a message published to a topic) given a
    name."""
    var names: List[String] = ["SOURCE_EVENT_UNSET", "OBJECT_CREATED", "OBJECT_DELETED"]
    for n in range(len(names)):
        assert_equal(SourceEvent(n).json_name(), names[n], String("SourceEvent ") + String(n))
        assert_equal(SourceEvent.from_json_name(names[n]).value, n, names[n])
    assert_equal(SourceEvent(3).json_name(), "3", "SourceEvent 3 is held")
    print("  test_source_event_ordinals: PASS")


def main() raises:
    print("test_resource_trigger_numbers: schedule, event_trigger")
    test_added_trigger_numbers_are_kept()
    test_schedule()
    test_event_trigger()
    test_source_event_ordinals()
    print("ALL kci.resource.v1 TRIGGER FIELD-NUMBER TESTS PASSED")
