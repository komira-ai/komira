# =============================================================================
# test_resource_dns_numbers.mojo
# =============================================================================
#
# THE NAME PRIMITIVES OF `kci.resource.v1`, AS WIRE BYTES: the `dns_zone` arm
# 18, the `dns_record` arm 26 and the `certificate` arm 27 of
# `Resource.body`, their messages `DnsZone`, `DnsRecord` and `Certificate`,
# and the `RecordType` enum. The field template of
# test_resource_field_numbers.mojo, in a file of its own (that file is past
# the size a Mojo source should stay under).
#
# 1. KEPT, BY BYTES ONLY. Nothing is read by name: `Resource` 18, 26 and 27,
#    each holding every field of its message, survive decode then encode.
#    Against a schema that lacks one of these numbers (or a field inside),
#    the record is unknown and dropped, and this fails.
# 2. DNSZONE. 1 `name` (a string); by name, binary, JSON, absent = unset; 2
#    is not a field; as `Resource.body` 18, the eighth arm.
# 3. DNSRECORD. 1 `name`, 2 `zone` (a `Ref`), 3 `type` (a `RecordType`), 4
#    `values` (repeated `Value`), 5 `ttl` (a `Duration`); by name, binary,
#    JSON (`"type":"CNAME"`, `"ttl":"300s"`), absent = unset; 6 is not a
#    field; as `Resource.body` 26, the fifteenth arm.
# 4. CERTIFICATE. 1 `domains` (repeated string), 2 `zone` (a `Ref`); by
#    name, binary, JSON, absent = unset; 3 is not a field; as
#    `Resource.body` 27, the sixteenth arm.
# 5. RECORDTYPE. Every value by number AND by name: 0 RECORD_TYPE_UNSET, 1
#    A, 2 AAAA, 3 CNAME, 4 TXT, 5 MX; 6 is no value.
# The census of every arm's number and oneof position is in
# test_resource_compute_numbers.mojo (the latest arms decide every position).
# The bytes are a LITERAL restatement of the proto, deliberately: deriving
# them from the generated code would agree with it by construction.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from kci_resource_proto.resource import (
    Certificate,
    DnsRecord,
    DnsZone,
    Output,
    RecordType,
    Resource,
    Retention,
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
    message (varint and length-delimited records only: no field here is
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


# ---- the three messages, as bytes ----------------------------------------------------


def _zone(name: String) -> List[UInt8]:
    """DnsZone { 1 name }."""
    var b = List[UInt8]()
    _str(b, 1, name)
    return b^


def _literal(s: String) -> List[UInt8]:
    """Value { 1 literal }."""
    var b = List[UInt8]()
    _str(b, 1, s)
    return b^


def _host_of(resource: String) -> List[UInt8]:
    """Value { 3 ref: Ref { 1 resource, 2 standard HOST } }."""
    var r = _ref(resource)
    _uint(r, 2, 2)  # Output.HOST
    var b = List[UInt8]()
    _msg(b, 3, r)
    return b^


def _seconds(n: Int) -> List[UInt8]:
    """google.protobuf.Duration { 1 seconds }."""
    var b = List[UInt8]()
    _uint(b, 1, UInt64(n))
    return b^


def _record() -> List[UInt8]:
    """DnsRecord { 1 name, 2 zone, 3 type CNAME, 4 values (one HOST ref), 5
    ttl 300s }."""
    var b = List[UInt8]()
    _str(b, 1, "www.example.com")
    _msg(b, 2, _ref("site"))
    _uint(b, 3, 3)  # RecordType.CNAME
    _msg(b, 4, _host_of("api"))
    _msg(b, 5, _seconds(300))
    return b^


def _certificate() -> List[UInt8]:
    """Certificate { 1 domains x2, 2 zone }."""
    var b = List[UInt8]()
    _str(b, 1, "example.com")
    _str(b, 1, "*.example.com")
    _msg(b, 2, _ref("site"))
    return b^


def _resource(id: String, arm: Int, body: List[UInt8]) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, id)
    _msg(b, arm, body)
    return b^


# ---- 1. kept, by bytes only -------------------------------------------------------


def test_added_dns_numbers_are_kept() raises:
    """Catches: `Resource` 18, 26 or 27 undeclared, renumbered or of another
    wire type, and any field of the three messages undeclared or of another
    wire type (each would be dropped or misread on re-encode)."""
    var z = _resource("site", 18, _zone("example.com"))
    _uint(z, 3, 2)  # retention KEEP beside the arm
    _same(encode_proto(decode_proto[Resource](z.copy())), z, "Resource 18 (DnsZone 1)")

    var r = _resource("www", 26, _record())
    _same(encode_proto(decode_proto[Resource](r.copy())), r, "Resource 26 (DnsRecord 1-5)")
    var mx = List[UInt8]()
    _str(mx, 1, "example.com")
    _msg(mx, 2, _ref("site"))
    _uint(mx, 3, 5)  # RecordType.MX
    _msg(mx, 4, _literal("10 mail.example.com"))
    _msg(mx, 4, _literal("20 backup.example.com"))
    _same(encode_proto(decode_proto[DnsRecord](mx.copy())), mx, "DnsRecord: two values, in order")

    var c = _resource("tls", 27, _certificate())
    _same(encode_proto(decode_proto[Resource](c.copy())), c, "Resource 27 (Certificate 1-2)")
    print("  test_added_dns_numbers_are_kept: PASS")


# ---- 2. DnsZone ---------------------------------------------------------------------


def test_dns_zone() raises:
    """Catches: `name` at another number or wire type, the JSON name not
    `name`, an unwritten name read as present, a field declared at 2, and
    the arm at another number or position."""
    var b = _zone("example.com")
    var z = decode_proto[DnsZone](b.copy())
    assert_equal(z.name, "example.com", "field 1 is `name`")
    _same(encode_proto(z), b, "DnsZone")
    var text = encode_json(z)
    assert_true('"name":"example.com"' in text, "DnsZone JSON: " + text)
    _bytes_equal(encode_proto(decode_json[DnsZone](text)), encode_proto(z), "DnsZone: JSON round trip")
    assert_equal(decode_proto[DnsZone](List[UInt8]()).name, "", "absent: no name")

    var probe = _zone("example.com")
    _str(probe, 2, "not-a-field")
    _same(encode_proto(decode_proto[DnsZone](probe.copy())), _zone("example.com"), "DnsZone has no field 2")

    var rb = _resource("site", 18, _zone("example.com"))
    var rr = decode_proto[Resource](rb.copy())
    assert_true(Bool(rr.dns_zone), "body 18 is `dns_zone`")
    assert_equal(rr._oneof0_case, 8, "the DNS zone is the eighth arm")
    assert_equal(rr.dns_zone.value().name, "example.com")
    var rt = encode_json(rr)
    assert_true('"dnsZone":{"name":"example.com"}' in rt, "Resource JSON carries the zone: " + rt)
    _bytes_equal(encode_proto(decode_json[Resource](rt)), encode_proto(rr), "Resource with a zone: JSON round trip")
    print("  test_dns_zone: PASS")


# ---- 3. DnsRecord -------------------------------------------------------------------


def test_dns_record() raises:
    """Catches: any of the five fields at another number or wire type, the
    values reordered or merged, a JSON name other than the proto3 one, the
    type or the TTL rendered otherwise in JSON, an unwritten zone or TTL read
    as present, a field declared at 6, and the arm at another number or
    position."""
    var b = _record()
    var r = decode_proto[DnsRecord](b.copy())
    assert_equal(r.name, "www.example.com", "field 1 is `name`")
    assert_equal(r.zone.value().resource, "site", "field 2 is `zone`, a Ref")
    assert_equal(r.type.value, RecordType.CNAME, "field 3 is `type`")
    assert_equal(len(r.values), 1, "field 4 is `values`")
    assert_equal(r.values[0]._oneof0_case, 3, "a value may be a Ref")
    assert_equal(r.values[0].ref_.value().resource, "api")
    assert_equal(r.values[0].ref_.value().standard.value().value, Output.HOST)
    assert_equal(Int(r.ttl.value().seconds), 300, "field 5 is `ttl`, a Duration")
    _same(encode_proto(r), b, "DnsRecord")

    var text = encode_json(r)
    for want in [
        '"name":"www.example.com"',
        '"zone":{"resource":"site"}',
        '"type":"CNAME"',
        '"values":[{"ref":{"resource":"api","standard":"HOST"}}]',
        '"ttl":"300s"',
    ]:
        assert_true(String(want) in text, String(want) + " in DnsRecord JSON: " + text)
    _bytes_equal(encode_proto(decode_json[DnsRecord](text)), encode_proto(r), "DnsRecord: JSON round trip")
    var authored = decode_json[DnsRecord](
        String('{"name":"example.com","type":"TXT","values":[{"literal":"v=spf1 -all"},{"literal":"x"}]}')
    )
    assert_equal(authored.type.value, RecordType.TXT, "JSON by name: type")
    assert_equal(len(authored.values), 2, "JSON by name: values")
    assert_equal(authored.values[1].literal.value(), "x", "values keep their order")

    var none = decode_proto[DnsRecord](List[UInt8]())
    assert_true(not Bool(none.zone) and not Bool(none.ttl), "absent: no zone, no ttl")
    assert_equal(none.type.value, RecordType.RECORD_TYPE_UNSET, "absent: the unset type")
    assert_equal(len(none.values), 0, "absent: no values")

    var probe = _record()
    _str(probe, 6, "not-a-field")
    _same(encode_proto(decode_proto[DnsRecord](probe.copy())), _record(), "DnsRecord has no field 6")

    var rr = decode_proto[Resource](_resource("www", 26, _record()))
    assert_true(Bool(rr.dns_record), "body 26 is `dns_record`")
    assert_equal(rr._oneof0_case, 15, "the DNS record is the fifteenth arm")
    var rt = encode_json(rr)
    assert_true('"dnsRecord":{' in rt, "Resource JSON carries the record: " + rt)
    print("  test_dns_record: PASS")


# ---- 4. Certificate -----------------------------------------------------------------


def test_certificate() raises:
    """Catches: `domains` or `zone` at another number or wire type, the
    domains reordered or merged, a JSON name other than the proto3 one, an
    unwritten zone read as present, a field declared at 3, and the arm at
    another number or position."""
    var b = _certificate()
    var c = decode_proto[Certificate](b.copy())
    assert_equal(len(c.domains), 2, "field 1 is `domains`, repeated")
    assert_equal(c.domains[0], "example.com")
    assert_equal(c.domains[1], "*.example.com", "domains keep their order")
    assert_equal(c.zone.value().resource, "site", "field 2 is `zone`, a Ref")
    _same(encode_proto(c), b, "Certificate")

    var text = encode_json(c)
    assert_true('"domains":["example.com","*.example.com"]' in text, "Certificate JSON: " + text)
    assert_true('"zone":{"resource":"site"}' in text, "Certificate JSON: " + text)
    _bytes_equal(encode_proto(decode_json[Certificate](text)), encode_proto(c), "Certificate: JSON round trip")

    var none = decode_proto[Certificate](List[UInt8]())
    assert_true(not Bool(none.zone), "absent: no zone")
    assert_equal(len(none.domains), 0, "absent: no domains")

    var probe = _certificate()
    _str(probe, 3, "not-a-field")
    _same(encode_proto(decode_proto[Certificate](probe.copy())), _certificate(), "Certificate has no field 3")

    var rr = decode_proto[Resource](_resource("tls", 27, _certificate()))
    assert_true(Bool(rr.certificate), "body 27 is `certificate`")
    assert_equal(rr._oneof0_case, 16, "the certificate is the sixteenth arm")
    var rt = encode_json(rr)
    assert_true('"certificate":{"domains":' in rt, "Resource JSON carries the certificate: " + rt)
    print("  test_certificate: PASS")


# ---- 5. RecordType ------------------------------------------------------------------


def test_record_type_ordinals() raises:
    """Catches: a record type renumbered or renamed (the number is what is
    stored), and a sixth value added without its pin."""
    var names: List[String] = ["RECORD_TYPE_UNSET", "A", "AAAA", "CNAME", "TXT", "MX"]
    for n in range(len(names)):
        assert_equal(RecordType(n).json_name(), names[n], String("RecordType ") + String(n))
        assert_equal(RecordType.from_json_name(names[n]).value, n, names[n])
    assert_equal(RecordType(6).json_name(), "6", "RecordType has six values")
    print("  test_record_type_ordinals: PASS")


def main() raises:
    print("test_resource_dns_numbers: dns_zone, dns_record, certificate")
    test_added_dns_numbers_are_kept()
    test_dns_zone()
    test_dns_record()
    test_certificate()
    test_record_type_ordinals()
    print("ALL kci.resource.v1 DNS FIELD-NUMBER TESTS PASSED")
