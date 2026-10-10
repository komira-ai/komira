# =============================================================================
# test_resource_network_numbers.mojo
# =============================================================================
#
# THE NETWORKS OF `kci.resource.v1`, AS WIRE BYTES: the `network` arm 23, the
# `subnet` arm 29, the `ip_address` arm 30, and `Service.network` 16. The
# field template of test_resource_field_numbers.mojo, in a file of its own
# (that file is past the size a Mojo source should stay under).
#
# 1. KEPT, BY BYTES ONLY. Nothing is read by name: `Resource` 23 holding a
#    network with every field, `Resource` 29 holding a subnet with every
#    field, `Resource` 30 (an empty record) and a service whose field 16 is a
#    `Ref` survive decode then encode. Every failure is collected, so one run
#    names every number that is missing.
# 2. NETWORK. 1 ipv4_cidr; by name, binary, JSON (`ipv4Cidr`), absent =
#    unset; 2 is not a field; as `Resource.body` 23, the twelfth arm, under
#    the JSON name `network`.
# 3. SUBNET. 1 network (a `Ref`), 2 ipv4_cidr, 3 zone (an optional number:
#    an explicit 0 is present); by name, binary, JSON (`network`,
#    `ipv4Cidr`, `zone`), absent = unset; 4 is not a field; as
#    `Resource.body` 29, the eighteenth arm, under the JSON name `subnet`.
# 4. IPADDRESS. It declares no field: any record in it is unknown and
#    dropped. As `Resource.body` 30, the nineteenth arm, under the JSON name
#    `ipAddress`, its empty record is kept, and `retention` 3 rides beside
#    it.
# 5. SERVICE.NETWORK. Field 16 is `network`, a `Ref`; by name, binary, JSON
#    (`"network":{"resource":"edge"}`), absent = unset; the fields beside it
#    keep their numbers; 17 is not a field.
# The census of every arm's oneof position is in
# test_resource_compute_numbers.mojo.
# The bytes are a LITERAL restatement of the proto, deliberately: deriving
# them from the generated code would agree with it by construction.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from kci_resource_proto.compute import Service
from kci_resource_proto.networks import IpAddress, Network, Subnet
from kci_resource_proto.refs import Retention
from kci_resource_proto.resource import Resource


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


def _network() -> List[UInt8]:
    """Network { 1 ipv4_cidr }."""
    var b = List[UInt8]()
    _str(b, 1, "10.20.0.0/16")
    return b^


def _subnet() -> List[UInt8]:
    """Subnet { 1 network, 2 ipv4_cidr, 3 zone }."""
    var b = List[UInt8]()
    _msg(b, 1, _ref("core"))
    _str(b, 2, "10.20.4.0/24")
    _uint(b, 3, 2)
    return b^


def _service() -> List[UInt8]:
    """Service { 2 port, 16 network }."""
    var b = List[UInt8]()
    _uint(b, 2, 8080)
    _msg(b, 16, _ref("edge"))
    return b^


def _resource(id: String, arm: Int, body: List[UInt8]) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, id)
    _msg(b, arm, body)
    return b^


# ---- 1. kept, by bytes only -------------------------------------------------------


def test_added_network_numbers_are_kept() raises:
    """Catches: `Resource` 23, 29 or 30 or `Service` 16 undeclared,
    renumbered or of another wire type, any field of `Network` or `Subnet`
    undeclared or of another wire type (each is dropped or misread on
    re-encode), and an empty `ip_address` arm dropped by the encoder.
    Collects every failure, so the red run against the earlier schema names
    all of them."""
    var bad = List[String]()
    var n = _resource("core", 23, _network())
    if not _kept(encode_proto(decode_proto[Resource](n.copy())), n):
        bad.append("Resource 23 (Network 1 ipv4_cidr)")
    var s = _resource("edge", 29, _subnet())
    if not _kept(encode_proto(decode_proto[Resource](s.copy())), s):
        bad.append("Resource 29 (Subnet 1 network, 2 ipv4_cidr, 3 zone)")
    # `_kept` drops an empty record as a zero value: the arm's tag (30,
    # length-delimited: 0xf2 0x01) and its zero length must be there.
    var a = _resource("ingress-ip", 30, List[UInt8]())
    var back = encode_proto(decode_proto[Resource](a.copy()))
    if not _kept(back, a) or _hex(back).find("f20100") < 0:
        bad.append("Resource 30 (IpAddress, an empty record): got " + _hex(back))
    var svc = _service()
    if not _kept(encode_proto(decode_proto[Service](svc.copy())), svc):
        bad.append("Service 16 (network, a Ref)")
    var names = String("")
    for i in range(len(bad)):
        names += String("\n  ") + bad[i]
    assert_equal(len(bad), 0, String("not kept as P10 declares them:") + names)
    print("  test_added_network_numbers_are_kept: PASS")


# ---- 2. Network -------------------------------------------------------------------


def test_network() raises:
    """Catches: `ipv4_cidr` at another number or wire type, a JSON name
    other than the proto3 one, a field declared at 2, and the arm at another
    number or position."""
    var b = _network()
    var n = decode_proto[Network](b.copy())
    assert_equal(n.ipv4_cidr, "10.20.0.0/16", "field 1 is `ipv4_cidr`")
    _same(encode_proto(n), b, "Network")

    var text = encode_json(n)
    assert_true('"ipv4Cidr":"10.20.0.0/16"' in text, "Network JSON: " + text)
    _bytes_equal(encode_proto(decode_json[Network](text)), encode_proto(n), "Network: JSON round trip")
    assert_equal(decode_proto[Network](List[UInt8]()).ipv4_cidr, "", "absent: no range")

    var probe = _network()
    _str(probe, 2, "not-a-field")
    _same(encode_proto(decode_proto[Network](probe.copy())), _network(), "Network has no field 2")

    var rr = decode_proto[Resource](_resource("core", 23, _network()))
    assert_true(Bool(rr.network), "body 23 is `network`")
    assert_equal(rr._oneof0_case, 12, "the network is the twelfth arm")
    var rt = encode_json(rr)
    assert_true('"network":{' in rt, "Resource JSON names the arm network: " + rt)
    _bytes_equal(encode_proto(decode_json[Resource](rt)), encode_proto(rr), "Resource with a network: JSON round trip")
    print("  test_network: PASS")


# ---- 3. Subnet --------------------------------------------------------------------


def test_subnet() raises:
    """Catches: `network` at another number or wire type, `ipv4_cidr` at
    another number, `zone` without presence (an explicit 0 read as absent)
    or at another number, a JSON name other than the proto3 one, an
    unwritten network or zone read as present, a field declared at 4, and
    the arm at another number or position."""
    var b = _subnet()
    var s = decode_proto[Subnet](b.copy())
    assert_equal(s.network.value().resource, "core", "field 1 is `network`")
    assert_equal(s.ipv4_cidr, "10.20.4.0/24", "field 2 is `ipv4_cidr`")
    assert_equal(Int(s.zone.value()), 2, "field 3 is `zone`")
    _same(encode_proto(s), b, "Subnet")

    var text = encode_json(s)
    for want in ['"network":{"resource":"core"}', '"ipv4Cidr":"10.20.4.0/24"', '"zone":2']:
        assert_true(String(want) in text, String(want) + " in Subnet JSON: " + text)
    _bytes_equal(encode_proto(decode_json[Subnet](text)), encode_proto(s), "Subnet: JSON round trip")

    var none = decode_proto[Subnet](List[UInt8]())
    assert_true(not Bool(none.network), "absent: no network")
    assert_equal(none.ipv4_cidr, "", "absent: no range")
    assert_true(not Bool(none.zone), "absent: no zone")
    var z = List[UInt8]()
    _uint(z, 3, 0)
    var zero = decode_proto[Subnet](z^)
    assert_true(Bool(zero.zone), "an explicit zone 0 is present (validate refuses it)")
    assert_equal(Int(zero.zone.value()), 0)

    var probe = _subnet()
    _str(probe, 4, "not-a-field")
    _same(encode_proto(decode_proto[Subnet](probe.copy())), _subnet(), "Subnet has no field 4")

    var rr = decode_proto[Resource](_resource("edge", 29, _subnet()))
    assert_true(Bool(rr.subnet), "body 29 is `subnet`")
    assert_equal(rr._oneof0_case, 18, "the subnet is the eighteenth arm")
    var rt = encode_json(rr)
    assert_true('"subnet":{' in rt, "Resource JSON names the arm subnet: " + rt)
    _bytes_equal(encode_proto(decode_json[Resource](rt)), encode_proto(rr), "Resource with a subnet: JSON round trip")
    print("  test_subnet: PASS")


# ---- 4. IpAddress -----------------------------------------------------------------


def test_ip_address() raises:
    """Catches: a field declared in `IpAddress` (it has none), the arm at
    another number or position, an empty arm dropped from JSON, and
    `retention` 3 moved by the arm beside it."""
    var probe = List[UInt8]()
    _str(probe, 1, "not-a-field")
    _same(encode_proto(decode_proto[IpAddress](probe^)), List[UInt8](), "IpAddress has no field 1")

    var b = List[UInt8]()
    _str(b, 1, "ingress-ip")
    _uint(b, 3, 2)  # retention KEEP
    _msg(b, 30, List[UInt8]())
    var rr = decode_proto[Resource](b.copy())
    assert_true(Bool(rr.ip_address), "body 30 is `ip_address`")
    assert_equal(rr._oneof0_case, 19, "the IP address is the nineteenth arm")
    assert_equal(rr.retention.value, Retention.KEEP, "retention rides beside it")
    var rt = encode_json(rr)
    assert_true('"ipAddress":{}' in rt, "Resource JSON names the empty arm ipAddress: " + rt)
    _bytes_equal(encode_proto(decode_json[Resource](rt)), encode_proto(rr), "Resource with an IP address: JSON round trip")
    print("  test_ip_address: PASS")


# ---- 5. Service.network -----------------------------------------------------------


def test_service_network() raises:
    """Catches: `network` at another number or wire type, a JSON name other
    than the proto3 one, an unwritten network read as present, a field
    beside it moved, and a field declared at 17."""
    var b = _service()
    var s = decode_proto[Service](b.copy())
    assert_equal(s.network.value().resource, "edge", "field 16 is `network`")
    assert_equal(Int(s.port), 8080, "`port` stays field 2")
    assert_true(not Bool(s.run_as), "`run_as` stays field 14")
    _same(encode_proto(s), b, "Service 16")
    var text = encode_json(s)
    assert_true('"network":{"resource":"edge"}' in text, "Service JSON: " + text)
    _bytes_equal(encode_proto(decode_json[Service](text)), encode_proto(s), "Service: JSON round trip")
    assert_true(not Bool(decode_proto[Service](List[UInt8]()).network), "absent: no network")
    var probe = b.copy()
    _str(probe, 17, "not-a-field")
    _same(encode_proto(decode_proto[Service](probe.copy())), b, "Service has no field 17")
    print("  test_service_network: PASS")


def main() raises:
    print("test_resource_network_numbers: network, subnet, ip_address, Service.network")
    test_added_network_numbers_are_kept()
    test_network()
    test_subnet()
    test_ip_address()
    test_service_network()
    print("ALL kci.resource.v1 NETWORK FIELD-NUMBER TESTS PASSED")
