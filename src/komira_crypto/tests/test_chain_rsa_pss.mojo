# =============================================================================
# komira_crypto/tests/test_chain_rsa_pss.mojo
#
# chain_verify's RSA-PSS link:
#   * a leaf signed RSASSA-PSS (SHA-256, MGF1-SHA-256, salt 32) by an
#     RSA-2048 CA verifies, and fails with one signature bit flipped;
#   * a link signed sha256WithRSAEncryption (PKCS#1 v1.5) is refused by name;
#   * the issuer's RSA key, refused when its SPKI is not rsaEncryption, when
#     the key is not SEQUENCE { INTEGER, INTEGER }, when the modulus is not
#     256 bytes (255 and 257 tried) or the exponent is wider than 8 bytes;
#     an 8-byte exponent passes the shape checks and reaches the verifier.
#
# Fixtures: the CA (self-signed, basicConstraints cA critical) and the leaf
# were made with Python `cryptography` 43 (CertificateBuilder.sign with
# rsa_padding=PSS(MGF1(SHA256), salt_length=32)) and checked with its
# verifier; validity 2030-01-01 to 2036-01-01.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.cert.x509 import X509Certificate, x509_parse_certificate
from komira_crypto.cert.chain import chain_verify


def _hex(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(0, len(b), 2):
        var hi = Int(b[i])
        var lo = Int(b[i + 1])
        hi = hi - 48 if hi < 58 else hi - 87
        lo = lo - 48 if lo < 58 else lo - 87
        out.append(UInt8(hi * 16 + lo))
    return out^


def _pss_issuer_hex() -> String:
    return (
        "308202be308201a6a003020102020101300d06092a864886f70d01010b050030183116301406035504030c0d6b6f6d69"
        + "726120707373206361301e170d3330303130313030303030305a170d3336303130313030303030305a30183116301406"
        + "035504030c0d6b6f6d6972612070737320636130820122300d06092a864886f70d01010105000382010f003082010a02"
        + "82010100c1d333f669ed6f66ff729bfc516139d3874963c6e34b9bc309fe83f5a0ebddb29711b7a42f31a975b1719e06"
        + "8da0773fe926b5428685e76d190523a544821e28dfd00c7c2da442f24737b07f265ef38e9550144a9ff0339f2424e7e0"
        + "07f9581a2278d20a7d8b57f84e902d486380912ed7869eac3bd300ebf330c1e3d9bf8838c3df008c7819b7466296ac4e"
        + "b4c12cb3193e513dbdaed2b623641b0f69776ff6a2c5688eedf5153e6cf8e7b072f1b2568b84309cab3aa5dce9463fb5"
        + "adc0230e5a9bcfa0906b89954d56e930357cf73315c9f493bb8499f2c29dbf0c8efaf01acb2624b0e22f337f26f2a7e0"
        + "e6afbb17accd88bfa59e1448b816ea7a81fd19470203010001a3133011300f0603551d130101ff040530030101ff300d"
        + "06092a864886f70d01010b050003820101000f7bcf0fd702b836df46beed1f22effd8762bfcf0d10198ac5b8397fb7e7"
        + "1723baa6c5e4eeb2080e6a41ed82faf72c7ff18f1f60cd1aeeea4be0be3df116091eb974d398cfa42b978daf144e78e3"
        + "be8dcb514ac00ad46bae577f17c503a4f874470bb1bc17ebc2fb7bd30a2c1a3bbc74aef66e7ea1a14d74c92856a4089e"
        + "ef1327a13e8b31393640d1fb18b0c8c6974f85de42d1f17fdd5dbebfcb4690b33d9c1b6e7226d838239586fefe4c0d59"
        + "1ed4e36ec887c84af1298623038dd55690898fc326ce3ac514eec074c21c93953905a67e7773a20f56b9cc13745e4e6f"
        + "887c0bdc457f6fe339df70fdc0842b67f6dbb68ffc0748698ad92534e1e248b9c366"
    )


def _pss_leaf_hex() -> String:
    return (
        "308202453081faa003020102020102304106092a864886f70d01010a3034a00f300d06096086480165030402010500a1"
        + "1c301a06092a864886f70d010108300d06096086480165030402010500a20302012030183116301406035504030c0d6b"
        + "6f6d69726120707373206361301e170d3330303130313030303030305a170d3336303130313030303030305a30183116"
        + "301406035504030c0d7073732e6c6561662e746573743059301306072a8648ce3d020106082a8648ce3d030107034200"
        + "04a205ceb1a325ded7ffdc1d9ce06dcc179a24e9840efe8a61831c12494e38ccdb987c1ddb1eb649ff73678606d70193"
        + "47f835bf42b4398086da88d6064367e500304106092a864886f70d01010a3034a00f300d060960864801650304020105"
        + "00a11c301a06092a864886f70d010108300d06096086480165030402010500a2030201200382010100757558e7340fc9"
        + "a170842260d804b20b56d2d7b68b44f5d93d5eb271756710823a5afd1c833f40e9d3ab75a657289107dc27c43966dea4"
        + "4cec858b08ea966cf92a7267646824ccbdf015eaa8ea5c3ad472af1b428347edd25ac262b878614520f86add87f83c29"
        + "cba105affd238f696956e7a2b471fe8e0a9f00bb92fe9139af6855d57695dc435caa7e4f33c73951461576fe5b5e1e4f"
        + "3fa0c1c4104c726c88ba85ab2619a57cbdef96bf5f939d93bbbd7ccb829bf0d490fbcba5d952649d5f04d91a9a845827"
        + "ae9fdc1f2aaa143db584387da5de8da401b6b8c88f94a3cd4f77680f7883cc4a60bda111c690ec152b00854c02a06d32"
        + "392cd05fc74bb7cab3"
    )


def _rsa_n_hex() -> String:
    return (
        "c1d333f669ed6f66ff729bfc516139d3874963c6e34b9bc309fe83f5a0ebddb29711b7a42f31a975b1719e068da0773f"
        + "e926b5428685e76d190523a544821e28dfd00c7c2da442f24737b07f265ef38e9550144a9ff0339f2424e7e007f9581a"
        + "2278d20a7d8b57f84e902d486380912ed7869eac3bd300ebf330c1e3d9bf8838c3df008c7819b7466296ac4eb4c12cb3"
        + "193e513dbdaed2b623641b0f69776ff6a2c5688eedf5153e6cf8e7b072f1b2568b84309cab3aa5dce9463fb5adc0230e"
        + "5a9bcfa0906b89954d56e930357cf73315c9f493bb8499f2c29dbf0c8efaf01acb2624b0e22f337f26f2a7e0e6afbb17"
        + "accd88bfa59e1448b816ea7a81fd1947"
    )


# -----------------------------------------------------------------------------
# DER builder (for issuers with hand-made RSA keys)
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


def _ascii(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for c in s.as_bytes():
        out.append(c)
    return out^


def _name(cn: String) -> List[UInt8]:
    return _seq(_tlv(0x31, _seq(_cat(_b(0x06, 0x03, 0x55, 0x04, 0x03), _tlv(0x0C, _ascii(cn))))))


def _alg_pss() -> List[UInt8]:
    return _seq(_b(0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0A))


def _alg_rsa() -> List[UInt8]:
    return _seq(_cat(_b(0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01), _b(0x05, 0x00)))


def _alg_ec() -> List[UInt8]:
    return _seq(_cat(_b(0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01), _b(0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07)))


def _bits(content: List[UInt8]) -> List[UInt8]:
    var v = List[UInt8]()
    v.append(0x00)
    for i in range(len(content)):
        v.append(content[i])
    return _tlv(0x03, v)


def _tbs(alg: List[UInt8], issuer: String, subject: String, spki: List[UInt8], exts: List[UInt8]) -> List[UInt8]:
    var validity = _seq(_cat(_tlv(0x18, _ascii("20300101000000Z")), _tlv(0x18, _ascii("20320101000000Z"))))
    return _seq(_cat(_tlv(0xA0, _b(0x02, 0x01, 0x02)), _b(0x02, 0x01, 0x05), alg, _name(issuer), validity, _name(subject), spki, exts))


def _ca_with_key(alg: List[UInt8], key: List[UInt8]) -> List[UInt8]:
    var bc = _seq(_cat(_b(0x06, 0x03, 0x55, 0x1D, 0x13), _b(0x01, 0x01, 0xFF), _tlv(0x04, _seq(_b(0x01, 0x01, 0xFF)))))
    var tbs = _tbs(_alg_pss(), "rsa ca", "rsa ca", _seq(_cat(alg, _bits(key))), _tlv(0xA3, _seq(bc)))
    return _seq(_cat(tbs, _alg_pss(), _bits(_b(0x01))))


def _pss_leaf_of_rsa_ca() -> List[UInt8]:
    var sig = List[UInt8]()
    for i in range(256):
        sig.append(UInt8((i * 37 + 11) & 0xFF))
    var tbs = _tbs(_alg_pss(), "rsa ca", "leaf", _seq(_cat(_alg_ec(), _bits(_b(0x04, 0x01)))), List[UInt8]())
    return _seq(_cat(tbs, _alg_pss(), _bits(sig)))


def _int_bytes(n: Int, first: Int) -> List[UInt8]:
    var v = List[UInt8]()
    v.append(UInt8(first))
    for _ in range(n - 1):
        v.append(0x5A)
    return _tlv(0x02, v)


# -----------------------------------------------------------------------------
# chain_verify driver
# -----------------------------------------------------------------------------


def _link(leaf: List[UInt8], issuer: List[UInt8]) raises -> String:
    var chain = List[X509Certificate]()
    chain.append(x509_parse_certificate(Span(leaf)))
    chain.append(x509_parse_certificate(Span(issuer)))
    var anchors = List[X509Certificate]()
    anchors.append(x509_parse_certificate(Span(issuer)))
    var now = (UInt16(2031), UInt8(1), UInt8(1), UInt8(0), UInt8(0), UInt8(0))
    try:
        if chain_verify(chain, anchors, now):
            return String("ok")
        return String("false")
    except e:
        return String(e)


def _refused(got: String, needle: String, what: String) raises:
    assert_true(got.find(needle) >= 0, what + ": got '" + got + "'")


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_pss_link_verifies() raises:
    var issuer = _hex(_pss_issuer_hex())
    var leaf = _hex(_pss_leaf_hex())
    assert_equal(_link(leaf, issuer), String("ok"), "RSA-PSS link")
    # The signature is the last BIT STRING of the leaf: flip its last bit.
    leaf[len(leaf) - 1] ^= 1
    _refused(_link(leaf, issuer), "signature verification failed at link 0 -> 1", "flipped bit")


def test_pkcs1_v15_link_is_refused_by_name() raises:
    # The CA is self-signed with sha256WithRSAEncryption: as its own child it
    # is a PKCS#1 v1.5 link.
    var issuer = _hex(_pss_issuer_hex())
    _refused(_link(issuer, issuer), "PKCS#1 v1.5 RSA signatures are not supported", "self link")


def test_issuer_key_is_not_rsa() raises:
    var ca = _ca_with_key(_alg_ec(), _b(0x04, 0x01, 0x02))
    _refused(_link(_pss_leaf_of_rsa_ca(), ca), "RSA pubkey extract: SPKI algo OID is not rsaEncryption", "EC SPKI")


def test_issuer_rsa_key_structure() raises:
    var n = _int_bytes(257, 0x00)  # 0x00 then 256 bytes: a 256-byte modulus
    var e = _b(0x02, 0x03, 0x01, 0x00, 0x01)
    _refused(_link(_pss_leaf_of_rsa_ca(), _ca_with_key(_alg_rsa(), n.copy())), "RSA pubkey: SPKI inner not SEQUENCE", "bare INTEGER")
    _refused(
        _link(_pss_leaf_of_rsa_ca(), _ca_with_key(_alg_rsa(), _seq(_cat(_b(0x04, 0x01, 0x05), e)))),
        "RSA pubkey: modulus not INTEGER", "modulus OCTET STRING",
    )
    _refused(
        _link(_pss_leaf_of_rsa_ca(), _ca_with_key(_alg_rsa(), _seq(_cat(n, _b(0x04, 0x01, 0x03))))),
        "RSA pubkey: exponent not INTEGER", "exponent OCTET STRING",
    )


def test_issuer_modulus_and_exponent_sizes() raises:
    var e = _b(0x02, 0x03, 0x01, 0x00, 0x01)
    _refused(
        _link(_pss_leaf_of_rsa_ca(), _ca_with_key(_alg_rsa(), _seq(_cat(_int_bytes(255, 0x5A), e)))),
        "only 2048-bit RSA is supported; modulus len=255", "255-byte modulus",
    )
    _refused(
        _link(_pss_leaf_of_rsa_ca(), _ca_with_key(_alg_rsa(), _seq(_cat(_int_bytes(257, 0x5A), e)))),
        "only 2048-bit RSA is supported; modulus len=257", "257-byte modulus",
    )
    var n = _hex(_rsa_n_hex())
    var n_der = _tlv(0x02, _cat(_b(0x00), n))  # the modulus's top bit is set
    _refused(
        _link(_pss_leaf_of_rsa_ca(), _ca_with_key(_alg_rsa(), _seq(_cat(n_der, _int_bytes(9, 0x01))))),
        "RSA-PSS chain link: exponent > 8 bytes not supported", "9-byte exponent",
    )
    # 8 bytes is accepted; the filler signature then fails to verify.
    _refused(
        _link(_pss_leaf_of_rsa_ca(), _ca_with_key(_alg_rsa(), _seq(_cat(n_der, _int_bytes(8, 0x01))))),
        "signature verification failed at link 0 -> 1", "8-byte exponent",
    )


def main() raises:
    test_pss_link_verifies()
    test_pkcs1_v15_link_is_refused_by_name()
    test_issuer_key_is_not_rsa()
    test_issuer_rsa_key_structure()
    test_issuer_modulus_and_exponent_sizes()
    print("test_chain_rsa_pss: 5 tests PASS")
