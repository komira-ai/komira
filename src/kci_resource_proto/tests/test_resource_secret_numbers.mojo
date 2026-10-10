# =============================================================================
# test_resource_secret_numbers.mojo
# =============================================================================
#
# THE SECRET PRIMITIVE OF `kci.resource.v1`, AS WIRE BYTES: the `secret` arm
# 16 of `Resource.body`, the `Secret` message, and `SecretRef.secret` 4 (a
# `secret_env` entry that names a `secret` resource of the list). The field
# template of test_resource_field_numbers.mojo, in a file of its own (that
# file is past the size a Mojo source should stay under).
#
# 1. KEPT, BY BYTES ONLY. Nothing is read by name: `Resource` 16 (an empty
#    record) and `SecretRef` 4 (a `Ref`), alone and inside a service's and a
#    container job's `secret_env`, survive decode then encode. Against a schema that
#    lacks either number the record is unknown and dropped, and this fails.
# 2. SECRET. `Secret` declares no field: any record in it is unknown and
#    dropped. As `Resource.body` 16 it fills the `secret` field, at its
#    position in declaration order (the seventh: service, container job,
#    worker, table, bucket, queue, secret), its empty record is kept on re-encode and in JSON, and
#    `retention` 3 rides beside it.
# 3. SECRETREF.SECRET. Field 4 is `secret`, a `Ref`; by name, binary round
#    trip, JSON (`"secret":{"resource":"db"}`), and absent = unset. Fields 1
#    to 3 keep their numbers beside it, and a record both named and
#    referenced decodes with both (refusing that is validate's job, never
#    the codec's).
# The census of every arm's number and oneof position is in
# test_resource_compute_numbers.mojo (the latest arms decide every position).
# The bytes are a LITERAL restatement of the proto, deliberately: deriving
# them from the generated code would agree with it by construction.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from kci_resource_proto.compute import ContainerJob, Service
from kci_resource_proto.refs import Retention, SecretRef
from kci_resource_proto.resource import Resource
from kci_resource_proto.secrets import Secret


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
    message (varint and length-delimited records only: no secret field is
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




def _secret_ref_to(resource: String) -> List[UInt8]:
    """SecretRef { secret: Ref { resource } } (field 4, a message)."""
    var b = List[UInt8]()
    _msg(b, 4, _ref(resource))
    return b^


def _entry(key: String, value: List[UInt8]) -> List[UInt8]:
    """One map entry: 1 key, 2 value (a message)."""
    var b = List[UInt8]()
    _str(b, 1, key)
    _msg(b, 2, value)
    return b^


# ---- 1. kept, by bytes only -------------------------------------------------------


def test_added_secret_numbers_are_kept() raises:
    """Catches: `Resource` 16 or `SecretRef` 4 undeclared, renumbered or of
    another wire type (each would be dropped or misread on re-encode), and
    an empty `secret` arm dropped by the encoder."""
    var r = List[UInt8]()
    _str(r, 1, "db")
    _uint(r, 3, 2)  # retention KEEP
    _msg(r, 16, List[UInt8]())
    var back = encode_proto(decode_proto[Resource](r.copy()))
    _same(back, r, "Resource 16")
    # `_same` drops an empty record as a zero value: the arm's tag (16,
    # length-delimited: 0x82 0x01) and its zero length must be there.
    assert_true(_hex(back).find("820100") >= 0, "the empty secret arm re-encodes: " + _hex(back))

    var ref_only = _secret_ref_to("db")
    _same(encode_proto(decode_proto[SecretRef](ref_only.copy())), ref_only, "SecretRef 4")
    var pinned = _secret_ref_to("db")
    _str(pinned, 3, "7")
    _same(encode_proto(decode_proto[SecretRef](pinned.copy())), pinned, "SecretRef 4 with version 3")

    var svc = List[UInt8]()
    _uint(svc, 2, 8080)
    _msg(svc, 12, _entry("DB_PASSWORD", _secret_ref_to("db")))
    _same(encode_proto(decode_proto[Service](svc.copy())), svc, "Service.secret_env with SecretRef 4")
    var job = List[UInt8]()
    _msg(job, 7, _entry("API_TOKEN", _secret_ref_to("token")))
    _same(encode_proto(decode_proto[ContainerJob](job.copy())), job, "ContainerJob.secret_env with SecretRef 4")
    print("  test_added_secret_numbers_are_kept: PASS")


# ---- 2. secret ------------------------------------------------------------------


def test_secret() raises:
    """Catches: a field declared on `Secret` (a record would survive), the
    arm at another number or position, the empty arm dropped on re-encode or
    from JSON, and retention not carried beside it."""
    var probe = List[UInt8]()
    _uint(probe, 1, 9)
    _str(probe, 2, "x")
    _msg(probe, 4, _ref("db"))
    _bytes_equal(encode_proto(decode_proto[Secret](probe.copy())), List[UInt8](), "Secret has no field")
    assert_equal(encode_json(decode_proto[Secret](List[UInt8]())), "{}", "Secret JSON")

    var r = List[UInt8]()
    _str(r, 1, "db")
    _uint(r, 3, UInt64(Retention.DELETE))
    _msg(r, 16, List[UInt8]())
    var rr = decode_proto[Resource](r.copy())
    assert_true(Bool(rr.secret), "body 16 is `secret`")
    assert_equal(rr._oneof0_case, 7, "the secret is the seventh arm")
    assert_equal(rr.retention.value, Retention.DELETE, "retention 3 beside the secret arm")
    assert_true(not Bool(rr.queue) and not Bool(rr.service_account), "no other arm is set")
    var again = encode_proto(rr)
    assert_true(_hex(again).find("820100") >= 0, "the empty secret arm re-encodes: " + _hex(again))
    var text = encode_json(rr)
    assert_true('"secret":{}' in text, "Resource JSON carries the empty secret: " + text)
    var back = decode_json[Resource](text)
    assert_true(Bool(back.secret), "JSON round trip keeps the secret arm")
    _bytes_equal(encode_proto(back), again, "Resource with a secret: JSON round trip, binary bytes")
    print("  test_secret: PASS")


# ---- 3. SecretRef.secret ------------------------------------------------------------


def test_secret_ref_secret() raises:
    """Catches: `secret` at another number or wire type, fields 1 to 3
    moved by the addition, the JSON name not `secret`, an unwritten `secret`
    decoded as present, and a codec that refuses (or drops one of) a record
    holding both a name and a secret."""
    var b = _secret_ref_to("db")
    var s = decode_proto[SecretRef](b.copy())
    assert_true(Bool(s.secret), "field 4 is `secret`")
    assert_equal(s.secret.value().resource, "db", "`secret` is a Ref")
    assert_equal(s.secret.value()._oneof0_case, 0, "no output asked")
    assert_equal(s.name, "", "no name written")
    assert_true(not Bool(s.store) and not Bool(s.version), "store and version absent")
    _same(encode_proto(s), b, "SecretRef with a secret")

    var text = encode_json(s)
    assert_true('"secret":{"resource":"db"}' in text, "SecretRef JSON carries `secret`: " + text)
    _bytes_equal(encode_proto(decode_json[SecretRef](text)), encode_proto(s), "SecretRef: JSON round trip")
    var authored = decode_json[SecretRef](String('{"secret":{"resource":"db"},"version":"3"}'))
    assert_equal(authored.secret.value().resource, "db", "JSON by name: secret")
    assert_equal(authored.version.value(), "3", "JSON by name: version")

    # Fields 1 to 3 beside 4, each read back by name.
    var all = List[UInt8]()
    _str(all, 1, "legacy")
    _str(all, 2, "vault")
    _str(all, 3, "9")
    _msg(all, 4, _ref("db"))
    var both = decode_proto[SecretRef](all.copy())
    assert_equal(both.name, "legacy", "field 1 is still `name`")
    assert_equal(both.store.value(), "vault", "field 2 is still `store`")
    assert_equal(both.version.value(), "9", "field 3 is still `version`")
    assert_equal(both.secret.value().resource, "db", "field 4 is `secret`")
    _same(encode_proto(both), all, "SecretRef with all four fields")

    var none = decode_proto[SecretRef](List[UInt8]())
    assert_true(not Bool(none.secret), "an unwritten secret is absent")
    var named = decode_json[SecretRef](String('{"name":"db_password"}'))
    assert_true(not Bool(named.secret), "JSON with a name only: no secret")

    # Inside a service's secret_env, read by name.
    var svc = List[UInt8]()
    _msg(svc, 12, _entry("DB_PASSWORD", _secret_ref_to("db")))
    var sv = decode_proto[Service](svc.copy())
    assert_equal(sv.secret_env["DB_PASSWORD"].secret.value().resource, "db", "Service.secret_env -> secret")
    print("  test_secret_ref_secret: PASS")


def main() raises:
    print("test_resource_secret_numbers: secret, SecretRef.secret")
    test_added_secret_numbers_are_kept()
    test_secret()
    test_secret_ref_secret()
    print("ALL kci.resource.v1 SECRET FIELD-NUMBER TESTS PASSED")
