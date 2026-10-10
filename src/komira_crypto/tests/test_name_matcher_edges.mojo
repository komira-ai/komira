# =============================================================================
# komira_crypto/tests/test_name_matcher_edges.mojo
#
# Hostname-matching edges test_name_matcher does not reach:
#   * _match_dns_pattern with an empty pattern, and a hostname whose first
#     label is empty against a wildcard;
#   * _parse_ipv4_literal: an empty octet, a fifth octet, a value above 255
#     (refused as the digits are read), a trailing dot, fewer than four
#     octets (not IPv4: empty result), and the 0 / 255 edges;
#   * match_hostname refusing a subjectAltName that is not a SEQUENCE.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.cert.x509 import x509_parse_certificate
from komira_crypto.cert.name_matcher import (
    match_hostname,
    _match_dns_pattern,
    _parse_ipv4_literal,
)


def _ip_err(s: String) -> String:
    try:
        var r = _parse_ipv4_literal(s)
        return String("ok ") + String(len(r))
    except e:
        return String(e)


def test_dns_pattern_edges() raises:
    assert_false(_match_dns_pattern(String(""), String("example.com")), "empty pattern")
    assert_false(_match_dns_pattern(String("*.example.com"), String(".example.com")), "empty first label")
    assert_true(_match_dns_pattern(String("*.example.com"), String("a.example.com")), "one label")


def test_ipv4_literal_refusals() raises:
    assert_true(_ip_err("1..2.3").find("ipv4: empty octet") >= 0, "empty octet")
    assert_true(_ip_err(".1.2.3").find("ipv4: empty octet") >= 0, "leading dot")
    assert_true(_ip_err("1.2.3.4.5").find("ipv4: > 4 octets") >= 0, "five octets")
    assert_true(_ip_err("256.1.1.1").find("ipv4: octet > 255") >= 0, "256")
    assert_true(_ip_err("1.2.3.1000").find("ipv4: octet > 255") >= 0, "1000 in the last octet")
    assert_true(_ip_err("1.2.3.").find("ipv4: trailing empty") >= 0, "trailing dot")
    assert_equal(_ip_err("1.2.3"), String("ok 0"), "three octets is not IPv4")
    assert_equal(_ip_err("example.com"), String("ok 0"), "a DNS name")


def test_ipv4_literal_values() raises:
    var r = _parse_ipv4_literal(String("255.0.10.1"))
    assert_equal(len(r), 4, "four octets")
    assert_equal(Int(r[0]), 255, "255")
    assert_equal(Int(r[1]), 0, "0")
    assert_equal(Int(r[2]), 10, "10")
    assert_equal(Int(r[3]), 1, "1")


# -----------------------------------------------------------------------------
# A certificate whose subjectAltName is a SET
# -----------------------------------------------------------------------------


def _b(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


def _cat(*parts: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(parts)):
        for j in range(len(parts[i])):
            out.append(parts[i][j])
    return out^


def _tlv(tag: Int, content: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(tag))
    var n = len(content)
    if n < 0x80:
        out.append(UInt8(n))
    else:
        out.append(0x81)
        out.append(UInt8(n))
    for j in range(len(content)):
        out.append(content[j])
    return out^


def _ascii(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for c in s.as_bytes():
        out.append(c)
    return out^


def _cert_with_san(san_value: List[UInt8]) -> List[UInt8]:
    var alg = _tlv(0x30, _b(0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02))
    var name = _tlv(0x30, _tlv(0x31, _tlv(0x30, _cat(_b(0x06, 0x03, 0x55, 0x04, 0x03), _tlv(0x0C, _ascii("h"))))))
    var validity = _tlv(0x30, _cat(_tlv(0x17, _ascii("300101000000Z")), _tlv(0x17, _ascii("360101000000Z"))))
    var spki = _tlv(0x30, _cat(_tlv(0x30, _b(0x06, 0x03, 0x2B, 0x65, 0x70)), _tlv(0x03, _b(0x00, 0x01))))
    var san = _tlv(0x30, _cat(_b(0x06, 0x03, 0x55, 0x1D, 0x11), _tlv(0x04, san_value)))
    var tbs = _tlv(0x30, _cat(_tlv(0xA0, _b(0x02, 0x01, 0x02)), _b(0x02, 0x01, 0x01), alg, name, validity, name, spki, _tlv(0xA3, _tlv(0x30, san))))
    return _tlv(0x30, _cat(tbs, alg, _tlv(0x03, _b(0x00, 0x00))))


def test_san_must_be_a_sequence() raises:
    var ok = _cert_with_san(_tlv(0x30, _tlv(0x82, _ascii("example.com"))))
    var cert_ok = x509_parse_certificate(Span(ok))
    assert_true(match_hostname(cert_ok, String("example.com")), "SEQUENCE SAN matches")
    var bad = _cert_with_san(_tlv(0x31, _tlv(0x82, _ascii("example.com"))))
    var cert = x509_parse_certificate(Span(bad))
    var e = String("no error")
    try:
        _ = match_hostname(cert, String("example.com"))
    except err:
        e = String(err)
    assert_true(e.find("SAN: top is not a SEQUENCE") >= 0, e)


def main() raises:
    test_dns_pattern_edges()
    test_ipv4_literal_refusals()
    test_ipv4_literal_values()
    test_san_must_be_a_sequence()
    print("test_name_matcher_edges: 4 tests PASS")
