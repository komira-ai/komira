# =============================================================================
# komira_crypto/tests/test_chain_policy.mojo
#
# chain_verify's checks that come before any signature, on certificates
# assembled here (no fixture has these shapes):
#   * the validity window compared field by field: _time_cmp on a table that
#     differs in exactly one field, and chain_verify at one second either
#     side of notBefore and notAfter in the same year, month, day and hour;
#   * critical extensions: each recognized one (basicConstraints, keyUsage,
#     extKeyUsage, subjectAltName, subjectKeyIdentifier,
#     authorityKeyIdentifier) passes, an unrecognized critical one is
#     refused, an unrecognized non-critical one is ignored;
#   * leaf keyUsage / extKeyUsage values of the wrong ASN.1 type, an
#     extKeyUsage holding a non-OID, serverAuth found after another purpose;
#   * issuer DN against subject DN differing in length or in an attribute
#     type with the same value;
#   * an issuer with no basicConstraints, or one that is not a SEQUENCE.
# A one-certificate chain whose subject is a trust anchor ends at the anchor
# with no signature check, so these certificates carry filler signatures.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.cert.asn1 import DerTime
from komira_crypto.cert.x509 import X509Certificate, x509_parse_certificate
from komira_crypto.cert.chain import chain_verify, _time_cmp


# -----------------------------------------------------------------------------
# DER builder
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
    elif n < 0x100:
        out.append(0x81)
        out.append(UInt8(n))
    else:
        out.append(0x82)
        out.append(UInt8(n >> 8))
        out.append(UInt8(n & 0xFF))
    for j in range(n):
        out.append(content[j])
    return out^


def _str(tag: Int, text: String) -> List[UInt8]:
    var v = List[UInt8]()
    for c in text.as_bytes():
        v.append(c)
    return _tlv(tag, v)


def _seq(content: List[UInt8]) -> List[UInt8]:
    return _tlv(0x30, content)


def _atv(oid_last: Int, value: String) -> List[UInt8]:
    # 2.5.4.<oid_last>: 3 = commonName, 10 = organizationName.
    return _tlv(0x31, _seq(_cat(_b(0x06, 0x03, 0x55, 0x04, oid_last), _str(0x0C, value))))


def _name(cn: String) -> List[UInt8]:
    return _seq(_atv(3, cn))


def _alg() -> List[UInt8]:
    return _seq(_b(0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02))


def _spki() -> List[UInt8]:
    var point = List[UInt8]()
    point.append(0x00)
    point.append(0x04)
    for i in range(64):
        point.append(UInt8(i + 1))
    var alg = _seq(
        _cat(
            _b(0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01),
            _b(0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07),
        )
    )
    return _seq(_cat(alg, _tlv(0x03, point)))


def _ext(oid_last: Int, critical: Bool, value: List[UInt8]) -> List[UInt8]:
    # 2.5.29.<oid_last>
    var crit = _b(0x01, 0x01, 0xFF) if critical else List[UInt8]()
    return _seq(_cat(_b(0x06, 0x03, 0x55, 0x1D, oid_last), crit, _tlv(0x04, value)))


def _bc_ca() -> List[UInt8]:
    return _ext(19, True, _seq(_b(0x01, 0x01, 0xFF)))


def _cert_der(
    issuer: List[UInt8],
    subject: List[UInt8],
    nb: String,
    na: String,
    exts: List[UInt8],
) -> List[UInt8]:
    var validity = _seq(_cat(_str(0x18, nb), _str(0x18, na)))
    var tail = _tlv(0xA3, _seq(exts)) if len(exts) > 0 else List[UInt8]()
    var tbs = _seq(
        _cat(
            _tlv(0xA0, _b(0x02, 0x01, 0x02)),
            _b(0x02, 0x01, 0x01),
            _alg(),
            issuer,
            validity,
            subject,
            _spki(),
            tail,
        )
    )
    var sig = _tlv(0x03, _b(0x00, 0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01))
    return _seq(_cat(tbs, _alg(), sig))


def _parse(der: List[UInt8]) raises -> X509Certificate:
    return x509_parse_certificate(Span(der))


comptime Now = Tuple[UInt16, UInt8, UInt8, UInt8, UInt8, UInt8]


def _now(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int) -> Now:
    return (UInt16(y), UInt8(mo), UInt8(d), UInt8(h), UInt8(mi), UInt8(s))


def _self_anchored(der: List[UInt8], now: Now) raises -> String:
    """chain_verify([cert], [cert], now): "ok" or the refusal message."""
    var chain = List[X509Certificate]()
    chain.append(_parse(der))
    var anchors = List[X509Certificate]()
    anchors.append(_parse(der))
    try:
        if chain_verify(chain, anchors, now):
            return String("ok")
        return String("false")
    except e:
        return String(e)


def _pair(leaf: List[UInt8], issuer: List[UInt8]) raises -> String:
    """chain_verify([leaf, issuer], [issuer], 2031-01-01)."""
    var chain = List[X509Certificate]()
    chain.append(_parse(leaf))
    chain.append(_parse(issuer))
    var anchors = List[X509Certificate]()
    anchors.append(_parse(issuer))
    try:
        if chain_verify(chain, anchors, _now(2031, 1, 1, 0, 0, 0)):
            return String("ok")
        return String("false")
    except e:
        return String(e)


def _has(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


def _wide(exts: List[UInt8]) -> List[UInt8]:
    return _cert_der(_name("self"), _name("self"), "20300101000000Z", "20320101000000Z", exts)


# -----------------------------------------------------------------------------
# Validity window
# -----------------------------------------------------------------------------


def _t(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int) -> DerTime:
    return DerTime(UInt16(y), UInt8(mo), UInt8(d), UInt8(h), UInt8(mi), UInt8(s))


def test_time_cmp_each_field() raises:
    var base = _t(2030, 6, 15, 12, 30, 30)
    assert_equal(_time_cmp(base, _t(2030, 6, 15, 12, 30, 30)), 0, "equal")
    assert_equal(_time_cmp(base, _t(2031, 1, 1, 0, 0, 0)), -1, "year <")
    assert_equal(_time_cmp(base, _t(2029, 12, 31, 23, 59, 59)), 1, "year >")
    assert_equal(_time_cmp(base, _t(2030, 7, 1, 0, 0, 0)), -1, "month <")
    assert_equal(_time_cmp(base, _t(2030, 5, 31, 23, 59, 59)), 1, "month >")
    assert_equal(_time_cmp(base, _t(2030, 6, 16, 0, 0, 0)), -1, "day <")
    assert_equal(_time_cmp(base, _t(2030, 6, 14, 23, 59, 59)), 1, "day >")
    assert_equal(_time_cmp(base, _t(2030, 6, 15, 13, 0, 0)), -1, "hour <")
    assert_equal(_time_cmp(base, _t(2030, 6, 15, 11, 59, 59)), 1, "hour >")
    assert_equal(_time_cmp(base, _t(2030, 6, 15, 12, 31, 0)), -1, "minute <")
    assert_equal(_time_cmp(base, _t(2030, 6, 15, 12, 29, 59)), 1, "minute >")
    assert_equal(_time_cmp(base, _t(2030, 6, 15, 12, 30, 31)), -1, "second <")
    assert_equal(_time_cmp(base, _t(2030, 6, 15, 12, 30, 29)), 1, "second >")


def test_window_edges_to_the_second() raises:
    var der = _cert_der(
        _name("w"), _name("w"), "20300615123030Z", "20300615123040Z", List[UInt8]()
    )
    var refused = String("not currently valid")
    assert_equal(_self_anchored(der, _now(2030, 6, 15, 12, 30, 30)), "ok", "at notBefore")
    assert_equal(_self_anchored(der, _now(2030, 6, 15, 12, 30, 40)), "ok", "at notAfter")
    assert_true(_has(_self_anchored(der, _now(2030, 6, 15, 12, 30, 29)), refused), "1 s early")
    assert_true(_has(_self_anchored(der, _now(2030, 6, 15, 12, 30, 41)), refused), "1 s late")
    assert_true(_has(_self_anchored(der, _now(2030, 6, 15, 12, 29, 35)), refused), "minute early")
    assert_true(_has(_self_anchored(der, _now(2030, 6, 15, 12, 31, 35)), refused), "minute late")
    assert_true(_has(_self_anchored(der, _now(2030, 6, 15, 11, 30, 35)), refused), "hour early")
    assert_true(_has(_self_anchored(der, _now(2030, 6, 15, 13, 30, 35)), refused), "hour late")
    assert_true(_has(_self_anchored(der, _now(2030, 6, 14, 12, 30, 35)), refused), "day early")
    assert_true(_has(_self_anchored(der, _now(2030, 6, 16, 12, 30, 35)), refused), "day late")
    assert_true(_has(_self_anchored(der, _now(2030, 5, 15, 12, 30, 35)), refused), "month early")
    assert_true(_has(_self_anchored(der, _now(2030, 7, 15, 12, 30, 35)), refused), "month late")


# -----------------------------------------------------------------------------
# Critical extensions
# -----------------------------------------------------------------------------


def test_each_recognized_critical_extension_passes() raises:
    var now = _now(2031, 1, 1, 0, 0, 0)
    var ku = _ext(15, True, _b(0x03, 0x02, 0x07, 0x80))  # digitalSignature
    var eku = _ext(37, True, _seq(_b(0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01)))
    var san = _ext(17, True, _seq(_str(0x82, "example.com")))
    var ski = _ext(14, True, _b(0x04, 0x02, 0xAA, 0xBB))
    var aki = _ext(35, True, _seq(_b(0x80, 0x02, 0xAA, 0xBB)))
    assert_equal(_self_anchored(_wide(_bc_ca()), now), "ok", "critical basicConstraints")
    assert_equal(_self_anchored(_wide(ku), now), "ok", "critical keyUsage")
    assert_equal(_self_anchored(_wide(eku), now), "ok", "critical extKeyUsage")
    assert_equal(_self_anchored(_wide(san), now), "ok", "critical subjectAltName")
    assert_equal(_self_anchored(_wide(ski), now), "ok", "critical subjectKeyIdentifier")
    assert_equal(_self_anchored(_wide(aki), now), "ok", "critical authorityKeyIdentifier")
    assert_equal(
        _self_anchored(_wide(_cat(_bc_ca(), ku, eku, san, ski, aki)), now),
        "ok",
        "all six critical",
    )


def test_unknown_critical_extension_is_refused() raises:
    var now = _now(2031, 1, 1, 0, 0, 0)
    # 2.5.29.32 certificatePolicies is not in the recognized set.
    var policies_crit = _ext(32, True, _seq(List[UInt8]()))
    var policies = _ext(32, False, _seq(List[UInt8]()))
    assert_equal(_self_anchored(_wide(policies), now), "ok", "non-critical unknown")
    var e = _self_anchored(_wide(_cat(_bc_ca(), policies_crit)), now)
    assert_true(_has(e, "cert 0 has unknown CRITICAL extension"), e)


# -----------------------------------------------------------------------------
# Leaf keyUsage / extKeyUsage
# -----------------------------------------------------------------------------


def test_leaf_usage_value_types() raises:
    var now = _now(2031, 1, 1, 0, 0, 0)
    var ku_int = _ext(15, False, _b(0x02, 0x01, 0x05))
    var e = _self_anchored(_wide(ku_int), now)
    assert_true(_has(e, "keyUsage: extnValue is not a BIT STRING"), e)
    var eku_set = _ext(37, False, _tlv(0x31, _b(0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01)))
    e = _self_anchored(_wide(eku_set), now)
    assert_true(_has(e, "extKeyUsage: not a SEQUENCE"), e)
    var eku_str = _ext(37, False, _seq(_str(0x0C, "serverAuth")))
    e = _self_anchored(_wide(eku_str), now)
    assert_true(_has(e, "extKeyUsage: child not OID"), e)


def test_server_auth_after_another_purpose() raises:
    var now = _now(2031, 1, 1, 0, 0, 0)
    var client = _b(0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02)
    var server = _b(0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01)
    assert_equal(
        _self_anchored(_wide(_ext(37, False, _seq(_cat(client, server)))), now),
        "ok",
        "clientAuth then serverAuth",
    )
    var e = _self_anchored(_wide(_ext(37, False, _seq(client))), now)
    assert_true(_has(e, "Leaf extKeyUsage lacks serverAuth"), e)


# -----------------------------------------------------------------------------
# DN match and issuer CA
# -----------------------------------------------------------------------------


def test_issuer_dn_must_equal_issuer_subject() raises:
    var issuer = _cert_der(_name("ca"), _name("ca"), "20300101000000Z", "20320101000000Z", _bc_ca())
    var refused = String("cert 0 issuer DN != cert 1 subject DN")
    # Leaf names a one-attribute issuer; the issuer's subject has two
    # attributes, the first equal.
    var issuer2 = _cert_der(
        _seq(_cat(_atv(3, "ca"), _atv(10, "org"))),
        _seq(_cat(_atv(3, "ca"), _atv(10, "org"))),
        "20300101000000Z", "20320101000000Z", _bc_ca(),
    )
    var leaf = _cert_der(_name("ca"), _name("leaf"), "20300101000000Z", "20320101000000Z", List[UInt8]())
    var e = _pair(leaf, issuer2)
    assert_true(_has(e, refused), "shorter issuer DN: " + e)
    # Same value "ca" under organizationName instead of commonName.
    var leaf_o = _cert_der(_seq(_atv(10, "ca")), _name("leaf"), "20300101000000Z", "20320101000000Z", List[UInt8]())
    e = _pair(leaf_o, issuer)
    assert_true(_has(e, refused), "attribute type differs: " + e)


def test_issuer_basic_constraints_required() raises:
    var leaf = _cert_der(_name("ca"), _name("leaf"), "20300101000000Z", "20320101000000Z", List[UInt8]())
    var no_bc = _cert_der(_name("ca"), _name("ca"), "20300101000000Z", "20320101000000Z", List[UInt8]())
    var e = _pair(leaf, no_bc)
    assert_true(_has(e, "Issuer cert lacks basicConstraints extension"), e)
    var bc_set = _cert_der(
        _name("ca"), _name("ca"), "20300101000000Z", "20320101000000Z",
        _ext(19, False, _tlv(0x31, _b(0x01, 0x01, 0xFF))),
    )
    e = _pair(leaf, bc_set)
    assert_true(_has(e, "basicConstraints: not a SEQUENCE"), e)


def main() raises:
    test_time_cmp_each_field()
    test_window_edges_to_the_second()
    test_each_recognized_critical_extension_passes()
    test_unknown_critical_extension_is_refused()
    test_leaf_usage_value_types()
    test_server_auth_after_another_purpose()
    test_issuer_dn_must_equal_issuer_subject()
    test_issuer_basic_constraints_required()
    print("test_chain_policy: 8 tests PASS")
