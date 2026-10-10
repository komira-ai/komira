# =============================================================================
# test_resource_metadata_numbers.mojo
# =============================================================================
#
# THE METADATA OF EVERY `kci.resource.v1` RESOURCE, AS WIRE BYTES:
# `Resource.physical_name` 6, `Resource.labels` 7 and `Resource.adopt` 8 (an
# `Adoption`; 9 is reserved, and test_resource_held_numbers probes it). The
# field template of test_resource_field_numbers.mojo, in a file of its own
# (that file is past the size a Mojo source should stay under).
#
# 1. KEPT, BY BYTES ONLY. Nothing is read by name: a `Resource` holding a
#    bucket with field 6 (a string), two field-7 map entries (each a message
#    of 1 key and 2 value), and field 8 at 1 and at 2 (varints) survives
#    decode then encode, and so does a written-empty field 6 (its tag and a
#    zero length must be written). Every failure is collected, so one run
#    names every number that is missing. Field 8 at 2 is what a bool field
#    cannot keep (it re-encodes as 1).
# 2. PHYSICAL_NAME. 6 is `physical_name`, an optional string: by name,
#    binary, JSON (`physicalName`); absent is None, and a written empty name
#    is present (Some("")), so validate can refuse it.
# 3. LABELS. 7 is `labels`, a map of string to string: by name (each entry's
#    1 is the key and 2 the value), binary, JSON (`"labels":{...}`); absent
#    is empty.
# 4. ADOPT. 8 is `adopt`, the enum `Adoption`: ADOPTION_UNSET 0, ADOPT 1,
#    ADOPT_DELETABLE 2, by number and by name; binary; JSON (`"adopt"`,
#    taking the value names). Absent is ADOPTION_UNSET and is written at its
#    default, `40 00`; ADOPT is `40 01`. These are the bytes every stored
#    list and every composite definition digest already holds, so none of
#    them moves.
# 5. BESIDE EVERY OTHER FIELD. The three ride with `uses` 2, `retention` 3
#    and a body arm without moving them (5 stays held, 4 and 9 reserved:
#    test_resource_held_numbers).
# The bytes are a LITERAL restatement of the proto, deliberately: deriving
# them from the generated code would agree with it by construction.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from kci_resource_proto.refs import Retention
from kci_resource_proto.resource import Adoption, Resource


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


def _entry(key: String, value: String) -> List[UInt8]:
    """One map entry: 1 key, 2 value."""
    var b = List[UInt8]()
    _str(b, 1, key)
    _str(b, 2, value)
    return b^


def _metadata() -> List[UInt8]:
    """Resource { 1 id, 6 physical_name, 7 labels (two entries, sorted by
    key), 8 adopt = ADOPT_DELETABLE, 14 bucket {} }."""
    var b = List[UInt8]()
    _str(b, 1, "logs")
    _str(b, 6, "acme-logs")
    _msg(b, 7, _entry("team", "data"))
    _msg(b, 7, _entry("tier", "gold"))
    _uint(b, 8, 2)
    _msg(b, 14, List[UInt8]())
    return b^


# ---- 1. kept, by bytes only -------------------------------------------------------


def test_added_metadata_numbers_are_kept() raises:
    """Catches: `Resource` 6, 7 or 8 undeclared, renumbered or of another
    wire type (each is dropped or misread on re-encode), 8 declared a bool
    (its value 2 re-encodes as 1), a map entry's key and value swapped, and
    a written-empty `physical_name` dropped by the encoder (presence lost).
    Collects every failure, so the red run against an earlier schema names
    all of them."""
    var bad = List[String]()
    var head = List[UInt8]()
    _str(head, 1, "logs")
    _msg(head, 14, List[UInt8]())
    var six = head.copy()
    _str(six, 6, "acme-logs")
    if not _kept(encode_proto(decode_proto[Resource](six.copy())), six):
        bad.append("Resource 6 (physical_name, a string)")
    var seven = head.copy()
    _msg(seven, 7, _entry("team", "data"))
    _msg(seven, 7, _entry("tier", "gold"))
    if not _kept(encode_proto(decode_proto[Resource](seven.copy())), seven):
        bad.append("Resource 7 (labels, map<string, string>)")
    var eight = head.copy()
    _uint(eight, 8, 1)
    if not _kept(encode_proto(decode_proto[Resource](eight.copy())), eight):
        bad.append("Resource 8 at 1 (adopt, an enum)")
    var two = head.copy()
    _uint(two, 8, 2)
    if not _kept(encode_proto(decode_proto[Resource](two.copy())), two):
        bad.append("Resource 8 at 2 (adopt, an enum: a bool keeps only 0 and 1)")
    var all = _metadata()
    if not _kept(encode_proto(decode_proto[Resource](all.copy())), all):
        bad.append("Resource 6, 7 and 8 together")
    # `_kept` drops an empty record as a zero value: a written-empty
    # physical_name keeps its tag (6, length-delimited: 0x32) and a zero
    # length, because the field has presence.
    var empty = head.copy()
    _str(empty, 6, "")
    var back = encode_proto(decode_proto[Resource](empty.copy()))
    if _hex(back).find("3200") < 0:
        bad.append("Resource 6 written empty (presence): got " + _hex(back))
    var names = String("")
    for i in range(len(bad)):
        names += String("\n  ") + bad[i]
    assert_equal(len(bad), 0, String("not kept as the schema declares them:") + names)
    print("  test_added_metadata_numbers_are_kept: PASS")


# ---- 2. physical_name ------------------------------------------------------------


def test_physical_name() raises:
    """Catches: `physical_name` at another number or wire type, a JSON name
    other than the proto3 one, presence lost (a written empty name read as
    unset, or an unset one read as written)."""
    var head = List[UInt8]()
    _str(head, 1, "logs")
    var b = head.copy()
    _str(b, 6, "acme-logs")
    var r = decode_proto[Resource](b.copy())
    assert_true(Bool(r.physical_name), "field 6 is `physical_name`")
    assert_equal(r.physical_name.value(), "acme-logs")
    _same(encode_proto(r), b, "Resource.physical_name")
    var text = encode_json(r)
    assert_true('"physicalName":"acme-logs"' in text, "JSON name physicalName: " + text)
    _bytes_equal(encode_proto(decode_json[Resource](text)), encode_proto(r), "physical_name: JSON round trip")

    assert_true(not Bool(decode_proto[Resource](head.copy()).physical_name), "absent: None")
    var e = head.copy()
    _str(e, 6, "")
    var written = decode_proto[Resource](e.copy())
    assert_true(Bool(written.physical_name), "a written empty name is present")
    assert_equal(written.physical_name.value(), "")
    var je = decode_json[Resource]('{"id":"logs","physicalName":""}')
    assert_true(Bool(je.physical_name), "JSON: a written empty name is present")
    assert_true(not Bool(decode_json[Resource]('{"id":"logs"}').physical_name), "JSON: absent is None")
    print("  test_physical_name: PASS")


# ---- 3. labels -----------------------------------------------------------------------


def test_labels() raises:
    """Catches: `labels` at another number, a map entry's key and value
    swapped (1 and 2), a JSON name other than `labels` (or the map written
    as a list of entries), and a missing map read as anything but empty."""
    var head = List[UInt8]()
    _str(head, 1, "logs")
    var b = head.copy()
    _msg(b, 7, _entry("team", "data"))
    _msg(b, 7, _entry("tier", "gold"))
    var r = decode_proto[Resource](b.copy())
    assert_equal(len(r.labels), 2, "field 7 is `labels`, two entries")
    assert_equal(r.labels["team"], "data", "entry 1 is the key, 2 the value")
    assert_equal(r.labels["tier"], "gold")
    _same(encode_proto(r), b, "Resource.labels")
    var text = encode_json(r)
    assert_true('"labels":{"team":"data","tier":"gold"}' in text, "JSON names the map labels: " + text)
    _bytes_equal(encode_proto(decode_json[Resource](text)), encode_proto(r), "labels: JSON round trip")
    assert_equal(len(decode_proto[Resource](head.copy()).labels), 0, "absent: empty")
    print("  test_labels: PASS")


# ---- 4. adopt ------------------------------------------------------------------------


def test_adopt() raises:
    """Catches: `adopt` at another number or wire type, an `Adoption` value
    renumbered (ADOPT and ADOPT_DELETABLE swapped would let kci delete what
    an author only adopted), a JSON name other than `adopt` or a value name
    other than the proto's, a missing field read as adopting, and the
    default not written (every stored list and definition digest holds
    `40 00`)."""
    assert_equal(Adoption.ADOPTION_UNSET, 0)
    assert_equal(Adoption.ADOPT, 1)
    assert_equal(Adoption.ADOPT_DELETABLE, 2)
    var head = List[UInt8]()
    _str(head, 1, "logs")
    var names: List[String] = ["ADOPT", "ADOPT_DELETABLE"]
    for v in range(1, 3):
        var b = head.copy()
        _uint(b, 8, UInt64(v))
        var r = decode_proto[Resource](b.copy())
        assert_equal(r.adopt.value, v, "field 8 is `adopt`")
        _same(encode_proto(r), b, "Resource.adopt")
        var text = encode_json(r)
        assert_true(String('"adopt":"') + names[v - 1] + String('"') in text, "JSON name adopt: " + text)
        _bytes_equal(encode_proto(decode_json[Resource](text)), encode_proto(r), "adopt: JSON round trip")
        var authored = decode_json[Resource](String('{"id":"logs","adopt":"') + names[v - 1] + String('"}'))
        assert_equal(authored.adopt.value, v, "JSON takes the value name " + names[v - 1])
    var absent = decode_proto[Resource](head.copy())
    assert_equal(absent.adopt.value, Adoption.ADOPTION_UNSET, "absent: ADOPTION_UNSET")
    assert_true(_hex(encode_proto(absent)).find("4000") >= 0, "the default is written: " + _hex(encode_proto(absent)))
    var one = head.copy()
    _uint(one, 8, 1)
    assert_true(_hex(encode_proto(decode_proto[Resource](one.copy()))).find("4001") >= 0, "ADOPT is 40 01")
    print("  test_adopt: PASS")


# ---- 5. beside every other field -----------------------------------------------------


def test_metadata_beside_the_other_fields() raises:
    """Catches: one of the three taking (or moving) `uses` 2, `retention` 3
    or the body arm."""
    var u = List[UInt8]()
    _msg(u, 1, _ref("reader"))
    _uint(u, 2, 2)  # READ
    var b = List[UInt8]()
    _str(b, 1, "logs")
    _msg(b, 2, u)
    _uint(b, 3, 2)  # retention KEEP
    _str(b, 6, "acme-logs")
    _msg(b, 7, _entry("team", "data"))
    _uint(b, 8, 2)
    _msg(b, 14, List[UInt8]())
    var r = decode_proto[Resource](b.copy())
    assert_equal(r.id, "logs")
    assert_equal(len(r.uses), 1, "uses 2 is unmoved")
    assert_equal(r.retention.value, Retention.KEEP, "retention 3 is unmoved")
    assert_true(Bool(r.bucket), "body 14 is the bucket")
    assert_equal(r.physical_name.value(), "acme-logs")
    assert_equal(r.labels["team"], "data")
    assert_equal(r.adopt.value, Adoption.ADOPT_DELETABLE)
    _same(encode_proto(r), b, "Resource with every header field")
    print("  test_metadata_beside_the_other_fields: PASS")


def main() raises:
    print("test_resource_metadata_numbers: physical_name, labels, adopt")
    test_added_metadata_numbers_are_kept()
    test_physical_name()
    test_labels()
    test_adopt()
    test_metadata_beside_the_other_fields()
    print("ALL kci.resource.v1 METADATA FIELD-NUMBER TESTS PASSED")
