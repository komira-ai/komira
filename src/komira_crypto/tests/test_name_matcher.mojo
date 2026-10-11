# =============================================================================
# komira_crypto/tests/test_name_matcher.mojo
# RFC 6125 hostname matcher tests.
# =============================================================================
#
# Tests construct synthetic X509Certificate PODs directly (no DER round-trip)
# to exercise the SAN/CN extraction logic against a controlled fixture set.
# This is faster than regenerating cert DERs for every test variant.
#
# The SAN extension extnValue is constructed by hand for the synthetic tests
# (it's the SEQUENCE OF GeneralName encoding, with each entry as a [N]
# IMPLICIT-tagged primitive). End-to-end DER round-trip via the actual
# parser is exercised in `test_x509_smoke.mojo`.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.cert.x509 import (
    X509Certificate,
    Extension,
    DnAttribute,
)
from komira_crypto.cert.asn1 import DerTime
from komira_crypto.cert.name_matcher import match_hostname


# -----------------------------------------------------------------------------
# OID + helper builders
# -----------------------------------------------------------------------------


def _oid_san() -> List[UInt32]:
    var o = List[UInt32]()
    o.append(UInt32(2))
    o.append(UInt32(5))
    o.append(UInt32(29))
    o.append(UInt32(17))
    return o^


def _oid_cn() -> List[UInt32]:
    var o = List[UInt32]()
    o.append(UInt32(2))
    o.append(UInt32(5))
    o.append(UInt32(4))
    o.append(UInt32(3))
    return o^


def _empty_time() -> DerTime:
    return DerTime(UInt16(2025), UInt8(1), UInt8(1), UInt8(0), UInt8(0), UInt8(0))


def _empty_bytes() -> List[UInt8]:
    var o = List[UInt8]()
    return o^


# Encode a single SAN dNSName entry: [2] IMPLICIT IA5String value
# Tag byte = 0x82 (class=context bit 0x80, primitive, tag=2).
def _san_dns(name: String, mut out: List[UInt8]):
    var bs = name.as_bytes()
    var n = len(bs)
    out.append(UInt8(0x82))  # [2] IMPLICIT primitive context
    out.append(UInt8(n))      # short-form length (assume < 128)
    for i in range(n):
        out.append(bs[i])


# Encode a single SAN iPAddress entry: [7] IMPLICIT OCTET STRING value
def _san_ip(ip_bytes: List[UInt8], mut out: List[UInt8]):
    out.append(UInt8(0x87))  # [7] IMPLICIT primitive context
    out.append(UInt8(len(ip_bytes)))
    for i in range(len(ip_bytes)):
        out.append(ip_bytes[i])


# Wrap a list of GeneralName entries in the outer SEQUENCE
def _wrap_san_seq(inner: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(0x30))  # SEQUENCE
    out.append(UInt8(len(inner)))
    for i in range(len(inner)):
        out.append(inner[i])
    return out^


# Build a minimal X509Certificate with SAN extension containing the given
# dNSName patterns and optional iPAddress entries.
def _cert_with_san(
    var dns_patterns: List[String], var ip_addrs: List[List[UInt8]]
) -> X509Certificate:
    var san_inner = List[UInt8]()
    for i in range(len(dns_patterns)):
        _san_dns(dns_patterns[i], san_inner)
    for i in range(len(ip_addrs)):
        _san_ip(ip_addrs[i], san_inner)
    var san_value = _wrap_san_seq(san_inner^)
    var exts = List[Extension]()
    exts.append(Extension(_oid_san(), False, san_value^))
    var empty_subj = List[DnAttribute]()
    var empty_iss = List[DnAttribute]()
    var empty_algo = List[UInt32]()
    var empty_pk_algo = List[UInt32]()
    return X509Certificate(
        UInt8(2),                # version v3
        _empty_bytes(),          # serial
        empty_algo^,             # signature_algo_oid
        empty_iss^,              # issuer
        _empty_time(),           # not_before
        _empty_time(),           # not_after
        empty_subj^,             # subject
        empty_pk_algo^,          # subject_pubkey_algo_oid
        _empty_bytes(),          # subject_pubkey
        exts^,                   # extensions
        _empty_bytes(),          # signature_value
        _empty_bytes(),          # tbs_raw
    )


# Build a cert with NO SAN but a CN in the subject.
def _cert_with_cn(cn: String) -> X509Certificate:
    var subj = List[DnAttribute]()
    subj.append(DnAttribute(_oid_cn(), cn))
    var iss = List[DnAttribute]()
    var algo = List[UInt32]()
    var pk_algo = List[UInt32]()
    var exts = List[Extension]()  # no SAN
    return X509Certificate(
        UInt8(2),
        _empty_bytes(),
        algo^,
        iss^,
        _empty_time(),
        _empty_time(),
        subj^,
        pk_algo^,
        _empty_bytes(),
        exts^,
        _empty_bytes(),
        _empty_bytes(),
    )


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_san_dns_exact_match() raises:
    """An exact-case SAN dNSName entry matches a same-case hostname."""
    var pats = List[String]()
    pats.append(String("example.com"))
    var ips = List[List[UInt8]]()
    var cert = _cert_with_san(pats^, ips^)
    assert_true(match_hostname(cert, "example.com"))


def test_san_dns_case_insensitive_match() raises:
    """SAN matching is ASCII case-insensitive."""
    var pats = List[String]()
    pats.append(String("Example.COM"))
    var ips = List[List[UInt8]]()
    var cert = _cert_with_san(pats^, ips^)
    assert_true(match_hostname(cert, "example.com"))
    var pats2 = List[String]()
    pats2.append(String("example.com"))
    var ips2 = List[List[UInt8]]()
    var cert2 = _cert_with_san(pats2^, ips2^)
    assert_true(match_hostname(cert2, "EXAMPLE.COM"))


def test_san_dns_wildcard_one_label() raises:
    """Wildcard `*.example.com` matches `foo.example.com` (single label)."""
    var pats = List[String]()
    pats.append(String("*.example.com"))
    var ips = List[List[UInt8]]()
    var cert = _cert_with_san(pats^, ips^)
    assert_true(match_hostname(cert, "foo.example.com"))


def test_san_dns_wildcard_rejects_two_labels() raises:
    """Wildcard `*.example.com` does NOT match `foo.bar.example.com`."""
    var pats = List[String]()
    pats.append(String("*.example.com"))
    var ips = List[List[UInt8]]()
    var cert = _cert_with_san(pats^, ips^)
    assert_false(match_hostname(cert, "foo.bar.example.com"))


def test_san_dns_wildcard_rejects_naked() raises:
    """Wildcard `*.example.com` does NOT match `example.com` (no label)."""
    var pats = List[String]()
    pats.append(String("*.example.com"))
    var ips = List[List[UInt8]]()
    var cert = _cert_with_san(pats^, ips^)
    assert_false(match_hostname(cert, "example.com"))


def test_san_dns_partial_wildcard_rejected() raises:
    """Partial wildcard `f*.example.com` is rejected per RFC 6125 §6.4.3."""
    var pats = List[String]()
    pats.append(String("f*.example.com"))
    var ips = List[List[UInt8]]()
    var cert = _cert_with_san(pats^, ips^)
    assert_false(match_hostname(cert, "foo.example.com"))


def test_san_multiple_entries_first_match_wins() raises:
    """If multiple SAN entries are present, any matching one returns True."""
    var pats = List[String]()
    pats.append(String("other.example.com"))
    pats.append(String("example.com"))
    pats.append(String("foo.example.com"))
    var ips = List[List[UInt8]]()
    var cert = _cert_with_san(pats^, ips^)
    assert_true(match_hostname(cert, "example.com"))
    var pats2 = List[String]()
    pats2.append(String("other.example.com"))
    pats2.append(String("example.com"))
    pats2.append(String("foo.example.com"))
    var ips2 = List[List[UInt8]]()
    var cert2 = _cert_with_san(pats2^, ips2^)
    assert_true(match_hostname(cert2, "foo.example.com"))


def test_san_no_matching_entry_returns_false() raises:
    """A hostname not matching any SAN dNSName returns False."""
    var pats = List[String]()
    pats.append(String("example.com"))
    pats.append(String("other.com"))
    var ips = List[List[UInt8]]()
    var cert = _cert_with_san(pats^, ips^)
    assert_false(match_hostname(cert, "different.com"))


def test_san_no_fallback_to_cn_when_san_present() raises:
    """When SAN is present, CN is NOT used per RFC 6125 §6.4.4."""
    # Build a cert with SAN that doesn't match AND a CN that would match.
    var san_inner = List[UInt8]()
    _san_dns(String("other.com"), san_inner)
    var san_value = _wrap_san_seq(san_inner^)
    var exts = List[Extension]()
    exts.append(Extension(_oid_san(), False, san_value^))
    var subj = List[DnAttribute]()
    subj.append(DnAttribute(_oid_cn(), String("example.com")))
    var iss = List[DnAttribute]()
    var algo = List[UInt32]()
    var pk_algo = List[UInt32]()
    var cert = X509Certificate(
        UInt8(2),
        _empty_bytes(),
        algo^,
        iss^,
        _empty_time(),
        _empty_time(),
        subj^,
        pk_algo^,
        _empty_bytes(),
        exts^,
        _empty_bytes(),
        _empty_bytes(),
    )
    # Even though CN matches, SAN-present means we ignore CN.
    assert_false(match_hostname(cert, "example.com"))


def test_cn_fallback_when_no_san() raises:
    """When SAN is absent, fall back to CN per RFC 6125 §6.4.4 (legacy)."""
    var cert = _cert_with_cn(String("legacy.example.com"))
    assert_true(match_hostname(cert, "legacy.example.com"))


def test_cn_fallback_wildcard() raises:
    """CN fallback also honors wildcard rules (one-label expansion)."""
    var cert = _cert_with_cn(String("*.legacy.com"))
    assert_true(match_hostname(cert, "foo.legacy.com"))
    var cert2 = _cert_with_cn(String("*.legacy.com"))
    assert_false(match_hostname(cert2, "foo.bar.legacy.com"))


def test_san_ipv4_match() raises:
    """An iPAddress SAN entry of 4 bytes matches a dotted-quad hostname."""
    var pats = List[String]()
    var ips = List[List[UInt8]]()
    var ip = List[UInt8]()
    ip.append(UInt8(192))
    ip.append(UInt8(168))
    ip.append(UInt8(1))
    ip.append(UInt8(1))
    ips.append(ip^)
    var cert = _cert_with_san(pats^, ips^)
    assert_true(match_hostname(cert, "192.168.1.1"))


def test_san_ipv4_no_match() raises:
    """An iPAddress SAN entry of 4 bytes does NOT match a different IP."""
    var pats = List[String]()
    var ips = List[List[UInt8]]()
    var ip = List[UInt8]()
    ip.append(UInt8(192))
    ip.append(UInt8(168))
    ip.append(UInt8(1))
    ip.append(UInt8(1))
    ips.append(ip^)
    var cert = _cert_with_san(pats^, ips^)
    assert_false(match_hostname(cert, "192.168.1.2"))


def test_san_dns_naked_wildcard_rejected() raises:
    """A pattern of `*` alone is rejected (no domain)."""
    var pats = List[String]()
    pats.append(String("*"))
    var ips = List[List[UInt8]]()
    var cert = _cert_with_san(pats^, ips^)
    assert_false(match_hostname(cert, "foo"))


def test_san_dns_double_wildcard_rejected() raises:
    """A pattern with multiple wildcards `*.*.example.com` is rejected."""
    var pats = List[String]()
    pats.append(String("*.*.example.com"))
    var ips = List[List[UInt8]]()
    var cert = _cert_with_san(pats^, ips^)
    assert_false(match_hostname(cert, "a.b.example.com"))


def test_empty_names_never_match() raises:
    """An empty dNSName (RFC 5280 4.2.1.6 forbids one) or an empty subject CN
    names nothing, and an empty hostname matches no certificate."""
    var pats = List[String]()
    pats.append(String(""))
    var ips = List[List[UInt8]]()
    var cert = _cert_with_san(pats^, ips^)
    assert_false(match_hostname(cert, ""), "empty dNSName, empty hostname")
    assert_false(match_hostname(cert, "example.com"), "empty dNSName")
    var cn = _cert_with_cn(String(""))
    assert_false(match_hostname(cn, ""), "empty CN, empty hostname")
    var named = _cert_with_cn(String("example.com"))
    assert_false(match_hostname(named, ""), "empty hostname")


def main() raises:
    test_san_dns_exact_match()
    test_san_dns_case_insensitive_match()
    test_san_dns_wildcard_one_label()
    test_san_dns_wildcard_rejects_two_labels()
    test_san_dns_wildcard_rejects_naked()
    test_san_dns_partial_wildcard_rejected()
    test_san_multiple_entries_first_match_wins()
    test_san_no_matching_entry_returns_false()
    test_san_no_fallback_to_cn_when_san_present()
    test_cn_fallback_when_no_san()
    test_cn_fallback_wildcard()
    test_san_ipv4_match()
    test_san_ipv4_no_match()
    test_san_dns_naked_wildcard_rejected()
    test_san_dns_double_wildcard_rejected()
    test_empty_names_never_match()
    print("All 16 name_matcher tests PASSED")
