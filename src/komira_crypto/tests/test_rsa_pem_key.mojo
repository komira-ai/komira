# =============================================================================
# komira_crypto/tests/test_rsa_pem_key.mojo -- rsa_pkcs8_der_from_pem.
# =============================================================================
#
# The function removes PEM armor and checks the PKCS#8 PrivateKeyInfo
# envelope; it leaves the RSAPrivateKey inside to AWS-LC. So every DER here is
# BUILT in the test from its ASN.1 fields, and the private-key OCTET STRING
# holds a placeholder, not a key: each case differs from the accepted one in
# exactly the field it is about, and no key material is in the tree.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_encoding import error_kind, pem_encode
from komira_crypto import rsa_pkcs8_der_from_pem, rsa_sha256_sign


# --- DER building blocks ----------------------------------------------------


def _tlv(tag: UInt8, content: List[UInt8]) -> List[UInt8]:
    """One short-form DER TLV (every value here is under 128 bytes)."""
    var out = List[UInt8]()
    out.append(tag)
    out.append(UInt8(len(content)))
    for b in content:
        out.append(b)
    return out^


def _cat(a: List[UInt8], b: List[UInt8]) -> List[UInt8]:
    var out = a.copy()
    for x in b:
        out.append(x)
    return out^


def _bytes(*values: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for v in values:
        out.append(UInt8(v))
    return out^


def _rsa_oid() -> List[UInt8]:
    """1.2.840.113549.1.1.1, rsaEncryption."""
    return _bytes(0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01)


def _algorithm(oid: List[UInt8]) -> List[UInt8]:
    """AlgorithmIdentifier { oid, NULL }."""
    return _tlv(0x30, _cat(_tlv(0x06, oid), _bytes(0x05, 0x00)))


def _placeholder_key() -> List[UInt8]:
    """An RSAPrivateKey-shaped SEQUENCE holding only `version 0`. It is the
    right SHAPE for the envelope and is not a key: AWS-LC refuses it."""
    return _tlv(0x30, _tlv(0x02, _bytes(0x00)))


def _pki(
    version: List[UInt8], algorithm: List[UInt8], key: List[UInt8]
) -> List[UInt8]:
    """PrivateKeyInfo { version, algorithm, privateKey OCTET STRING }."""
    var body = _cat(_cat(_tlv(0x02, version), algorithm), _tlv(0x04, key))
    return _tlv(0x30, body)


def _good_der() -> List[UInt8]:
    return _pki(_bytes(0x00), _algorithm(_rsa_oid()), _placeholder_key())


def _pem(label: String, der: List[UInt8]) raises -> String:
    return pem_encode(label, Span[UInt8, origin_of(der)](der))


def _outcome(pem: String) -> String:
    """`OK`, or the message rsa_pkcs8_der_from_pem raised."""
    try:
        _ = rsa_pkcs8_der_from_pem(pem)
    except e:
        return String(e)
    return String("OK")


def _refused(pem: String, detail: String) raises:
    var msg = _outcome(pem)
    assert_true(
        msg.startswith("rsa_pkcs8_der_from_pem: "), "unexpected: " + msg
    )
    assert_true(detail in msg, "want '" + detail + "', got: " + msg)


def _refused_der(der: List[UInt8], detail: String) raises:
    _refused(_pem("PRIVATE KEY", der), detail)


def _assert_no_body_window(pem: String, msg: String) raises:
    """No 8 consecutive base64 symbols of `pem`'s body appear in `msg`: the
    message echoes no part of the key, at any alignment."""
    var body = String("")
    for line in pem.split("\n"):
        if line.byte_length() > 0 and not String(line).startswith("-----"):
            body += String(line)
    assert_true(body.byte_length() >= 8)
    for i in range(body.byte_length() - 7):
        assert_false(body[byte = i : i + 8] in msg, msg)


def _assert_bytes(got: List[UInt8], want: List[UInt8]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


# --- accepted ---------------------------------------------------------------


def test_returns_the_der_of_a_private_key_block() raises:
    """THE CONTROL: every refusal below is one field away from this."""
    var der = _good_der()
    var pem = _pem("PRIVATE KEY", der)
    _assert_bytes(rsa_pkcs8_der_from_pem(pem), der)
    # The Span overload, which the String one forwards to.
    _assert_bytes(rsa_pkcs8_der_from_pem(pem.as_bytes()), der)


def test_accepts_explanatory_text_and_crlf() raises:
    var der = _good_der()
    var block = _pem("PRIVATE KEY", der)
    var crlf = String("")
    for line in block.split("\n"):
        if line.byte_length() > 0:
            crlf += String(line) + "\r\n"
    var pem = String("Service account key\r\n") + crlf + "trailing text\r\n"
    _assert_bytes(rsa_pkcs8_der_from_pem(pem), der)


def test_optional_fields_after_the_key_are_left_alone() raises:
    """RFC 5208 `attributes [0] IMPLICIT` may follow the key OCTET STRING."""
    var body = _cat(
        _cat(_tlv(0x02, _bytes(0x00)), _algorithm(_rsa_oid())),
        _tlv(0x04, _placeholder_key()),
    )
    var der = _tlv(0x30, _cat(body, _tlv(0xA0, List[UInt8]())))
    _assert_bytes(rsa_pkcs8_der_from_pem(_pem("PRIVATE KEY", der)), der)


def test_the_rsa_key_itself_is_left_to_aws_lc() raises:
    """The envelope check does not claim the key is valid: the placeholder
    passes it, and the signer is the one that refuses it."""
    var pem = _pem("PRIVATE KEY", _good_der())
    var der = rsa_pkcs8_der_from_pem(pem)
    var msg = String("message").as_bytes()
    var err = String("OK")
    try:
        _ = rsa_sha256_sign(Span[UInt8, origin_of(der)](der), msg)
    except e:
        err = String(e)
    assert_true(err != String("OK"), "a placeholder key must not sign")
    # Refused where the key is parsed, and not for some other reason (an
    # allocation, a digest), and without any of the key in the message.
    assert_true("EVP_parse_private_key failed" in err, err)
    _assert_no_body_window(pem, err)


# --- refused by label -------------------------------------------------------


def test_pkcs1_rsa_private_key_is_refused_by_name() raises:
    _refused(_pem("RSA PRIVATE KEY", _good_der()), "PKCS#1 'RSA PRIVATE KEY'")
    _refused(_pem("RSA PRIVATE KEY", _good_der()), "openssl pkcs8 -topk8 -nocrypt")


def test_encrypted_private_key_is_refused_by_name() raises:
    _refused(
        _pem("ENCRYPTED PRIVATE KEY", _good_der()),
        "'ENCRYPTED PRIVATE KEY'; encrypted keys are not supported",
    )


def test_other_labels_and_armor_are_komira_encoding_errors() raises:
    var cert = _outcome(_pem("CERTIFICATE", _good_der()))
    assert_equal(error_kind(Error(cert)), "LabelMismatch", cert)
    var public = _outcome(_pem("PUBLIC KEY", _good_der()))
    assert_equal(error_kind(Error(public)), "LabelMismatch", public)
    var bare = _outcome(String("no armor here\n"))
    assert_equal(error_kind(Error(bare)), "InvalidBoundary", bare)
    var empty = _outcome(String(""))
    assert_equal(error_kind(Error(empty)), "InvalidBoundary", empty)


# --- refused by structure ---------------------------------------------------


def test_not_a_sequence() raises:
    _refused_der(_tlv(0x02, _bytes(0x00)), "no outer SEQUENCE")
    # A SET (0x31) is constructed but is not a SEQUENCE.
    var set_ = _good_der()
    set_[0] = UInt8(0x31)
    _refused_der(set_, "no outer SEQUENCE")


def test_outer_length_and_trailer() raises:
    var long = _good_der()
    long[1] = long[1] + UInt8(1)
    _refused_der(long, "no outer SEQUENCE")
    var trailer = _good_der()
    trailer.append(UInt8(0x00))
    trailer.append(UInt8(0x00))
    _refused_der(trailer, "bytes after the outer SEQUENCE")
    _refused_der(_tlv(0x30, List[UInt8]()), "no version INTEGER")


def test_version_must_be_zero() raises:
    _refused_der(
        _pki(_bytes(0x01), _algorithm(_rsa_oid()), _placeholder_key()),
        "version is not 0 (v1)",
    )
    _refused_der(
        _pki(_bytes(0x00, 0x00), _algorithm(_rsa_oid()), _placeholder_key()),
        "version is not 0 (v1)",
    )
    var no_version = _tlv(
        0x30, _cat(_algorithm(_rsa_oid()), _tlv(0x04, _placeholder_key()))
    )
    _refused_der(no_version, "no version INTEGER")


def test_algorithm_must_be_rsa_encryption() raises:
    # id-ecPublicKey, 1.2.840.10045.2.1.
    _refused_der(
        _pki(
            _bytes(0x00),
            _algorithm(_bytes(0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01)),
            _placeholder_key(),
        ),
        "not rsaEncryption",
    )
    # rsassaPss, 1.2.840.113549.1.1.10: one byte away from rsaEncryption.
    _refused_der(
        _pki(
            _bytes(0x00),
            _algorithm(_bytes(0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0A)),
            _placeholder_key(),
        ),
        "not rsaEncryption",
    )
    # pkcs-1, 1.2.840.113549.1.1: a prefix of rsaEncryption.
    _refused_der(
        _pki(
            _bytes(0x00),
            _algorithm(_bytes(0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01)),
            _placeholder_key(),
        ),
        "not rsaEncryption",
    )
    # Ed25519, 1.3.101.112, with no parameters.
    _refused_der(
        _pki(
            _bytes(0x00),
            _tlv(0x30, _tlv(0x06, _bytes(0x2B, 0x65, 0x70))),
            _placeholder_key(),
        ),
        "not rsaEncryption",
    )
    _refused_der(
        _pki(_bytes(0x00), _tlv(0x30, List[UInt8]()), _placeholder_key()),
        "no algorithm OBJECT IDENTIFIER",
    )
    _refused_der(
        _pki(_bytes(0x00), _tlv(0x06, _rsa_oid()), _placeholder_key()),
        "no privateKeyAlgorithm SEQUENCE",
    )


def test_private_key_octet_string_is_required() raises:
    var no_key = _tlv(0x30, _cat(_tlv(0x02, _bytes(0x00)), _algorithm(_rsa_oid())))
    _refused_der(no_key, "no privateKey OCTET STRING")
    _refused_der(
        _pki(_bytes(0x00), _algorithm(_rsa_oid()), List[UInt8]()),
        "no privateKey OCTET STRING",
    )
    # The key as a bare SEQUENCE, not wrapped in an OCTET STRING.
    var bare = _tlv(
        0x30,
        _cat(
            _cat(_tlv(0x02, _bytes(0x00)), _algorithm(_rsa_oid())),
            _placeholder_key(),
        ),
    )
    _refused_der(bare, "no privateKey OCTET STRING")


def _marker_key() -> List[UInt8]:
    """A key slot that holds a distinctive marker, so a message that echoed
    the key would show it: SEQUENCE { OCTET STRING "KEYMARKER-..." }."""
    var marker = String("KEYMARKER-7f3a9c-private-exponent-bytes")
    var raw = List[UInt8]()
    for b in marker.as_bytes():
        raw.append(b)
    return _tlv(0x30, _tlv(0x04, raw))


def test_messages_carry_no_input_bytes() raises:
    """The input is a private key: no refusal may echo any of it, neither
    the label refusals nor the ones raised inside the DER check, whose key
    slot carries a marker here."""
    var key = _marker_key()
    var cases = List[String]()
    # Refused on the label, before any decoding.
    var good = _pki(_bytes(0x00), _algorithm(_rsa_oid()), key)
    cases.append(_pem("RSA PRIVATE KEY", good))
    cases.append(_pem("ENCRYPTED PRIVATE KEY", good))
    cases.append(_pem("CERTIFICATE", good))
    # Refused inside the PrivateKeyInfo check, with the marker decoded.
    var v1 = _pki(_bytes(0x01), _algorithm(_rsa_oid()), key)
    cases.append(_pem("PRIVATE KEY", v1))
    cases.append(
        _pem(
            "PRIVATE KEY",
            _pki(
                _bytes(0x00),
                _algorithm(_bytes(0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01)),
                key,
            ),
        )
    )
    var trailer = good.copy()
    trailer.append(UInt8(0x00))
    trailer.append(UInt8(0x00))
    cases.append(_pem("PRIVATE KEY", trailer))
    var bare = _tlv(
        0x30, _cat(_cat(_tlv(0x02, _bytes(0x00)), _algorithm(_rsa_oid())), key)
    )
    cases.append(_pem("PRIVATE KEY", bare))
    for i in range(len(cases)):
        ref c = cases[i]
        var msg = _outcome(c)
        assert_true(msg != String("OK"), msg)
        if i >= 3:  # past the label: refused by the DER check itself
            assert_true(msg.startswith("rsa_pkcs8_der_from_pem: "), msg)
        assert_false("KEYMARKER" in msg, msg)
        assert_false("private-exponent" in msg, msg)
        _assert_no_body_window(c, msg)
    # The control: the same key slot, in a good envelope, is accepted.
    _assert_bytes(rsa_pkcs8_der_from_pem(_pem("PRIVATE KEY", good)), good)


def main() raises:
    test_returns_the_der_of_a_private_key_block()
    test_accepts_explanatory_text_and_crlf()
    test_optional_fields_after_the_key_are_left_alone()
    test_the_rsa_key_itself_is_left_to_aws_lc()
    test_pkcs1_rsa_private_key_is_refused_by_name()
    test_encrypted_private_key_is_refused_by_name()
    test_other_labels_and_armor_are_komira_encoding_errors()
    test_not_a_sequence()
    test_outer_length_and_trailer()
    test_version_must_be_zero()
    test_algorithm_must_be_rsa_encryption()
    test_private_key_octet_string_is_required()
    test_messages_carry_no_input_bytes()
    print("test_rsa_pem_key: OK")
