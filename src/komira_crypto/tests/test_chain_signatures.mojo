# =============================================================================
# komira_crypto/tests/test_chain_signatures.mojo
#
# chain_verify's signature step on certificates assembled and signed here
# (ECDSA P-256 / P-384 with this package's RFC 6979 signers):
#   * a terminal certificate that is not itself an anchor but is signed by
#     one (the anchor-signs-terminal case), and the same with its signature
#     broken;
#   * DER signatures whose r or s has a leading zero byte, so the INTEGER is
#     shorter than the field and must be left-padded (P-256 and P-384; the
#     signers are deterministic, so the serial number that yields one is
#     fixed);
#   * the issuer key a signature algorithm needs, refused when the issuer's
#     SPKI is another algorithm, the wrong length, or a compressed point
#     (P-256, P-384, Ed25519);
#   * ECDSA signature values that are not SEQUENCE { INTEGER, INTEGER } or
#     whose r is wider than the field;
#   * a signature algorithm the chain does not support.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.cert.x509 import X509Certificate, x509_parse_certificate
from komira_crypto.cert.chain import chain_verify
from komira_crypto.ecdsa_p256 import (
    ecdsa_p256_sign_deterministic,
    ecdsa_p256_generate_pubkey,
)
from komira_crypto.ecdsa_p384 import (
    ecdsa_p384_sign_deterministic,
    ecdsa_p384_generate_pubkey,
)


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


def _seq(content: List[UInt8]) -> List[UInt8]:
    return _tlv(0x30, content)


def _name(cn: String) -> List[UInt8]:
    var v = List[UInt8]()
    for c in cn.as_bytes():
        v.append(c)
    return _seq(_tlv(0x31, _seq(_cat(_b(0x06, 0x03, 0x55, 0x04, 0x03), _tlv(0x0C, v)))))


def _int(v: List[UInt8]) -> List[UInt8]:
    """Minimal positive DER INTEGER of the big-endian magnitude `v`."""
    var i = 0
    while i < len(v) - 1 and v[i] == 0:
        i += 1
    var body = List[UInt8]()
    if v[i] >= 0x80:
        body.append(0)
    for j in range(i, len(v)):
        body.append(v[j])
    return _tlv(0x02, body)


def _alg_p256() -> List[UInt8]:
    return _seq(_b(0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02))


def _alg_p384() -> List[UInt8]:
    return _seq(_b(0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03))


def _alg_ed25519() -> List[UInt8]:
    return _seq(_b(0x06, 0x03, 0x2B, 0x65, 0x70))


def _alg_md5_rsa() -> List[UInt8]:
    # md5WithRSAEncryption 1.2.840.113549.1.1.4
    return _seq(_cat(_b(0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x04), _b(0x05, 0x00)))


def _ec_alg(curve: List[UInt8]) -> List[UInt8]:
    return _seq(_cat(_b(0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01), curve))


def _p256_curve() -> List[UInt8]:
    return _b(0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07)


def _p384_curve() -> List[UInt8]:
    return _b(0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22)


def _spki_raw(alg: List[UInt8], key: List[UInt8]) -> List[UInt8]:
    var bits = List[UInt8]()
    bits.append(0x00)
    for i in range(len(key)):
        bits.append(key[i])
    return _seq(_cat(alg, _tlv(0x03, bits)))


def _point(prefix: Int, xy_len: Int, fill: Int) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(prefix))
    for _ in range(xy_len):
        out.append(UInt8(fill))
    return out^


def _bc_ca_exts() -> List[UInt8]:
    var bc = _seq(_cat(_b(0x06, 0x03, 0x55, 0x1D, 0x13), _b(0x01, 0x01, 0xFF), _tlv(0x04, _seq(_b(0x01, 0x01, 0xFF)))))
    return _tlv(0xA3, _seq(bc))


def _tbs(
    serial: Int,
    alg: List[UInt8],
    issuer: List[UInt8],
    subject: List[UInt8],
    spki: List[UInt8],
    exts: List[UInt8],
) -> List[UInt8]:
    var validity = _seq(_cat(_tlv(0x18, _ascii("20300101000000Z")), _tlv(0x18, _ascii("20320101000000Z"))))
    return _seq(
        _cat(
            _tlv(0xA0, _b(0x02, 0x01, 0x02)),
            _int(_b(serial >> 8, serial & 0xFF)),
            alg, issuer, validity, subject, spki, exts,
        )
    )


def _ascii(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for c in s.as_bytes():
        out.append(c)
    return out^


def _assemble(tbs: List[UInt8], alg: List[UInt8], sig_value: List[UInt8]) -> List[UInt8]:
    var bits = List[UInt8]()
    bits.append(0x00)
    for i in range(len(sig_value)):
        bits.append(sig_value[i])
    return _seq(_cat(tbs, alg, _tlv(0x03, bits)))


def _rs_der(raw: List[UInt8], half: Int) -> List[UInt8]:
    var r = List[UInt8]()
    var s = List[UInt8]()
    for i in range(half):
        r.append(raw[i])
        s.append(raw[half + i])
    return _seq(_cat(_int(r), _int(s)))


# -----------------------------------------------------------------------------
# Keys and signers
# -----------------------------------------------------------------------------


def _priv(n: Int, seed: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((seed + 7 * i) & 0x7F))  # top bit clear: below n
    return out^


def _sign256(priv: List[UInt8], msg: List[UInt8]) raises -> List[UInt8]:
    var sig = ecdsa_p256_sign_deterministic(Span(priv), Span(msg))
    var out = List[UInt8]()
    for i in range(64):
        out.append(sig[i])
    return out^


def _sign384(priv: List[UInt8], msg: List[UInt8]) raises -> List[UInt8]:
    var sig = ecdsa_p384_sign_deterministic(Span(priv), Span(msg))
    var out = List[UInt8]()
    for i in range(96):
        out.append(sig[i])
    return out^


def _spki256(priv: List[UInt8]) -> List[UInt8]:
    var pub = ecdsa_p256_generate_pubkey(Span(priv))
    var key = List[UInt8]()
    key.append(0x04)
    for i in range(64):
        key.append(pub[i])
    return _spki_raw(_ec_alg(_p256_curve()), key)


def _spki384(priv: List[UInt8]) -> List[UInt8]:
    var pub = ecdsa_p384_generate_pubkey(Span(priv))
    var key = List[UInt8]()
    key.append(0x04)
    for i in range(96):
        key.append(pub[i])
    return _spki_raw(_ec_alg(_p384_curve()), key)


def _ca256(priv: List[UInt8]) raises -> List[UInt8]:
    var tbs = _tbs(1, _alg_p256(), _name("ca"), _name("ca"), _spki256(priv), _bc_ca_exts())
    return _assemble(tbs, _alg_p256(), _rs_der(_sign256(priv, tbs), 32))


def _ca384(priv: List[UInt8]) raises -> List[UInt8]:
    var tbs = _tbs(1, _alg_p384(), _name("ca"), _name("ca"), _spki384(priv), _bc_ca_exts())
    return _assemble(tbs, _alg_p384(), _rs_der(_sign384(priv, tbs), 48))


def _ca_with_spki(spki: List[UInt8], alg: List[UInt8]) -> List[UInt8]:
    """An issuer CA whose key is `spki`; its own signature is never checked."""
    var tbs = _tbs(1, alg, _name("ca"), _name("ca"), spki, _bc_ca_exts())
    return _assemble(tbs, alg, _seq(_cat(_b(0x02, 0x01, 0x01), _b(0x02, 0x01, 0x01))))


def _leaf_with(alg: List[UInt8], sig_value: List[UInt8]) -> List[UInt8]:
    var tbs = _tbs(9, alg, _name("ca"), _name("leaf"), _spki_raw(_ec_alg(_p256_curve()), _point(4, 64, 3)), List[UInt8]())
    return _assemble(tbs, alg, sig_value)


# -----------------------------------------------------------------------------
# chain_verify drivers
# -----------------------------------------------------------------------------


def _now() -> Tuple[UInt16, UInt8, UInt8, UInt8, UInt8, UInt8]:
    return (UInt16(2031), UInt8(1), UInt8(1), UInt8(0), UInt8(0), UInt8(0))


def _verify(chain_der: List[List[UInt8]], anchor_der: List[List[UInt8]]) raises -> String:
    var chain = List[X509Certificate]()
    for i in range(len(chain_der)):
        chain.append(x509_parse_certificate(Span(chain_der[i])))
    var anchors = List[X509Certificate]()
    for i in range(len(anchor_der)):
        anchors.append(x509_parse_certificate(Span(anchor_der[i])))
    try:
        if chain_verify(chain, anchors, _now()):
            return String("ok")
        return String("false")
    except e:
        return String(e)


def _link(leaf: List[UInt8], issuer: List[UInt8]) raises -> String:
    var chain = List[List[UInt8]]()
    chain.append(leaf.copy())
    chain.append(issuer.copy())
    var anchors = List[List[UInt8]]()
    anchors.append(issuer.copy())
    return _verify(chain, anchors)


def _refused(got: String, needle: String, what: String) raises:
    assert_true(got.find(needle) >= 0, what + ": got '" + got + "'")


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_terminal_signed_by_an_anchor() raises:
    var ca_priv = _priv(32, 0x21)
    var ca = _ca256(ca_priv)
    var leaf_priv = _priv(32, 0x35)
    var tbs = _tbs(2, _alg_p256(), _name("ca"), _name("leaf"), _spki256(leaf_priv), List[UInt8]())
    var leaf = _assemble(tbs, _alg_p256(), _rs_der(_sign256(ca_priv, tbs), 32))
    var chain = List[List[UInt8]]()
    chain.append(leaf.copy())
    var anchors = List[List[UInt8]]()
    anchors.append(ca.copy())
    assert_equal(_verify(chain, anchors), String("ok"), "leaf signed by the anchor")
    # The same leaf signed by its own key instead: no anchor signed it.
    var forged = _assemble(tbs, _alg_p256(), _rs_der(_sign256(leaf_priv, tbs), 32))
    var chain2 = List[List[UInt8]]()
    chain2.append(forged.copy())
    _refused(_verify(chain2, anchors), "does not chain to any trust anchor", "self-signed leaf")


def _short_component_link_256(want_short_s: Bool) raises -> Int:
    var ca_priv = _priv(32, 0x21)
    var ca = _ca256(ca_priv)
    for serial in range(2, 6000):
        var tbs = _tbs(serial, _alg_p256(), _name("ca"), _name("leaf"), _spki_raw(_ec_alg(_p256_curve()), _point(4, 64, 3)), List[UInt8]())
        var raw = _sign256(ca_priv, tbs)
        var lead = raw[32] if want_short_s else raw[0]
        if lead != 0:
            continue
        var der = _rs_der(raw, 32)
        var leaf = _assemble(tbs, _alg_p256(), der)
        assert_equal(_link(leaf, ca), String("ok"), "short component verifies")
        return serial
    return -1


def test_p256_short_r_and_short_s_are_padded() raises:
    assert_true(_short_component_link_256(False) > 0, "an r with a leading zero byte")
    assert_true(_short_component_link_256(True) > 0, "an s with a leading zero byte")


def _short_component_link_384(want_short_s: Bool) raises -> Int:
    var ca_priv = _priv(48, 0x13)
    var ca = _ca384(ca_priv)
    for serial in range(2, 6000):
        var tbs = _tbs(serial, _alg_p384(), _name("ca"), _name("leaf"), _spki_raw(_ec_alg(_p256_curve()), _point(4, 64, 3)), List[UInt8]())
        var raw = _sign384(ca_priv, tbs)
        var lead = raw[48] if want_short_s else raw[0]
        if lead != 0:
            continue
        var leaf = _assemble(tbs, _alg_p384(), _rs_der(raw, 48))
        assert_equal(_link(leaf, ca), String("ok"), "short component verifies")
        return serial
    return -1


def test_p384_short_r_and_short_s_are_padded() raises:
    assert_true(_short_component_link_384(False) > 0, "an r with a leading zero byte")
    assert_true(_short_component_link_384(True) > 0, "an s with a leading zero byte")


def test_issuer_key_shape_for_p256() raises:
    var sig = _seq(_cat(_b(0x02, 0x01, 0x01), _b(0x02, 0x01, 0x01)))
    var leaf = _leaf_with(_alg_p256(), sig)
    _refused(
        _link(leaf, _ca_with_spki(_spki_raw(_alg_ed25519(), _point(7, 31, 7)), _alg_p256())),
        "EC pubkey extract: SPKI algo OID is not ecPublicKey", "Ed25519 issuer",
    )
    _refused(
        _link(leaf, _ca_with_spki(_spki_raw(_ec_alg(_p256_curve()), _point(4, 63, 7)), _alg_p256())),
        "EC pubkey extract: expected 65 bytes", "64-byte point",
    )
    _refused(
        _link(leaf, _ca_with_spki(_spki_raw(_ec_alg(_p256_curve()), _point(3, 64, 7)), _alg_p256())),
        "EC pubkey extract: not uncompressed form", "0x03 prefix",
    )


def test_issuer_key_shape_for_p384() raises:
    var sig = _seq(_cat(_b(0x02, 0x01, 0x01), _b(0x02, 0x01, 0x01)))
    var leaf = _leaf_with(_alg_p384(), sig)
    _refused(
        _link(leaf, _ca_with_spki(_spki_raw(_alg_ed25519(), _point(7, 31, 7)), _alg_p384())),
        "EC-P-384 pubkey extract: SPKI algo OID is not ecPublicKey", "Ed25519 issuer",
    )
    _refused(
        _link(leaf, _ca_with_spki(_spki_raw(_ec_alg(_p384_curve()), _point(4, 64, 7)), _alg_p384())),
        "EC-P-384 pubkey extract: expected 97 bytes", "P-256-sized point",
    )
    _refused(
        _link(leaf, _ca_with_spki(_spki_raw(_ec_alg(_p384_curve()), _point(2, 96, 7)), _alg_p384())),
        "EC-P-384 pubkey extract: not uncompressed form", "0x02 prefix",
    )


def test_issuer_key_shape_for_ed25519() raises:
    var sig = List[UInt8]()
    for _ in range(64):
        sig.append(0x01)
    var leaf = _leaf_with(_alg_ed25519(), sig)
    _refused(
        _link(leaf, _ca_with_spki(_spki_raw(_ec_alg(_p256_curve()), _point(4, 64, 7)), _alg_ed25519())),
        "Ed25519 pubkey extract: SPKI algo OID is not Ed25519", "EC issuer",
    )
    _refused(
        _link(leaf, _ca_with_spki(_spki_raw(_alg_ed25519(), _point(7, 32, 7)), _alg_ed25519())),
        "Ed25519 pubkey extract: expected 32 bytes", "33-byte key",
    )


def _sig_shapes(alg: List[UInt8], ca: List[UInt8], field: Int, prefix: String) raises:
    var one = _b(0x02, 0x01, 0x01)
    var wide = List[UInt8]()
    wide.append(0x01)
    for _ in range(field):
        wide.append(0x02)
    _refused(
        _link(_leaf_with(alg, _tlv(0x31, _cat(one, one))), ca),
        prefix + " sig: not SEQUENCE", "SET",
    )
    _refused(
        _link(_leaf_with(alg, _seq(_cat(_b(0x04, 0x01, 0x01), one))), ca),
        prefix + " sig: r not INTEGER", "r OCTET STRING",
    )
    _refused(
        _link(_leaf_with(alg, _seq(_cat(one, _b(0x04, 0x01, 0x01)))), ca),
        prefix + " sig: s not INTEGER", "s OCTET STRING",
    )
    _refused(
        _link(_leaf_with(alg, _seq(_cat(_tlv(0x02, wide), one))), ca),
        prefix + " sig: r or s > " + String(field) + " bytes", "r one byte too wide",
    )
    _refused(
        _link(_leaf_with(alg, _seq(_cat(one, _tlv(0x02, wide)))), ca),
        prefix + " sig: r or s > " + String(field) + " bytes", "s one byte too wide",
    )


def test_ecdsa_signature_value_shapes() raises:
    _sig_shapes(_alg_p256(), _ca256(_priv(32, 0x21)), 32, "ECDSA")
    _sig_shapes(_alg_p384(), _ca384(_priv(48, 0x13)), 48, "ECDSA-P384")


def test_unsupported_signature_algorithm() raises:
    var ca = _ca256(_priv(32, 0x21))
    var leaf = _leaf_with(_alg_md5_rsa(), _b(0x00, 0x01))
    _refused(_link(leaf, ca), "Cert chain: unsupported signature algorithm OID", "md5WithRSA")


def main() raises:
    test_terminal_signed_by_an_anchor()
    test_p256_short_r_and_short_s_are_padded()
    test_p384_short_r_and_short_s_are_padded()
    test_issuer_key_shape_for_p256()
    test_issuer_key_shape_for_p384()
    test_issuer_key_shape_for_ed25519()
    test_ecdsa_signature_value_shapes()
    test_unsupported_signature_algorithm()
    print("test_chain_signatures: 8 tests PASS")
