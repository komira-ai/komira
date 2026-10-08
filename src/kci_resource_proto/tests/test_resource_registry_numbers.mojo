# =============================================================================
# test_resource_registry_numbers.mojo
# =============================================================================
#
# THE REGISTRY OF `kci.resource.v1`, AS WIRE BYTES: the `registry` arm 24 of
# `Resource.body`, the `Registry` message and the `ArtifactFormat` enum. The
# field template of test_resource_field_numbers.mojo, in a file of its own
# (that file is past the size a Mojo source should stay under).
#
# 1. KEPT, BY BYTES ONLY. Nothing is read by name: `Resource` 24 holding a
#    registry with every field survives decode then encode, and so does an
#    empty `registry` arm (its tag must be written). Every failure is
#    collected, so one run names every number that is missing.
# 2. REGISTRY. 1 format (an `ArtifactFormat`); by name, binary, JSON
#    (`"format":"OCI"`), absent = unset; 2 (held for who may read it beyond
#    the identities granted READ) and 3 are not fields; as `Resource.body`
#    24, the thirteenth arm, under the JSON name `registry`, with
#    `retention` 3 beside it.
# 3. ARTIFACTFORMAT. Every value by number AND by name: 0
#    ARTIFACT_FORMAT_UNSET, 1 OCI; 2 is no value.
# The census of every arm's oneof position is in
# test_resource_compute_numbers.mojo.
# The bytes are a LITERAL restatement of the proto, deliberately: deriving
# them from the generated code would agree with it by construction.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from kci_resource_proto.resource import ArtifactFormat, Registry, Resource, Retention


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


def _registry() -> List[UInt8]:
    """Registry { 1 format = OCI }."""
    var b = List[UInt8]()
    _uint(b, 1, 1)
    return b^


def _resource(id: String, arm: Int, body: List[UInt8]) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, id)
    _msg(b, arm, body)
    return b^


# ---- 1. kept, by bytes only -------------------------------------------------------


def test_added_registry_numbers_are_kept() raises:
    """Catches: `Resource` 24 undeclared, renumbered or of another wire
    type, `Registry.format` undeclared or of another wire type (each is
    dropped or misread on re-encode), and an empty `registry` arm dropped
    by the encoder. Collects every failure, so the red run against the
    earlier schema names all of them."""
    var bad = List[String]()
    var r = _resource("images", 24, _registry())
    if not _kept(encode_proto(decode_proto[Resource](r.copy())), r):
        bad.append("Resource 24 (Registry 1 format)")
    # `_kept` drops an empty record as a zero value: the arm's tag (24,
    # length-delimited: 0xc2 0x01) must be there, followed by its length
    # (this codec writes the unset format inside it, so not always zero).
    var e = _resource("images", 24, List[UInt8]())
    var back = encode_proto(decode_proto[Resource](e.copy()))
    if not _kept(back, e) or _hex(back).find("c201") < 0:
        bad.append("Resource 24 (an empty registry record): got " + _hex(back))
    var names = String("")
    for i in range(len(bad)):
        names += String("\n  ") + bad[i]
    assert_equal(len(bad), 0, String("not kept as P11 declares them:") + names)
    print("  test_added_registry_numbers_are_kept: PASS")


# ---- 2. Registry ------------------------------------------------------------------


def test_registry() raises:
    """Catches: `format` at another number or wire type, a JSON name other
    than the proto3 one (or the format rendered as a number), an unwritten
    format read as written, a field declared at 2 (held) or 3, the arm at
    another number or position, and `retention` 3 moved by the arm beside
    it."""
    var b = _registry()
    var g = decode_proto[Registry](b.copy())
    assert_equal(g.format.value, ArtifactFormat.OCI, "field 1 is `format`")
    _same(encode_proto(g), b, "Registry")

    var text = encode_json(g)
    assert_true('"format":"OCI"' in text, "Registry JSON names the format: " + text)
    _bytes_equal(encode_proto(decode_json[Registry](text)), encode_proto(g), "Registry: JSON round trip")
    assert_equal(
        decode_proto[Registry](List[UInt8]()).format.value,
        ArtifactFormat.ARTIFACT_FORMAT_UNSET,
        "absent: the unset format (validate refuses it)",
    )

    for n in [2, 3]:
        var probe = _registry()
        _str(probe, n, "not-a-field")
        _same(encode_proto(decode_proto[Registry](probe.copy())), _registry(), String("Registry has no field ") + String(n))

    var rb = List[UInt8]()
    _str(rb, 1, "images")
    _uint(rb, 3, 2)  # retention KEEP
    _msg(rb, 24, _registry())
    var rr = decode_proto[Resource](rb.copy())
    assert_true(Bool(rr.registry), "body 24 is `registry`")
    assert_equal(rr._oneof0_case, 13, "the registry is the thirteenth arm")
    assert_equal(rr.retention.value, Retention.KEEP, "retention rides beside it")
    assert_equal(rr.registry.value().format.value, ArtifactFormat.OCI)
    _same(encode_proto(rr), rb, "Resource with a registry")
    var rt = encode_json(rr)
    assert_true('"registry":{"format":"OCI"}' in rt, "Resource JSON names the arm registry: " + rt)
    _bytes_equal(encode_proto(decode_json[Resource](rt)), encode_proto(rr), "Resource with a registry: JSON round trip")
    print("  test_registry: PASS")


# ---- 3. ArtifactFormat ------------------------------------------------------------


def test_artifact_format_ordinals() raises:
    """Catches: a format renumbered or renamed (the number is what is
    stored), and a second format added without its pin."""
    var names: List[String] = ["ARTIFACT_FORMAT_UNSET", "OCI"]
    for n in range(len(names)):
        assert_equal(ArtifactFormat(n).json_name(), names[n], String("ArtifactFormat ") + String(n))
        assert_equal(ArtifactFormat.from_json_name(names[n]).value, n, names[n])
    assert_equal(ArtifactFormat(2).json_name(), "2", "ArtifactFormat has two values")
    print("  test_artifact_format_ordinals: PASS")


def main() raises:
    print("test_resource_registry_numbers: registry, ArtifactFormat")
    test_added_registry_numbers_are_kept()
    test_registry()
    test_artifact_format_ordinals()
    print("ALL kci.resource.v1 REGISTRY FIELD-NUMBER TESTS PASSED")
